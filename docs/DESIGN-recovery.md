# MVCC crash recovery

`MvccRecovery.qnt` models the files that a crash leaves, and the open of those
files. It checks whether the open refuses, and whether a successful open gives
the committed rows now and after more commits and checkpoints. The other specs
check recovery with a pure function that never refuses, so they cannot find
bugs where a database does not open.

All paths in this document are relative to the repository root. Older line references
are for Turso commit `7c607534b`. The sync and truncate changes use
Turso main `172b828a9`.

## Scope

- The file syncs use one sync mode for all connections. Under FULL, a commit
  syncs the logical log and a checkpoint pager commit syncs the WAL. Under
  NORMAL, both skip that sync (`core/mvcc/database/mod.rs:1955-1957`,
  `core/storage/pager.rs:4776`). Backfill syncs the WAL before it copies
  pages. The checkpoint syncs the database file if it copied any frames
  (`core/storage/wal.rs:5085-5122`, `core/mvcc/database/checkpoint.rs:3330-3349`).
- A passive backfill can copy zero frames (`PassiveBackfillSkips`). A pinned
  reader can leave the range empty, or the backfill can return Busy. The
  checkpoint can finish without syncing the WAL or the database file
  (`wal.rs:5093`, `checkpoint.rs:3292-3309`).
- Since Turso `d52ed55ca`, a checkpoint proceeds from logical-log truncate
  to WAL cleanup after truncate completion. The log truncate changes the
  live image. A crash can keep that image or the prior synced one. If the
  old log survives, replay skips its frames at or below the recovered
  `persistent_tx_ts_max`. The open path still syncs the recovery header
  (`checkpoint.rs:3257-3279`, `mod.rs:9395-9419`, `mod.rs:9848` on
  Turso main `172b828a9`).
- An explicit `FULL` or `RESTART` checkpoint maps to TRUNCATE
  (`core/mvcc/database/checkpoint.rs:896-902`), so it is the `blocking` kind (flag
  off) or the `truncflag` kind (flag on).
- The checkpoints that automatic checkpoints (`mod.rs:3700`),
  `Connection::checkpoint` (`core/connection.rs:2591`) and
  `PRAGMA wal_checkpoint(PASSIVE)` or `(TRUNCATE)` start. The SQL compiler
  accepts an explicit `FULL` or `RESTART` checkpoint with the passive flag off
  (`core/translate/pragma.rs:1009`). Both map to TRUNCATE (see above), so the
  blocking kinds cover them.
  `CheckpointKinds` is a scope choice, not a list of every checkpoint mode.
- One commit in flight at a time. One key changes in each commit.

## Files on disk

| Model variable | File | Notes |
|---|---|---|
| `fs.dbMem`, `fs.metaMem` | `.db` in the page cache | A backfill writes here |
| `fs.dbDisk`, `fs.metaDisk` | `.db` after fsync | `meta` is `persistent_tx_ts_max` |
| `fs.wal` | `.db-wal` | The WAL truncate and its fsync are one step |
| `fs.walDisk` | `.db-wal` after fsync | The number of frames that an fsync made durable. Equals `wal.length()` under FULL. A crash keeps all frames or only these (`walKept`) |
| `hist`, `floor` | none (ghost state) | Under NORMAL only. `hist(t)` is the committed rows after timestamp t. `floor` is the newest timestamp that a WAL sync made durable or an open recovered |
| `lg.file`, `lg.hfile` | `.db-log` as the OS shows it | `hfile` is `None` or `Valid` |
| `lg.disk`, `lg.hdisk` | `.db-log` after fsync | `hdisk` can also be `Invalid` after a torn write |
| `lg.off0`, `lg.maxApp`, `lg.crcReset` | log writer state | Offset 0, `max_appended_commit_ts`, and a running CRC that restarted from a new salt at an offset above 0 |

The header states match `HeaderReadResult` of
`core/mvcc/persistent_storage/logical_log.rs:1832`. A file shorter than the
header, or a header of only zeros (line 1840), is `None`. A header that does
not decode is `Invalid`. If recovery cannot chain the CRC of a frame to the
header, the frame has `ok = false`. Replay stops before the first such frame.

## Actions and code

| Action | Code | Notes |
|---|---|---|
| `CommitWrite` | `logical_log.rs:717` (header with the first frame), `logical_log.rs:687` (`max_appended_commit_ts`) | Submits the append. An update writes a delete and an upsert, as `mod.rs:2470` describes |
| `CommitAppendDone` | append completion (`mod.rs:3498`) | |
| `CommitFsync` | `mod.rs:3542` | The frame is durable here. Under NORMAL the step copies nothing to `lg.disk` (`mod.rs:3539-3546`) |
| `CommitPublish` | `mod.rs:3629` | The commit is acknowledged, and its versions enter the store |
| `CkBegin` | collect states, `checkpoint_state_machine.rs:2488-2604` | The blocking kind waits for every transaction. The flag-on kinds do not take the lock before the snapshot |
| `CkCommit` | `checkpoint_state_machine.rs:3241-3295`, `pager.rs:4776` | Pager commit of one WAL frame. An empty write set skips the pager commit and the publish (line 2643). The frame is durable (`walDisk`) under FULL, or under NORMAL with `FixCkCommitSyncsWal`, which also raises `floor` |
| `CkPublish` | `apply_checkpoint_publish_window`, line 2188 | `durable_txid_max` advances. A separate step for a crash, an error or an abandoned checkpoint after the pager commit. Other connections can commit while the pager commit I/O completes. The passive retry on a busy publish flag (line 3299) cannot fire today: one flag-on checkpoint runs at a time (line 2488), and only it sets the flag (`mod.rs:7957`) |
| `CkBackfill` | `wal.rs:5085-5122` | Syncs the WAL, then copies all its frames in one step. Under NORMAL a nonempty sync raises `floor` to the newest metadata timestamp covered by the sync |
| `CkBackfillNone` | `checkpoint.rs:3292-3309`, `wal.rs:5093` | With `PassiveBackfillSkips`, leaves the files and `floor` as they were and goes to `CkTruncLog`. Tags `BackfillSkipped` (WAL has frames) and `BackfillSkippedUnsynced` (some are not durable) |
| `CkSyncDb` | `checkpoint_state_machine.rs:3409` | |
| `CkTruncLog` | `checkpoint.rs:3257-3279`, `logical_log.rs:1063-1100`, lock at `core/mvcc/persistent_storage/mod.rs:230` | Under the log lock: the decision, the truncate submit and the writer reset. The blocking kind clears the whole log (`clears_whole_logical_log`, line 1942). If one frame is above the snapshot, the flag-on kinds keep the log. The truncate only changes the live image |
| `CkTruncDone` | `core/io/io_uring.rs:848` | Only with `AsyncLogTruncate`. The truncate completes later, and it can run after a newer append |
| `CkTruncWal` | `checkpoint_state_machine.rs:3446` | The WAL truncate and its fsync, one step. The passive kind keeps the WAL |
| `CkGc` | `gc_checkpointed_table_versions` (line 2252), then `Finalize` (line 3531) | Stamps only the write set (`stamp_chain_materialized`, `mod.rs:8651`), then runs `gc_version_chain` (`mod.rs:8581`) on every chain. The GC batches are one step |
| `CkFail` | `cleanup_after_external_io_error` (`checkpoint_state_machine.rs:1039-1075`) | See below |
| `Crash` | none | Keeps fsynced data. An unsynced write is lost, kept, or torn. `walKept` keeps the unsynced WAL frames or drops them (allowed only when some frame is unsynced) |
| `OpenStart` | `maybe_complete_interrupted_checkpoint_nonblock` (`mod.rs:9179`) | The startup decision. It keeps the open flag, whether the WAL had frames, and the header state in `op`. With no WAL frames, replay follows at once |
| `OpenBackfill`, `OpenSyncDb` | `mod.rs:9278`, `mod.rs:9295` | |
| `OpenHeader`, `OpenFsyncLog` | `mod.rs:9341`, `mod.rs:9372` | A crash can tear a new header. A valid header is written again with the same bytes (`mod.rs:9228`, `logical_log.rs:988`), so the model does not tear it |
| `OpenFinish` | `mod.rs:9404`, then `maybe_recover_logical_log` (`mod.rs:9609`) | WAL truncate, then replay |

`CkFail` stops a checkpoint at one of the steps from `CkCommit` to
`CkTruncWal`. It stands for an error, `Busy`, or a checkpoint that a caller
drops (`mod.rs:1705`). The checkpoint stops without GC. A committed WAL frame
stays, and after the publish `durable_txid_max` keeps its new value. The
model gives most failures no other effect. These effects are modeled:

- A failure between the pager commit and the publish keeps the WAL frame
  with the old boundary.
- With `LogTruncateErrors`, the log truncate call fails. Unix returns the
  `ftruncate` error from the submit call (`core/io/unix.rs:510`). By then
  `truncate_to_zero` gave the in-memory header a new salt and restarted the
  running CRC, but it keeps the offset (`logical_log.rs:1061-1075`).
- An async truncate that fails after the submit leaves the writer reset and
  the file unchanged.

A failure between the WAL truncate and its fsync, and a failure inside the
backfill, are not modeled.

The three checkpoint kinds:

- `blocking`: the passive flag is off. The checkpoint is TRUNCATE and holds
  the blocking lock from the start.
- `passive`: the flag is on. The checkpoint keeps the WAL.
- `truncflag`: the flag is on, and the user runs
  `PRAGMA wal_checkpoint(TRUNCATE)`. Writers do not wait for it.

## Open

The open follows the code in this order.

1. If the WAL has frames and the open is read-only, refuse with "Cannot
   reconcile interrupted MVCC checkpoint in read-only mode" (`mod.rs:9222`).
2. If the WAL has frames, the header is `None` and the passive flag is off,
   refuse with "WAL has committed frames but logical log header is missing"
   (`mod.rs:9237`). PR #9770 removes this refusal (`Fix9770`).
3. If the WAL has frames and the header is `Invalid`, refuse (`mod.rs:9247`).
4. If the WAL has frames, backfill them, fsync the DB file, write a fresh log
   header, fsync the log and truncate the WAL. Each is its own step, and a
   crash can come between any two.
5. If the header is `Invalid` now, refuse with "Logical log header corrupt and
   no WAL recovery available" (`mod.rs:9633`).
6. Replay the frames with `commit_ts > persistent_tx_ts_max`
   (`mod.rs:9936`), up to the first frame that does not chain. Each version
   keeps the timestamp of its frame. Set the clock to the largest frame
   timestamp (`mod.rs:9857`).

The open does not restore `max_appended_commit_ts`. The model sets `maxApp` to
0 after an open.

## Invariants

- `RecoveryCorrect`: every open that the configuration allows and that
  succeeds gives the committed rows. While the system runs, reads give the
  committed rows.
- `OpenSucceeds`: if the files hold every committed row, every allowed open
  succeeds. The only allowed refusals are the ones that
  `RECOVERY_SEMANTICS.md` states as intended: case 3 and case 5, the invalid
  header.
- `OpenSucceedsWithWal` and `OpenSucceedsStrict`: the same with no stated
  refusals. The first one checks only files with WAL frames.
- `RunCorrect`: while the system runs, reads give the committed rows. It is
  the run half of `RecoveryCorrect`, for NORMAL.
- `NormalPrefix`: every successful NORMAL open gives the rows of a commit
  point `t` with `floor <= t <= clock`. Both read-only and read-write opens
  enter the check. The WAL sync in `CkBackfill` raises `floor` to the highest
  timestamp it covers. In the hypothetical pager sync control, `CkCommit`
  raises it too. The upper bound includes a commit in flight. When recovery
  finishes, `GoRun` resets `truth`, `hist` and `floor` to the recovered state.
- `NoLeak`: after a checkpoint succeeds, no chain is left whose every version
  has its last event at or below the snapshot. GC runs with no open snapshot
  in the model, so the B-tree holds that row. After a blocking checkpoint with no
  failed pass before it, the store is empty (`DESIGN-rows.md`, "Mode B").

## Historical results before removing the checkpoint log sync

These runs use the model before Turso's `d52ed55ca` change. The current
profiles and replay commands are below.

Bounds: one key, `MaxTs = 3`, two checkpoints, one crash, one checkpoint
failure. `twoCrashes` has two crashes and `MaxTs = 2`. The state counts come
from `make check` and `make variants` with `SPECS=MvccRecovery`.

| Module | Result | States | Meaning |
|---|---|---|---|
| `main` | no error | 206,754 | The code today with PR #9770 off. Checks `RecoveryCorrect` |
| `mainPassive` | no error | 357,952 | The same with the passive flag on at the start |
| `fixed` | no error | 208,721 | PR #9770 and `FixStampBelowBoundary`. Every invariant except read-only opens |
| `fixedPassive` | no error | 366,941 | The same with the passive flag on at the start |
| `twoCrashes` | no error | 61,191 | A crash can stop recovery, and a second crash can follow an open |
| `issue7480` | `OpenSucceeds` fails | 608 | A crash between the log truncate and the WAL truncate of a blocking checkpoint. Known |
| `issue7480Fixed` | no error | 4,004 | PR #9770 fixes it |
| `issue9749` | `OpenSucceeds` fails | 1,270 | An open with the flag off after a passive checkpoint. Known |
| `issue9749Fixed` | no error | 10,356 | PR #9770 fixes it |
| `leadA` | `OpenSucceeds` fails | 1,270 | A passive database that closed cleanly keeps WAL frames. A read-only open refuses. A Rust test failed on that engine revision |
| `leadB` | `OpenSucceedsWithWal` fails | 1,478 | A torn first header write after a passive checkpoint. Every open refuses, but the WAL holds every committed row. Case 3 states this refusal as intended. Needs a header write that tears into bytes that do not decode (not verified). Not reproduced as a crash |
| `leadBStated` | no error | 65,920 | Lead B with the stated refusals allowed |
| `leadBZeros` | no error | 59,155 | If a torn header reads as zeros, the open completes the checkpoint |
| `idea1` | `RecoveryCorrect` fails | 425 | One timestamp for every replayed version brings back a deleted row |
| `idea2` | `NoLeak` fails | 900 | A blocking checkpoint that fails after its publish leaves its versions unstamped. A Rust test failed on that engine revision |
| `idea2Passive` | `NoLeak` fails | 5,182 | The same in passive mode. The precondition audit shows it in Rust |
| `idea2Fixed` | no error | 1,423 | `FixBlockingStoreEmpty` |
| `idea2PassiveFixed` | no error | 42,233 | `FixStampBelowBoundary` |
| `logTruncSplit` | `RecoveryCorrect` fails | 2,793 | Hypothesis for an async backend: the truncate runs after a newer append and erases an acknowledged commit. Not shown in Rust |
| `logTruncError` | `RecoveryCorrect` fails | 2,358 | A log truncate error makes the next acknowledged commit unreadable after a crash. A `LogicalLog` unit test shows the unreadable frame |
| `normal` | no error | 630,679 | As `main` with SyncMode NORMAL. Checks `RunCorrect`, `NormalPrefix` |
| `normalPassive` | no error | 1,268,890 | As `mainPassive` with NORMAL |
| `normalBackfillSkip` | `NormalPrefix` fails | 9,314 | Gap 19: a passive backfill that copies no frame, under NORMAL. A row that a FULL commit made durable is lost after a power loss (second Rust test). The checkpoint truncates the log durably and its WAL frame is not fsynced, so a power loss loses commits that the checkpoint acknowledged. Losing a recent NORMAL commit alone matches SQLite NORMAL, but Turso's own comment says NORMAL still fsyncs on checkpoint (`mod.rs:3540`), and the checkpoint returned OK. A Rust test shows it (`harness/repro/README.md`, `passive-checkpoint-normal-power-loss.patch`, `FINDINGS.md` row 29) |
| `normalBackfillSkipFixed` | no error | 1,971,692 | `FixCkCommitSyncsWal` |
| `fullBackfillSkip` | no error | 617,950 | Control: the same skip under FULL |

The variables `hist` and `floor` stay constant under FULL, and `walDisk`
always equals the WAL length. The counts for failing configs and witnesses
changed, because the new variables change the search order. Passing configs
keep their counts. The run of 2026-11-18 on the Mac checked all 54 configs and
took 342 s.

| Witness module | Check that fails | States |
|---|---|---|
| `reachAppendErased` | `NeverAppendErased` | 511 |
| `reachCkOfReplayedRows` | `NeverCkOfReplayedRows` | 327 |
| `reachCleanCloseWithWal` | `NeverCleanCloseWithWal` | 1,346 |
| `reachCommitInPublishWindow` | `NeverCommitInPublishWindow` | 1,085 |
| `reachCrashInRecovery` | `NeverCrashInRecovery` | 2,558 |
| `reachFailAfterPublish` | `NeverFailAfterPublishBlocking` | 124 |
| `reachFailAfterPublishFlagOn` | `NeverFailAfterPublishFlagOn` | 242 |
| `reachFailBeforePublish` | `NeverFailBeforePublish` | 374 |
| `reachFsyncCoversUnacked` | `NeverFsyncCoversUnacked` | 692 |
| `reachInvalidHeaderWithWal` | `NeverInvalidHeaderWithWal` | 1,299 |
| `reachLogRetained` | `NeverLogRetained` | 279 |
| `reachReplayMany` | `NeverReplayMany` | 412 |
| `reachTruncFlag` | `NeverTruncFlagDone` | 6,652 |
| `reachTruncWindow` | `NeverCrashBetweenLogAndWalTruncate` | 832 |
| `reachWalFramesNoLog` | `NeverWalFramesNoLog` | 1,861 |
| `reachNormalLoss` | `NeverLostUnsynced` | 52 |
| `reachPublishDurableNormal` | `NeverPublishDurableNormal` | 1,038 |
| `reachBackfillSkipped` | `NeverBackfillSkipped` | 663 |
| `reachBackfillSkippedUnsynced` | `NeverBackfillSkippedUnsynced` | 776 |
| `reachBackfillSkippedFixed` | `NeverBackfillSkipped` | 731 |
| `reachBackfillSkippedFull` | `NeverBackfillSkipped` | 744 |
| `repairFixed` | `NeverStampFixUsed` | 11,161 |
| `repairFixedOpen` | `NeverOpenNoLogFlagOffOk` | 14,076 |
| `repairFixedPassive` | `NeverStampFixUsed` | 17,913 |
| `repairFixedPassiveOpen` | `NeverOpenNoLogFlagOffOk` | 26,086 |
| `repairIdea2` | `NeverStampFixUsed` | 895 |
| `repairIdea2Passive` | `NeverStampFixUsed` | 5,230 |
| `repairIssue7480` | `NeverOpenNoLogFlagOffOk` | 1,203 |
| `repairIssue9749` | `NeverOpenNoLogFlagOffOk` | 4,651 |
| `repairLeadBZeros` | `NeverOpenAfterTornFirstAppendOk` | 7,756 |

Each passing configuration has a witness module that must fail a `Never*`
check. A witness requires the full dangerous state, not only an action:

- The `reach*` modules require rows in the pager commit, WAL frames with the
  right header state, or the open flag that the configuration names.
- The `repair*` modules show that the failure state is reached and that the
  repair then runs. For a stamp fix, a checkpoint fails after its publish,
  and a later checkpoint stamps a chain outside its write set. For PR #9770,
  an open starts on WAL frames with no log header, with the flag off, and
  `OpenFinish` ends with the WAL removed and reads equal to the committed
  rows. `repairLeadBZeros` also requires that the last crash tore the header
  of a first append while the WAL had frames.

## Historical Rust results

The tests below came from the initial recovery model. `FINDINGS.md` records
their engine revisions and any reruns.

- `leadA`: a read-only open after a clean close fails with "Cannot reconcile
  interrupted MVCC checkpoint in read-only mode".
- `idea2`: after a failed blocking checkpoint, the next successful one leaves
  one version chain in the store.
- `logTruncError`: a `LogicalLog` unit test makes the truncate call fail, then
  appends a frame. A reader sees 1 frame, not 2. The test drives the log
  directly, not a full commit and crash through SQL.
- `normalBackfillSkip`: the tests in
  `harness/repro/passive-checkpoint-normal-power-loss.patch` found both
  NORMAL and FULL commit loss on Turso main `740300d9d`. Row 29 in
  `FINDINGS.md` records that the FULL test passed on `67717af53` after
  removal of the log sync. The same test discards the unsynced truncate
  along with the unsynced WAL writes.
- `leadB`: not reproduced as a crash. The test writes a damaged log image and
  shows that the open refuses it, which `RECOVERY_SEMANTICS.md` case 3 states
  as intended.
- `logTruncSplit`: a hypothesis for an async backend such as io_uring. The
  Unix truncate completes in the submit call (`core/io/unix.rs:500`), so it
  cannot reorder. Not shown in Rust.

## Checks after removing the checkpoint log sync

`normalBackfillSkip` checks the same prefix rule as `normalPassive`. A
successful zero-frame pass leaves the previous durability floor in place.
The old `reachFsyncCoversUnacked` and `reachPublishDurableNormal` witnesses
belong to the removed checkpoint action.

The read-only open profiles expose the refusal of WAL-backed files, as in
`leadA`. The read-write control enables the passive flag and allows the
stated invalid-header refusals. The strict read-write profile checks those
refusals as counterexamples. The two `NoLeak` profiles use full backfill
and no live snapshots. A skipped backfill in Turso retains unbackfilled
versions using its WAL backfill boundary (`checkpoint.rs:3392-3402`,
`mod.rs:8642-8681`).

| Check | TLC result | Distinct states |
|---|---|---:|
| `normal` | Pass | 198,762 |
| `normalPassive` | Pass | 338,859 |
| `normalBackfillSkip` | Pass | 606,202 |
| `normalBackfillSkipFixed` | Pass | 474,270 |
| `fullBackfillSkip` | Pass | 321,032 |
| `normalReadOnlyOpen` | `OpenSucceeds` fails as expected | 291 |
| `normalReadOnlyOpenWithWal` | `OpenSucceedsWithWal` fails as expected | 276 |
| `normalReadWriteOpenStrict` | `OpenSucceedsStrict` fails as expected | 44 |
| `normalReadWriteOpen` | Pass | 530,119 |
| `normalNoLeak` | `NoLeak` fails as expected | 3,396 |
| `normalNoLeakFixed` | Pass | 20,207 |

All 59 recovery profiles returned their expected results on macOS. The
table uses the targeted run. The count at the first counterexample can vary
with the search order. All four deterministic Quint replays passed. The FULL-commit pinned-reader
test from row 29 and both power-loss controls passed on Turso main
`172b828a9` using the existing test patch. The controls cover FULL with
a pinned reader and NORMAL with backfill.

```sh
cd specs
make recovery
quint test RecoveryTests.qnt --main recoveryFullTests --max-samples 1
quint test RecoveryTests.qnt --main recoveryNormalTests --max-samples 1
```

## What the model leaves out

- Readers and snapshots. GC runs with `lwm = MAX`.
- Schema changes, root pages, indexes and aborts.
- SyncMode OFF. No fsync runs, so a power loss gives no promise.
- Mixed sync modes per connection (`needs_full_sync`, `mod.rs:1957`).
- A crash that keeps a middle part of the unsynced log or WAL. The model
  keeps none or all of it.
- A partial backfill (some frames but not all). A skipped backfill stands for
  a pinned reader or Busy, but the model has no reader.
- The commit-path GC (`gc_incremental`).
- The header CRC retry at open and I/O errors at open.
- More than one commit in flight.
