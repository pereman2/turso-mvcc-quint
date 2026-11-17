// -*- mode: Bluespec; -*-
/**
 * Turso MVCC group commit and the durability of a commit.
 *
 * One commit, the leader, writes the logical log records of the queued
 * commits, the waiters, and covers them with one fsync. See
 * docs/DESIGN-group-commit.md for the design in prose and the map to the
 * Rust code. Code lines are at turso rev 0c9fe0dd94. mod.rs is
 * core/mvcc/database/mod.rs, group_commit.rs is
 * core/mvcc/database/group_commit.rs.
 *
 * State.
 *   grp        GroupState of the coordinator (group_commit.rs:39).
 *   lock       The holder of pager_commit_lock, "" when free.
 *   txs        Each transaction: its commit step, ticket, state, and the
 *              batch that it leads.
 *   recs       Each ticket: its transaction and whether it needs FULL sync.
 *   log        Frames whose offset advanced, in file order.
 *   unadvanced A frame whose write was issued and whose offset did not
 *              advance. It sits right after log. The next write replaces it.
 *   disk       The frames of the file as of the last fsync. The fsync
 *              covers the unadvanced frame too.
 *   acked      Transactions whose COMMIT returned success.
 *
 * A frame is one record. A shorter frame that replaces a longer one leaves
 * bytes behind it. The spec assumes that recovery stops there, because those
 * bytes do not chain to the CRC.
 *
 * Not modeled: the non-group path (group commit off, an exclusive
 * transaction), I/O errors, the checkpoint, the log header, readers and
 * commit dependencies. SyncMode OFF acts as NORMAL here, because only FULL
 * forces an fsync (mod.rs:1960).
 */
module MvccGroupCommit {
  const Txs: Set[str]            // Transactions. Each one commits once.
  const FullTxs: Set[str]        // The transactions with SyncMode FULL. The
                                 // others use NORMAL.
  const MaxTicket: int           // Bound on tickets. A retry takes a new one.
  const CanDrop: bool            // A COMMIT statement can drop.
  // true only for trace replay: a transaction acts only while every other
  // one is at a point where the engine gives control back (field stop).
  const ReplaySegments: bool

  // Guards of the code. true in the code today.
  const GuardDensePrefix: bool   // dense_prefix_cap (group_commit.rs:322)
  const GuardFullSyncWritten: bool // needs_full_sync in log_sync_required
                                 // (mod.rs:1960)
  const GuardRetryBlocksLead: bool // take_work leads no batch while a retry
                                 // is pending (group_commit.rs:165).
  const GuardRetryHole: bool     // request_retry lowers written_through and
                                 // durable_through (group_commit.rs:252), and
                                 // note_written skips past a hole
                                 // (group_commit.rs:211).

  type Frame = { tx: str, ticket: int }
  type LogRec = { tx: str, full: bool }
  // pc: "active" (before BeginCommitLogicalLog), "await"
  // (AwaitGroupCommit), "upgrade" (UpgradeLogicalLogHeader, before the
  // owner check), "write" (WriteLogicalLog after the owner check, before
  // log_tx), "issued" (FinishLogicalLogWrite or MarkLogRecordWritten),
  // "sync" (SyncLogicalLog), "prefix" (SyncGroupPrefix), "prefixSynced"
  // (GroupPrefixSynced), "end" (EndCommitLogicalLog), "commitEnd"
  // (CommitEnd to FinalizeCommit), "done" (the statement returned),
  // "dropping" (cleanup_dropped_commit read the state), "dropped".
  // st: "Preparing", "Committed", "RolledBack".
  // led: this commit took a batch (group_batch is Some).
  // writing, rest, advanced: the batch (GroupBatch, group_commit.rs:22),
  // advanced is 0 for None.
  // appended: log_appended of the transaction.
  // stop: the engine gives control back to its caller here. A parked
  // commit, a leader after it issued a waiter record or marked its own
  // record, and a finished or dropped statement. Only ReplaySegments reads it.
  type Tx = { pc: str, ticket: int, st: str, appended: bool, led: bool,
              writing: int, rest: List[int], advanced: int, stop: bool }
  type Group = { next: int, durable: int, written: int, fullWritten: int,
                 pending: List[int], retry: Set[int], issued: str,
                 abandoned: Set[str] }

  var grp: Group
  var lock: str
  var txs: str -> Tx
  var recs: int -> LogRec
  var log: List[Frame]
  var unadvanced: Set[Frame]    // empty or one frame
  var disk: List[Frame]
  var acked: Set[str]
  var seen: Set[str]            // Events, for the reachability checks.

  pure val NoFrame: Set[Frame] = Set()

  pure def maxI(a: int, b: int): int = if (a > b) a else b
  pure def minSet(s: Set[int]): int = s.fold(1000, (m, x) => if (x < m) x else m)
  pure def removeFrom(l: List[int], x: int): List[int] = l.select(y => y != x)
  pure def hasTx(l: List[Frame], t: str): bool = l.indices().exists(i => l[i].tx == t)

  // The frames that the OS shows: the log, then the unadvanced frame.
  def fileFrames: List[Frame] =
    unadvanced.fold(log, (l, f) => l.append(f))

  // A transaction is in `txs` of the engine: not removed by a rollback or
  // by the end of its commit.
  def live(t: str): bool =
    txs.get(t).st == "Preparing"

  // dense_prefix_cap (group_commit.rs:322).
  def densePrefixCap(ticket: int, g: Group): int =
    val cap = if (ticket < g.written) ticket else g.written
    val holes = g.retry.filter(h => h <= cap)
    if (GuardDensePrefix and holes.size() > 0) minSet(holes) - 1 else cap

  // mark_durable (group_commit.rs:194). It runs after the fsync, or where
  // the fsync was skipped because no record needs FULL.
  def markDurable(g: Group, ticket: int): Group =
    { ...g, durable: maxI(g.durable, densePrefixCap(ticket, g)) }

  // note_written (group_commit.rs:209).
  def noteWritten(g: Group, ticket: int): Group =
    if (GuardRetryHole and g.retry.exists(h => h <= ticket)) g
    else { ...g, written: maxI(g.written, ticket) }

  // request_retry (group_commit.rs:248).
  def requestRetry(g: Group, ticket: int): Group =
    if (GuardRetryHole)
      { ...g, retry: g.retry.union(Set(ticket)),
        written: if (g.written >= ticket) ticket - 1 else g.written,
        durable: if (g.durable >= ticket) ticket - 1 else g.durable }
    else { ...g, retry: g.retry.union(Set(ticket)) }

  // needs_full_sync (group_commit.rs:222) inside log_sync_required
  // (mod.rs:1960).
  def syncRequired(t: str): bool =
    FullTxs.contains(t) or (GuardFullSyncWritten and grp.fullWritten > grp.durable)

  action Init = all {
    grp' = { next: 0, durable: 0, written: 0, fullWritten: 0, pending: List(),
             retry: Set(), issued: "", abandoned: Set() },
    lock' = "",
    txs' = Txs.mapBy(t => { pc: "active", ticket: 0, st: "Preparing",
                             appended: false, led: false, writing: 0,
                             rest: List(), advanced: 0, stop: true }),
    recs' = Map(),
    log' = List(),
    unadvanced' = NoFrame,
    disk' = List(),
    acked' = Set(),
    seen' = Set(),
  }

  // BeginCommitLogicalLog, group path (mod.rs:3408, enqueue at
  // group_commit.rs:139). A retry builds the record again and comes back
  // here with a new ticket.
  action Enqueue(t: str): bool = all {
    txs.get(t).pc == "active",
    grp.next < MaxTicket,
    val tk = grp.next + 1
    all {
      grp' = { ...grp, next: tk, pending: grp.pending.append(tk) },
      recs' = recs.put(tk, { tx: t, full: FullTxs.contains(t) }),
      txs' = txs.set(t, { ...txs.get(t), pc: "await", ticket: tk, stop: true }),
    },
    lock' = lock, log' = log, unadvanced' = unadvanced, disk' = disk,
    acked' = acked, seen' = seen,
  }

  // step_await_group_commit (mod.rs:2009). One step: the durable check,
  // the retry check, and with the lock free, the second retry check and
  // take_work (group_commit.rs:163). These run under the lock or read
  // values that only the lock holder changes. A park changes nothing, so it
  // is no action.
  action Await(t: str): bool = all {
    val x = txs.get(t)
    all {
      x.pc == "await",
      if (grp.durable >= x.ticket) all {
        // Durable: go to EndCommitLogicalLog without the lock. The engine
        // stops here only if the commit was parked before.
        txs' = txs.set(t, { ...x, pc: "end", stop: x.stop }),
        grp' = grp, lock' = lock, seen' = seen,
      } else if (grp.retry.contains(x.ticket)) all {
        // take_retry: build the record again (rebuild_log_record).
        txs' = txs.set(t, { ...x, pc: "active", stop: false }),
        grp' = { ...grp, retry: grp.retry.exclude(Set(x.ticket)) },
        lock' = lock, seen' = seen.union(Set("retry")),
      } else all {
        lock == "",
        val leadable = not(GuardRetryBlocksLead) or grp.retry.size() == 0
        if (leadable and grp.pending.length() > 0) all {
          // GroupWork::Lead: the batch is every pending commit.
          txs' = txs.set(t, { ...x, pc: "upgrade", led: true,
                               writing: grp.pending[0],
                               rest: grp.pending.slice(1, grp.pending.length()),
                               advanced: 0, stop: false }),
          grp' = { ...grp, pending: List() },
          lock' = t,
          seen' = seen.union(if (grp.pending.length() >= 2) Set("batch2") else Set()),
        } else all {
          // GroupWork::SyncPrefix.
          grp.written > grp.durable,
          txs' = txs.set(t, { ...x, pc: "prefix", stop: false }),
          grp' = grp, lock' = t, seen' = seen.union(Set("syncPrefix")),
        }
      }
    },
    recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk,
    acked' = acked,
  }

  // The leader moves to the next record of its batch, or to the sync
  // (advance_group_or_sync, mod.rs:1975).
  def advance(x: Tx): Tx =
    if (x.rest.length() > 0)
      { ...x, pc: "upgrade", writing: x.rest[0], rest: x.rest.slice(1, x.rest.length()) }
    else { ...x, pc: "sync" }

  // UpgradeLogicalLogHeader and the check at the top of WriteLogicalLog
  // (mod.rs:3453, mod.rs:3489): a record whose transaction left txs is
  // skipped. Another thread can drop the owner after this check.
  action IssueCheck(t: str): bool = all {
    val x = txs.get(t)
    val owner = recs.get(x.writing).tx
    all {
      x.pc == "upgrade",
      txs' = if (live(owner)) txs.set(t, { ...x, pc: "write", stop: false })
             else txs.set(t, { ...advance(x), stop: false }),
      seen' = if (live(owner)) seen else seen.union(Set("skipDropped")),
    },
    grp' = grp, lock' = lock, recs' = recs, log' = log, unadvanced' = unadvanced,
    disk' = disk, acked' = acked,
  }

  // log_tx and note_write_issued (mod.rs:3498, mod.rs:3501). The frame is
  // written at the current offset, also when its owner rolled back after
  // IssueCheck. The write completes here. A write that completes later is
  // not modeled: after a drop, it can land over the next frame at the same
  // offset.
  action IssueWrite(t: str): bool = all {
    val x = txs.get(t)
    val owner = recs.get(x.writing).tx
    all {
      x.pc == "write",
      txs' = txs.set(t, { ...x, pc: "issued", stop: owner != t }),
      grp' = { ...grp, issued: owner },
      unadvanced' = Set({ tx: owner, ticket: x.writing }),
      seen' = seen.union(if (live(owner)) Set() else Set("writeRolledBack")),
    },
    lock' = lock, recs' = recs, log' = log, disk' = disk, acked' = acked,
  }

  // FinishLogicalLogWrite and MarkLogRecordWritten (mod.rs:3518, mod.rs:3528,
  // mark_log_record_written at mod.rs:1895). The offset advances over the
  // frame. An abandoned owner becomes Committed at once
  // (finish_abandoned_group_waiter, mod.rs:1933).
  action MarkWritten(t: str): bool = all {
    val x = txs.get(t)
    val w = x.writing
    val owner = recs.get(w).tx
    val g1 = noteWritten(grp, w)
    val g2 = if (recs.get(w).full) { ...g1, fullWritten: maxI(g1.fullWritten, w) } else g1
    val abandonedOwner = owner != t and grp.abandoned.contains(owner)
    val g3 = { ...g2, issued: "",
               abandoned: grp.abandoned.exclude(Set(owner)) }
    val x2 = { ...advance({ ...x, advanced: w, appended: x.appended or owner == t }),
               stop: owner == t }
    val o = txs.get(owner)
    all {
      x.pc == "issued",
      grp' = g3,
      log' = log.append({ tx: owner, ticket: w }),
      unadvanced' = NoFrame,
      txs' = if (owner == t) txs.set(t, x2)
             else txs.set(t, x2).set(owner,
               if (abandonedOwner) { ...o, appended: true, st: "Committed" }
               else { ...o, appended: true }),
      seen' = seen.union(if (abandonedOwner) Set("abandonCommit") else Set()),
    },
    lock' = lock, recs' = recs, disk' = disk, acked' = acked,
  }

  // The fsync of SyncLogicalLog (mod.rs:3542) and SyncGroupPrefix
  // (mod.rs:3558). It covers every completed write, also the unadvanced
  // frame. It is skipped when no record needs FULL.
  def fsync(t: str): List[Frame] =
    if (syncRequired(t)) fileFrames else disk

  action Sync(t: str): bool = all {
    txs.get(t).pc == "sync",
    disk' = fsync(t),
    txs' = txs.set(t, { ...txs.get(t), pc: "end", stop: false }),
    seen' = seen.union(
      if (not(FullTxs.contains(t)) and syncRequired(t)) Set("normalLeaderSyncs") else Set()),
    grp' = grp, lock' = lock, recs' = recs, log' = log, unadvanced' = unadvanced,
    acked' = acked,
  }

  action SyncPrefix(t: str): bool = all {
    txs.get(t).pc == "prefix",
    disk' = fsync(t),
    txs' = txs.set(t, { ...txs.get(t), pc: "prefixSynced", stop: false }),
    grp' = grp, lock' = lock, recs' = recs, log' = log, unadvanced' = unadvanced,
    acked' = acked, seen' = seen,
  }

  // GroupPrefixSynced (mod.rs:3572): mark durable, release the lock, and
  // wait again.
  action PrefixSynced(t: str): bool = all {
    txs.get(t).pc == "prefixSynced",
    grp' = markDurable(grp, grp.written),
    lock' = "",
    txs' = txs.set(t, { ...txs.get(t), pc: "await", stop: false }),
    recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk,
    acked' = acked, seen' = seen,
  }

  // EndCommitLogicalLog (mod.rs:3586). A leader marks its batch durable.
  // That wakes parked waiters, which can finish before this commit is
  // Committed.
  action End(t: str): bool = all {
    val x = txs.get(t)
    all {
      x.pc == "end",
      grp' = if (x.led) markDurable(grp, grp.written) else grp,
      txs' = txs.set(t, { ...x, pc: "commitEnd", led: false, stop: false }),
    },
    lock' = lock, recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk,
    acked' = acked, seen' = seen,
  }

  // CommitEnd (mod.rs:3629), RewriteLiveVersions and FinalizeCommit
  // (mod.rs:3661), merged: Committed, the lock release, and COMMIT returns
  // success. A drop in RewriteLiveVersions takes the Committed branch of
  // cleanup_dropped_commit, which gives the same state without the ack.
  action CommitEnd(t: str): bool = all {
    val x = txs.get(t)
    all {
      x.pc == "commitEnd",
      txs' = txs.set(t, { ...x, pc: "done", st: "Committed", stop: true }),
      lock' = if (lock == t) "" else lock,
      acked' = acked.union(Set(t)),
    },
    grp' = grp, recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk,
    seen' = seen,
  }

  // cleanup_unfinished_commit (mod.rs:1846): release_group_claim
  // (mod.rs:1792), drop_pending, the discard of a pending write, and the
  // first half of cleanup_dropped_commit (mod.rs:7292), which reads
  // log_appended. A transaction with log_appended becomes Committed. Any
  // other one goes on to DropFinish.
  action Drop(t: str): bool = all {
    CanDrop,
    not(ReplaySegments) or txs.get(t).stop,
    val x = txs.get(t)
    val owner = recs.get(x.writing).tx
    val submitted = x.pc == "issued"
    val beforeLogTx = x.led and Set("upgrade", "write").contains(x.pc)
    val markedWritten = x.advanced == x.writing
    // release_group_claim
    val g1 =
      if (not(x.led)) grp
      else if (beforeLogTx)
        { ...grp, pending: List(x.writing).concat(x.rest).concat(grp.pending) }
      else if (not(markedWritten) and submitted)
        val gc = { ...grp, issued: "", pending: x.rest.concat(grp.pending) }
        if (owner != t and not(gc.abandoned.contains(owner))) requestRetry(gc, x.writing)
        else if (owner != t) { ...gc, abandoned: gc.abandoned.exclude(Set(owner)) }
        else gc
      else { ...grp, pending: x.rest.concat(grp.pending) }
    val rollOwner = x.led and not(beforeLogTx) and not(markedWritten) and submitted
                    and owner != t and grp.abandoned.contains(owner)
    // drop_pending for a waiter.
    val g2 = if (x.pc == "await")
               { ...g1, retry: g1.retry.exclude(Set(x.ticket)),
                 pending: removeFrom(g1.pending, x.ticket) }
             else g1
    val toCommitted = x.st == "Preparing" and x.appended
    val txs1 = if (rollOwner) txs.set(owner, { ...txs.get(owner), st: "RolledBack" }) else txs
    all {
      // "active" with a ticket: BuildLogRecord after a retry, which yields.
      Set("await", "upgrade", "write", "issued", "sync", "prefix", "prefixSynced",
          "end", "commitEnd").contains(x.pc) or (x.pc == "active" and x.ticket > 0),
      grp' = g2,
      txs' = txs1.set(t,
        if (toCommitted) { ...x, pc: "dropped", st: "Committed", led: false, stop: true }
        else { ...x, pc: "dropping", led: false, stop: false }),
      lock' = if (lock == t and toCommitted) "" else lock,
      seen' = seen
        .union(if (toCommitted) Set("dropCommit") else Set())
        .union(if (rollOwner) Set("abandonRollback") else Set()),
    },
    recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk, acked' = acked,
  }

  // The second half of cleanup_dropped_commit: abandon_if_issued
  // (group_commit.rs:275) under the group lock, else rollback_tx_inner,
  // which releases the commit lock.
  action DropFinish(t: str): bool = all {
    val x = txs.get(t)
    val abandon = grp.issued == t
    all {
      x.pc == "dropping",
      grp' = if (abandon) { ...grp, abandoned: grp.abandoned.union(Set(t)) } else grp,
      txs' = txs.set(t, { ...x, pc: "dropped", stop: true,
                          st: if (abandon) "Preparing" else "RolledBack" }),
      lock' = if (lock == t) "" else lock,
      seen' = seen
        .union(if (abandon) Set("abandon") else Set())
        .union(if (not(abandon) and hasTx(fileFrames, t)) Set("rollbackWritten") else Set()),
    },
    recs' = recs, log' = log, unadvanced' = unadvanced, disk' = disk, acked' = acked,
  }

  action Next = {
    nondet t = Txs.oneOf()
    all {
      not(ReplaySegments) or Txs.forall(u => u == t or txs.get(u).stop),
      any {
        Enqueue(t),
        Await(t),
        IssueCheck(t),
        IssueWrite(t),
        MarkWritten(t),
        Sync(t),
        SyncPrefix(t),
        PrefixSynced(t),
        End(t),
        CommitEnd(t),
        Drop(t),
        DropFinish(t),
      }
    }
  }

  // Invariants.

  val TypeOK =
    unadvanced.size() <= 1 and disk.length() <= log.length() + 1

  // An acknowledged FULL commit survives a power loss: its frame is on disk.
  val AckDurable =
    acked.forall(t => not(FullTxs.contains(t)) or hasTx(disk, t))

  // An acknowledged commit of any sync mode survives a process crash: its
  // frame is in the log.
  val AckLogged =
    acked.forall(t => hasTx(log, t))

  // A Committed FULL transaction survives a power loss. Readers and
  // dependents see it from Committed on. A dropped COMMIT breaks it in the
  // code today: see dropCommitsUnsynced.
  val CommittedDurable =
    Txs.forall(t => txs.get(t).st != "Committed" or not(FullTxs.contains(t)) or hasTx(disk, t))

  // A Committed transaction of any mode has its frame in the log.
  val CommittedLogged =
    Txs.forall(t => txs.get(t).st != "Committed" or hasTx(log, t))

  // Recovery replays no rolled-back transaction, after a process crash (the
  // file) or after a power loss (the disk).
  val RecoveryNoRolledBack =
    fileFrames.indices().forall(i => txs.get(fileFrames[i].tx).st != "RolledBack")
    and disk.indices().forall(i => txs.get(disk[i].tx).st != "RolledBack")

  // No transaction has two frames in the log.
  val OneFramePerTx =
    log.indices().forall(i => log.indices().forall(j =>
      i == j or log[i].tx != log[j].tx))

  // Reachability checks. Each must fail.
  val NeverBatchTwo = not(seen.contains("batch2"))
  val NeverRetry = not(seen.contains("retry"))
  val NeverAbandon = not(seen.contains("abandon"))
  val NeverAbandonCommit = not(seen.contains("abandonCommit"))
  val NeverSyncPrefix = not(seen.contains("syncPrefix"))
  val NeverDropCommit = not(seen.contains("dropCommit"))
  val NeverNormalLeaderSyncs = not(seen.contains("normalLeaderSyncs"))
  val NeverWriteRolledBack = not(seen.contains("writeRolledBack"))
  val NeverRollbackWritten = not(seen.contains("rollbackWritten"))
  val NeverAbandonRollback = not(seen.contains("abandonRollback"))
  val NeverSkipDropped = not(seen.contains("skipDropped"))
  val NeverAllAcked = acked != Txs
}
