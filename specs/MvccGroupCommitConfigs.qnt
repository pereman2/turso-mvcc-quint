// Configurations of MvccGroupCommit.qnt. Each module sets the constants of
// one configuration. The comment above a module gives the result to expect
// and the invariants to check. The Makefile reads these comments.

// Expect no error: the code today. Three commits, a and c with FULL, b with
// NORMAL. Each COMMIT statement can drop at any step. A retry takes a new
// ticket. CommittedDurable and RecoveryNoRolledBack fail in the code today:
// see dropCommitsUnsynced and dropResurrects.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx
module main {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// The module for make traces. As main, but a transaction acts only where the
// engine gives control back, so the trace replay can follow it. It is not
// model checked.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx
module mbt {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = true,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect CommittedDurable to fail: a COMMIT that drops after its record is
// written makes the transaction Committed before any fsync covers it
// (cleanup_dropped_commit, mod.rs:7296). The same holds for a waiter that
// abandoned after its write was issued (finish_abandoned_group_waiter,
// mod.rs:1933). No COMMIT returns success there, so AckDurable holds.
// Invariants: CommittedDurable
module dropCommitsUnsynced {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect RecoveryNoRolledBack to fail: a transaction rolls back while its
// frame is in the file, and a crash replays it. Four paths. A COMMIT drops
// while the write of its own record is issued (one transaction, the shortest
// path). A leader drops after it issued the write of an abandoned waiter. A
// waiter drops between the owner check of the leader and log_tx. A waiter
// drops, reads log_appended as false, and the leader marks its record
// written before abandon_if_issued.
// Invariants: RecoveryNoRolledBack
module dropResurrects {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect no error: no COMMIT drops. A positive control for CommittedDurable:
// without drops, a Committed FULL transaction is on disk. RecoveryNoRolledBack
// holds by construction here, because nothing rolls back.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx CommittedDurable RecoveryNoRolledBack
module noDrop {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = false,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect AckDurable to fail: without needs_full_sync, a NORMAL leader skips
// the fsync and marks the record of a FULL waiter durable.
// Invariants: AckDurable
module noFullSyncWritten {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = false,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect no error: without dense_prefix_cap. Not shown needed at these
// bounds: TLC finds no error with this guard off and the other
// two hole guards on.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx
module noDensePrefix {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = false,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect no error: without the hole in written_through. Not shown needed at
// these bounds: TLC finds no error with this guard off and the other
// two hole guards on.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx
module noRetryHole {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = false
  ).* from "./MvccGroupCommit"
}

// Expect no error: without the retry check in take_work. Not shown needed at
// these bounds: TLC finds no error with this guard off and the other
// two hole guards on.
// Invariants: TypeOK AckDurable AckLogged CommittedLogged OneFramePerTx
module noRetryBlocksLead {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = false,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect AckDurable to fail: without the three hole guards (the retry check
// in take_work, the hole in written_through and dense_prefix_cap). A later
// ticket marks the retry ticket durable, and its waiter returns success with
// no frame in the log.
// Invariants: AckDurable
module noHoleGuards {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = false,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = false,
    GuardRetryHole = false
  ).* from "./MvccGroupCommit"
}

// Expect NeverBatchTwo to fail: a leader writes a batch of two records.
// Invariants: NeverBatchTwo
module reachBatchTwo {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverRetry to fail: a waiter builds its record again after a retry.
// Invariants: NeverRetry
module reachRetry {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverAbandon to fail: a waiter abandons after its write was issued.
// Invariants: NeverAbandon
module reachAbandon {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverAbandonCommit to fail: the leader commits an abandoned waiter.
// Invariants: NeverAbandonCommit
module reachAbandonCommit {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverSyncPrefix to fail: a waiter fsyncs a written prefix that a dropped leader left.
// Invariants: NeverSyncPrefix
module reachSyncPrefix {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverDropCommit to fail: a dropped COMMIT with a written record becomes Committed.
// Invariants: NeverDropCommit
module reachDropCommit {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverNormalLeaderSyncs to fail: a NORMAL leader fsyncs because its batch has a FULL record.
// Invariants: NeverNormalLeaderSyncs
module reachNormalLeaderSyncs {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverWriteRolledBack to fail: a leader writes the frame of an owner that rolled back after the owner check.
// Invariants: NeverWriteRolledBack
module reachWriteRolledBack {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverRollbackWritten to fail: a dropped COMMIT rolls back while its frame is in the file.
// Invariants: NeverRollbackWritten
module reachRollbackWritten {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverAbandonRollback to fail: a dropping leader rolls back an abandoned waiter.
// Invariants: NeverAbandonRollback
module reachAbandonRollback {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverSkipDropped to fail: a leader skips the record of a transaction that left txs.
// Invariants: NeverSkipDropped
module reachSkipDropped {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}

// Expect NeverAllAcked to fail: every commit returns success.
// Invariants: NeverAllAcked
module reachAllAcked {
  import MvccGroupCommit(
    Txs = Set("a", "b", "c"),
    FullTxs = Set("a", "c"),
    MaxTicket = 4,
    CanDrop = true,
    ReplaySegments = false,
    GuardDensePrefix = true,
    GuardFullSyncWritten = true,
    GuardRetryBlocksLead = true,
    GuardRetryHole = true
  ).* from "./MvccGroupCommit"
}
