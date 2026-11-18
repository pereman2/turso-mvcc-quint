# Group commit and the durability of a commit

This note states the design of group commit in turso MVCC and how
`specs/MvccGroupCommit.qnt` models it. It closes gap 8 of `MODEL-GAPS.md`.
Code paths are in the turso repo at rev
`0c9fe0dd94c14a4f00106bffa9c9433d5965fd3a`. `mod.rs` is
`core/mvcc/database/mod.rs`, and `group_commit.rs` is
`core/mvcc/database/group_commit.rs`.

## What we model and why

Group commit lets one commit write the logical log records of other commits
and cover all of them with one fsync. A logical log record is the frame that
recovery replays after a crash. The commit that does the work is the leader.
The other commits are waiters. Group commit is on by default
(`group_commit.rs:82`).

The spec checks these promises:

- When COMMIT returns success in SyncMode FULL, the frame is on disk. A power
  loss keeps the commit (`AckDurable`).
- When COMMIT returns success in any mode, the frame is in the log. A process
  crash keeps the commit (`AckLogged`).
- A transaction that rolled back never comes back after a crash
  (`RecoveryNoRolledBack`).
- When a FULL transaction becomes `Committed`, its frame is on disk
  (`CommittedDurable`). This promise is too weak for the readers. A
  speculative reader sees a `Preparing` row before `Committed`, and only the
  wait of `ReaderEnd` covers that window. A reader that begins after
  `Committed` reads the row with no wait. So every break of `CommittedDurable`
  is visible to readers. See "The direct path and readers".

The recovery spec assumes one commit in flight (`MvccRecovery.qnt:68`). It
does not show that the batch, the tickets and the retry path keep these
promises. A wrong order of fsync and `CommitEnd` loses an acknowledged commit
after a power loss. The recovery spec cannot see that loss, because it never
sees the commit.

## The code

The state of the coordinator is `GroupState` (`group_commit.rs:39`).

| Field | Meaning |
|---|---|
| `next_ticket` | The last ticket. A ticket is the place of a commit in the queue |
| `pending` | Queued commits, each with its ticket, record and sync mode |
| `written_through` | The largest ticket with its record written, kept below every retry hole |
| `durable_through` | The release watermark. A waiter with a ticket at or below it finishes |
| `full_sync_written_through` | The largest written ticket of a FULL commit |
| `retry` | Tickets whose write the leader discarded. Each waiter builds a new record |
| `issued` | The owner of the record whose `log_tx` was issued and whose offset did not advance yet. It can be the leader itself |
| `abandoned` | Waiters that dropped after their `log_tx` was issued |

`durable_through` is not "covered by an fsync". If no record in the batch
needs FULL, the fsync is skipped and `mark_durable` still runs
(`mod.rs:3545-3547` then `mod.rs:3590-3592`, and `mod.rs:3560-3561` then
`mod.rs:3573`). The spec keeps the fsync as a separate fact, the `disk`
image.

The pager commit lock (`pager_commit_lock`) lets one leader at a time write.

The steps of one commit (`mod.rs:3408-3661`):

1. `BeginCommitLogicalLog` (`mod.rs:3408`) enqueues the record and gets a
   ticket (`group_commit.rs:139`).
2. `AwaitGroupCommit` (`mod.rs:3448`, `step_await_group_commit` at
   `mod.rs:2009`). If `durable_through >= ticket`, go to step 6. If the ticket
   is in `retry`, build the record again and go to step 1 for a new ticket.
   Else take the lock or park. With the lock, check `retry` again
   (`mod.rs:2028`), then `take_work` (`group_commit.rs:163`). While any retry
   is pending, it never leads (`group_commit.rs:165`). If
   `written_through > durable_through`, it returns `SyncPrefix`. Else it
   returns `None`.
   With no retry, `Lead` pops every pending commit into a batch.
3. For each record of the batch, in ticket order:
   if the transaction of the record left `txs`, `UpgradeLogicalLogHeader`
   and `WriteLogicalLog` skip it (`mod.rs:3453`, `mod.rs:3489`). Else `log_tx`
   writes the frame at the current offset and `note_write_issued` names the
   owner (`mod.rs:3498`, `mod.rs:3501`). The check and the write are separate
   steps. `FinishLogicalLogWrite` and `MarkLogRecordWritten` advance the
   offset and set `log_appended` of the owner (`mark_log_record_written`,
   `mod.rs:1895`). If the owner abandoned, the leader makes it `Committed` at
   once (`finish_abandoned_group_waiter`, `mod.rs:1933`).
4. If this commit or a written record needs FULL, `SyncLogicalLog` fsyncs
   the log (`log_sync_required`, `mod.rs:1960`). The
   fsync covers the whole file, also bytes after the offset
   (`logical_log.rs:980`).
5. `SyncGroupPrefix` and `GroupPrefixSynced` (`mod.rs:3558-3584`): a waiter
   that got `SyncPrefix` fsyncs under the same rule, marks durable, releases
   the lock and goes back to step 2.
6. `EndCommitLogicalLog` (`mod.rs:3586`) calls `mark_durable(written_through)`
   if this commit led a batch. That wakes parked waiters. `CommitEnd`
   (`mod.rs:3629`) sets `Committed`. `RewriteLiveVersions` can yield. Then
   `FinalizeCommit` (`mod.rs:3661`) releases the lock.

When a COMMIT statement drops, two cleanup paths run
(`cleanup_unfinished_commit`, `mod.rs:1846`):

- `release_group_claim` (`mod.rs:1792`). A leader that drops before it issues
  a write puts the batch back. Assume that a leader drops between the issue
  of a waiter write and the offset advance. If the waiter abandoned, the
  leader rolls it back. Else the leader puts the ticket in `retry`. The
  discarded write keeps its bytes in the file (`logical_log.rs:976`).
- `cleanup_dropped_commit` (`mod.rs:7292`). It reads the state. A commit with
  `log_appended` set becomes `Committed` and is published, with no fsync.
  Else, under the group lock, a commit whose write is issued is marked
  abandoned (`abandon_if_issued`, `group_commit.rs:275`). Any other commit
  rolls back. The read and the abandon check are separate steps.

## State and actions of the spec

The spec has a fixed set of transactions `Txs`, each with one row and a sync
mode (`FULL` or `NORMAL`). Each transaction starts its COMMIT once. The
main configuration has three transactions, two FULL and one NORMAL, and at
most four tickets. A retry uses one ticket.

State:

- `grp`: the `GroupState` fields above, with tickets as integers.
- `lock`: the transaction that holds the pager commit lock, or none.
- `txs`: for each transaction, its step (`pc`), its ticket, its state
  (`Preparing`, `Committed`, `RolledBack`) and the batch that it leads.
- `log`: the frames whose offset advanced, in file order.
- `unadvanced`: a frame whose write completed and whose offset did not
  advance. It sits right after `log`. The next write at that offset replaces
  it.
- `disk`: the frames of the file as of the last fsync, with the unadvanced
  frame of that moment. A later write does not change it.
- `acked`: transactions whose COMMIT returned success.

A shorter frame that replaces a longer one leaves bytes behind it. The spec
assumes that recovery stops there, because those bytes do not chain to the
CRC.

Actions. Each one is a step that another thread can interleave with:

| Action | Code |
|---|---|
| `Enqueue(t)` | `BeginCommitLogicalLog`, group path |
| `Await(t)` | `step_await_group_commit`: ack, retry, lead, sync prefix. A park is no action |
| `IssueCheck(t)` | `UpgradeLogicalLogHeader` and the skip check of `WriteLogicalLog` |
| `IssueWrite(t)` | `log_tx` and `note_write_issued` |
| `MarkWritten(t)` | `FinishLogicalLogWrite` and `MarkLogRecordWritten`, then the next record or the sync |
| `Sync(t)`, `SyncPrefix(t)` | `SyncLogicalLog`, `SyncGroupPrefix` |
| `PrefixSynced(t)` | `GroupPrefixSynced` |
| `End(t)` | `EndCommitLogicalLog` |
| `CommitEnd(t)` | `CommitEnd`, `RewriteLiveVersions` and `FinalizeCommit` |
| `Drop(t)` | `release_group_claim`, `drop_pending`, and the state read of `cleanup_dropped_commit` |
| `DropFinish(t)` | `abandon_if_issued` or the rollback |

Four merges remain:

- `Await` reads `durable_through` and runs the first `take_retry` before it
  takes the lock (`mod.rs:2015`, `mod.rs:2019`). The lock holder can change
  both values before this thread gets the lock. The second retry check
  (`mod.rs:2028`) catches a new retry. The code can then lead with a ticket
  that became durable in that window. That ticket is already written, so the
  batch does not change. The spec cannot reach that state, and nothing in it
  tests the second retry check.
- `Drop` merges `release_group_claim`, `drop_pending`, the discard and the
  state read of `cleanup_dropped_commit`. A dropping leader holds the lock
  through all of them. For a dropping waiter, `drop_pending` touches only its
  own ticket, so a leader step in between gives the same state as a step
  before or after the whole `Drop`.
- `MarkWritten` sets `log_appended` and clears `issued` in one step
  (`mod.rs:1923-1925`). A `Drop` between them sees `log_appended` set, which
  `Drop` already allows with `log_appended` set before the read.
- `CommitEnd` merges `Committed`, the chunked rewrite and the lock release.
  A drop in the rewrite takes the `Committed` branch of
  `cleanup_dropped_commit`, which gives the same state without the ack. The
  code also sets `Committed` before it releases the lock. In between, only a
  thread that needs no lock can act: a waiter that finishes, a drop, or an
  enqueue. None of them reads `Committed` of this transaction, so each one
  gives the same state before or after the merged step.

`SyncMode OFF` acts as NORMAL here, because only FULL forces an fsync
(`mod.rs:1960`).

## Invariants

The main configuration checks `TypeOK`, `AckDurable`, `AckLogged`,
`CommittedLogged` (a `Committed` transaction has its frame in the log) and
`OneFramePerTx`.

`CommittedDurable` and `RecoveryNoRolledBack` fail in the code today. Their
variants show it:

- `dropCommitsUnsynced` fails `CommittedDurable`. A COMMIT drops after its
  record is written and before the fsync. Cleanup makes it `Committed`
  (`mod.rs:7296`), and a reader sees it. A power loss then loses it. The same
  holds for an abandoned waiter that `finish_abandoned_group_waiter` makes
  `Committed` before the leader fsyncs. No COMMIT returns success on these
  paths, so `AckDurable` holds.
- `dropResurrects` fails `RecoveryNoRolledBack`. A transaction rolls back
  while its frame is in the file. A crash then replays it. Four paths reach
  it:
  - A COMMIT drops while the write of its own record is issued. This path has
    one transaction and is the shortest, so TLC likely reports it.
  - A leader drops after it issued the write of an abandoned waiter.
  - A waiter drops between the owner check of the leader and `log_tx`.
  - A waiter drops and reads `log_appended` as false. Then the leader marks
    its record written before `abandon_if_issued`.

The second path has a Rust reproducer that fails on turso main
(`FINDINGS.md` row 20). The first path needs a write that is still in
flight when the COMMIT drops, which `MemoryIO` and the Unix backend never
leave. The last two paths need two threads.

Each reachability check must fail. They show that these states occur:

- a batch of two records
- a retry
- an abandoned waiter, and one that becomes `Committed`
- a sync prefix
- a dropped COMMIT that becomes `Committed`
- a NORMAL leader that fsyncs for a FULL record
- a write for an owner that rolled back after the check
- a rollback while the frame is in the file
- a dropping leader that rolls back an abandoned waiter
- a leader that skips the record of a transaction that left `txs`
- every commit acknowledged

## Variants

| Variant | Guard turned off | Result |
|---|---|---|
| `noFullSyncWritten` | `needs_full_sync` in `log_sync_required` (`mod.rs:1960`) | `AckDurable` fails: a NORMAL leader skips the fsync for a FULL waiter |
| `noDensePrefix` | `dense_prefix_cap` (`group_commit.rs:322`) | Not shown needed at these bounds |
| `noRetryHole` | the hole in `written_through` (`group_commit.rs:211`, `group_commit.rs:252`) | Not shown needed at these bounds |
| `noRetryBlocksLead` | no lead while a retry is pending (`group_commit.rs:165`) | Not shown needed at these bounds |
| `noHoleGuards` | all three hole guards | `AckDurable` fails: a later ticket marks the retry ticket durable, and its waiter returns success with no frame |

Direct path and readers (one reader, `MaxTicket = 2`, TLC):

| Variant | Setting | Result |
|---|---|---|
| `direct` | two direct commits, `a` FULL, with drops | `ReadsSurviveCrash` and the main invariants hold (1,004 states) |
| `directNoDrop` | as `direct`, no drops | All three reader invariants hold (159 states). A finished reader saw only durable rows of FULL commits. `RecoveryKeepsReadAborts` is vacuous here, because no transaction rolls back |
| `directNoDepWait` | one FULL direct commit, no drops, `GuardDepWait` false | `ReadsSurvivePowerLoss` fails (35 states). The reader tests the dependency wait |
| `directNoDepWaitDurable` | as `directNoDepWait` | `CommittedDurable` holds (35 states). So the failure above comes from the reader |
| `directDropReadUnsynced` | one FULL direct commit, with drops | `ReadsSurvivePowerLoss` fails (66 states): a dropped commit notifies before its fsync |
| `directDropResurrects` | one NORMAL direct commit, with drops | `RecoveryKeepsReadAborts` fails (58 states): the rollback leaves the frame in the file |
| `directFixSyncOnDrop` | as `directDropReadUnsynced` with `FixSyncOnDrop` | `ReadsSurvivePowerLoss` holds (59 states). The fix covers the client drop and the test yield. It does not cover the fsync error of `FINDINGS.md` row 30 |
| `mixed` | group `a`, direct `b`, both FULL, with drops | The main invariants and `ReadsSurviveCrash` hold (1,962 states) |

With any one of the three hole guards turned off, the other two still pass
at these bounds. With all three off, `AckDurable` fails. No run keeps only
one guard. This is not a reason to delete any of them.

The skip of dropped records and the abandon path have no variant. With all
guards on, the model already fails `RecoveryNoRolledBack` (`dropResurrects`),
the invariant that they protect.

## How the trace replay checks it

`harness/mbt_tests/group.rs` replays traces of `MvccGroupCommit` on the
engine. Each spec transaction has its own connection with `BEGIN
CONCURRENT`, one INSERT and a COMMIT statement that the driver steps.

- The database runs on `ShadowIo`, a test IO that wraps `MemoryIO`. It keeps
  the bytes of each file as the OS shows them and as of the last fsync. The
  power-loss probe opens the fsynced bytes. The process-crash probe opens the
  current bytes. Both write the bytes to a temporary folder and open them
  with `PlatformIO`.
- The driver holds the pager commit lock as a gate while the spec lock is
  free, so a COMMIT parks where the spec has it wait. It releases the gate
  before an `Await` that takes the lock.
- The engine gives control back only at four points: a park, the
  `LogicalLogWriteIssued` yield after a waiter record is issued, the
  `LogRecordMarkedWritten` yield after the leader marks its own record, and
  the end of the statement. A drop runs its whole cleanup. The driver steps
  the engine to its next point and then reads spec actions of the same
  transaction until the spec reaches the same point. If another transaction
  acts in between, the driver refuses the trace.
- The `mbt` configuration sets `ReplaySegments`. A transaction then acts only
  while every other one is at such a point. The generated traces all replay.
  The two-thread paths of `dropResurrects` cannot appear in them.
- After each matched step, the driver compares the engine with the spec:
  `durable_through()` and `written_through()` of the coordinator, and the
  state of each transaction. It reads the state from `txs` of the store. For
  a transaction that left `txs`, it reads its row, because a removed
  transaction is final and no speculative read applies. It compares the rows
  of the process-crash probe with the frames of the file. It compares the
  rows of the power-loss probe with the frames of `disk`. Then it checks the
  promises on the engine.
- The test requires the replayed traces to cover a list of reachability
  events, so that a change that refuses more traces fails.
- Two bug traces come from the `mbt` configuration with the invariant of a
  bug variant. Their replay must fail at the same step with
  `CommittedNotDurable` and `RolledBackReplayed`.

The direct path and the readers use the same driver.

- `GroupDriver::new_direct` sets `PRAGMA mvcc_group_commit = off`. The
  `mbtDirect` configuration has every transaction in `DirectTxs`, so it
  matches that setting. `DirectLock` releases the gate and steps the COMMIT.
  The engine runs the lock, the write and the mark in one step and stops at
  `LogRecordMarkedWritten`. The spec reaches that stop with
  `DirectMarkWritten`. The `LogicalLogWriteIssued` yield is not a stop on this
  path.
- A reader is one more connection. `Read` runs `BEGIN CONCURRENT` and
  `SELECT pk FROM t`, and the driver compares the rows with `saw`. It leaves
  out a transaction that has not started its commit, because the engine shows
  no row of it. `ReaderEnd` steps the reader COMMIT, which must end as
  `done` or `aborted` as in the spec.
- After each step, the driver checks the three reader invariants on the
  engine, with the rows that the reader scanned.
- 100 traces of `mbtDirect` replay and conform. The traces that are committed
  are `group-direct-0` and `group-direct-76`. The bug trace of
  `directDropReadUnsynced` fails at its `ReaderEnd` with `ReadNotDurable`:
  a reader finished with row 1 and a power loss recovers no row. The bug
  trace of `directDropResurrects` is refused. It drops the COMMIT between the
  issue of the write and its mark, and the engine does that in one step. So
  the resurrect path of the direct case is not verified on the engine.
- The group and direct tests pass 3 of 3 runs.

A replay that passes shows that the engine can follow the paths of the
model. It does not test paths that the model lacks.

## The direct path and readers

If its transaction is exclusive, or group commit is off, a COMMIT takes the
non-group path (`mod.rs:3404-3405`). Every write in `TransactionMode::Write` is
exclusive (`execute.rs:4385`). So a plain autocommit INSERT takes this path.
Only `BEGIN CONCURRENT` writers use group commit.

The spec models this path for the transactions of `DirectTxs`. It has three
steps. `DirectLock` takes the lock (`mod.rs:3418`). `DirectWrite` is `log_tx`
(`mod.rs:3498`). `DirectMarkWritten` marks the record (`mod.rs:3523`). It has
no ticket, so `grp` does not change. `Sync`, `End`, `CommitEnd`, `Drop` and `DropFinish` serve both paths.
An fsync error is the `Drop` at pc "sync". The error leaves `SyncLogicalLog`
(`mod.rs:3546`), the statement aborts, and abort runs the same cleanup.

A reader is one atomic `Read` and one `ReaderEnd`. `Read` sees the
transactions that are `Committed` or `Preparing`. It depends on the
`Preparing` ones (`mod.rs:11057`). The engine shows a `Preparing` version
only to a reader whose `begin_ts` is above the writer `end_ts`. The commit sets
`end_ts` when it starts (`mod.rs:11057-11068`). So `Read` counts a `Preparing`
transaction only once its commit started: its pc is not "active", or it has a ticket. A group retry goes back to "active" with its ticket and keeps its `end_ts` (`mod.rs:1980-2016`). `ReaderEnd` waits until each
dependency has its `notified` flag (`mod.rs:3343`). The guard `GuardDepWait`
turns that wait on. If a dependency is `RolledBack`, the reader aborts
(`mod.rs:3347`). A FULL commit sets `notified` after its fsync. So a reader
that finishes saw only durable rows of FULL commits. A NORMAL commit notifies
with no fsync. A dropped commit sets `notified` at once (`mod.rs:7342`),
before any fsync.

Three invariants link readers and recovery. `recovered(power)` is the set of
transactions in `disk` (power loss) or in the file (process crash).

- `ReadsSurvivePowerLoss`: a finished reader saw only FULL transactions that a
  power loss keeps.
- `ReadsSurviveCrash`: a finished reader saw only transactions that a process
  crash keeps.
- `RecoveryKeepsReadAborts`: a transaction that a finished reader saw as
  rolled back is not in `recovered`.

`FixSyncOnDrop` is a proposed fix. The cleanup fsyncs a FULL record before it
marks the transaction `Committed`. The fix covers the client drop and the test
yield. It does not cover the fsync error of `FINDINGS.md` row 30. On Linux a
failed fsync can mark dirty pages clean, and a retry can then report success
with the frame not on disk. This is why `pager.rs:4788-4796` panics. The model
does not cover that. A real fsync error can lose pages and break the CRC
chain. So for the error case, a later fsync that covers the frame
(`coveredLater`) is optimistic.

Results are in `MODEL-GAPS.md`, gap 10. The model leaves out a write that
completes after the COMMIT returned IO. The resurrect path of the direct case
needs it, because the engine writes and marks the frame in one step.

## Not modeled

The spec leaves out these parts:

- I/O errors on write, and the effect of an fsync error on the disk. The
  model has the fsync error only as the `Drop` at pc "sync".
- a write that completes after its issue. After a drop, such a write can land over the next frame at the same
  offset (`FINDINGS.md` row 23)
- the checkpoint, with its log fsync and its log truncate
- the log header
- a reader that reads a row while a commit is in flight, as more than one
  atomic step. `finish_abandoned_group_waiter` removes the transaction
  without `notify_committed_dependents` (`mod.rs:1949`). A reader that read it
  speculatively waits for ever in the model. Not verified on the engine.
- a lost wakeup in `park` (`group_commit.rs:105`). The spec has no liveness
  check.
