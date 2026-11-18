# The TxID rewrite after CommitEnd (gap 22)

This note covers the window between `CommitEnd` and `FinalizeCommit`, where a
commit rewrites its row versions from a TxID to its commit timestamp. The
rewrite resets `materialized_at`. A checkpoint pass inside the window can stamp
a version and prune its dirty key, and the rewrite then clears the stamp.

Line numbers are for turso main 9cf2de2d8. The replay test pins 0c9fe0dd,
which has the same code. `mod.rs` is `core/mvcc/database/mod.rs`, `ck.rs` is
`core/mvcc/database/checkpoint.rs` (named `checkpoint_state_machine.rs` at the
pin).

## Engine behavior

1. `CommitEnd` stores `Committed(end_ts)` in `txs` and moves to
   `RewriteLiveVersions` (mod.rs:3625-3652).
2. `step_rewrite_live_versions` rewrites `MVCC_COMMIT_BATCH_SIZE` (1024) write
   set entries per call and yields between chunks (mod.rs:3016-3051, 1536).
   It calls `rewrite_txid_to_timestamp` (mod.rs:10832-10843). That calls
   `set_begin` or `set_end`, and both set `materialized_at = ORIGIN`
   (mod.rs:10812-10825).
3. `FinalizeCommit` releases the pager commit lock (mod.rs:3669), then
   `publish_committed_tx` raises `last_committed_tx_ts` (mod.rs:3673,
   7366-7381).
4. `checkpoint_snapshot_ts` is `min(last_committed_tx_ts, lowest Preparing
   end_ts - 1)` (mod.rs:7884-7899). A commit in the window is `Committed`, not
   `Preparing`, so it does not clamp the snapshot. Its `end_ts` is above the
   snapshot unless a later commit raised `last_committed_tx_ts` first.
5. A pass collects a key from the dirty map (ck.rs:1251-1275).
   `committed_ts` resolves a TxID through `txs` (ck.rs:1749-1759), and
   `stamp_chain_materialized` does the same (mod.rs:8694-8720). So a version
   that still carries the TxID is collected and stamped like a rewritten one.
   `prune_dirty_keys` then removes the key, because its stamp did not change
   (ck.rs:1663-1680).
6. GC Rule 2 and Rule 3 need `materialized_at != ORIGIN` (mod.rs:8643-8645).

## When the window opens

Without group commit, a commit takes `pager_commit_lock` before its log write
(mod.rs:3422-3427) and holds it until `FinalizeCommit` (mod.rs:3669). No later
commit can finish inside the window. So `last_committed_tx_ts < end_ts`, the
pass skips the commit, and nothing is stamped in the window. This explains
the probe of gap 22: it ran without group commit, and 0 versions were left.

With group commit (`PRAGMA mvcc_group_commit`, mod.rs:3405-3416), a leader
takes the lock and writes the queued records of other commits. Its own record
ends in `SyncLogicalLog` (mod.rs:1970-1976), so the leader keeps the lock until
its own `FinalizeCommit`. A follower, whose record a leader wrote, reaches
`CommitEnd` with no lock. So a follower can be in the window while a commit
with a higher timestamp finishes. Example with follower T1 at ts 10 and T2 at
ts 11:

```
T1: CommitEnd(10) -- rewrite chunk 1 (rows 1..1024) -- yield ...... rewrite rows 1025..1100 (mat := 0)
T2:                  CommitEnd(11) .. Finalize: last_committed = 11
CK:                                    snap = 11, collect + stamp rows 1..1100, prune dirty keys
```

When the pass stamps rows 1025 to 1100, they still carry the TxID of T1. The rewrite
then resets their stamp. Their keys are no longer dirty, so a later pass does
not collect them. A full scan also skips them, because their `end_ts` is at or
below `durable_txid_max_old` (ck.rs:1740-1745). Rule 3 never drops them. They
stay in memory until the key is written again. The rule also holds for a
superseded version: if T2 deleted the row of T1, the rewrite of the begin of
that version resets the stamp, and Rule 2 never drops it.

The effect is a memory leak. Reads stay correct, because the B-tree has the
row. Recovery stays correct, because the stamp does not take part in it.

Rule 3 inside the pass has two conditions: `lwm` is MAX, and every read mark
is at or above the new frame. Only then does it drop a stamped current version.
So the leak needs a reader
or a pinned WAL mark during the pass. The commit connection of T1 pins a mark
until `remove_tx` (connection.rs:4897, see `WritersPinMarks`), and so does any
open reader.

Index chains use the same write set, the same rewrite, and the same prune of
`checkpoint_dirty_index_keys`. The leak has the same form there. The index spec
does not need the rewrite: the row spec models the shared code.

## Model changes (MvccPassiveCheckpoint.qnt)

Constants:

- `ModelCommitEndRewrite`: split `WriteFinish` into three steps. Off keeps every
  old configuration and its state count.
- `RewriteResetsMat`: the rewrite sets `mat = 0` on each version that it
  rewrites. The engine has true. False is the fix: the rewrite keeps the stamp,
  because it does not change the committed state of the version.

State: `ending: Set[Inflight]` holds commits between `CommitEnd` and
`FinalizeCommit`, with a `rewritten` flag.

Actions:

- `WriteCommitEnd(i)`: the commit leaves `inflight` (so `Resolved` and
  `SnapshotTs` treat it as committed) and joins `ending`. `lastCommitted` does
  not change.
- `WriteRewriteTxId(e)`: if `RewriteResetsMat`, every version of `chain[e.k]`
  with `b == e.ts` or `e == e.ts` gets `mat = 0`. If one of them had
  `mat != 0`, the step adds `rewroteStamped` to `ck.seen`. One key per writer means one
  step: chunking only decides which keys are rewritten before the pass.
- `WriteFinalize(e)`: needs the rewrite. It does the rest of the old
  `WriteFinish`: `lastCommitted`, `lateMarks` and `fin`.
- `WriteLogAppend` with `LogAppendOneAtATime` (the pager commit lock) also
  waits for `ending == Set()`, because the lock is held until
  `FinalizeCommit`. `LogAppendOneAtATime = false` is group commit.

`Lwm` does not change: `compute_lwm` counts only `Active` and `Preparing`
(mod.rs:8036-8048).

## Invariants

- `NoStrandedVersions` (in `Safety`) already states the property: after a
  completed pass, every committed version at or below `durable` has
  `mat != 0`. The leak breaks it at the rewrite step. There, the stamp of a
  version below `durable` goes back to 0, and its key is not dirty.
- `NeverRewritesStamped`: reachability, `rewroteStamped` is never seen. It
  must fail in the fixed configuration, so the fix check is not vacuous.

Configurations, based on `dirtyKeys`:

| Module | Constants | Expect |
|---|---|---|
| `rewriteGroupCommit` | group commit, reset on | `NoStrandedVersions` fails |
| `rewriteGroupCommitFixed` | group commit, reset off | no error, `Safety` |
| `reachRewriteStamped` | as fixed | `NeverRewritesStamped` fails |
| `rewriteSerialized` | `LogAppendOneAtATime`, reset on | no error, `Safety` |
| `mbtRewrite` | as `mbt`, split on, one writer at a time | traces only |

## Replay

The row replay drives one logged writer at a time, so it replays
`mbtRewrite` traces, where the window exists but nothing is stamped in it.
`WriteCommitEnd` stops at a new test yield point at the start of
`step_rewrite_live_versions`. That point needs a `#[cfg(test)]` hook in
`harness/turso-hooks.patch`, because a one-row write set never yields there.
`WriteRewriteTxId` stops at `BeforeGlobalHeaderUpdate`. `WriteFinalize` runs
the old `WriteFinish` code.

The group commit leak is shown by a Rust test instead
(`harness/repro/commitend-rewrite-leak.patch`). The commits use SQL, and a
1100-row commit gives the window, because the rewrite yields after 1024 rows.
The test is single-threaded, so it holds `pager_commit_lock` by hand until a
leader and a follower are both queued. In a real workload, two threads queue
them. The test reads `MvStore::rows` to count versions. It needs no
`#[cfg(test)]` hook, but it needs these crate-internal reads, so it is a test
inside `turso_core`.
