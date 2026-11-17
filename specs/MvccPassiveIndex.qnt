// -*- mode: Bluespec; -*-
/**
 * Turso MVCC passive checkpoint: index rows.
 *
 * One row (rowid 1) of a table t(k INTEGER PRIMARY KEY, v INTEGER) with an
 * index on v. The row has a table chain. Each index key x, the record (x, 1),
 * has its own chain in index_rows. A commit that changes v ends the chain of
 * the old index key and starts the chain of the new one. The checkpoint
 * collects table rows and index rows in separate phases with one snapshot,
 * writes both in one WAL frame, and stamps them in separate phases. Two GC
 * loops, one for table chains and one for index chains, run at any moment.
 * See docs/DESIGN-indexes.md for the design and the mapping to the code.
 *
 * Checked properties.
 *   IndexReadsCorrect       An index lookup of key x at begin b finds x
 *                           exactly when the row has value x at b.
 *   BtreeIndexMatchesTable  Every readable B-tree image has the index
 *                           entries of its row.
 *   RecoveryCorrect         A crash now recovers the row and the index of the
 *                           last logged commit.
 *   IndexChainsStamped      After a completed pass, every index version at or
 *                           below durable is stamped, so GC can drop it.
 *
 * Not modeled: more rows, unique indexes, aborts, failed passes, a checkpoint
 * on a reader connection, WAL restart, modes B and T, index DDL.
 */
module MvccPassiveIndex {
  const Vals: Set[int]            // Row values. Index key x is the record (x, rowid 1).
  const Readers: Set[str]
  const MaxTs: int
  const MaxCheckpoints: int

  // Rules of the code. The main configuration sets all of them to true.
  const MarkIndexKeys: bool          // MarkDirtyKeys marks the index keys of the write set
  const StampIndexRows: bool         // GcIndexRows stamps the collected index chains
  const IndexGcWaitsForReaders: bool // index GC Rule 2 and 3 need mat <= floor
  const PruneKeepsNewerStamp: bool   // PruneDirtyKeys keeps an index key whose stamp rose
  const StampUnwrittenIndexRows: bool // GcIndexRows stamps unwritten_index_rows
  const IndexRule3OnlyWhenIdle: bool  // index GC Rule 3 needs lwm == MAX (mod.rs:8623-8628)

  // Trace replay constants (docs/HARNESS.md). False in every checked module.
  const BackfillToLimit: bool
  const LogAppendOneAtATime: bool
  const WriterBeginTicks: bool
  const WritersPinMarks: bool

  pure val Inf = 1000
  pure val None = -1
  pure val NoWrite = -1

  /* A version is { b, e, value, mat } as in MvccPassiveCheckpoint.qnt. b = 0
     is "begin None", a marker for an entry that was only in the B-tree. For a
     table version, value is the row value. For an index version, value is 1. */
  type Version = { b: int, e: int, value: int, mat: int }
  // A commit: new row value v (0 = delete) and the old row value.
  type Write = { ts: int, v: int, old: int }
  type Inflight = { ts: int, v: int, old: int, marked: bool, logged: bool, mark: int }
  // row = NoWrite: the frame does not write the row. idx: written index keys,
  // 1 = insert, 0 = delete.
  type WalFrame = { row: int, idx: int -> int, meta: int }
  // iw: index keys that the frame writes. iu: unwritten_index_rows, keys that
  // changed in (old, snap] but need no write (inserted and deleted after old).
  type CkState = { pc: str, snap: int, old: int, row: int, iw: int -> int, iu: Set[int],
                   frame: int, tcand: int, icand: int -> int, completed: bool }
  type RdState = { pc: str, pinned: bool, mark: int, b: int, key: int, vis1: bool,
                   valid1: bool }
  type ErrRec = { reader: str, key: int, begin: int, mark: int, got: Set[int], want: int }

  var clock: int
  var tchain: Set[Version]
  var ichain: int -> Set[Version]
  var inflight: Set[Inflight]
  var lastCommitted: int
  var llog: Set[Write]
  var wal: List[WalFrame]
  var nBackfill: int
  var dbRow: int                 // row value in the database file, 0 = no row
  var dbIdx: int -> int          // dbIdx[x] = 1 when the index entry x is in the file
  var dbMeta: int
  var durable: int
  var backfillFloor: int
  var ck: CkState
  var nCk: int
  var rd: str -> RdState
  var writes: Set[Write]         // History: every prepared commit.
  var logged: Set[Write]         // History: every commit in the logical log.
  var err: Set[ErrRec]           // History: wrong index lookups.
  var tdirty: int                // stamp in checkpoint_dirty_table_keys, 0 = none
  var idirty: int -> int         // stamps in checkpoint_dirty_index_keys

  // ---------------------------------------------------------------------------
  // Helpers

  pure def Max(S: Set[int]): int = S.fold(-Inf - 1, (a, x) => if (x > a) x else a)
  pure def Min(S: Set[int]): int = S.fold(Inf + 1, (a, x) => if (x < a) x else a)

  pure def AnyVersion(c: Set[Version]): Version =
    c.fold({ b: -1, e: 0, value: 0, mat: 0 }, (a, x) => if (a.b == -1) x else a)

  pure val NoIdx: int -> int = Map()

  val InflightTs: Set[int] = inflight.map(i => i.ts)
  def Resolved(t: int): bool = not(InflightTs.contains(t))

  // Row value after the writes in W below t. 0 = no row.
  pure def LatestIn(W: Set[Write], t: int): int =
    val ws = W.filter(w => w.ts < t)
    if (ws == Set()) 0
    else ws.fold({ ts: -1, v: 0, old: 0 }, (a, w) => if (w.ts > a.ts) w else a).v

  def Oracle(b: int): int = LatestIn(writes, b)
  def IdxOracle(x: int, b: int): int = if (Oracle(b) == x) 1 else 0

  pure def Visible(c: Set[Version], b: int): Set[Version] =
    c.filter(v => v.b != 0 and v.b < b and b < v.e)

  pure def BtreeRowValid(c: Set[Version], b: int): bool = and {
    Visible(c, b) == Set(),
    not(c.exists(v => v.e < b)),
  }

  def Frame(i: int): WalFrame = wal[i - 1]

  // The B-tree through WAL read mark m: the newest frame at or below m that
  // wrote the entry, else the database file.
  def RowFrames(lo: int, hi: int): Set[int] = lo.to(hi).filter(i => Frame(i).row != NoWrite)
  def IdxFrames(x: int, lo: int, hi: int): Set[int] =
    lo.to(hi).filter(i => Frame(i).idx.keys().contains(x))

  def BtreeRowAt(m: int): int =
    if (RowFrames(1, m) == Set()) dbRow else Frame(Max(RowFrames(1, m))).row
  def BtreeIdxAt(x: int, m: int): int =
    if (IdxFrames(x, 1, m) == Set()) dbIdx.get(x) else Frame(Max(IdxFrames(x, 1, m))).idx.get(x)

  val Pinned: Set[str] = Readers.filter(r => rd.get(r).pinned)
  val Registered: Set[str] = Readers.filter(r => Set("active", "reading").contains(rd.get(r).pc))
  val AnyVal: int = Vals.fold(None, (a, x) => if (a == None) x else a)

  // ---------------------------------------------------------------------------
  // Initial state

  action Init = all {
    clock' = 0,
    tchain' = Set(),
    ichain' = Vals.mapBy(x => Set()),
    inflight' = Set(),
    lastCommitted' = 0,
    llog' = Set(),
    wal' = List(),
    nBackfill' = 0,
    dbRow' = 0,
    dbIdx' = Vals.mapBy(x => 0),
    dbMeta' = 0,
    durable' = 0,
    backfillFloor' = 0,
    ck' = { pc: "idle", snap: 0, old: 0, row: NoWrite, iw: NoIdx, iu: Set(), frame: 0, tcand: 0,
            icand: NoIdx, completed: false },
    nCk' = 0,
    rd' = Readers.mapBy(r => { pc: "idle", pinned: false, mark: 0, b: 0, key: AnyVal,
                               vis1: false, valid1: false }),
    writes' = Set(),
    logged' = Set(),
    err' = Set(),
    tdirty' = 0,
    idirty' = Vals.mapBy(x => 0),
  }

  // ---------------------------------------------------------------------------
  // Writers

  // End the current version of chain c at ts. If the chain has none but the
  // entry is in the B-tree, add a marker with begin None.
  pure def EndCurrent(c: Set[Version], ts: int, oldValue: int): Set[Version] =
    val cur = c.filter(x => x.e == Inf and x.b != 0)
    if (cur != Set()) c.exclude(cur).union(cur.map(x => { ...x, e: ts, mat: 0 }))
    else c.union(Set({ b: 0, e: ts, value: oldValue, mat: 0 }))

  action UnchangedCheckpointVars = all {
    wal' = wal, nBackfill' = nBackfill, dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk,
  }

  // INSERT, UPDATE or DELETE of the row in one commit. The table chain and the
  // two index chains change in the same transaction. Writes to the same row
  // conflict, so one commit is in flight at a time. UPDATE t SET v = v also
  // rewrites the index entry: the planner updates the index of every SET
  // column (core/translate/update.rs:581-672).
  action WritePrepare(v: int): bool = {
    val ts = if (WriterBeginTicks) clock + 2 else clock + 1
    val old = Oracle(ts)
    all {
      ts <= MaxTs,
      inflight == Set(),
      not(v == 0 and old == 0),
      clock' = ts,
      tchain' = (if (old != 0) EndCurrent(tchain, ts, old) else tchain)
                  .union(if (v != 0) Set({ b: ts, e: Inf, value: v, mat: 0 }) else Set()),
      ichain' = Vals.mapBy(x =>
                  (if (x == old) EndCurrent(ichain.get(x), ts, 1) else ichain.get(x))
                    .union(if (x == v) Set({ b: ts, e: Inf, value: 1, mat: 0 }) else Set())),
      inflight' = Set({ ts: ts, v: v, old: old, marked: false, logged: false,
                        mark: if (WritersPinMarks) wal.length() else 0 }),
      writes' = writes.union(Set({ ts: ts, v: v, old: old })),
      lastCommitted' = lastCommitted, llog' = llog, rd' = rd, logged' = logged, err' = err,
      tdirty' = tdirty, idirty' = idirty,
      UnchangedCheckpointVars,
    }
  }

  // MarkDirtyKeys: one step marks the whole write set (up to 1024 keys).
  action WriteMarkDirty(i: Inflight): bool = all {
    not(i.marked),
    tdirty' = Max(Set(tdirty, i.ts)),
    idirty' = Vals.mapBy(x =>
                if (MarkIndexKeys and (x == i.v or x == i.old)) Max(Set(idirty.get(x), i.ts))
                else idirty.get(x)),
    inflight' = Set({ ...i, marked: true }),
    clock' = clock, tchain' = tchain, ichain' = ichain, lastCommitted' = lastCommitted,
    llog' = llog, rd' = rd, writes' = writes, logged' = logged, err' = err,
    UnchangedCheckpointVars,
  }

  // The log record holds the table write and the two index writes.
  action WriteLogAppend(i: Inflight): bool = all {
    i.marked, not(i.logged),
    llog' = llog.union(Set({ ts: i.ts, v: i.v, old: i.old })),
    logged' = logged.union(Set({ ts: i.ts, v: i.v, old: i.old })),
    inflight' = Set({ ...i, logged: true }),
    clock' = clock, tchain' = tchain, ichain' = ichain, lastCommitted' = lastCommitted,
    rd' = rd, writes' = writes, err' = err, tdirty' = tdirty, idirty' = idirty,
    UnchangedCheckpointVars,
  }

  action WriteFinish(i: Inflight): bool = all {
    i.logged,
    inflight' = Set(),
    lastCommitted' = Max(Set(lastCommitted, i.ts)),
    clock' = clock, tchain' = tchain, ichain' = ichain, llog' = llog, rd' = rd,
    writes' = writes, logged' = logged, err' = err, tdirty' = tdirty, idirty' = idirty,
    UnchangedCheckpointVars,
  }

  // ---------------------------------------------------------------------------
  // Readers

  action UnchangedForReaders = all {
    clock' = clock, tchain' = tchain, ichain' = ichain, inflight' = inflight,
    lastCommitted' = lastCommitted, llog' = llog, writes' = writes, logged' = logged,
    tdirty' = tdirty, idirty' = idirty,
    UnchangedCheckpointVars,
  }

  action ReaderPin(r: str): bool = all {
    rd.get(r).pc == "idle",
    rd' = rd.setBy(r, x => { ...x, pc: "pinned", pinned: true, mark: wal.length() }),
    err' = err, UnchangedForReaders,
  }

  action ReaderBegin(r: str): bool = all {
    rd.get(r).pc == "pinned",
    clock < MaxTs,
    clock' = clock + 1,
    rd' = rd.setBy(r, x => { ...x, pc: "active", b: clock + 1 }),
    tchain' = tchain, ichain' = ichain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, writes' = writes, logged' = logged, err' = err,
    tdirty' = tdirty, idirty' = idirty,
    UnchangedCheckpointVars,
  }

  // The dual cursor of an index lookup or scan looks at the chain of index
  // key x twice: the MVCC side for a visible version, the B-tree side for
  // index_chain_invalidates_btree. ReaderReadStart takes the first look. If
  // the MVCC side wins, Column reads the visible version a third time
  // (cursor.rs:698-703), which ReaderReadEnd also does.
  action ReaderReadStart(r: str, x: int): bool = all {
    rd.get(r).pc == "active",
    rd' = rd.setBy(r, y => { ...y, pc: "reading", key: x,
                             vis1: Visible(ichain.get(x), y.b) != Set(),
                             valid1: BtreeRowValid(ichain.get(x), y.b) }),
    err' = err, UnchangedForReaders,
  }

  action ReaderReadEnd(r: str): bool = {
    val x = rd.get(r).key
    val b = rd.get(r).b
    val vis2 = Visible(ichain.get(x), b) != Set()
    val valid2 = BtreeRowValid(ichain.get(x), b)
    val bt = BtreeIdxAt(x, rd.get(r).mark)
    val resA = if (rd.get(r).vis1) (if (vis2) 1 else 0) else if (valid2) bt else 0
    val resB = if (vis2) 1 else if (rd.get(r).valid1) bt else 0
    val want = IdxOracle(x, b)
    all {
      rd.get(r).pc == "reading",
      err' = if (resA == want and resB == want) err
             else err.union(Set({ reader: r, key: x, begin: b, mark: rd.get(r).mark,
                                  got: Set(resA, resB), want: want })),
      rd' = rd.setBy(r, y => { ...y, pc: "active" }),
      UnchangedForReaders,
    }
  }

  action ReaderEnd(r: str): bool = all {
    Set("pinned", "active").contains(rd.get(r).pc),
    rd' = rd.setBy(r, y => { ...y, pc: "idle", pinned: false }),
    err' = err, UnchangedForReaders,
  }

  // ---------------------------------------------------------------------------
  // Checkpoint

  val SnapshotTs: int =
    if (inflight != Set()) Min(Set(lastCommitted, Min(InflightTs) - 1)) else lastCommitted

  def ChangedSince(c: Set[Version], old: int, snap: int): bool =
    c.exists(v => or {
      v.b != 0 and Resolved(v.b) and old < v.b and v.b <= snap,
      v.e != Inf and Resolved(v.e) and old < v.e and v.e <= snap,
    })

  def ValueAt(c: Set[Version], t: int): int =
    val vs = c.filter(v => and {
      v.b != 0, Resolved(v.b), v.b <= t,
      v.e == Inf or not(Resolved(v.e)) or t < v.e,
    })
    if (vs == Set()) 0 else AnyVersion(vs).value

  pure def LastEvent(v: Version): int = if (v.e != Inf) v.e else v.b

  def Stamp(c: Set[Version], snap: int, frame: int): Set[Version] =
    c.map(v => if (Resolved(LastEvent(v)) and LastEvent(v) <= snap) { ...v, mat: frame } else v)

  action UnchangedForCheckpoint = all {
    clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
  }

  action CheckpointStart: bool = all {
    ck.pc == "idle",
    nCk < MaxCheckpoints,
    ck' = { pc: "collectTable", snap: SnapshotTs, old: durable, row: NoWrite, iw: NoIdx, iu: Set(),
            frame: 0, tcand: 0, icand: NoIdx, completed: false },
    nCk' = nCk + 1,
    tchain' = tchain, ichain' = ichain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, tdirty' = tdirty, idirty' = idirty,
    UnchangedForCheckpoint,
  }

  action UnchangedForCollect = all {
    tchain' = tchain, ichain' = ichain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk, tdirty' = tdirty, idirty' = idirty,
    UnchangedForCheckpoint,
  }

  // CollectTableRows: a dirty key with a change in (old, snap] goes into the
  // write set. A stamp at or below snap is a prune candidate.
  action CheckpointCollectTable: bool = all {
    ck.pc == "collectTable",
    ck' = { ...ck, pc: "collectIndex",
            row: if (tdirty != 0 and ChangedSince(tchain, ck.old, ck.snap))
                   ValueAt(tchain, ck.snap) else NoWrite,
            tcand: if (tdirty != 0 and tdirty <= ck.snap) tdirty else 0 },
    UnchangedForCollect,
  }

  // An index entry that the B-tree had at the old boundary, and that a
  // version of the chain ends in (old, snap]: a delete that the frame writes.
  def DeletesBtreeEntry(c: Set[Version], old: int, snap: int): bool =
    c.exists(v => and {
      v.b == 0 or v.b <= old,
      v.e != Inf, Resolved(v.e), old < v.e, v.e <= snap,
    })

  // CollectIndexRows over checkpoint_dirty_index_keys, with the same snapshot.
  // The engine yields between keys. One step gives the same write set: a
  // commit between two keys is above snap, and GC drops only versions whose
  // last event is at or below old, which ChangedSince skips.
  // collect_index_row_versions writes an insert, or a delete of an entry that
  // the B-tree has. Another changed key goes to unwritten_index_rows.
  action CheckpointCollectIndex: bool = {
    val visit = Vals.filter(x => idirty.get(x) != 0 and ChangedSince(ichain.get(x), ck.old, ck.snap))
    val written = visit.filter(x => ValueAt(ichain.get(x), ck.snap) == 1
                                    or DeletesBtreeEntry(ichain.get(x), ck.old, ck.snap))
    val cand = Vals.filter(x => idirty.get(x) != 0 and idirty.get(x) <= ck.snap)
    all {
      ck.pc == "collectIndex",
      ck' = { ...ck, pc: "writing",
              iw: written.mapBy(x => ValueAt(ichain.get(x), ck.snap)),
              iu: visit.exclude(written),
              icand: cand.mapBy(x => idirty.get(x)) },
      UnchangedForCollect,
    }
  }

  // One pager transaction writes the row, the index entries and the new
  // boundary (persistent_tx_ts_max) as one WAL frame.
  action CheckpointCommit: bool = {
    val boundary = Max(Set(ck.old, ck.snap))
    val write = ck.row != NoWrite or ck.iw.keys() != Set() or boundary > ck.old
    all {
      ck.pc == "writing",
      wal' = if (write) wal.append({ row: ck.row, idx: ck.iw, meta: boundary }) else wal,
      ck' = { ...ck, pc: "committed", frame: if (write) wal.length() + 1 else 0 },
      tchain' = tchain, ichain' = ichain, llog' = llog, nBackfill' = nBackfill,
      dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk, tdirty' = tdirty, idirty' = idirty,
      UnchangedForCheckpoint,
    }
  }

  action CheckpointPublish: bool = all {
    ck.pc == "committed",
    durable' = Max(Set(ck.old, ck.snap)),
    ck' = { ...ck, pc: "published" },
    tchain' = tchain, ichain' = ichain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, backfillFloor' = backfillFloor,
    nCk' = nCk, tdirty' = tdirty, idirty' = idirty,
    UnchangedForCheckpoint,
  }

  // PASSIVE WAL checkpoint up to the lowest pinned read mark.
  action CheckpointBackfill: bool = {
    val marks = Pinned.map(r => rd.get(r).mark)
                  .union(if (WritersPinMarks) inflight.map(i => i.mark) else Set())
    val limit = Min(marks.union(Set(wal.length())))
    all {
      ck.pc == "published",
      nBackfill <= limit,
      nondet upTo = (if (BackfillToLimit) Set(limit) else nBackfill.to(limit)).oneOf()
      all {
        dbRow' = if (RowFrames(nBackfill + 1, upTo) == Set()) dbRow
                 else Frame(Max(RowFrames(nBackfill + 1, upTo))).row,
        dbIdx' = Vals.mapBy(x =>
                   if (IdxFrames(x, nBackfill + 1, upTo) == Set()) dbIdx.get(x)
                   else Frame(Max(IdxFrames(x, nBackfill + 1, upTo))).idx.get(x)),
        dbMeta' = if (upTo > nBackfill) Frame(upTo).meta else dbMeta,
        nBackfill' = upTo,
      },
      ck' = { ...ck, pc: "backfilled" },
      tchain' = tchain, ichain' = ichain, llog' = llog, wal' = wal, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk, tdirty' = tdirty, idirty' = idirty,
      UnchangedForCheckpoint,
    }
  }

  // TruncateLogicalLog: all or nothing against the boundary.
  action CheckpointTruncateLog: bool = all {
    ck.pc == "backfilled",
    llog' = if (llog.forall(l => l.ts <= durable)) Set() else llog,
    ck' = { ...ck, pc: "truncated" },
    tchain' = tchain, ichain' = ichain, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk, tdirty' = tdirty, idirty' = idirty,
    UnchangedForCheckpoint,
  }

  // Set backfill_floor, then GcTableRows stamps the collected table chain.
  action CheckpointStampTable: bool = all {
    ck.pc == "truncated",
    backfillFloor' = nBackfill,
    tchain' = if (ck.row != NoWrite) Stamp(tchain, ck.snap, ck.frame) else tchain,
    ck' = { ...ck, pc: "stampIndex" },
    ichain' = ichain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable, nCk' = nCk,
    tdirty' = tdirty, idirty' = idirty,
    UnchangedForCheckpoint,
  }

  // GcIndexRows stamps the written index chains and the unwritten keys
  // (csm.rs:2343-2361). PruneDirtyKeys then removes each candidate whose
  // stamp did not rise since collection.
  action CheckpointStampIndex: bool = all {
    ck.pc == "stampIndex",
    ichain' = Vals.mapBy(x =>
                if ((StampIndexRows and ck.iw.keys().contains(x))
                    or (StampUnwrittenIndexRows and ck.iu.contains(x)))
                  Stamp(ichain.get(x), ck.snap, ck.frame)
                else ichain.get(x)),
    tdirty' = if (ck.tcand != 0 and tdirty == ck.tcand) 0 else tdirty,
    idirty' = Vals.mapBy(x =>
                if (ck.icand.keys().contains(x)
                    and (not(PruneKeepsNewerStamp) or idirty.get(x) == ck.icand.get(x))) 0
                else idirty.get(x)),
    ck' = { ...ck, pc: "idle", completed: true },
    tchain' = tchain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    dbRow' = dbRow, dbIdx' = dbIdx, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
  }

  // ---------------------------------------------------------------------------
  // GC: gc_chain_now with lwm and the floor min(reader marks, backfill_floor).

  val Lwm: int = if (Registered == Set()) Inf else Min(Registered.map(r => rd.get(r).b))
  val GcFloor: int = Min(Registered.map(r => rd.get(r).mark).union(Set(backfillFloor, Inf)))

  def Rule2(v: Version, waits: bool): bool = and {
    v.e != Inf, Resolved(v.e), v.e < Lwm,
    not(waits) or (v.mat != 0 and v.mat <= GcFloor),
  }

  def Rule3(c: Set[Version], waits: bool, idle: bool): bool = and {
    c.size() == 1,
    val v = AnyVersion(c)
    and {
      v.e == Inf, v.b != 0, Resolved(v.b),
      not(waits) or (v.mat != 0 and v.mat <= GcFloor),
      not(idle) or Lwm == Inf,
    },
  }

  def GcChain(c: Set[Version], waits: bool, idle: bool): Set[Version] =
    val after2 = c.filter(v => not(Rule2(v, waits)))
    if (Rule3(after2, waits, idle)) Set() else after2

  action UnchangedForGc = all {
    clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, llog' = llog,
    rd' = rd, writes' = writes, logged' = logged, err' = err,
    tdirty' = tdirty, idirty' = idirty,
    UnchangedCheckpointVars,
  }

  // gc_incremental over table rows, or the GC in GcTableRows and Finalize.
  action GcTable: bool = all {
    GcChain(tchain, true, true) != tchain,
    tchain' = GcChain(tchain, true, true),
    ichain' = ichain,
    UnchangedForGc,
  }

  // gc_index_incremental, or the GC in GcIndexRows and Finalize.
  action GcIndex(x: int): bool = all {
    GcChain(ichain.get(x), IndexGcWaitsForReaders, IndexRule3OnlyWhenIdle) != ichain.get(x),
    ichain' = ichain.set(x, GcChain(ichain.get(x), IndexGcWaitsForReaders, IndexRule3OnlyWhenIdle)),
    tchain' = tchain,
    UnchangedForGc,
  }

  // ---------------------------------------------------------------------------
  // Specification

  action Next = any {
    nondet v = Vals.union(Set(0)).oneOf()
    WritePrepare(v),
    all {
      inflight != Set(),
      nondet i = inflight.oneOf()
      any { WriteMarkDirty(i), WriteLogAppend(i), WriteFinish(i) },
    },
    all {
      Readers != Set(),
      nondet r = Readers.oneOf()
      any {
        ReaderPin(r),
        ReaderBegin(r),
        nondet x = Vals.oneOf()
        ReaderReadStart(r, x),
        ReaderReadEnd(r),
        ReaderEnd(r),
      },
    },
    CheckpointStart,
    CheckpointCollectTable,
    CheckpointCollectIndex,
    CheckpointCommit,
    CheckpointPublish,
    CheckpointBackfill,
    CheckpointTruncateLog,
    CheckpointStampTable,
    CheckpointStampIndex,
    GcTable,
    nondet x = Vals.oneOf()
    GcIndex(x),
  }

  // ---------------------------------------------------------------------------
  // Properties

  val IndexReadsCorrect: bool = err == Set()

  // Every B-tree image that a reader can see, at a mark from nBackfill to the
  // last frame, has the index entry of its row and no other.
  val BtreeIndexMatchesTable: bool =
    nBackfill.to(wal.length()).forall(m =>
      Vals.forall(x => BtreeIdxAt(x, m) == (if (BtreeRowAt(m) == x) 1 else 0)))

  // Crash recovery: the B-tree through every frame, then the log records
  // above the stored boundary, in timestamp order. A record deletes the old
  // index entry and inserts the new one.
  val RecoveredMeta: int = if (wal == List()) dbMeta else Frame(wal.length()).meta
  val Replay: Set[Write] = llog.filter(l => l.ts > RecoveredMeta)

  val RecoveredRow: int =
    if (Replay == Set()) BtreeRowAt(wal.length())
    else Replay.fold({ ts: -1, v: 0, old: 0 }, (a, l) => if (l.ts > a.ts) l else a).v

  def RecoveredIdx(x: int): int =
    range(1, MaxTs + 1).foldl(BtreeIdxAt(x, wal.length()), (acc, t) =>
      val ls = Replay.filter(l => l.ts == t)
      if (ls.exists(l => l.v == x)) 1
      else if (ls.exists(l => l.old == x)) 0
      else acc)

  val RecoveryCorrect: bool = and {
    RecoveredRow == LatestIn(logged, Inf),
    Vals.forall(x => RecoveredIdx(x) == (if (LatestIn(logged, Inf) == x) 1 else 0)),
  }

  val IndexChainsStamped: bool =
    (ck.pc == "idle" and ck.completed) implies
      Vals.forall(x => ichain.get(x).forall(v =>
        (Resolved(LastEvent(v)) and LastEvent(v) <= durable) implies v.mat != 0))

  val BackfillBelowReaders: bool = Pinned.forall(r => nBackfill <= rd.get(r).mark)

  val TypeOK: bool = and {
    clock.in(0.to(MaxTs)),
    nBackfill.in(0.to(wal.length())),
    wal.length() <= MaxCheckpoints,
    durable <= lastCommitted,
    Vals.forall(x => ichain.get(x).forall(v => v.mat.in(0.to(wal.length())))),
  }

  val Safety: bool = and {
    TypeOK, IndexReadsCorrect, BtreeIndexMatchesTable, RecoveryCorrect,
    IndexChainsStamped, BackfillBelowReaders,
  }

  // ---------------------------------------------------------------------------
  // Reachability checks. Each one must be violated.

  // One frame deletes one index entry and inserts another: an UPDATE of v.
  val NeverMovesIndexEntry: bool =
    not(wal.indices().exists(i => and {
      wal[i].idx.keys().exists(x => wal[i].idx.get(x) == 0),
      wal[i].idx.keys().exists(x => wal[i].idx.get(x) == 1),
    }))
  // GC empties the chain of the current index entry, so readers use the B-tree.
  val NeverEmptiesCurrentIndexChain: bool =
    not(Vals.exists(x => ichain.get(x) == Set() and LatestIn(writes, Inf) == x))
  // A reader takes its result from the B-tree at an old read mark, and the
  // newest B-tree image has another answer for that entry.
  val NeverReadsIndexFromOldMark: bool =
    not(Readers.exists(r => and {
      rd.get(r).pc == "reading", rd.get(r).mark > 0,
      Visible(ichain.get(rd.get(r).key), rd.get(r).b) == Set(),
      BtreeRowValid(ichain.get(rd.get(r).key), rd.get(r).b),
      BtreeIdxAt(rd.get(r).key, rd.get(r).mark) != BtreeIdxAt(rd.get(r).key, wal.length()),
    }))
  // A commit ends an entry that only the B-tree has, with a marker version.
  val NeverIndexMarker: bool = not(Vals.exists(x => ichain.get(x).exists(v => v.b == 0)))
  // A pass writes the delete of an entry whose chain has a marker.
  val NeverWritesMarkerDelete: bool =
    not(ck.pc == "writing" and Vals.exists(x => and {
      ck.iw.keys().contains(x), ck.iw.get(x) == 0, ichain.get(x).exists(v => v.b == 0),
    }))
  // A reader finds an entry through the B-tree because GC emptied its chain.
  val NeverReadsFromBtree: bool =
    not(Readers.exists(r => and {
      rd.get(r).pc == "reading", ichain.get(rd.get(r).key) == Set(),
      BtreeIdxAt(rd.get(r).key, rd.get(r).mark) == 1,
    }))
  // UPDATE t SET v = v: one commit ends and restarts the same index chain.
  val NeverRewritesSameKey: bool = not(writes.exists(w => w.v == w.old))
  // A pass collects an index key that needs no write.
  val NeverUnwrittenIndexKey: bool = ck.iu == Set()
  // A pass prunes an index key while a later commit is still marking it.
  val NeverIndexStampRisesBeforePrune: bool =
    not(ck.pc == "stampIndex" and ck.icand.keys().exists(x => idirty.get(x) > ck.icand.get(x)))
}
