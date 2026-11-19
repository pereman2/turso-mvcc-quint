# Row protocol: aborts, dirty keys, GC samples and the WAL

This part extends the row model in `MvccPassiveCheckpoint.qnt` with the row
parts that `DESIGN.md` leaves out. Each part is behind a constant. When the
constant is off, the model is the same as before, state for state.

## Aborts

A writer can roll back while it is `Active` or `Preparing`
(`rollback_tx_inner`, mod.rs:7144). The model covers a `Preparing` writer
that rolls back before its log append. Three causes lead to this case. One
is a write-write conflict (`CommitState::Commit`). One is a failed commit
dependency (`WaitForDependencies`). One is a failed dirty mark
(`MarkDirtyKeys`).

1. The code stores `Aborted` first. Then it edits each chain in the write set
   (`rollback_version_chain`, mod.rs:7264). It removes each version that the
   writer began. On each version that the writer ended, it calls
   `set_end(None)`, which also sets `materialized_at` to `ORIGIN`
   (mod.rs:10997).
2. A marker for a B-tree row (begin None, end TxID) becomes begin None and
   end None. GC Rule 1 drops it (`gc_version_chain`, mod.rs:8581).
3. Between steps 1 and 2, readers, collection and stamping resolve the TxID
   to "not committed". That gives the same result as the edited chain, or it
   keeps more. So the model does the rollback in one step (`WriteAbort`).

A reader can read a `Preparing` version. The reader then uses the version as
a committed one. It also takes a commit dependency on the writer
(`is_visible_to`, `is_btree_invalidating_version` at mod.rs:11065,
`register_commit_dependency` at mod.rs:11129). If the writer rolls back, it sets `abort_now` on each
dependent reader, and the reader's commit fails with
`CommitDependencyAborted`. In the model, a read depends on each `Preparing`
writer of the same key whose timestamp is below the reader's `begin_ts`.
If one of those writers rolled back or is still `Preparing`, `ReadsCorrect`
does not count a wrong read.

The checkpoint needs nothing new for aborts. `checkpoint_snapshot_ts` stays
below every `Preparing` commit, and collection and stamping skip a TxID that
did not commit (`committed_ts`, `stamp_chain_materialized`).

## Dirty keys

Collection visits only the keys in `checkpoint_dirty_table_keys` and
`checkpoint_dirty_index_keys`, unless a full scan is required. Each entry
holds a stamp, which is the highest commit timestamp that marked the key.

1. Mark. In `MarkDirtyKeys` (`step_mark_dirty_keys`, mod.rs:2737), a commit
   marks each key in its write set with its commit timestamp
   (`mark_checkpoint_dirty_key`, a `fetch_max`). This is after the commit is
   `Preparing` with its timestamp, and before the log append and
   `CommitEnd`. If the mark fails, the commit fails and rolls back.
2. Collect. The walk reads the stamp of each key it visits. A key with a stamp
   at or below `snapshot_ts` is a prune candidate (`record_prune_candidate`,
   checkpoint_state_machine.rs:1734). In a full scan, the `DirtyStamps` phase
   records the candidates (`record_dirty_stamps`).
3. Prune. After GC, `prune_dirty_keys` (checkpoint_state_machine.rs:1741)
   removes each candidate. If a writer raised the stamp after collection, it
   marks the key again with the new stamp.
4. Rollback. If no version in the chain keeps the key dirty, a `Preparing`
   writer that rolls back removes its keys
   (`unmark_checkpoint_dirty_key_if_stamp`, mod.rs:7883).
5. Failed mark. A mark again in step 3 or 4 can fail on allocation. Then the
   stamp is lost. `require_checkpoint_full_scan` raises the lost stamp into
   `checkpoint_full_scan_min_snapshot_ts` and increments
   `checkpoint_full_scan_generation`. A checkpoint reads the generation at its
   start (checkpoint_state_machine.rs:2503). If the generation is not zero,
   the checkpoint does a full scan. At its end, `clear_checkpoint_full_scan`
   has two conditions: `snapshot_ts` is at or above the lost stamp, and the
   generation did not change. If both are true, it sets the generation to
   zero.

The property is `CollectsEveryChange`: when collection ends, every key with a
committed change in `(old boundary, snapshot_ts]` is in the frame. A commit
at or below `snapshot_ts` was not `Preparing` at the time of the snapshot. So
its mark was already in the map, and the property holds.

## GC samples

`sample_gc_lwm` (mod.rs:8139) reads `lwm` under the clock lock, before any
chain lock. The floor is also read before the chain loop (`gc_incremental`,
`gc_floor_reader_mark`). `gc_chain_now` (mod.rs:8154) then applies the rules
to each chain under its lock. If the sample is `u64::MAX` (no reader), it
computes `lwm` again. The model has `GcSample`, then `GcApply` on any
number of keys, then `GcEnd`.

A stale `lwm` that is not `MAX` is safe. A reader that begins after the sample
has a `begin_ts` above the clock, so it does not need a version that ended
before the sample. A stale floor is also safe: a new reader pins the end of
the WAL, which is at or above every `materialized_at`.

## WAL restart

Modes P and T, turso main 9cf2de2d8, modeled by `ModelWalRestart` (off: the
model of before, state for state). Mode B counts frames across its restart
(section "Mode B").

`WalPos` is `(checkpoint_seq, frame)` and compares in that order. A restart adds
1 to the sequence and sets the frame to 0. There are two restart paths.

1. Restart for write (modes P and T). `begin_write_tx` calls
   `try_restart_log_before_write` (wal.rs:3632, wal.rs:5367). It restarts only if
   the writer reads the database file (read mark 0), `max_frame == nbackfills > 0`,
   it can upgrade read lock 0 (wal.rs:2386), and `begin_restart` gets marks 1 to
   4 exclusive (wal.rs:2359). `upgrade` needs exactly one reader on the lock
   (wal.rs:371). So in process, any other reader blocks this restart, also a
   database file reader at mark 0. The intent `restart_ignores_db_file_readers`
   (wal.rs:2348) is true only of `begin_restart` itself. In MVCC only the
   checkpoint writes pages, so the restart runs at the `BeginPagerTxn` of the
   next pass. The model does it in `CheckpointBeginPager`.
2. Restart in the T WAL checkpoint. It takes the `Writer` guard (read lock 0 and
   the write lock, wal.rs:2230-2244), needs every frame backfilled (else Busy,
   wal.rs:5246) and calls `restart_log` (wal.rs:5249-5258). That is Busy while a
   reader holds marks 1 to 4. While the guard is held, a new reader takes a mark
   in slots 1 to 4 (wal.rs:2117-2145). The model has `CheckpointRestart`, and
   `CheckpointFail` at `"backfilled"` for the Busy.

So both paths restart only when no pager reader other than the checkpoint holds a
mark. A reader that pins after the restart gets `(s+1, 0)`. After the T restart,
`backfill_floor` and the stamp are `(s+1, 0)` (ck.rs:3385-3388, ck.rs:2176).

Mode T Finalize runs `drop_unused_row_versions_and_slots` (ck.rs:3431), which is
`drop_unused_row_versions_inner(true, true, STAGED)` (mod.rs:8232). The floor is
`min(compute_min_reader_mark, backfill_floor, reader_mark_floor)` (mod.rs:8504).
The
comment "That lock waits out open MVCC txs" (ck.rs:3428) is false with the
passive flag: `begin_tx` and `gc_incremental` skip `blocking_checkpoint_lock`
(mod.rs:6749, mod.rs:8250). Readers begin and inline GC runs during the pass.
The model has this sweep as `CheckpointFinalSweep`: one `GcChain` of every key
with `SweepFloor`.

Why it matters. The sweep drops the last current version (Rule 3) once its stamp
is at or below the floor and no snapshot is open. A reader that pinned a mark
below the stamp and is not in `txs` (rule R5) is not in that floor. In mode T
this reader still reads every row, and the floor is not the reason. Every T
sweep follows a full backfill and a restart in the same pass. So every stamp is
at or below `genStart(walSeq)`. A reader that pins after the restart has a mark
at or above every stamp. If a reader stays pinned across the restart (guard
off), its `EffMark` is also at or above `genStart(walSeq)`. So it reads every
stamped row from the database file. So no sweep floor can break
`PinnedReaderKeepsVisible` in mode T, not even `Inf`. The model cannot show that
the `backfill_floor` term is needed there. The harm in the guard-off variants
comes from a reader that reads frames of the new generation at its old frame
number (`EffMark`). It does not come from the sweep.

Simplification. In the engine, a reader in marks 1 to 4 lets the T backfill
copy frames up to its mark. Then the pass fails with Busy (wal.rs:5246,
wal.rs:2359). A database file reader makes the `Writer` guard fail before any
backfill (wal.rs:2236). The model does not backfill in mode T while a reader is
pinned (`CheckpointBackfill`), and the pass fails with Busy. The partial
backfill is left out. It does not move `backfill_floor` and does not stamp,
because the pass stops before `TruncateWal`. The engine backfills only frames
that the reader can already see.

Invariants: `PinnedReaderKeepsVisible` (a pinned reader, in `txs` or not, reads
the oracle value of every key at its begin, through `EffMark`; checked when no
Preparing writer is below that begin) and `NoReaderCrossesRestart`. Witnesses:
`NeverRestart`, `NeverReadAfterRestart`, `NeverSweepWithUnregistered` (no digit
in the name, because the Makefile cannot read one).

Results (1 key, 2 readers, 5 timestamps).

| Module | Result | Distinct states | Time |
|---|---|---|---|
| `main`, `truncateFlagOnFixed` (regression) | No error, same counts as before | 17,344,980 and 300,115 | 990 s, 18 s |
| `restartPassive` (2 passes) | No error | 22,042,689 | 838 s |
| `restartTruncate` (2 passes) | No error | 44,829,324 | 1198 s |
| `restartPassiveIgnoresReaders` | `NoReaderCrossesRestart` fails. `PinnedReaderKeepsVisible` fails (`...Visible`, 1,284,769 states). `ReadsCorrect` fails (`...Reads`, 2,293,919) | 333,194 | 22 s |
| `restartTruncateIgnoresReaders` | `NoReaderCrossesRestart` fails. `PinnedReaderKeepsVisible` fails (2,969,174). `ReadsCorrect` fails (5,000,708) | 17,452 | 8 s |
| `restartTruncateFloorRegistered` (2 passes) | No error for `PinnedReaderKeepsVisible` (the only invariant checked). The floor cannot change a sweep in mode T: the state count equals `restartTruncate` | 44,829,324 | 1390 s |
| `reachRestartPassive` (3 passes) | `NeverReadAfterRestart` fails. `reachRestartPassiveSeq`: `NeverRestart` fails (233,922 states, 13 s) | 5,767,332 | 342 s |
| `reachSweepWithR5` | `NeverSweepWithUnregistered` fails (3 passes) | 116,743 | 15 s |

`restartTruncate` with 3 passes ran 39 minutes and was stopped, so the modules
marked "2 passes" use `MaxCheckpoints = 2`.

Replay of `mbtRestart`: 19 traces, 0 refused, 0 failed. After each
`CheckpointBeginPager`, the engine sequence changed iff `walSeq` did. The committed row traces still conform
(`mbt_tests::rows`, 6 passed). The three probes of
`harness/repro/wal-restart-floor.patch` pass on main 9cf2de2d8: pin `(2, 0)` and the T checkpoint gives `Err(Busy)`; T checkpoint 2 moves
`(3, 0)` to `(4, 0)`, and a reader that pins reads `b` with `rows_versions = 0`;
with a database file reader open, four passive checkpoints keep sequence 2
(frames 3, 6, 9, 12, backfill stops at 3), and with no reader they give 2, 3, 4, 5.

Left out: a restart with no frame in the generation (skipped), writer marks
across a restart, a crash inside a restart, and the T steps in the replay (refused).

## Rules

| Rule | Code | Without it |
|------|------|------------|
| A reader that read a `Preparing` write takes a commit dependency. If the writer rolls back, the reader aborts. | `register_commit_dependency`, `abort_now` | `ReadsCorrect` fails (`abortsNoDependency`). The reader read the row value of a write that never happened. |
| A commit marks its keys dirty while it is `Preparing`, before `CommitEnd`. | `step_mark_dirty_keys` | `CollectsEveryChange` fails (`dirtyMarkAfterCommit`). The commit finishes, a checkpoint takes a snapshot above it and walks the dirty map before the mark. |
| A full scan stays required until a checkpoint with `snapshot_ts` at or above the lost stamp ends. | `clear_checkpoint_full_scan` | `CollectsEveryChange` fails (`dirtyClearFullScanEarly`). A re-mark fails for a `Preparing` commit. The next full scan has a snapshot below that commit and clears the flag. Then the commit is never collected. |
| If the generation changed, the clear does nothing. | `compare_exchange` in `clear_checkpoint_full_scan` | No error in the row model (`dirtyNoGenerationCas`). See Findings. |
| If the sample is `MAX`, `gc_chain_now` computes `lwm` again. | `gc_chain_now` | `ReadsCorrect` fails (`gcSampleNoRecheck`). GC samples "no reader", a reader begins and makes its first look, and Rule 3 empties the chain. This is rule R3 again. |
| Stamp only rows whose pager write finished. | `written_table_rowids` | Not modeled. `WriteRow` skips a table-row write in two cases. In one, this or an earlier checkpoint destroyed the table. In the other, the row is a delete in a B-tree that this checkpoint created. Those are schema cases, so the schema model must check them. |
| If a passive checkpoint gets `Busy`, it goes on without backfill. | `CheckpointWal` | Not needed as a separate rule. The model already lets a backfill copy zero frames, and `Busy` gives the same state. |

## Checks

The counts below describe earlier configurations. The checkpoint-stop results
near the end of this file describe the current configurations.

All runs use one key, five clock timestamps and the invariants of the main
configuration plus `CollectsEveryChange`. TLC finds no error in any of them.
This is evidence within these bounds, not proof.
The counts are the ones that `make variants` gives. The time is for `quint verify --backend tlc` with 3 workers.

| Configuration | Readers | Checkpoints | Distinct states | Time |
|--------|---------|-------------|-----------------|------|
| `aborts` | 1 | 2 | 3,164,577 | 2 minutes |
| `abortsKeepMaterialized` | 1 | 2 | 3,338,621 | 2 minutes |
| `dirtyKeys` (with aborts, one failed re-mark) | 1 | 3 | 45,359,101 | 26 minutes |
| `dirtyNoGenerationCas` (two failed re-marks) | 0 | 3 | 2,517,764 | 2 minutes |
| `gcSample` | 2 | 2 | not counted | not run in full |

`gcSample` is the largest variant. It is too large for a full run. The same configuration with four clock timestamps has
8,066,627 distinct states, and TLC finds no error.

## Findings

Each finding below is a lead until a Rust test shows it. `FINDINGS.md` gives
the verdicts.

1. A rollback leaves the restored current version with `materialized_at =
   ORIGIN` (`set_end(None)` resets it). The B-tree still has that version, but
   GC Rule 3 cannot drop it. No later checkpoint stamps it again, because the
   key has no change in its range. The version stays in memory until the next
   write to the row. This also happens for every update or delete of an
   `Active` transaction that rolls back, for example after a constraint error.
   TLC reaches this state (the `NeverLeavesUnstampedCurrent` check fails in
   `aborts`). This is a reachability check, not an invariant violation.
   Issue #11749 reports the same leak, and its Rust test shows
   `materialized_at` reset to `ORIGIN`. Rollback can keep the old
   `materialized_at`. TLC finds no error with that rule
   (`abortsKeepMaterialized`). This is a memory leak, not a
   correctness bug.
2. The generation `compare_exchange` in `clear_checkpoint_full_scan` is not
   shown needed in the row model. A re-mark can fail at the same time as a clear
   only in a rollback. The stamp that it loses belongs to a version that GC
   already dropped, so there is nothing left to collect. A failed mark in
   `seqcompact_commit_delete` (mod.rs:9002) is a third source, and it is not in
   this model. Keep the check for that case.

## Finalized TxID states

A version stores the TxID of its writer until the writer commits. Then the
engine rewrites each marker to a timestamp. After that the writer leaves
`txs`, and `remove_tx` puts its state in `finalized_tx_states`
(mod.rs:6823-6861). A prune drops entries that no chain names
(`collect_referenced_txids`, `prune_finalized_tx_states`, mod.rs:8531-8561).
A TxID that both maps have lost would make a read see a version as invisible
(mod.rs:11291-11296) or ignore an end (mod.rs:11358-11362).

`ModelFinalizedPrune` (off by default) adds this. `WriteFinish` becomes
`CommitEnd` plus the rewrite and the publish, up to
`BeforeFinishCommittedTx`. `WriteRemoveTx` is `remove_tx`. `FinPruneCollect`
and `FinPruneApply` are the prune in two steps, and they can run at any time.
`TxIdsResolve` says that no version names a TxID that both maps have lost.
With the constant off, the model is the same, state for state.

Two what-ifs test the order. `RemoveTxBeforeRewrite` lets `remove_tx` run
before the rewrite (`WriteRewrite`). `GuardPruneReferenced` turns the
referenced filter on or off.

Results with one key, one reader, `MaxTs = 4` and one checkpoint:

| Configuration | Filter | Order | Result |
|---|---|---|---|
| `finalizedMain` | on | rewrite first | No error, 3,071,602 states |
| `finalizedNoReferenced` | off | rewrite first | No error, 1,709,056 states. Also no error at `MaxTs = 5` (15,360,546 states). Two readers at `MaxTs = 5` did not finish in 44 minutes |
| `finalizedRemoveBeforeRewriteNoReferenced` | off | remove first | `TxIdsResolve` fails. This is the negative control |
| `finalizedRemoveBeforeRewrite` | on | remove first | `ReadsCorrect` fails. The filter reads a set that is out of date |
| `reachFinalizedPrune` | on | rewrite first | `NeverPrunesWithVersion` fails. This shows only that a prune runs while the writer's version still exists |
| `reachFinalizedGuardFires` | on | rewrite first | `NeverPruneGuardFires` fails, so the filter is reached |

In engine order the model assumes that the rewrite comes before `remove_tx`.
So `TxIdsResolve` holds by construction, and the filter-off pass
(`finalizedNoReferenced`) holds by construction too. Those passes do not test
the filter. They show only that the new steps keep the other invariants.

The redundancy verdict rests on the engine source order at rev 0c9fe0dd9, plus
the what-if controls. The rewrite runs before `remove_tx` on every path:

- The normal commit: `RewriteLiveVersions` at mod.rs:3652 and mod.rs:3660, before
  `finish_committed_tx` at mod.rs:3698.
- The dropped COMMIT: mod.rs:7320, before mod.rs:7330.
- The abandoned group waiter: mod.rs:1951, before mod.rs:1956.
- The fast paths at mod.rs:3303 and mod.rs:3377. The write set is empty, so
  `remove_tx` inserts nothing (mod.rs:6831-6832).

The what-if shows that a broken order breaks reads, even with the filter on.

The code is safe because the rewrite comes before `remove_tx`. The filter is
not the reason. It does not help when the order breaks, and it never protects
a read when the order holds. It does fire in the engine order. A writer can be
Preparing at the collect and leave `txs` before the apply. Then the filter
keeps its TxID for one more round. This only delays the prune. The replay found
this case, and the first version of the model missed it.

`main` keeps its 17,344,980 states. The trace replay (`mbtFinalized`) conforms
on 100 of 100 traces. A retiring writer keeps its WAL read mark until its statement
ends. The COMMIT statement ends its pager read tx after `remove_tx`
(connection.rs:4894-4897), and the passive backfill stops at every read mark that
it cannot take (wal.rs:1209-1232). So `WritersPinMarks` keeps the mark of a writer in
`fin.pins` from `WriteFinish` to `WriteRemoveTx`, and `CheckpointBackfill` reads it.
An older spec dropped the mark at `WriteFinish`, and 1 to 3 percent of traces failed at
`CheckpointBackfill`. The driver splits a commit only when the writer is in
`fin.retiring`, and it checks the cache only in such traces. The check is that `finalized_tx_states` is a subset of the spec
set. After `FinPruneApply` the sets are equal, unless a checkpoint finalized
between the collect and the apply. The engine also prunes at `Finalize`
(csm.rs:3535 and csm.rs:3543), and the spec does not.

Left out:

- `still_retiring`. The insert and the removal from `txs` are one step.
- `rootpage_gc_protected`. It skips the collect, and the row spec has no root
  pages.
- Write-write conflict checks. A lost TxID gives "no conflict" (mod.rs:2215-2217).
  Gap 7 models conflicts with timestamps, not with lost TxIDs. The order argument
  below covers conflicts too, but nothing models a lost TxID in a conflict check.
- The checkpoint `committed_ts` lookup of a lost TxID (csm.rs:1827-1838).
- The prune only at `Finalize` and VACUUM. The model prunes at any time.
- Writers of more than one row, rewrite chunks, mode B and index rows.

## Not modeled

- Aborts of `Active` writers. Their versions are invisible to readers. Their
  only effect on the checkpoint is the reset of `materialized_at` in
  finding 1.
- Aborts after the log append. `cleanup_dropped_commit` treats such a commit
  as committed.
- WAL restart in modes P and T. See the analysis above, which is not verified.
  Mode B models the restart inside its atomic pass.
- Index keys. They use the same dirty-key code as table keys, with their own
  map.

## Checkpoint stops and later stamps

`CheckpointFailures` lets a pass stop at each modeled phase. `CheckpointFail`
keeps committed WAL frames, the published boundary, and completed backfill.
It ends the owner's pager pin only while the pass owns a pager transaction.
The MVCC snapshot stays registered (`MvccPassiveCheckpoint.qnt:788`). This matches cleanup at
`core/mvcc/database/checkpoint_state_machine.rs:1079`.
The cleanup discards staged root operations at line 1087 and ends the pager
read transaction at line 1098 of that file.

The pager commit and publish stay separate (`MvccPassiveCheckpoint.qnt:619` and `MvccPassiveCheckpoint.qnt:643`).
The code ends the pager transaction at
`core/mvcc/database/checkpoint_state_machine.rs:3333`.
It can yield before publish at line 3341 of that file.
The boundary store follows at line 2232 of that file.

`NoStrandedVersions` requires a successful completed pass to leave no
unstamped version whose resolved last event is at or below `durable`
(`MvccPassiveCheckpoint.qnt:1011`). The property allows a failed pass to leave repair work.
It then checks the result of the next successful pass.
It does not prove that a later pass will finish.

`failedPublish` models probe 4 in the supplied Rust results.
A nonempty pass publishes, fails before stamping, and leaves versions below
the collection boundary. A later successful pass does not collect them.
`FixRecollectUnstamped` makes collection include those versions
(`MvccPassiveCheckpoint.qnt:580`). The later pass writes their row and stamps them
(`MvccPassiveCheckpoint.qnt:724`). This is a proposed model fix. A Rust fix is not verified.

`NeverFailsAfterPublish` requires a nonempty pager commit, an unstamped
version below the published boundary, and a failure at `published`
(`MvccPassiveCheckpoint.qnt:1061`). `NeverRepairsVersions` requires that failure first.
A later pass must then stamp an unstamped version below its old boundary
(`MvccPassiveCheckpoint.qnt:1062`). The witness cannot pass through a no-op checkpoint.

## Connection owners and mode T

The checkpoint stores its owner at start (`MvccPassiveCheckpoint.qnt:537`).
Its pager commit releases that connection's pin (`MvccPassiveCheckpoint.qnt:619`).
The MVCC snapshot keeps its begin timestamp and remains registered.

`CheckpointBeginPager` skips the pager transaction and publish for an empty pass
(`MvccPassiveCheckpoint.qnt:602`). A new metadata boundary still counts as work
(`3a95ac963:core/mvcc/database/checkpoint_state_machine.rs:2467`).
The model tracks the transaction with `pagerOwned`.
Only failure during `writing` can clear an owner pin through cleanup
(`MvccPassiveCheckpoint.qnt:788`).

An explicit owner must be between statements, in the `active` reader state
(`MvccPassiveCheckpoint.qnt:537`). This represents the active-statement check
(`3a95ac963:core/connection.rs:2590`, `3a95ac963:core/connection.rs:4833`).
A stale pinned mark stops the pass before pager writes
(`MvccPassiveCheckpoint.qnt:602`). The owner keeps its pin.
Rust reports `BusySnapshot` for that write upgrade
(`3a95ac963:core/storage/wal.rs:3598`).

The pager commit changes the connection transaction state at
`core/storage/pager.rs:3429` at base `3a95ac963`.
`set_tx_state` only writes that field (`core/connection.rs:4845` at that base).
The MVCC transaction id has a separate setter (`core/connection.rs:4886`).
The model therefore keeps the registered snapshot when it releases the pager pin.

`FixRefuseCheckpointOwner` refuses an owner with an open reader.
The main configuration enables this proposed fix.
The code-today owner variants leave the fix off.

Mode T means the passive flag is on and the caller requests TRUNCATE.
`CheckpointPublish` and `CheckpointPublishBoundary` form separate steps
(`MvccPassiveCheckpoint.qnt:643` and `MvccPassiveCheckpoint.qnt:649`).
`ReaderBegin` can occur between them.
The code takes this publish path without the clock wrapper at
`core/mvcc/database/checkpoint_state_machine.rs:3356`.
The wrapper that orders a passive publish is at line 2250 of that file.

The row model has no root map or header cookie.
Its split publish therefore adds an interleaving point but cannot detect
half-published schema state. That schema race is not verified.
A pinned reader makes mode T fail at `published`, before the stamp
(`MvccPassiveCheckpoint.qnt:788`). `truncateFlagOn` checks the resulting stranded versions.
`truncateFlagOnFixed` and `reachTruncateRepair` check the later stamp repair.
The model keeps WAL frame numbers. It does not model WAL restart.

The owner model keeps the MVCC snapshot after it releases the pager pin
(`MvccPassiveCheckpoint.qnt:238`, `MvccPassiveCheckpoint.qnt:239`).
`GcKeepsVersionsAboveReaders` checks both sets (`MvccPassiveCheckpoint.qnt:1030`).
The code floor still counts the retained registered mark (`MvccPassiveCheckpoint.qnt:824`).
`ownCheckpointGc` therefore expects no GC violation.
Its earlier expected failure assumed a different relation between those sets.
The pinned-only control, `ownCheckpointGcPinnedFloor`, now expects the GC check to fail.
It ignores that registered mark after the pin disappears.
The new simulator trace uses a registered owner and a nonempty pager commit.
At step 25, owner `r1` has begin timestamp 5 and mark 0, then commits frame 1.
The first empty pass keeps every reader pin. No `committed` state has frame 0.
The GC check sees an ended version stamped at frame 1 above the retained mark 0.
A wrong read from this GC step is not verified.
`reachReaderMarkBelowFloor` checks both sets too (`MvccPassiveCheckpoint.qnt:1078`).
TLC reaches that retained-mark state after 38,049 states.

| Owner control | Result | Distinct states |
|---|---|---:|
| `ownCheckpoint` | `ReadsCorrect` fails as expected | 148,132 |
| `ownCheckpointBackfillFloor` | `ReadsCorrect` fails as expected | 146,017 |
| `ownCheckpointKeepsMark` | `ReadsCorrect` fails as expected | 149,126 |
| `ownCheckpointKeepsMarkBackfillFloor` | `ReadsCorrect` fails as expected | 150,509 |
| `ownCheckpointGc` | No GC-floor violation | 32,893,504 |
| `ownCheckpointGcBackfillFloor` | `GcKeepsVersionsAboveReaders` fails as expected | 128,575 |
| `ownCheckpointGcPinnedFloor` | `GcKeepsVersionsAboveReaders` fails as expected | 135,575 |
| `reachStampedAboveReader` | `NeverStampedAboveReader` fails as expected | 17,532 |
| `reachReaderMarkBelowFloor` | `NeverReaderMarkBelowBackfillFloor` fails as expected | 38,049 |

## Logical log truncate ordering

`CheckpointTruncateDecide` checks the log against the published boundary
(`MvccPassiveCheckpoint.qnt:697`). With `SplitLogTruncate`, completion occurs in
`CheckpointTruncateApply` (`MvccPassiveCheckpoint.qnt:708`).
`WriteLogAppend` can occur between these actions.
The code checks the boundary at
`core/mvcc/persistent_storage/logical_log.rs:1089`.
It submits the truncate at line 1072 of that file.
The storage lock ends before completion at
`core/mvcc/persistent_storage/mod.rs:238`.
Whether an I/O backend permits the model's destructive ordering is not verified.

`logTruncateRace` checks recovery after the split truncate.
`reachTruncateAppend` requires a nonempty pager commit and a truncate that
actually discards an append above the boundary (`MvccPassiveCheckpoint.qnt:1063`).
`logTruncateAtomic` checks the unsplit control at the same bounds.
This control prevents the race. It is not a repair after a failure.

## Stamp and publish rules from the Rust fix

The Rust fix is in a local worktree that is not published.
Its checked head is `633aeb51a`. Source references in this section use that head.
The earlier sections use the requested base, `3a95ac963`.

`FixStampAtPagerCommit` stamps each written chain in `CheckpointCommit`
(`MvccPassiveCheckpoint.qnt:619`). The stamp is the new WAL frame number.
The code calls `stamp_committed_versions` immediately after pager commit at
`core/mvcc/database/checkpoint_state_machine.rs:3301`.
The helper reads the pager WAL position at
`core/mvcc/database/checkpoint_state_machine.rs:3569`.
It stamps only versions whose resolved terminal event is within the snapshot
(`core/mvcc/database/mod.rs:8675`).
The model uses one atomic commit-and-stamp step at these one-key bounds.
The Rust helper locks each chain separately. Interleavings between those
chain locks are not verified.

`FixCleanupPublishes` makes `CheckpointFail` publish a committed pass before
it clears the checkpoint state (`MvccPassiveCheckpoint.qnt:788`).
`ApplyCheckpointPublish` applies the same boundary update for normal publish
and cleanup (`MvccPassiveCheckpoint.qnt:654`).
Rust selects this cleanup at
`core/mvcc/database/checkpoint_state_machine.rs:1040`.
It uses the passive window at
`core/mvcc/database/checkpoint_state_machine.rs:1044` and the blocking window at
`core/mvcc/database/checkpoint_state_machine.rs:1048`.
Publish errors, allocation failures, and failures inside the publish window
are not verified by these atomic model steps.

`rustFix` checks all main invariants and `NoStrandedVersions` with both constants.
It also refuses an owner with an open snapshot, as the row main configuration does.
`rustFixOwner` turns that refusal off and checks the same promises through `Safety`
(`MvccPassiveCheckpoint.qnt:1052`). The saved trace has a wrong read.
The reader expects 0 at begin timestamp 1 and receives 2 after backfill.
The regenerated owner trace includes the new pager phase and a real frame commit.
The two Rust fixes do not restore the owner's pager pin in this model.
Rust reproduction of this trace is not verified.

`rustFixTruncate` checks mode T with both constants.
`rustFixPinnedFloor` uses the lowest pinned mark as its GC floor.
All four variants use one key, one reader, four timestamps, and two passes.
`reachCleanupPublish` requires failure after a nonempty pager commit and an
actual cleanup publish (`MvccPassiveCheckpoint.qnt:1057`).
`reachEarlyStampGc` requires GC to drop a version stamped by the current pass
while a registered reader remains open (`MvccPassiveCheckpoint.qnt:914`).
`reachEarlyStampGcAfterFailure` requires a published-pass failure first, then
GC after a later empty pass completes (`MvccPassiveCheckpoint.qnt:920`).
The first GC witness uses the lowest pinned mark as a control.
The after-failure witness uses the code GC floor.
Both GC witnesses record the actual removal in `AfterGc`
(`MvccPassiveCheckpoint.qnt:908`).
These witnesses use the same bounds as `rustFix`.

The saved traces are in `traces/bugs/`. The owner trace is
`MvccPassiveCheckpoint-rustFixOwner.itf.json`.
The early-stamp GC trace is
`MvccPassiveCheckpoint-reachEarlyStampGc.itf.json`.
The simulator did not capture the after-failure GC witness in 200,000 walks
of 40 steps. TLC reached it after 144,369 states.
An ITF trace for that witness is not verified.

## Checkpoint-stop results

All new leak variants use one key and two passes.
The passive failure variants use no reader and three clock timestamps.
The mode T variants use one reader and four clock timestamps.
The truncate-order variants use no reader, three timestamps, and one pass.
Each fixed variant checks every main invariant and `NoStrandedVersions`.
The results below count distinct TLC states with eight workers.
Counts from an interrupted search are not complete state-space counts.

| Configuration | Result | Invariant | Distinct states |
|---|---|---|---:|
| `failedPublish` | Fail (expected) | `NoStrandedVersions` | 2,790 |
| `failedPublishFixed` | Pass | All listed invariants | 10,167 |
| `reachFailedPublish` | Fail (expected) | `NeverFailsAfterPublish` | 731 |
| `reachRepairedVersions` | Fail (expected) | `NeverRepairsVersions` | 4,685 |
| `logTruncateRace` | Fail (expected) | `RecoveryCorrect` | 205 |
| `reachTruncateAppend` | Fail (expected) | `NeverLosesAppendAtTruncate` | 503 |
| `logTruncateAtomic` | Pass | All listed invariants | 615 |
| `truncateFlagOn` | Fail (expected) | `NoStrandedVersions` | 34,195 |
| `truncateFlagOnFixed` | Pass | All listed invariants | 300,115 |
| `reachTruncateRepair` | Fail (expected) | `NeverRepairsVersions` | 73,059 |
| `refuseCheckpointOwner` | Pass | All listed invariants | 210,694 |
| `rustFix` | Pass | All listed invariants | 502,396 |
| `rustFixOwner` | Fail (expected) | `Safety` | 23,598 |
| `rustFixTruncate` | Pass | All listed invariants | 457,428 |
| `reachCleanupPublish` | Fail (expected) | `NeverCleanupPublishes` | 1,086 |
| `rustFixPinnedFloor` | Pass | All listed invariants | 1,037,362 |
| `reachEarlyStampGc` | Fail (expected) | `NeverGcEarlyStampWithReader` | 7,970 |
| `reachEarlyStampGcAfterFailure` | Fail (expected) | `NeverGcEarlyStampAfterFailure` | 144,369 |

## Write-write conflicts and GC

Question: can GC drop a version that a write-write check needs, so that an
update is lost? Gap 7 in `MODEL-GAPS.md`. Code lines are turso rev 0c9fe0dd9.

The spec has a feature constant `Updates` (false in every older module) and a
guard `GuardRule2Lwm` (true in every older module: Rule 2 needs `v.e < lwm`,
mod.rs:8606; the engine test is `e <= lwm`, and the two are equal because
timestamps are unique). `ReaderUpdate(r, k)` is one step for a registered reader: it
decides the conflict with `EndEvidence` and `CurrentEvidence`, and it either
rolls back or adds a new version and a Preparing commit. After a writer W has
written `k`, the chain holds W's TxID, GC keeps it, and another writer sees
a conflict at its commit check (an Active insert is invisible to a second
inserter). So the window that matters is from W's begin to W's first write of
`k`. `ReaderBegin`, `Gc` and `ReaderUpdate` are separate steps, so the model
keeps that window. `NoLostUpdate` is first committer wins: no write of `k` has
a timestamp between the begin and the commit of an update.

`WritePrepare` and the commit branch of `ReaderUpdate` use
`ChainAfterWrite` to end the old version and add its replacement, if any.
Both use `NewInflight` to record the pending commit. With
`WritersPinMarks`, a plain writer uses the current WAL length and an
upgrading reader keeps its read mark.

| Module | Result | Distinct states | Seconds |
|---|---|---|---|
| `main` | No error | 17,344,980 | 473 |
| `updates` (2 readers, 5 timestamps, 1 pass) | No error (all main invariants and `NoLostUpdate`) | 8,466,039 | 206 |
| `reachUpdateCommits` | `NeverUpdateCommits` fails | 96 | 9 |
| `reachUpdateConflict` | `NeverUpdateConflict` fails | 137 | 9 |
| `reachConflictByEndOnly` | `NeverConflictByEndOnly` fails | 420 | 9 |
| `reachConflictByCurrentOnly` | `NeverConflictByCurrentOnly` fails | 187 | 8 |
| `reachConflictAfterGc` | `NeverConflictAfterGc` fails | 42,988 | 10 |
| `updatesNoGcWait` | No error (`NoLostUpdate`) | 351,787 | 15 |
| `updatesNoRule2Lwm` | No error (`NoLostUpdate`) | 73,230 | 10 |
| `updatesNoRule2LwmNoGcWait` | `NoLostUpdate` fails | 2,303 | 10 |
| `updatesNoIdleRule3NoGcWait` | `NoLostUpdate` fails | 599 | 11 |
| `updatesGcSampleNoRecheck` (2 passes) | No error (`NoLostUpdate`) | 1,481,376 | 99 |
| `updatesGcSampleNoRecheckNoGcWait` | `NoLostUpdate` fails | 2,211 | 9 |
| `blockingUpdates` | No error (blockingMain invariants and `NoLostUpdate`) | 18,458 | 11 |
| `blockingUpdatesNoRule2Lwm` | No error (`NoLostUpdate`) | 21,378 | 11 |

Size S is 1 key, 1 reader, 4 timestamps and 1 pass, except where the table
says 2 passes. Counts of a failing run are where TLC stopped, so they change
between runs. The run of `updates` with 2 passes was not tried (the run with 1
pass took 206 s). `noGcWait` and `blockingNoB2Keep` still fail
`RecoveryCorrect` and `ReadsCorrect`.

Reading of the results:

- Each guard that GC uses alone is not shown needed: the lwm term of Rule 2
  and the floor with the idle Rule 3 guard each keep what an update needs at these bounds. With both
  off, GC drops the delete (Rule 2) or the only current version (Rule 3) and an
  update commits over a newer write. In these two traces the update is step 18
  (`updatesNoRule2LwmNoGcWait`) and step 11 (`updatesNoIdleRule3NoGcWait`).
  Both end with `Gc`, then `ReaderUpdate`. They are model what-ifs, not engine
  bugs: the code has both guards.
- The first run of `updatesNoGcWait` listed every main invariant and failed.
  That was a mistake in the configuration, not a result: with
  `GuardGcWaitsForReaders` off, `RecoveryCorrect` fails already, as in
  `noGcWait`. The module now lists `NoLostUpdate` only.
- Not shown, so not claimed: more than one key, deletes by the updater,
  2 passes with 2 readers, indexes.

Model gap. After the step the updater leaves `Registered`. In the engine W stays
in `txs` as Preparing, and its begin still counts in the lwm. So the model GC can
drop more than the engine. This is safe: W needs no version after its check,
and every other reader has its own begin in the lwm.

Trace replay. The driver step `ReaderUpdate` (`harness/mbt_tests/rows.rs`) runs
`INSERT ... ON CONFLICT DO UPDATE` in a `BEGIN CONCURRENT` reader and steps
`COMMIT` to `WaitForDependencies`, after the commit check. The engine decides
the conflict in that step. The spec adds `"wwConflict"` or a version, and the
driver compares. 
The commit-dependency path is not modeled. `ReaderUpdate` is not enabled while
an in-flight write of `k` has a timestamp below the begin `b` of the updater. In
the engine the updater then sees the Preparing version speculatively
(`is_begin_visible`, mod.rs:11234-11248), registers a commit dependency, and gets
no conflict (`is_write_write_conflict`, mod.rs:10884). This path is safe
for `NoLostUpdate` because writes of `k` are serialized: `WritePrepare` and the
commit branch of `ReaderUpdate` both need no in-flight write of `k`. So while an
in-flight write below `b` exists, no write of `k` lies in `(b, clock]`. A
Preparing delete of `k` below `b` is a different case: the engine hides that
version (mod.rs:11324-11331) and the commit check gives a conflict
(mod.rs:2232-2245, 2299-2308). That conflict has no cause, and it can abort an
update that snapshot isolation allows. It is a lead with no run, and it cannot
lose an update. An in-flight
write with a timestamp above `b` stays a conflict in the model. The update
statement does not see that version, and the commit check
(`check_version_conflicts`, about mod.rs:2280-2290) raises `WriteWriteConflict`
for a Preparing owner. So in this case the conflict comes at commit time, and the
driver accepts a conflict from the statement or from the commit.

Difference found by the replay, fixed in the spec: the first version of
`reachConflictByCurrentOnly` had a writer W (timestamp 2, Preparing) and a
reader `r2` that began at 3 and updated `k1`. The spec said conflict, the engine
did not (the commit-dependency path above). The spec now leaves that step out.
After the change all five witnesses (`ww-reachUpdateCommits`,
`ww-reachUpdateConflict`, `ww-reachConflictByEndOnly`,
`ww-reachConflictByCurrentOnly`, `ww-reachConflictAfterGc`) replay on the engine,
and the regression replay gives 100 of 100 traces for `mbt` and `mbtBlocking`. The trace `ww-reachConflictAfterGc` runs `Gc` before
the updater begins, so the replay does not show committed evidence kept across a
GC while the updater is open. Only the TLC negative controls show that.

## Mode B

Mode B is the default. The flag `experimental_mvcc_passive_checkpoint` is off.
The row spec models it with `Mode = "blocking"`. Code lines are turso main
2827d0cc1. `mod.rs` is `core/mvcc/database/mod.rs`. `ck.rs` is
`core/mvcc/database/checkpoint.rs`.

### The design

Each MVCC transaction holds `blocking_checkpoint_lock` in read mode for its
whole life. The checkpoint takes the lock in write mode at `AcquireLock`
(ck.rs:2437-2441). Both sides are try locks, so a checkpoint fails with `Busy`
while a transaction is open. A B checkpoint that succeeds writes every
committed change, truncates the whole logical log, restarts the WAL and then
runs GC. So a successful B checkpoint is one atomic step with no MVCC
transaction open. The GC then empties the version store.

A few paths pin a WAL read mark with no gate and no MVCC transaction. Only the
two schema reparse paths (`maybe_reparse_schema`, core/connection.rs:1413, and
`force_reparse_schema`, core/connection.rs:1469) keep the pin while their
`SELECT` begins an MVCC transaction. The raw WAL API does not open the window.
`wal_insert_begin` (core/connection.rs:2529) also takes the WAL write lock, so
a checkpoint fails before its publish. `wal_get_frame` (core/connection.rs:2500)
pins only inside its call and runs no SQL. A reparse pin makes the
checkpoint fail with `Busy` at `CheckpointWal`, after the publish of
`durable_txid_max` (ck.rs:2108-2110 and ck.rs:3238-3243).

How a B reader reads a row. A reader reads the chain, and in one case it skips
the chain and reads the B-tree (`chain_is_write_buffer_for`, mod.rs:6047-6076).
The chain must be one current version. The version began before the reader.
Its begin is at or below `durable_txid_max`. Its stamp is not `ORIGIN` and is
at or below the reader mark. An empty chain also reads the B-tree.

The B GC rules (`gc_version_chain`, mod.rs:8625-8685):

- Rule 2, B form, drops a superseded version that ended below `lwm`, except
  when `e > ckpt_max` and (`in_btree` or no current version) (mod.rs:8648-8665).
  The rule has no stamp test.
- Rule 3 drops the last current version when `lwm` is `MAX`, the version has
  a stamp at or below the floor, and `b <= ckpt_max` (mod.rs:8673-8683).

Three callers run these rules: `gc_incremental` (mod.rs:8247), `GcTableRows`
(ck.rs:2172) and the `Finalize` sweep (ck.rs:3452-3456).

### The stamp after the WAL restart (gap 14)

In B the WAL checkpoint restarts the WAL inside `CheckpointWal`
(wal.rs:5249-5258), before the stamp. The stamp is `pager.wal_pos()` in
`GcTableRows` (ck.rs:2179). Its value is `(checkpoint_seq + 1, 0)`, because
`restart_wal_header` adds 1 to the sequence and sets the frame to 0
(wal.rs:6106-6119). It equals `ORIGIN` only after 2^32 restarts of this WAL file (the sequence
is read from the WAL header at open, core/storage/sqlite3_ondisk.rs:1812).
A Rust probe on turso main printed the WAL position after each of three
checkpoints: `(3, 0)`, `(4, 0)` and `(5, 0)`. It also printed
`rows_versions = 0` after each one
(`probe_mode_b_stamp_after_restart` in `harness/repro/mode-b-pager-pin.patch`).
The stamp is that position by code reading (ck.rs:2179). The probe does not
print the stamp itself. Verdict: no leak path at real sizes. The
variant `blockingStampOrigin` shows the harm of the what-if.

### The model

- `CheckpointBlocking` is one action. Its guard: no writer in flight, no
  registered reader, no pinned reader, GC idle. It writes every change since
  the boundary as one WAL frame `F`. It publishes `durable`, backfills every
  frame, empties the logical log and stamps the written versions with `F`.
  Then it applies the B rules to every chain with `lwm = Inf`.
- `CheckpointBlockingFail` is a pass that stops after its publish. It writes
  the frame and publishes `durable`. It does not backfill, truncate, stamp or
  collect garbage. A pinned reader with no gate (`PagerPinsWithoutGate`) or an
  I/O error (`CheckpointFailures`) causes it.
- `CheckpointBlockingStop` runs only with `BlockingStopsAfterStamp`. It
  stops a pass after the stamp and before the GC. Whether the engine stops
  there is not verified.
- If `Mode == "blocking"`, `Gc` and the reads use the B rules, and the
  fall-through read of `chain_is_write_buffer_for`.

The WAL restart needs no new variable. Frame numbers count across restarts, as
`RowDriver::counted_frame` does (`harness/mbt_tests/rows.rs`). The restart
position `(seq + 1, 0)` counts to the number of frame `F`, so the spec stamps
`F`, as in mode P.

Constants of mode B. All "off" values give the passive model, state for state.

| Constant | Code today | Meaning |
|---|---|---|
| `PagerPinsWithoutGate` | false in the main module | A pinned reader holds a WAL mark but not the gate |
| `GuardB2KeepUncheckpointed` | true | Rule 2 B keeps `e > ckpt_max && (...)` |
| `GuardB2InBtree` | true | The `in_btree` term of that clause |
| `GuardB2Tombstone` | true | The `not(has_current)` term of that clause |
| `GuardB3InCkptMax` | true | Rule 3 needs `b <= ckpt_max` |
| `GuardFallThroughCkptMax` | true | The fall-through needs `b <= durable` |
| `GuardFallThroughMark` | true | The fall-through needs a stamp at or below the mark |
| `BlockingStampOrigin` | false | What-if: the B stamp writes `ORIGIN` |
| `FixB2WaitsForPinned` | false | A fix that keeps GC alive in the model: Rule 2 B drops nothing while a pinned read mark is below the WAL max frame. Not in the engine and not tried in Rust |
| `ModelWalRestart` | false | `walSeq`, `genStart`, `RdState.seq`, the restarts and the T final sweep (section "WAL restart") |
| `GuardRestartWaitsForReaders` | true | A restart needs no pinned reader (wal.rs:371, wal.rs:2359) |
| `TruncateSweepFloor` | `"staged"` | Floor of the T final sweep: `"staged"` (the code) or `"registered"` (probe) |
| `BlockingFailTruncatesLog` | false | What-if: a failed pass also empties the logical log (control for `RecoveryCorrect`) |
| `BlockingStopsAfterStamp` | false | A pass stops after its stamp |

Invariants: `ReadsCorrect`, `RecoveryCorrect`, `TypeOK`, `BackfillBelowReaders`
and `BlockingStoreEmpty` (a successful B pass leaves no version in the store).

### Results

Every run used 1 key, 2 readers, 5 timestamps and 2 checkpoints, with
`make variants SPECS=MvccPassiveCheckpoint` on a Mac with 4 TLC workers
(2026-11-17). The state counts of a failing run
are the states found before the first error. The state counts of the B modules
include the flag `gcDroppedB` that `NeverGcDropsB` reads.

| Module | Result | States | Seconds | Prediction |
|---|---|---:|---:|---|
| `blockingMain` | No error | 563,686 | 61 | Right |
| `blockingNoB2Keep` | `ReadsCorrect` fails | 13,683 | 43 | Right |
| `blockingNoB2InBtree` | `ReadsCorrect` fails. `RecoveryCorrect` holds | 87,133 | 40 | Wrong, see below |
| `blockingNoB2Tombstone` | No error | 662,548 | 48 | Right |
| `blockingNoB3CkptMax` | No error. Vacuous | 563,686 | 46 | Right |
| `blockingNoFallThroughMark` | No error. Vacuous | 563,686 | 49 | Right |
| `blockingNoFallThroughMarkPinned` | `ReadsCorrect` fails | 936 | 39 | Right |
| `blockingNoFallThroughCkptMax` | No error. Vacuous | 563,686 | 52 | Right |
| `blockingStampOrigin` | `BlockingStoreEmpty` fails | 77 | 40 | Right |
| `blockingFailAfterPublish` | `BlockingStoreEmpty` fails | 334 | 43 | Right |
| `blockingFailTruncatesLog` | `RecoveryCorrect` fails | 219 | 41 | No prediction |
| `blockingPagerPin` | `ReadsCorrect` fails | 48,470 | 40 | Right |
| `blockingPagerPinFixed` | No error | 2,009,967 | 100 | Right |
| `blockingMainNoFallThrough` | No error | 563,686 | 48 | Right |
| `reachBlockingFallThrough` | `NeverFallsThrough` fails | 1,855 | 42 | Right |
| `reachBlockingDropsSuperseded` | `NeverBlockingDropsSuperseded` fails | 1,082 | 43 | Right |
| `reachBlockingDropsCurrent` | `NeverBlockingDropsCurrent` fails | 156 | 42 | Right |
| `reachBlockingStamp` | `NeverStampAtRestart` fails | 130 | 41 | Right |
| `reachBlockingFailsAfterPublish` | `NeverBlockingFailsAfterPublish` fails | 101 | 42 | Right |
| `reachMainGcDrops` | `NeverGcDropsB` fails | 461 | 40 | No prediction |
| `reachPinGcDrops` | `NeverGcDropsB` fails | 401 | 40 | No prediction |
| `reachFixedGcDrops` | `NeverGcDropsB` fails | 400 | 41 | No prediction |

What the results say:

- `blockingMain` finds no error. The B rules with no pager pin keep every read
  right. `blockingMainNoFallThrough` finds no error for `NeverFallsThrough`. So
  the fall-through read never runs in `blockingMain`: a pass that succeeds
  with no failed pass before it empties the store, and no stamped version is left. It runs only when a pass
  stops after its stamp (`reachBlockingFallThrough`). This is a lead for
  `SIMPLIFY.md`, not a reason to delete code. Whether the engine stops a pass
  there is not verified.
- `blockingNoB2Keep` is the negative control. GC drops a delete that no pass
  wrote, and a reader reads the old B-tree row.
- `blockingNoB2InBtree` fails `ReadsCorrect`, not `RecoveryCorrect`. The trace
  is 16 steps. A reader begins at timestamp 3 and takes its first look at the
  chain. The chain has the marker of a delete that ended at 2. A new INSERT
  commits at 4, and GC drops the marker because 2 is below the `lwm` of 3. The
  second look of the dual cursor finds only the version from 4, which the
  reader does not see. So it reads the B-tree row that the delete removed. The
  `in_btree` term keeps the marker until a checkpoint removes the B-tree row.
  The prediction said `RecoveryCorrect` first. That was wrong, because the log
  still replays the delete.
- Three guard variants are vacuous: `blockingNoB3CkptMax`,
  `blockingNoFallThroughMark` and `blockingNoFallThroughCkptMax`. They have the
  same 563,686 states as `blockingMain`. The guarded path never decides a step
  in `blockingMain`. The two `ckpt_max` terms (`GuardB3InCkptMax` and
  `GuardFallThroughCkptMax`) are implied by the stamp in this model, because a
  pass stamps only versions at or below its new `durable`. These results do not
  show that a guard is safe to delete. `GuardFallThroughMark` is needed:
  `blockingNoFallThroughMarkPinned` fails `ReadsCorrect`. That module also
  sets `FixB2WaitsForPinned`, so that the wrong read of `blockingPagerPin`
  does not hide the fall-through.
- `blockingNoB2Tombstone` finds no error. This means "not shown needed at
  these bounds". It does not mean that the guard is safe to delete.
- `blockingStampOrigin` and `blockingFailAfterPublish` leave versions in the
  store after a pass. They break `BlockingStoreEmpty`, which is a memory
  check, not a read check. `ReadsCorrect` holds in `blockingStampOrigin` and
  `ReadsCorrect` and `RecoveryCorrect` hold in `blockingFailAfterPublish`
  (extra runs on 2026-11-17 with the invariant lists changed).
- `blockingFailTruncatesLog` is the control for `RecoveryCorrect`. A failed
  pass empties the logical log and its frame never lands, so the committed rows
  are in no file. A first version of the what-if wrote the frame and emptied
  the log. It found no error (1,495,149 states), because the frame already has
  every change.
- `blockingPagerPin` fails `ReadsCorrect` with the code of today. Section
  "Pager pin" gives the trace and the probe.
- `blockingPagerPinFixed` has `FixB2WaitsForPinned`: Rule 2 B drops nothing
  while a pinned read mark is below the WAL max frame. It finds no error. The
  fix keeps GC alive: `reachFixedGcDrops` fails `NeverGcDropsB`. That drop
  happens with no pin, so it does not show a drop after a failed pass. An earlier fix
  (`FixB2NeedsStamp`, Rule 2 B needs a stamp) was rejected. It stopped every
  Rule 2 B drop, because a version has a stamp only inside a pass, so its
  "no error" came from a GC that never ran. The cost of
  `FixB2WaitsForPinned`: while a stale pin exists, Rule 2 drops nothing. The fix
  is in the model only. It is not in the engine and not tried in Rust.
  An engine form of the fix must count every pager reader, also a reader on
  read slot 0. `min_pinned_read_frame()` reads only slots 1 to 4
  (wal.rs:916-927 on main 2827d0cc1). A reader that pins on a fully backfilled
  WAL takes slot 0 (wal.rs:1059-1065), and the reader of the probe is that
  case. So a fix that uses only that function still drops the delete. This is
  by code reading.
  `BlockingStoreEmpty` is not listed, because versions stay unstamped after a
  failed pass.

### Pager pin

`blockingPagerPin` is a 17-step trace (`harness/mbt_tests/traces/MvccPassiveCheckpoint-blockingPagerPin.itf.json`).
Reader `r1` pins a WAL mark. A writer inserts a row. A pass publishes frame 1
and fails, because a pinned reader holds a mark. A second reader pins mark 1.
A writer deletes the row. A second pass publishes frame 2 and fails. GC drops
the delete, because it ended at 2 and `durable` is 2. The second reader
begins its MVCC transaction, adopts mark 1 and reads the B-tree at mark 1,
which still has the row.

The Rust probe `probe_mode_b_pager_pin_after_failed_publish` shows the same
shape on turso main 2827d0cc1 (3 of 3 runs, and once more at the time of this
work). It inserts a row, runs `PRAGMA wal_checkpoint(TRUNCATE)`, pins a mark
with `pager.begin_read_tx()`, deletes the row, and runs the checkpoint again.
That checkpoint returns `Busy` after the publish. `gc_incremental` drops the
delete, and the reader then reads the deleted row. The control without the GC
reads no row. `FINDINGS.md` row 24 gives the verdict. The probe pins the mark
with a direct call. A trigger through a public API is not shown.

The replay of the bug trace on the engine at the pinned rev 0c9fe0dd9 fails
at step 16 with `WrongRead`. Step 16 is the first read of the new reader
(`blocking_pager_pin_trace_shows_wrong_read` in `harness/mbt_tests/rows.rs`).

### What mode B leaves out

- Index rows in B (`GcIndexRows` and the index chain rules).
- An I/O error after the WAL restart (`SyncDbFile`, `TruncateLogicalLog`,
  `FsyncLogicalLog` or `TruncateWal`). That leaves the WAL backfilled and
  restarted, the log kept, and no stamp. The model has one failure point, the
  one after the publish.
- A partial backfill in a failed pass. With a reader on read mark 1 to 4, the
  WAL checkpoint may backfill up to the reader mark before `begin_restart`
  returns `Busy` (wal.rs:1239-1248). `CheckpointBlockingFail` backfills
  nothing.
- A run on the engine of a failed pass that an I/O error causes. The replay
  runs only failed passes that a pager pin causes (`rows-blocking-pin-171`,
  `rows-blocking-fail-then-pass-220`). There the chain check matches the
  versions that the next successful pass leaves.
- A writer in flight in the `lwm` of the checked B modules. They have
  `WriterBeginTicks = false`, so their GC can drop more than the engine. That
  is the safe side for `ReadsCorrect`. A reachability result can rely on such
  a drop (not verified).
- Root bindings and `is_btree_readable_at`. The one table exists before the
  first pass.
- The real reparse window. The pinned reader of the model stands for it.
- The partial GC of `GcTableRows` batches with yields. The pass is one step.
- A crash inside a B pass. The recovery spec covers the file steps.
- Attached databases, VACUUM and `checkpoint_in_progress` (always false in B).
- The empty slot unlink and the writer retry in `insert_version`.
