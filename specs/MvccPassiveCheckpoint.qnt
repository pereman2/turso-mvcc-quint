// -*- mode: Bluespec; -*-
/**
 * Turso MVCC passive checkpoint.
 *
 * This specification models how a passive checkpoint moves committed row
 * versions from the in-memory version store into the B-tree while writers
 * commit and readers read at the same time. See DESIGN.md next to this file
 * for the design in prose and for the mapping to the Rust code in
 * core/mvcc/database/checkpoint_state_machine.rs and core/mvcc/database/mod.rs.
 *
 * Actors.
 *   Writers  commit one row change each: Prepare (take a commit timestamp
 *            and change the version chain), LogAppend (write the logical log
 *            record), Finish (raise lastCommitted).
 *   Readers  pin a WAL read mark, take a begin timestamp, read rows, end.
 *   The checkpoint runs one pass at a time: take a snapshot timestamp,
 *            collect, commit one WAL frame, publish, backfill the WAL into
 *            the database file, truncate the logical log, stamp the versions
 *            it wrote.
 *   GC       drops versions from the version store. It can run at any time,
 *            which covers the commit-path GC and the checkpoint GC.
 *
 * Two properties are checked.
 *   ReadsCorrect     Every read returns the value of the row at the
 *                    reader's begin timestamp.
 *   RecoveryCorrect  If the process crashes now, the database file, the WAL
 *                    and the logical log rebuild every logged commit.
 *
 * The constants named Guard* switch off one rule of the design each. The
 * main configuration sets all of them to true. Each variant configuration
 * in MvccPassiveCheckpointConfigs.qnt sets one of them to false, and the
 * model checker then finds the bug that the rule prevents.
 *
 * Row-level extensions (DESIGN-rows.md). Each one is behind a constant
 * whose "off" value gives the model above, state for state.
 *   Aborts         A Preparing writer can roll back before its log append.
 *                  Readers that read its versions speculatively must abort.
 *   DirtyKeys      Collection visits only keys in the dirty-key map, unless
 *                  a failed mark forced a full scan.
 *   GcSamplesFirst GC samples lwm and the floor first, then applies the
 *                  rules to a chain in a later step.
 *   ModelFinalizedPrune
 *                  remove_tx is a step after WriteFinish, and GC prunes the
 *                  finalized TxID cache (finalized_tx_states).
 *
 * Mode B (Mode = "blocking", the passive flag off) is two actions: a pass that
 * succeeds (CheckpointBlocking, one atomic step, with the WAL restart in
 * counted frames and the GC sweep) and a pass that stops after its publish
 * (CheckpointBlockingFail).
 *
 * WAL restart (ModelWalRestart, DESIGN-rows.md). walSeq counts restarts. A restart
 * for write (modes P and T, at BeginPager) and the restart in the T WAL checkpoint
 * (CheckpointRestart) need no pinned reader. A reader that crosses a restart reads
 * the new generation at its old frame number (EffMark). Mode T then runs a final
 * sweep (CheckpointFinalSweep). Mode B keeps its counted restart.
 *
 * Not modeled: schema changes and root-page bindings, indexes, sequences,
 * aborts of Active writers and aborts after
 * the log append, write-write conflicts between writers (except a reader that
 * updates one key, see Updates), page-level I/O, and a crash inside a mode B
 * pass.
 *
 * Notes on the Quint code:
 *   - Keys and Readers are strings. The model checker sees every order of
 *     them.
 *   - Max, Min and "the one element of a set" use fold.
 *   - Lists start at index 0. WAL frame numbers still start at 1: frame i
 *     is wal[i - 1] (see Frame).
 *   - Every action assigns every variable.
 *   - "val" is a keyword in Quint, so the version field is "value".
 *   - Each argument that a step picks comes from a named nondet in Next.
 *     `quint run --mbt` then records the action and its picks in the
 *     trace. "to" is a built-in name in Quint, so the backfill pick is
 *     named upTo.
 */
module MvccPassiveCheckpoint {
  const Keys: Set[str]            // Row keys of one table.
  const Readers: Set[str]         // Reader connections.
  const MaxTs: int                // Bound on the logical clock (commits and reader begins).
  const FixRefuseCheckpointOwner: bool
  const Mode: str
  const FixRecollectUnstamped: bool
  const SplitLogTruncate: bool // The truncate decision and I/O finish in separate steps.
  const FixStampAtPagerCommit: bool
  const FixCleanupPublishes: bool
  const CheckpointFailures: bool // A pass can stop before it finishes.
  const MaxCheckpoints: int       // Bound on the number of checkpoint passes.

  // Rules of the design. true in the main configuration.
  const GuardSnapshotBelowPreparing: bool  // snapshot_ts < every Preparing commit ts
  const GuardGcWaitsForReaders: bool       // GC drops a version only when every reader
                                           // can read its effect from the B-tree
  const GuardDropCurrentOnlyWhenIdle: bool // GC Rule 3 needs "no open snapshot"
  const GuardBackfillStopsAtReaders: bool  // WAL backfill stops at the lowest read mark
  const GuardRule2Lwm: bool                // GC Rule 2 (both forms) needs v.e < lwm (engine: e <= lwm, mod.rs:8606; equal because timestamps are unique)

  // Which reader marks bound the GC floor. One of:
  //   "code"       registered readers' marks and backfillFloor (what
  //                gc_incremental uses today)
  //   "registered" only readers registered in txs
  //   "pinned"     every reader that pinned a WAL read mark
  //   "backfill"   only backfillFloor
  const GcFloorRule: str

  // Whether Connection::checkpoint can run on the connection of an open
  // reader. The backfill then ignores that reader's pin. One of:
  //   "none"      it cannot (PRAGMA wal_checkpoint refuses)
  //   "movesMark" the reader's read mark moves to the end of the WAL
  //   "keepsMark" the reader keeps its read mark
  const CheckpointOnReaderConnection: str

  // true: a read looks at the chain twice, once for each side of the dual
  // cursor (what MvccLazyCursor does). false: one look decides both sides.
  const ReadLooksAtChainTwice: bool

  // Aborts. false in the main configuration.
  const Aborts: bool                        // a Preparing writer can roll back
  const GuardReadersAbortOnDependency: bool // register_commit_dependency + abort_now
  const AbortKeepsMaterialized: bool        // false: set_end(None) resets
                                            // materialized_at (the code). true: keep it.

  // Updates. false in the main configuration.
  const Updates: bool                       // a registered reader can write one key
                                            // (ReaderUpdate, first committer wins)

  // Dirty keys. false / 0 in the main configuration.
  const DirtyKeys: bool                      // collect only keys in the dirty map
  const GuardMarkBeforeCommitEnd: bool       // MarkDirtyKeys runs while Preparing
  const MaxMarkFailures: int                 // bound on failed re-marks
  const GuardFullScanUntilStampCovered: bool // clear only if snap >= lost stamp
  const GuardFullScanGenerationCas: bool     // clear only if no new failure

  // GC in two steps. false in the main configuration.
  const GcSamplesFirst: bool          // sample lwm and floor, then apply
  const GuardGcRechecksIdleLwm: bool  // gc_chain_now recomputes lwm = MAX

  // Finalized TxID states (gap 6). false / true / false in the main configuration.
  const ModelFinalizedPrune: bool   // remove_tx is its own step and the finalized cache is pruned
  const GuardPruneReferenced: bool  // prune skips TxIDs that collect_referenced_txids saw
  const RemoveTxBeforeRewrite: bool // what-if: remove_tx can run before the TxID rewrite

  // The TxID rewrite after CommitEnd (gap 22). false / true in the main configuration.
  const ModelCommitEndRewrite: bool // WriteFinish is three steps: CommitEnd, rewrite, FinalizeCommit
  const RewriteResetsMat: bool      // the rewrite sets materialized_at to ORIGIN (the engine); false is the fix

  // Trace replay only. Each one makes the spec take only the steps that the
  // engine can take. false in every configuration that is model checked.
  const BackfillToLimit: bool      // the backfill copies every frame up to
                                   // the limit, not any frame up to it
  const LogAppendOneAtATime: bool  // a writer appends its log record only when
                                   // no other writer appended and did not
                                   // finish (pager_commit_lock)
  const WriterBeginTicks: bool     // a writer takes a begin timestamp from
                                   // the clock before its commit timestamp
  const WritersPinMarks: bool      // a writer holds a WAL read mark from its
                                   // prepare to its finish (to WriteRemoveTx
                                   // with ModelFinalizedPrune), and the
                                   // backfill stops at it

  // Mode B (Mode = "blocking": the passive flag is off). All "off" values give
  // the passive model, state for state.
  const PagerPinsWithoutGate: bool          // a pinned reader holds a WAL mark but not the
                                            // gate (schema reparse, raw WAL API). Off: a
                                            // pinned reader holds the gate.
  const GuardB2KeepUncheckpointed: bool     // Rule 2 B keeps `e > ckpt_max && (...)`. Off:
                                            // drop every superseded version with e < lwm.
  const GuardB2InBtree: bool                // the in_btree term of that keep clause
  const GuardB2Tombstone: bool              // the not(hasCurrent) term of that keep clause
  const GuardB3InCkptMax: bool              // Rule 3 B needs b <= ckpt_max
  const GuardFallThroughCkptMax: bool       // the B-tree fall-through needs b <= durable
  const GuardFallThroughMark: bool          // the fall-through needs mat != 0 and mark >= mat
  const BlockingStampOrigin: bool           // what-if: the B stamp writes mat = 0 (gap 14)
  const FixB2WaitsForPinned: bool           // a fix that keeps GC alive: Rule 2 B drops nothing
                                            // while a pinned read mark is below the WAL max
                                            // frame. It counts readers on slot 0 too, which
                                            // min_pinned_read_frame() skips. Not in the engine.
  const BlockingFailTruncatesLog: bool      // what-if: a failed pass empties the logical
                                            // log and its frame never lands (RecoveryCorrect
                                            // control). With the frame, RecoveryCorrect holds.
  const BlockingStopsAfterStamp: bool       // a pass can stop after its stamp, before its GC

  // WAL restart (gaps 1, 4, 9). false / true / "staged" in the main configuration.
  const ModelWalRestart: bool               // walSeq, EffMark, the restarts and the T final sweep
  const GuardRestartWaitsForReaders: bool   // a restart needs no pinned reader (wal.rs:371, :2359)
  const TruncateSweepFloor: str             // floor of the T final sweep: "staged" (the code:
                                            // GcFloor) or "registered" (probe: no backfill_floor)

  pure val Inf = 1000   // "no end timestamp", "no reader"
  pure val None = -1    // "no visible version"

  /* A version is { b, e, value, mat }:
       b      begin timestamp. 0 means "begin None": a marker for a row that
              was only in the B-tree when a writer deleted or replaced it.
       e      end timestamp, Inf while the version is current.
       value  the row value. Values are the commit timestamp of the insert.
       mat    materialized_at: the WAL frame whose B-tree shows this version's
              last event, 0 when no frame shows it yet. */
  type Version = { b: int, e: int, value: int, mat: int }
  type Write = { ts: int, k: str, v: int }
  // mark: the WAL mark of the writer's read transaction, 0 without
  // WritersPinMarks.
  type Inflight = { ts: int, k: str, v: int, logged: bool, marked: bool, omat: int,
                    mark: int }
  // A commit between CommitEnd and FinalizeCommit (ModelCommitEndRewrite).
  type Ending = { i: Inflight, rewritten: bool }
  type WalFrame = { w: str -> int, meta: int }
  type Cand = { k: str, s: int }
  type CkState = { pc: str, owner: str, snap: int, old: int, todo: Set[str], wset: str -> int,
                   frame: int, full: int, cand: Set[Cand], clearOk: bool, truncate: bool,
                   completed: bool, seen: Set[str], pagerOwned: bool }
  type RdState = { pc: str, pinned: bool, mark: int, seq: int, b: int, key: str, vis1: int, valid1: bool,
                   deps1: Set[int] }
  type ErrRec = { reader: str, key: str, begin: int, mark: int, got: Set[int],
                  want: int, deps: Set[int] }
  type LateMark = { k: str, ts: int }
  type GcState = { pc: str, lwm: int, floor: int }
  type Rmw = { k: str, b: int, ts: int }
  // TxIDs are commit timestamps, because each writer has one timestamp.
  // retiring: committed and still in txs. finalized: keys of finalized_tx_states.
  // unrewritten: committed writers whose versions still carry the TxID marker.
  // pc/ref: the prune between its collect and its apply. pruned, fired: history.
  type FinState = { retiring: Set[int], finalized: Set[int], unrewritten: Set[int],
                    pc: str, ref: Set[int], pruned: Set[int], fired: bool,
                    pins: Set[{ ts: int, mark: int }] }

  var clock: int                 // Last timestamp taken from the logical clock.
  var chain: str -> Set[Version] // chain[k]: set of versions of key k in the version store.
  var inflight: Set[Inflight]    // Commits in the Preparing state.
  var lastCommitted: int         // last_committed_tx_ts (a fetch_max high-water mark).
  var llog: Set[Write]           // Records in the logical log file.
  var wal: List[WalFrame]        // WAL frames written by checkpoints. Frame i is wal[i - 1].
  var nBackfill: int             // WAL frames 1..nBackfill are copied to the database file.
  var db: str -> int             // B-tree rows in the database file.
  var dbMeta: int                // persistent_tx_ts_max in the database file.
  var durable: int               // durable_txid_max in memory.
  var backfillFloor: int         // backfill_floor in memory.
  var ck: CkState                // State of the running checkpoint pass.
  var nCk: int                   // Number of checkpoint passes started.
  var rd: str -> RdState         // rd[r]: state of reader r.
  var writes: Set[Write]         // History: every prepared write. Used only by checks.
  var logged: Set[Write]         // History: every write that reached the logical log.
  var err: Set[ErrRec]           // History: reads that returned a wrong value.
  var aborted: Set[int]          // History: commit timestamps of aborted writers.
  var readDeps: Set[int]         // History: writers that a read depended on, recorded
                                 // only when readers ignore their dependencies.
  var dirty: str -> int          // dirty[k]: stamp in checkpoint_dirty_table_keys, 0 = none.
  var lateMarks: Set[LateMark]   // Dirty marks still to do after CommitEnd (variant only).
  var fullGen: int               // checkpoint_full_scan_generation, 0 = no full scan.
  var fullMin: int               // checkpoint_full_scan_min_snapshot_ts.
  var markFails: int             // Number of failed re-marks so far.
  var gcs: GcState               // Sampled GC values when GC runs in two steps.
  var rmw: Set[Rmw]              // History: updates that passed validation, with begin and commit ts.
  var ending: Set[Ending]        // Commits between CommitEnd and FinalizeCommit (ModelCommitEndRewrite).
  var walSeq: int                // Number of WAL restarts so far (ModelWalRestart).
  var genStart: int -> int       // genStart[s]: counted frames before sequence s. genStart[0] = 0.
  var fin: FinState              // finalized_tx_states and the TxID rewrite (ModelFinalizedPrune).

  // ---------------------------------------------------------------------------
  // Helpers

  pure def Max(S: Set[int]): int = S.fold(-Inf - 1, (a, x) => if (x > a) x else a)
  pure def Min(S: Set[int]): int = S.fold(Inf + 1, (a, x) => if (x < a) x else a)

  // CHOOSE x \in c : TRUE. The fold keeps the first element it visits.
  pure def AnyVersion(c: Set[Version]): Version =
    c.fold({ b: -1, e: 0, value: 0, mat: 0 }, (a, x) => if (a.b == -1) x else a)

  pure val EmptyFn: str -> int = Map()

  val InflightTs: Set[int] = inflight.map(i => i.ts)

  // A timestamp is resolved when its commit left the Preparing state. The code
  // stores a TxID instead of a timestamp until then, and the checkpoint and GC
  // skip such versions.
  def Resolved(t: int): bool = not(InflightTs.contains(t))

  // A TxID that txs and finalized_tx_states have both lost, while a version
  // still names it (only in the what-if where remove_tx runs before the rewrite).
  def Lost(t: int): bool = and { ModelFinalizedPrune, fin.unrewritten.contains(t),
    not(InflightTs.contains(t)), not(fin.retiring.contains(t)), not(fin.finalized.contains(t)) }
  // What is_begin_visible / is_end_visible see: a lost begin is invisible
  // (mod.rs:11291-11296), a lost end is ignored (mod.rs:11358-11362).
  def ReadView(c: Set[Version]): Set[Version] =
    c.map(v => { ...v, b: if (Lost(v.b)) 0 else v.b, e: if (Lost(v.e)) Inf else v.e })

  // Value of key k after the writes in W with a timestamp below t. 0 = no row.
  pure def LatestIn(W: Set[Write], k: str, t: int): int =
    val ws = W.filter(w => w.k == k and w.ts < t)
    if (ws == Set()) 0
    else ws.fold({ ts: -1, k: k, v: 0 }, (a, w) => if (w.ts > a.ts) w else a).v

  // The value that a reader with begin timestamp b must see.
  def Oracle(k: str, b: int): int = LatestIn(writes, k, b)

  pure def Visible(c: Set[Version], b: int): Set[Version] =
    c.filter(v => v.b != 0 and v.b < b and b < v.e)

  pure def VisibleValue(c: Set[Version], b: int): int =
    if (Visible(c, b) == Set()) None else AnyVersion(Visible(c, b)).value

  // The B-tree row is valid for the reader unless a version shadows it: a
  // visible version, or a version that ended before the reader began.
  pure def BtreeRowValid(c: Set[Version], b: int): bool = and {
    Visible(c, b) == Set(),
    not(c.exists(v => v.e < b)),
  }

  // WAL frame number i, counted from 1.
  def Frame(i: int): WalFrame = wal[i - 1]

  // The B-tree as seen through WAL read mark m: the newest frame at or below
  // m that wrote k, else the database file.
  def FramesWith(k: str, lo: int, hi: int): Set[int] =
    lo.to(hi).filter(i => Frame(i).w.keys().contains(k))

  def BtreeAt(k: str, m: int): int =
    if (FramesWith(k, 1, m) == Set()) db.get(k)
    else Frame(Max(FramesWith(k, 1, m))).w.get(k)

  // The counted frame that a reader's pager reads. A mark of an older sequence
  // is an engine frame number, and it now reads that frame of the new
  // generation. Floors keep the counted mark: (s, N) orders below every
  // position of s + 1, the same as the counted frames.
  def EffMarkOf(x: RdState): int =
    if (x.seq == walSeq) x.mark
    else Min(Set(wal.length(), genStart.get(walSeq) + (x.mark - genStart.get(x.seq))))
  def EffMark(r: str): int = EffMarkOf(rd.get(r))

  val Pinned: Set[str] = Readers.filter(r => rd.get(r).pinned)
  val Registered: Set[str] = Readers.filter(r => Set("active", "reading").contains(rd.get(r).pc))

  // CHOOSE k \in Keys : TRUE
  val AnyKey: str = Keys.fold("", (a, k) => if (a == "") k else a)

  // ---------------------------------------------------------------------------
  // Initial state

  action Init = all {
    clock' = 0,
    chain' = Keys.mapBy(k => Set()),
    inflight' = Set(),
    lastCommitted' = 0,
    llog' = Set(),
    wal' = List(),
    nBackfill' = 0,
    db' = Keys.mapBy(k => 0),
    dbMeta' = 0,
    durable' = 0,
    backfillFloor' = 0,
    ck' = { pc: "idle", owner: "", snap: 0, old: 0, todo: Set(), wset: EmptyFn, frame: 0,
            full: 0, cand: Set(), clearOk: false, truncate: false, completed: false, seen: Set(), pagerOwned: false },
    nCk' = 0,
    rd' = Readers.mapBy(r => { pc: "idle", pinned: false, mark: 0, seq: 0, b: 0, key: AnyKey, vis1: None,
                               valid1: false, deps1: Set() }),
    writes' = Set(),
    logged' = Set(),
    err' = Set(),
    aborted' = Set(),
    readDeps' = Set(),
    dirty' = Keys.mapBy(k => 0),
    lateMarks' = Set(),
    fullGen' = 0,
    fullMin' = 0,
    markFails' = 0,
    gcs' = { pc: "idle", lwm: 0, floor: 0 },
    rmw' = Set(),
    ending' = Set(),
    fin' = { retiring: Set(), finalized: Set(), unrewritten: Set(), pc: "idle", ref: Set(),
             pruned: Set(), fired: false, pins: Set() },
    walSeq' = 0,
    genStart' = Map(0 -> 0),
  }

  // Keeps the row variables as they are.
  action UnchangedRowVars = all {
    UnchangedRowVarsNoWal,
    UnchangedWal,
  }

  action UnchangedWal = all { walSeq' = walSeq, genStart' = genStart }

  action UnchangedRowVarsNoWal = all {
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    fullGen' = fullGen, fullMin' = fullMin, markFails' = markFails, gcs' = gcs,
    rmw' = rmw,
    ending' = ending,
    fin' = fin,
  }

  action UnchangedFullScan = all {
    fullGen' = fullGen, fullMin' = fullMin, markFails' = markFails,
    rmw' = rmw,
  }

  // ---------------------------------------------------------------------------
  // Writers

  // A version with begin None and end None is rolled-back garbage.
  def CurrentVersions(k: str): Set[Version] =
    chain.get(k).filter(x => x.e == Inf and x.b != 0)

  def ChainAfterWrite(k: str, ts: int, isDelete: bool): Set[Version] = {
    val cur = CurrentVersions(k)
    val old = Oracle(k, ts)
    val ended =
      if (cur != Set()) cur.map(x => { ...x, e: ts, mat: 0 })
      else if (old != 0) Set({ b: 0, e: ts, value: old, mat: 0 })
      else Set()
    val added = if (isDelete) Set() else Set({ b: ts, e: Inf, value: ts, mat: 0 })
    chain.get(k).exclude(cur).union(ended).union(added)
  }

  def NewInflight(k: str, ts: int, v: int, mark: int): Inflight = {
    val cur = CurrentVersions(k)
    {
      ts: ts, k: k, v: v, logged: false,
      marked: not(DirtyKeys and GuardMarkBeforeCommitEnd),
      omat: if (AbortKeepsMaterialized and cur != Set()) AnyVersion(cur).mat else 0,
      mark: mark,
    }
  }

  // A commit takes its timestamp from the clock, ends the current version and
  // adds the new one. In the code the chain holds the TxID until the commit
  // rewrites it to the timestamp. Readers read Preparing versions
  // speculatively, which this model shows as plain visibility, because every
  // prepared commit finishes.
  action WritePrepare(k: str, isDelete: bool): bool = {
    val ts = if (WriterBeginTicks) clock + 2 else clock + 1
    val v = if (isDelete) 0 else ts
    all {
      ts <= MaxTs,
      not(inflight.exists(i => i.k == k)),
      not(isDelete and Oracle(k, ts) == 0),
      clock' = ts,
      chain' = chain.set(k, ChainAfterWrite(k, ts, isDelete)),
      inflight' = inflight.union(Set(NewInflight(k, ts, v, if (WritersPinMarks) wal.length() else 0))),
      writes' = writes.union(Set({ ts: ts, k: k, v: v })),
      lastCommitted' = lastCommitted, llog' = llog, wal' = wal, nBackfill' = nBackfill,
      db' = db, dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor,
      ck' = ck, nCk' = nCk, rd' = rd, logged' = logged, err' = err,
      UnchangedRowVars,
    }
  }

  // MarkDirtyKeys: after the commit has its timestamp and before the log
  // append, raise the stamp of the key to the commit timestamp (fetch_max).
  // A failed mark fails the commit, which WriteAbort covers.
  action WriteMarkDirty(i: Inflight): bool = all {
    not(i.marked),
    dirty' = dirty.set(i.k, Max(Set(dirty.get(i.k), i.ts))),
    inflight' = inflight.exclude(Set(i)).union(Set({ ...i, marked: true })),
    clock' = clock, chain' = chain, lastCommitted' = lastCommitted, llog' = llog,
    wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, writes' = writes,
    logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, lateMarks' = lateMarks, UnchangedFullScan,
    gcs' = gcs,
    ending' = ending,
    fin' = fin, UnchangedWal,
  }

  action WriteLogAppend(i: Inflight): bool = all {
    not(i.logged),
    i.marked,
    not(LogAppendOneAtATime and (inflight.exists(j => j.logged) or ending != Set())),
    llog' = llog.union(Set({ ts: i.ts, k: i.k, v: i.v })),
    logged' = logged.union(Set({ ts: i.ts, k: i.k, v: i.v })),
    inflight' = inflight.exclude(Set(i)).union(Set({ ...i, logged: true })),
    clock' = clock, chain' = chain, lastCommitted' = lastCommitted, wal' = wal,
    nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, writes' = writes,
    err' = err,
    UnchangedRowVars,
  }

  action WriteFinish(i: Inflight): bool = all {
    i.logged,
    not(ModelCommitEndRewrite),
    inflight' = inflight.exclude(Set(i)),
    lastCommitted' = Max(Set(lastCommitted, i.ts)),
    lateMarks' = if (DirtyKeys and not(GuardMarkBeforeCommitEnd))
                   lateMarks.union(Set({ k: i.k, ts: i.ts }))
                 else lateMarks,
    clock' = clock, chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill,
    db' = db, dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor,
    ck' = ck, nCk' = nCk, rd' = rd, writes' = writes, logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, UnchangedFullScan, UnchangedWal,
    gcs' = gcs,
    ending' = ending,
    fin' = if (ModelFinalizedPrune)
             { ...fin, retiring: fin.retiring.union(Set(i.ts)),
               unrewritten: if (RemoveTxBeforeRewrite) fin.unrewritten.union(Set(i.ts))
                            else fin.unrewritten,
               // The COMMIT statement ends its pager read tx only after
               // remove_tx (connection.rs:4897), so the WAL read mark
               // stays until WriteRemoveTx.
               pins: if (WritersPinMarks) fin.pins.union(Set({ ts: i.ts, mark: i.mark }))
                     else fin.pins }
           else fin,
  }

  // CommitEnd (gap 22): the commit is Committed in txs, so readers and the
  // snapshot see it as resolved. last_committed_tx_ts does not change yet. The
  // dirty mark after CommitEnd (lateMarks) belongs to this step.
  action WriteCommitEnd(i: Inflight): bool = all {
    ModelCommitEndRewrite,
    i.logged,
    inflight' = inflight.exclude(Set(i)),
    ending' = ending.union(Set({ i: i, rewritten: false })),
    lateMarks' = if (DirtyKeys and not(GuardMarkBeforeCommitEnd))
                   lateMarks.union(Set({ k: i.k, ts: i.ts }))
                 else lateMarks,
    clock' = clock, chain' = chain, lastCommitted' = lastCommitted, llog' = llog,
    wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, writes' = writes,
    logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, UnchangedFullScan,
    gcs' = gcs, UnchangedWal,
    fin' = fin,
  }

  pure def Touches(v: Version, t: int): bool = v.b == t or v.e == t

  // rewrite_txid_to_timestamp: set_begin / set_end reset materialized_at. The
  // model stores the timestamp already, so only mat changes.
  action WriteRewriteTxId(e: Ending): bool = {
    val t = e.i.ts
    all {
      not(e.rewritten),
      chain' = chain.set(e.i.k, chain.get(e.i.k).map(v =>
                 if (RewriteResetsMat and Touches(v, t)) { ...v, mat: 0 } else v)),
      ck' = if (chain.get(e.i.k).exists(v => Touches(v, t) and v.mat != 0))
              { ...ck, seen: ck.seen.union(Set("rewroteStamped")) }
            else ck,
      ending' = ending.exclude(Set(e)).union(Set({ ...e, rewritten: true })),
      clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, llog' = llog,
      wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk, rd' = rd, writes' = writes,
      logged' = logged, err' = err,
      aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
      UnchangedFullScan,
      gcs' = gcs, UnchangedWal,
      fin' = fin,
    }
  }

  // FinalizeCommit: the rest of the old WriteFinish.
  action WriteFinalize(e: Ending): bool = {
    val i = e.i
    all {
      e.rewritten,
      ending' = ending.exclude(Set(e)),
      lastCommitted' = Max(Set(lastCommitted, i.ts)),
      clock' = clock, inflight' = inflight, chain' = chain, llog' = llog, wal' = wal,
      nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
      backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, writes' = writes,
      logged' = logged, err' = err,
      aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
      UnchangedFullScan,
      gcs' = gcs, UnchangedWal,
      fin' = if (ModelFinalizedPrune)
               { ...fin, retiring: fin.retiring.union(Set(i.ts)),
                 unrewritten: if (RemoveTxBeforeRewrite) fin.unrewritten.union(Set(i.ts))
                              else fin.unrewritten,
                 pins: if (WritersPinMarks) fin.pins.union(Set({ ts: i.ts, mark: i.mark }))
                       else fin.pins }
             else fin,
    }
  }

  // remove_tx (mod.rs:6823-6861): the insert into finalized_tx_states and the
  // removal from txs are one step here. still_retiring is not modeled.
  action WriteRemoveTx(t: int): bool = all {
    ModelFinalizedPrune,
    fin.retiring.contains(t),
    ending' = ending,
    fin' = { ...fin, retiring: fin.retiring.exclude(Set(t)), finalized: fin.finalized.union(Set(t)),
             pins: fin.pins.filter(p => p.ts != t) },
    clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    UnchangedFullScan, UnchangedWal,
    gcs' = gcs,
  }

  // What-if only: the TxID rewrite after remove_tx. The chain does not change,
  // because the model already stores the timestamp. The replay refuses it.
  action WriteRewrite(t: int): bool = all {
    ModelFinalizedPrune,
    RemoveTxBeforeRewrite,
    fin.unrewritten.contains(t),
    ending' = ending,
    fin' = { ...fin, unrewritten: fin.unrewritten.exclude(Set(t)) },
    clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    UnchangedFullScan, UnchangedWal,
    gcs' = gcs,
  }

  // Variant only: the dirty mark happens after CommitEnd.
  action WriteLateMark(m: LateMark): bool = all {
    dirty' = dirty.set(m.k, Max(Set(dirty.get(m.k), m.ts))),
    lateMarks' = lateMarks.exclude(Set(m)),
    clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, UnchangedFullScan, gcs' = gcs,
    ending' = ending,
    fin' = fin, UnchangedWal,
  }

  // require_checkpoint_full_scan after a failed re-mark lost stamp s.
  action RequireFullScan(s: int): bool = all {
    fullMin' = Max(Set(fullMin, s)),
    fullGen' = fullGen + 1,
    markFails' = markFails + 1,
    rmw' = rmw,
  }

  // unmark then mark again with the stamp that was there. The second mark
  // can fail, and then the stamp is lost and a full scan is required.
  action Remark(k: str, s: int): bool = any {
    all { dirty' = dirty, UnchangedFullScan },
    all {
      markFails < MaxMarkFailures,
      dirty' = dirty.set(k, 0),
      RequireFullScan(s),
    },
  }

  // rollback_tx of a Preparing writer before its log append. The versions it
  // began are removed, the version it ended is current again (set_end(None),
  // which resets materialized_at), and a marker of a B-tree row becomes
  // garbage with begin None and end None. The code first stores Aborted and
  // then edits each chain. In between, readers and the checkpoint resolve
  // the TxID to "not committed", which gives the same result as the edited
  // chain, so the model does both in one step.
  action WriteAbort(i: Inflight): bool = {
    val k = i.k
    val rolled = chain.get(k).filter(x => x.b != i.ts)
                   .map(v => if (v.e == i.ts) { ...v, e: Inf, mat: i.omat } else v)
    val keeps = rolled.exists(v => v.b != 0 or v.e != Inf)
    val actual = dirty.get(k)
    all {
      Aborts,
      not(i.logged),
      chain' = chain.set(k, rolled),
      // unmark_checkpoint_dirty_key_if_stamp, only when no version keeps the
      // key dirty.
      if (DirtyKeys and not(keeps) and actual != 0)
        if (actual == i.ts) all { dirty' = dirty.set(k, 0), UnchangedFullScan }
        else Remark(k, actual)
      else all { dirty' = dirty, UnchangedFullScan },
      inflight' = inflight.exclude(Set(i)),
      writes' = writes.filter(w => w.ts != i.ts),
      aborted' = aborted.union(Set(i.ts)),
      clock' = clock, lastCommitted' = lastCommitted, llog' = llog, wal' = wal,
      nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
      backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, logged' = logged,
      err' = err,
      readDeps' = readDeps, lateMarks' = lateMarks, gcs' = gcs,
      ending' = ending,
      fin' = fin, UnchangedWal,
    }
  }

  // ---------------------------------------------------------------------------
  // Readers

  action UnchangedForReaders = all {
    ck' = ck,
    UnchangedForReadersExceptCk,
  }

  action UnchangedForReadersExceptCk = all {
    clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    writes' = writes, logged' = logged,
  }

  // Mode B (btree_covers_chain_for_snapshot, chain_is_write_buffer_for): when
  // the chain is one current version that began before the reader, is inside
  // the durable boundary and has a stamp at or below the reader's mark, the
  // look skips the chain. The B-tree at the read mark decides, as it does for
  // an empty chain. Passive mode returns false at once.
  def FallThrough(c: Set[Version], b: int, mark: int): bool = and {
    Mode == "blocking",
    c.size() == 1,
    val v = AnyVersion(c)
    and {
      v.e == Inf, v.b != 0, Resolved(v.b), v.b < b,
      not(GuardFallThroughCkptMax) or v.b <= durable,
      not(GuardFallThroughMark) or (v.mat != 0 and mark >= v.mat),
    },
  }

  def LookVis(c: Set[Version], b: int, mark: int): int =
    if (FallThrough(c, b, mark)) None else VisibleValue(ReadView(c), b)

  def LookValid(c: Set[Version], b: int, mark: int): bool =
    if (FallThrough(c, b, mark)) true else BtreeRowValid(ReadView(c), b)

  def SeenFall(c: Set[Version], b: int, mark: int): CkState =
    if (FallThrough(c, b, mark)) { ...ck, seen: ck.seen.union(Set("fellThrough")) } else ck

  // pager.wal_pos() is read before the clock lock in begin_tx, so a reader
  // holds its WAL read mark for a while before it is in txs.
  action ReaderPin(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "idle",
    rd' = rd.setBy(r, x => { ...x, pc: "pinned", pinned: true, mark: wal.length(), seq: walSeq }),
    UnchangedForReaders, err' = err,
    UnchangedRowVars,
  }

  action ReaderBegin(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "pinned",
    clock < MaxTs,
    clock' = clock + 1,
    rd' = rd.setBy(r, x => { ...x, pc: "active", b: clock + 1 }),
    chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted, llog' = llog,
    wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, writes' = writes,
    logged' = logged, err' = err,
    UnchangedRowVars,
  }

  // A dual cursor merges the version store side and the B-tree side, and the
  // two sides look at the chain at different moments. ReaderReadStart takes
  // the first look, ReaderReadEnd the second, and both orders are checked.
  // Writers whose Preparing versions a read of k at begin b looks at. The
  // read uses them speculatively and takes a commit dependency on each one
  // (is_visible_to, is_btree_invalidating_version).
  def SpecDeps(k: str, b: int): Set[int] =
    if (Aborts) inflight.filter(j => j.k == k and j.ts < b).map(i => i.ts)
    else Set()

  action ReaderReadStart(r: str, k: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "active",
    rd' = rd.setBy(r, x => { ...x, pc: "reading", key: k,
                             vis1: LookVis(chain.get(k), x.b, x.mark),
                             valid1: LookValid(chain.get(k), x.b, x.mark),
                             deps1: SpecDeps(k, x.b) }),
    ck' = SeenFall(chain.get(k), rd.get(r).b, rd.get(r).mark),
    UnchangedForReadersExceptCk, err' = err,
    UnchangedRowVars,
  }

  action ReaderReadEnd(r: str): bool = {
    val k = rd.get(r).key
    val b = rd.get(r).b
    val vis2 = LookVis(chain.get(k), b, rd.get(r).mark)
    val valid2 = LookValid(chain.get(k), b, rd.get(r).mark)
    val bt = BtreeAt(k, EffMark(r))
    // Version store side first, B-tree side second.
    val resA = if (rd.get(r).vis1 != None) rd.get(r).vis1 else if (valid2) bt else 0
    // B-tree side first, version store side second.
    val resB = if (vis2 != None) vis2 else if (rd.get(r).valid1) bt else 0
    val want = Oracle(k, b)
    // One look decides both sides.
    val resOne = if (vis2 != None) vis2 else if (valid2) bt else 0
    val ok = if (ReadLooksAtChainTwice) resA == want and resB == want else resOne == want
    val deps = rd.get(r).deps1.union(SpecDeps(k, b))
    val ck0 = SeenFall(chain.get(k), b, rd.get(r).mark)
    // The value came from the B-tree, through a mark of a later sequence.
    val ck1 = if (rd.get(r).seq > 0 and vis2 == None and valid2)
                { ...ck0, seen: ck0.seen.union(Set("readAfterRestart")) } else ck0
    all {
      ck.owner != r or ck.pc == "idle",
      rd.get(r).pc == "reading",
      err' = if (ok) err
             else err.union(Set({ reader: r, key: k, begin: b, mark: rd.get(r).mark,
                                  got: Set(resA, resB), want: want, deps: deps })),
      readDeps' = if (GuardReadersAbortOnDependency) readDeps else readDeps.union(deps),
      rd' = rd.setBy(r, x => { ...x, pc: "active", deps1: Set() }),
      ck' = ck1,
      UnchangedForReadersExceptCk,
      aborted' = aborted, dirty' = dirty, lateMarks' = lateMarks, UnchangedFullScan,
      gcs' = gcs,
      ending' = ending,
      fin' = fin, UnchangedWal,
    }
  }

  action ReaderEnd(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    Set("pinned", "active").contains(rd.get(r).pc),
    rd' = rd.setBy(r, x => { ...x, pc: "idle", pinned: false }),
    UnchangedForReaders, err' = err,
    UnchangedRowVars,
  }

  // ReaderUpdate: a registered reader writes one key (an UPSERT) and commits.
  // It merges the statement check, Preparing, the commit check and the chain
  // edit into one step. This is safe for the question "can GC hide a
  // write-write conflict": once a writer W has written k, the chain holds W's
  // TxID, GC never drops it and another writer sees a conflict at its commit check (an Active insert is invisible to a second inserter). So
  // the window that matters is from W's begin to W's first write of k, and
  // ReaderBegin, Gc and ReaderUpdate are separate steps, so the model keeps it.
  // ts = clock + 1 does not mirror WritePrepare under WriterBeginTicks; no configuration sets both.
  // Model gap: after the step the updater leaves Registered. In the engine W
  // stays in txs as Preparing, and its begin still counts in the lwm. So the
  // model GC can drop more than the engine. This is safe: W needs no version
  // after its check, and every other reader has its own begin in Lwm.
  // Conflict evidence for begin b (check_version_conflicts,
  // is_write_write_conflict).
  pure def EndEvidence(c: Set[Version], b: int, inf: Set[int]): bool =
    c.exists(v => v.e != Inf and (inf.contains(v.e) or v.e > b))
  pure def CurrentEvidence(c: Set[Version], b: int, inf: Set[int]): bool =
    c.exists(v => v.e == Inf and v.b != 0 and (inf.contains(v.b) or v.b > b))
  def WwConflict(k: str, b: int): bool =
    EndEvidence(chain.get(k), b, InflightTs) or CurrentEvidence(chain.get(k), b, InflightTs)
  // A write of k has no version left in the chain: GC trimmed the chain.
  def ChainTrimmed(k: str): bool =
    writes.exists(w => w.k == k and not(chain.get(k).exists(v => v.b == w.ts or v.e == w.ts)))

  action ReaderUpdate(r: str, k: str): bool = {
    val b = rd.get(r).b
    val ts = clock + 1
    all {
      Updates,
      ck.owner != r or ck.pc == "idle",
      rd.get(r).pc == "active",
      ts <= MaxTs,
      // Left out: a Preparing write of k with ts < b. For an insert or update the engine reads that version speculatively and registers a commit dependency, with no conflict (core/mvcc/database/mod.rs:11234-11248, 10884). Safe because writes of k are serialized, so no write of k lies in (b, clock]. A Preparing delete below b is a lead, not verified: the commit check gives a conflict with no cause (mod.rs:11324-11331, 2232-2245, 2299-2308). A write with ts > b stays a conflict: the statement sees no version, and the commit check raises WriteWriteConflict (about mod.rs:2280-2290), so the driver accepts that conflict from the COMMIT.
      not(inflight.exists(i => i.k == k and i.ts < b)),
      rd' = rd.setBy(r, x => { ...x, pc: "idle", pinned: false }),
      if (WwConflict(k, b)) all {
        // WriteWriteConflict: roll back, nothing written.
        ck' = { ...ck, seen: ck.seen.union(Set("wwConflict"))
          .union(if (not(EndEvidence(chain.get(k), b, InflightTs))) Set("wwCurrentOnly") else Set())
          .union(if (not(CurrentEvidence(chain.get(k), b, InflightTs))) Set("wwEndOnly") else Set())
          .union(if (ChainTrimmed(k)) Set("wwAfterGc") else Set()) },
        clock' = clock, chain' = chain, inflight' = inflight, writes' = writes, rmw' = rmw,
      } else all {
        not(inflight.exists(i => i.k == k)),
        clock' = ts,
        chain' = chain.set(k, ChainAfterWrite(k, ts, false)),
        inflight' = inflight.union(Set(NewInflight(k, ts, ts, if (WritersPinMarks) rd.get(r).mark else 0))),
        writes' = writes.union(Set({ ts: ts, k: k, v: ts })),
        rmw' = rmw.union(Set({ k: k, b: b, ts: ts })),
        ck' = ck,
      },
      lastCommitted' = lastCommitted, llog' = llog, wal' = wal, nBackfill' = nBackfill,
      db' = db, dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor,
      nCk' = nCk, logged' = logged, err' = err,
      aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
      fullGen' = fullGen, fullMin' = fullMin, markFails' = markFails, gcs' = gcs,
      ending' = ending,
      fin' = fin, UnchangedWal,
    }
  }

  // ---------------------------------------------------------------------------
  // Checkpoint

  // checkpoint_snapshot_ts: under the clock lock, stay below every commit that
  // has a timestamp but did not finish.
  val SnapshotTs: int =
    if (GuardSnapshotBelowPreparing and inflight != Set())
      Min(Set(lastCommitted, Min(InflightTs) - 1))
    else lastCommitted

  action UnchangedForCheckpoint = all {
    clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
  }

  action CheckpointStart: bool = {
    nondet owner = (if (CheckpointOnReaderConnection == "none") Set("")
                    else Readers.filter(r => rd.get(r).pc == "active").union(Set(""))).oneOf()
    all {
      (FixRefuseCheckpointOwner and owner != "") implies
        not(Pinned.union(Registered).contains(owner)),
      Mode != "blocking",
      ck.pc == "idle",
      nCk < MaxCheckpoints,
      ck' = { pc: "collect", owner: owner, snap: SnapshotTs, old: durable, todo: Keys, wset: EmptyFn,
              frame: 0, full: if (DirtyKeys) fullGen else 0, cand: Set(), clearOk: false,
              truncate: false, completed: false, seen: ck.seen, pagerOwned: false },
      nCk' = nCk + 1,
      chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
      dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor,
      UnchangedForCheckpoint,
      UnchangedRowVars,
    }
  }

  // The key changed in (old, snap]: some resolved begin or end is in that range.
  def ChangedSince(c: Set[Version], old: int, snap: int): bool =
    c.exists(v => or {
      v.b != 0 and Resolved(v.b) and old < v.b and v.b <= snap,
      v.e != Inf and Resolved(v.e) and old < v.e and v.e <= snap,
    })

  // The value of the row at snapshot ts t: the version that began at or
  // before t and did not end at or before t. Unresolved timestamps are in
  // the future of every snapshot.
  def ValueAt(c: Set[Version], t: int): int =
    val vs = c.filter(v => and {
      v.b != 0, Resolved(v.b), v.b <= t,
      v.e == Inf or not(Resolved(v.e)) or t < v.e,
    })
    if (vs == Set()) 0 else AnyVersion(vs).value

  pure def LastEvent(v: Version): int = if (v.e != Inf) v.e else v.b

  // Collection looks at one key at a time while writers keep committing.
  // With dirty keys, it visits a key only if the key is in the dirty map at
  // that moment, unless this pass is a full scan. A visited key with a stamp
  // at or below snap is a prune candidate (record_prune_candidate; the
  // DirtyStamps phase does the same for a full scan).
  action CheckpointCollect(k: str): bool = {
    val repair = FixRecollectUnstamped and chain.get(k).exists(v =>
      v.mat == 0 and Resolved(LastEvent(v)) and LastEvent(v) <= ck.snap)
    val visit = repair or not(DirtyKeys) or ck.full != 0 or dirty.get(k) != 0
    all {
      ck.pc == "collect",
      ck.todo.contains(k),
      ck' = { ...ck,
              todo: ck.todo.exclude(Set(k)),
              wset: if (visit and (repair or ChangedSince(chain.get(k), ck.old, ck.snap)))
                      ck.wset.put(k, ValueAt(chain.get(k), ck.snap))
                    else ck.wset,
              cand: if (DirtyKeys and dirty.get(k) != 0 and dirty.get(k) <= ck.snap)
                      ck.cand.union(Set({ k: k, s: dirty.get(k) }))
                    else ck.cand },
      chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
      dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
      UnchangedForCheckpoint,
      UnchangedRowVars,
    }
  }

  // A restart needs frames in this generation and all of them backfilled.
  val CanRestart: bool = and {
    wal.length() > genStart.get(walSeq),
    nBackfill == wal.length(),
  }

  action CheckpointBeginPager: bool = {
    val work = ck.wset.keys() != Set() or ck.snap > ck.old
    val stale = ck.owner != "" and rd.get(ck.owner).pinned
                  and rd.get(ck.owner).mark != wal.length()
    // Restart for write (try_restart_log_before_write): every frame of the
    // generation is backfilled, and no reader but the checkpoint holds a mark.
    val restart = and {
      ModelWalRestart, work, not(stale),
      CanRestart,
      not(GuardRestartWaitsForReaders) or and {
        Pinned.forall(r => r == ck.owner),
        not(WritersPinMarks) or (inflight == Set() and fin.pins == Set()),
      },
    }
    all {
      ck.pc == "collect", ck.todo == Set(),
      ck' = { ...ck, pc: if (not(work)) "published" else if (stale) "idle" else "writing",
              pagerOwned: work and not(stale) },
      chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
      dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
      UnchangedForCheckpoint,
      UnchangedRowVarsNoWal,
      walSeq' = if (restart) walSeq + 1 else walSeq,
      genStart' = if (restart) genStart.put(walSeq + 1, wal.length()) else genStart,
    }
  }

  // One pager transaction writes the collected rows and the new boundary
  // (persistent_tx_ts_max) as one WAL frame.
  action CheckpointCommit: bool = {
    val boundary = Max(Set(ck.old, ck.snap))
    val write = ck.wset.keys() != Set() or boundary > ck.old
    all {
      ck.pc == "writing", ck.pagerOwned,
      wal' = if (write) wal.append({ w: ck.wset, meta: boundary }) else wal,
      ck' = { ...ck, pc: "committed", frame: if (write) wal.length() + 1 else 0, pagerOwned: false },
      chain' = if (FixStampAtPagerCommit and write) Keys.mapBy(k =>
        if (ck.wset.keys().contains(k)) chain.get(k).map(v =>
          if (Resolved(LastEvent(v)) and LastEvent(v) <= ck.snap)
            { ...v, mat: wal.length() + 1 } else v)
        else chain.get(k)) else chain,
      llog' = llog, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
      durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
      clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted,
      rd' = if (ck.owner == "") rd else rd.setBy(ck.owner, x =>
        { ...x, pinned: false,
          mark: if (CheckpointOnReaderConnection == "movesMark") wal.length() + (if (write) 1 else 0)
                else x.mark }),
      writes' = writes, logged' = logged, err' = err,
      UnchangedRowVars,
    }
  }

  action CheckpointPublish: bool = all {
    ck.pc == "committed",
    ApplyCheckpointPublish({ ...ck,
      pc: if (Mode == "truncateFlagOn") "publishing" else "published" }),
  }

  action CheckpointPublishBoundary: bool = all {
    ck.pc == "publishing",
    ApplyCheckpointPublish({ ...ck, pc: "published" }),
  }

  action ApplyCheckpointPublish(nextCk: CkState): bool = all {
    durable' = if (nextCk.pc == "publishing") durable else Max(Set(ck.old, ck.snap)),
    ck' = nextCk,
    chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
    dbMeta' = dbMeta, backfillFloor' = backfillFloor, nCk' = nCk,
    clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted,
    rd' = rd,
    writes' = writes, logged' = logged, err' = err,
    UnchangedRowVars,
  }

  // PASSIVE WAL checkpoint: copy frames into the database file, but never past
  // a frame that a pinned reader does not see. Busy is the case upTo = nBackfill.
  action CheckpointBackfill: bool = {
    val marks = Pinned.map(r => EffMark(r))
                  .union(if (WritersPinMarks) inflight.map(i => i.mark) else Set())
                  .union(if (WritersPinMarks) fin.pins.map(p => p.mark) else Set())
                  // A writer in the commit end window still holds its read mark.
                  .union(if (WritersPinMarks) ending.map(e => e.i.mark) else Set())
    val limit = if (GuardBackfillStopsAtReaders) Min(marks.union(Set(wal.length())))
                else wal.length()
    all {
      ck.pc == "published",
      // Simplification: the engine can backfill up to a slot 1-4 mark and then fail with Busy.
      Mode == "truncateFlagOn" implies Pinned == Set(),
      // \E to \in nBackfill..limit is false when the range is empty. "to" is
      // a built-in name in Quint, so the pick is named upTo.
      nBackfill <= limit,
      nondet upTo = (if (BackfillToLimit) Set(limit) else nBackfill.to(limit)).oneOf()
      all {
        db' = Keys.mapBy(k =>
                if (FramesWith(k, nBackfill + 1, upTo) == Set()) db.get(k)
                else Frame(Max(FramesWith(k, nBackfill + 1, upTo))).w.get(k)),
        dbMeta' = if (upTo > nBackfill) Frame(upTo).meta else dbMeta,
        nBackfill' = upTo,
      },
      ck' = { ...ck, pc: "backfilled" },
      chain' = chain, llog' = llog, wal' = wal, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk,
      clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted,
      rd' = rd,
      writes' = writes, logged' = logged, err' = err,
      UnchangedRowVars,
    }
  }

  // Mode T: the WAL checkpoint takes the Writer guard, needs every frame
  // backfilled, and restarts the log (restart_log, wal.rs:5246-5258). It is Busy
  // while a reader holds a mark (CheckpointFail at "backfilled").
  action CheckpointRestart: bool = all {
    ModelWalRestart,
    Mode == "truncateFlagOn",
    ck.pc == "backfilled",
    nBackfill == wal.length(),
    not(GuardRestartWaitsForReaders) or Pinned == Set(),
    ck' = { ...ck, pc: "restarted" },
    walSeq' = if (wal.length() > genStart.get(walSeq)) walSeq + 1 else walSeq,
    genStart' = if (wal.length() > genStart.get(walSeq)) genStart.put(walSeq + 1, wal.length())
                else genStart,
    chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
    UnchangedRowVarsNoWal,
  }

  // In mode T with ModelWalRestart the pass goes on to the final sweep.
  val AfterStamp: str = if (ModelWalRestart and Mode == "truncateFlagOn") "sweep" else "idle"

  // LogicalLog::truncate checks the boundary before the file truncate completes.
  action CheckpointTruncateDecide: bool = all {
    ck.pc == (if (ModelWalRestart and Mode == "truncateFlagOn") "restarted" else "backfilled"),
    llog' = if (not(SplitLogTruncate) and llog.forall(l => l.ts <= durable)) Set() else llog,
    ck' = { ...ck, pc: if (SplitLogTruncate) "truncateDecided" else "truncated",
            truncate: llog.forall(l => l.ts <= durable) },
    chain' = chain, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
    UnchangedRowVars,
  }

  action CheckpointTruncateApply: bool = all {
    ck.pc == "truncateDecided",
    llog' = if (ck.truncate) Set() else llog,
    ck' = { ...ck, pc: "truncated", seen:
      if (ck.truncate and ck.frame > 0 and ck.wset.keys() != Set()
          and llog.exists(l => l.ts > durable)) ck.seen.union(Set("truncateLostAppend"))
      else ck.seen },
    chain' = chain, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
    UnchangedRowVars,
  }

  // stamp_chain_materialized: on each written key, every version whose last
  // event is resolved and at or below snap is in the B-tree from this frame on.

  action CheckpointStamp: bool = all {
    ck.pc == "truncated",
    backfillFloor' = nBackfill,
    chain' = Keys.mapBy(k =>
               if (ck.wset.keys().contains(k))
                 chain.get(k).map(v =>
                   if (Resolved(LastEvent(v)) and LastEvent(v) <= ck.snap) { ...v, mat: ck.frame }
                   else v)
               else chain.get(k)),
    ck' = { ...ck, pc: if (DirtyKeys) "prune" else AfterStamp, completed: true,
      seen: if (FixRecollectUnstamped and ck.seen.contains("failedPublished")
                 and ck.wset.keys().exists(k => chain.get(k).exists(v =>
                   v.mat == 0 and Resolved(LastEvent(v)) and LastEvent(v) <= ck.old)))
              ck.seen.union(Set("repairedVersions")) else ck.seen },
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, nCk' = nCk,
    UnchangedForCheckpoint,
    UnchangedRowVars,
  }

  // PruneDirtyKeys, one candidate at a time: remove the key from the dirty
  // map. If a writer raised the stamp since collection, mark it again.
  action CheckpointPrune(c: Cand): bool = {
    val latest = dirty.get(c.k)
    all {
      ck.pc == "prune",
      ck.cand.contains(c),
      if (latest == 0) all { dirty' = dirty, UnchangedFullScan }
      else if (latest == c.s) all { dirty' = dirty.set(c.k, 0), UnchangedFullScan }
      else Remark(c.k, latest),
      ck' = { ...ck, cand: ck.cand.exclude(Set(c)) },
      chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
      dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
      UnchangedForCheckpoint,
      aborted' = aborted, readDeps' = readDeps, lateMarks' = lateMarks, gcs' = gcs,
      ending' = ending,
      fin' = fin, UnchangedWal,
    }
  }

  // clear_checkpoint_full_scan, first half: compare snap with the highest
  // lost stamp.
  action CheckpointPruneDone: bool = all {
    ck.pc == "prune",
    ck.cand == Set(),
    ck' = { ...ck, pc: if (ck.full != 0) "clear" else AfterStamp,
                   clearOk: not(GuardFullScanUntilStampCovered) or ck.snap >= fullMin },
    chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
    dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
    UnchangedRowVars,
  }

  // clear_checkpoint_full_scan, second half: compare_exchange(generation, 0).
  action CheckpointClearFullScan: bool = all {
    ck.pc == "clear",
    fullGen' = if (ck.clearOk and (not(GuardFullScanGenerationCas) or fullGen == ck.full)) 0
               else fullGen,
    ck' = { ...ck, pc: AfterStamp },
    chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
    dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    fullMin' = fullMin, markFails' = markFails, gcs' = gcs, rmw' = rmw,
    ending' = ending,
    fin' = fin, UnchangedWal,
  }

  // The floor of the T final sweep. "staged": min(registered marks, backfillFloor),
  // what drop_unused_row_versions_inner(true, true, STAGED) takes (mod.rs:8504).
  // "registered": no backfillFloor (a probe).
  val SweepFloor: int =
    if (TruncateSweepFloor == "registered")
      Min(Registered.map(r => rd.get(r).mark).union(Set(Inf)))
    else GcFloor

  // Mode T Finalize: drop_unused_row_versions_and_slots, one GC of every chain.
  action CheckpointFinalSweep: bool = {
    val after = Keys.mapBy(k => GcChain(k, Lwm, SweepFloor))
    val dropped = Keys.exists(k => after.get(k) != chain.get(k))
    all {
      ModelWalRestart,
      Mode == "truncateFlagOn",
      ck.pc == "sweep",
      chain' = after,
      ck' = { ...ck, pc: "idle",
              seen: if (dropped and not(Pinned.forall(r => Registered.contains(r))))
                      ck.seen.union(Set("sweepWithR5")) else ck.seen },
      llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
      durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
      UnchangedForCheckpoint,
      UnchangedRowVars,
    }
  }

  action CheckpointFail(at: str): bool = {
    val failed = if (at == "published" and ck.frame > 0 and ck.wset.keys() != Set()
                       and ck.wset.keys().exists(k => chain.get(k).exists(v =>
                         v.mat == 0 and Resolved(LastEvent(v)) and LastEvent(v) <= durable)))
                   ck.seen.union(Set("failedPublished")) else ck.seen
    val publish = FixCleanupPublishes and Set("committed", "publishing").contains(at)
    val early = if (FixStampAtPagerCommit and at == "published" and ck.frame > 0
                    and ck.wset.keys().exists(k => chain.get(k).exists(v => v.mat == ck.frame)))
                  failed.union(Set("failedEarlyStamp")) else failed
    val history = if (publish and ck.frame > 0 and ck.wset.keys() != Set())
                    early.union(Set("cleanupPublished")) else early
    val stopped = { ...ck, pc: "idle", completed: false, seen: history, pagerOwned: false }
    all {
      or {
        CheckpointFailures,
        Mode == "truncateFlagOn" and at == "published" and Pinned != Set(),
        // Busy from the T restart: a frame is not backfilled, or a reader holds a mark.
        ModelWalRestart and Mode == "truncateFlagOn" and at == "backfilled" and
          (nBackfill < wal.length() or (GuardRestartWaitsForReaders and Pinned != Set())),
      },
      ck.pc == at,
      if (publish) ApplyCheckpointPublish(stopped)
      else all {
        ck' = stopped,
        chain' = chain, llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db,
        dbMeta' = dbMeta, durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk,
        clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted,
        rd' = if (not(ck.pagerOwned) or ck.owner == "") rd
              else rd.setBy(ck.owner, x => { ...x, pinned: false }),
        writes' = writes, logged' = logged, err' = err,
        UnchangedRowVars,
      },
    }
  }

  // ---------------------------------------------------------------------------
  // Mode B checkpoint (the passive flag is off)
  //
  // A MVCC transaction holds blocking_checkpoint_lock in read mode from begin
  // to the end of the transaction. The checkpoint takes the write mode with a
  // try lock at AcquireLock and fails with Busy while a transaction is open.
  // So a pass that succeeds runs with no MVCC actor open, and no other actor
  // can run between its steps. The model merges the pass into one action. The
  // only actors that remain are GC (it takes the read mode as a try lock, so
  // it cannot run inside the pass) and a pager reader with no MVCC
  // transaction. A pager reader makes the pass fail at CheckpointWal, after
  // the publish. That is CheckpointBlockingFail.
  //
  // The WAL restart (restart_log in CheckpointWal) needs no variable. Frame
  // numbers here count across restarts, as the replay does. The row stamp
  // pager.wal_pos() after the restart is (seq + 1, 0), which counts to frame F.

  // The spec counts (seq, F) and (seq + 1, 0) as frame F. The engine orders them.
  // A reader pinned at (seq, F) blocks the restart, so a successful pass never
  // meets it. Only CheckpointBlockingStop can.
  // The rows of the pass: each key that changed in (old, snap], with its value at snap.
  def BlockingWset(snap: int): str -> int =
    Keys.filter(k => ChangedSince(chain.get(k), durable, snap))
        .fold(EmptyFn, (m, k) => m.put(k, ValueAt(chain.get(k), snap)))

  def BlockingWrites(snap: int): bool =
    BlockingWset(snap).keys() != Set() or Max(Set(durable, snap)) > durable

  // The database file after the backfill of frames lo..hi of a WAL w.
  def DbAfterBackfill(w: List[WalFrame], lo: int, hi: int): str -> int =
    Keys.mapBy(k =>
      if (lo.to(hi).filter(i => w[i - 1].w.keys().contains(k)) == Set()) db.get(k)
      else w[Max(lo.to(hi).filter(i => w[i - 1].w.keys().contains(k))) - 1].w.get(k))

  // The version store after the stamp of the pass: every version of a written
  // key whose last event is at or below snap gets mat = F.
  def StampedChains(wset: str -> int, snap: int, f: int): str -> Set[Version] =
    Keys.mapBy(k =>
      if (wset.keys().contains(k))
        chain.get(k).map(v =>
          if (Resolved(LastEvent(v)) and LastEvent(v) <= snap)
            { ...v, mat: if (BlockingStampOrigin) 0 else f }
          else v)
      else chain.get(k))

  action CheckpointBlocking: bool = BlockingPass(true)

  // Variant only (BlockingStopsAfterStamp): the pass stops after its stamp and
  // before its GC. Whether the engine can stop there is not verified.
  action CheckpointBlockingStop: bool = all {
    BlockingStopsAfterStamp,
    BlockingPass(false),
  }

  action BlockingPass(withGc: bool): bool = {
    val snap = lastCommitted     // no writer is in flight, so snapshot_ts is lastCommitted
    val wset = BlockingWset(snap)
    val boundary = Max(Set(durable, snap))
    val write = BlockingWrites(snap)
    val newWal = if (write) wal.append({ w: wset, meta: boundary }) else wal
    val f = newWal.length()
    val stamped = StampedChains(wset, snap, f)
    // GcTableRows and Finalize run with lwm = MAX and the floor backfill_floor = f.
    val collected = if (withGc) Keys.mapBy(k => GcChainB(stamped.get(k), Inf, boundary, f))
                    else stamped
    val b3 = withGc and Keys.exists(k =>
      Rule3B(AfterRule2B(stamped.get(k), Inf, boundary, f), Inf, boundary, f))
    val left = Keys.exists(k => collected.get(k) != Set())
    val stampRan = Keys.exists(k => stamped.get(k).exists(v => v.mat == f and f > 0))
    all {
      Mode == "blocking",
      ck.pc == "idle",
      nCk < MaxCheckpoints,
      inflight == Set(),
      Registered == Set(),
      Pinned == Set(),
      gcs.pc == "idle",
      wal' = newWal,
      durable' = boundary,
      nBackfill' = f,
      db' = DbAfterBackfill(newWal, nBackfill + 1, f),
      dbMeta' = if (f > nBackfill) newWal[f - 1].meta else dbMeta,
      backfillFloor' = f,
      // Every record is at or below durable' because no writer is in flight.
      llog' = Set(),
      chain' = collected,
      ck' = { ...ck, completed: withGc,
              seen: ck.seen
                .union(if (left) Set("blockingLeftVersions") else Set())
                .union(if (b3) Set("b3Drop") else Set())
                .union(if (stampRan) Set("stampedAtRestart") else Set()) },
      nCk' = nCk + 1,
      clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, rd' = rd,
      writes' = writes, logged' = logged, err' = err,
      UnchangedRowVars,
    }
  }

  // A pass that stops at CheckpointWal, after its publish: the pager commit
  // wrote frame F and the publish window stored durable_txid_max, but the WAL
  // checkpoint returned Busy (a pager reader holds a read mark) or failed. No
  // backfill, no log truncate, no stamp and no GC.
  action CheckpointBlockingFail: bool = {
    val snap = lastCommitted
    val wset = BlockingWset(snap)
    val boundary = Max(Set(durable, snap))
    all {
      Mode == "blocking",
      ck.pc == "idle",
      nCk < MaxCheckpoints,
      inflight == Set(),
      Registered == Set(),
      gcs.pc == "idle",
      PagerPinsWithoutGate or Pinned == Set(),
      (PagerPinsWithoutGate and Pinned != Set()) or CheckpointFailures,
      BlockingWrites(snap),
      // BlockingFailTruncatesLog (what-if): the log is emptied and the frame never lands.
      wal' = if (BlockingFailTruncatesLog) wal else wal.append({ w: wset, meta: boundary }),
      durable' = if (BlockingFailTruncatesLog) durable else boundary,
      ck' = { ...ck, completed: false, seen: ck.seen.union(Set("blockingFailedPublished")) },
      nCk' = nCk + 1,
      llog' = if (BlockingFailTruncatesLog) Set() else llog, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
      backfillFloor' = backfillFloor, chain' = chain,
      clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, rd' = rd,
      writes' = writes, logged' = logged, err' = err,
      UnchangedRowVars,
    }
  }

  // ---------------------------------------------------------------------------
  // Garbage collection of the version store

  // compute_lwm: the lowest begin timestamp of a registered reader. The engine also
  // counts the begin timestamp of a writer that has not finished (its BEGIN
  // CONCURRENT tick, one below its commit timestamp). The model has that begin only
  // with WriterBeginTicks, so the trace replay sees the same lwm as the engine.
  val Lwm: int = Min(Registered.map(r => rd.get(r).b)
                       .union(if (WriterBeginTicks) inflight.map(i => i.ts - 1) else Set())
                       .union(Set(Inf)))

  // The lowest read mark that GC must respect.
  val GcFloor: int =
    if (GcFloorRule == "code")
      Min(Registered.map(r => rd.get(r).mark).union(Set(backfillFloor, Inf)))
    else if (GcFloorRule == "registered")
      Min(Registered.map(r => rd.get(r).mark).union(Set(Inf)))
    else if (GcFloorRule == "pinned")
      Min(Pinned.map(r => rd.get(r).mark).union(Set(Inf)))
    else backfillFloor

  // Rule 2: a superseded version that no snapshot sees.
  def Rule2(v: Version, lwm: int, floor: int): bool = and {
    v.e != Inf, Resolved(v.e), not(GuardRule2Lwm) or v.e < lwm,
    not(fin.unrewritten.contains(v.e)),  // a TxID marker is not dropped (mod.rs:8595)
    not(GuardGcWaitsForReaders) or (v.mat != 0 and v.mat <= floor),
  }

  // Rule 3: the last, current version, once the B-tree has it.
  def Rule3(c: Set[Version], lwm: int, floor: int): bool = and {
    c.size() == 1,
    val v = AnyVersion(c)
    and {
      v.e == Inf, v.b != 0, Resolved(v.b),
      not(fin.unrewritten.contains(v.b)),  // a TxID marker is not dropped (mod.rs:8606)
      not(GuardGcWaitsForReaders) or (v.mat != 0 and v.mat <= floor),
      not(GuardDropCurrentOnlyWhenIdle) or lwm == Inf,
    },
  }

  // gc_version_chain. Rule 1 drops rolled-back garbage (begin None, end None).
  def GcChain(k: str, lwm: int, floor: int): Set[Version] =
    if (Mode == "blocking") GcChainB(chain.get(k), lwm, durable, floor)
    else
      val afterRule1 = chain.get(k).filter(v => not(v.b == 0 and v.e == Inf))
      val afterRule2 = afterRule1.filter(v => not(Rule2(v, lwm, floor)))
      if (Rule3(afterRule2, lwm, floor)) Set() else afterRule2

  // Mode B form of the rules (gc_version_chain with passive = false,
  // mod.rs:8625-8685). ckptMax is durable_txid_max.
  // has_current counts the versions with a timestamp begin and no end, taken
  // after Rule 1 (mod.rs:8635-8640).
  def HasCurrentB(c: Set[Version]): bool =
    c.exists(x => x.b != 0 and Resolved(x.b) and x.e == Inf)

  // in_btree: the version came from the B-tree (begin None) or began at or
  // below ckptMax.
  def InBtreeB(v: Version, ckptMax: int): bool =
    v.b == 0 or (Resolved(v.b) and v.b <= ckptMax)

  // The keep clause of Rule 2, B form: e > ckpt_max && (in_btree || !has_current).
  // A guard that is off removes its term. With both terms off the clause is
  // false.
  def KeepClauseB(v: Version, ckptMax: int, hasCur: bool): bool = and {
    GuardB2KeepUncheckpointed,
    v.e > ckptMax,
    or {
      GuardB2InBtree and InBtreeB(v, ckptMax),
      GuardB2Tombstone and not(hasCur),
    },
  }

  def Rule2B(v: Version, c: Set[Version], lwm: int, ckptMax: int, floor: int): bool = and {
    v.e != Inf, Resolved(v.e), not(GuardRule2Lwm) or v.e < lwm,
    not(KeepClauseB(v, ckptMax, HasCurrentB(c))),
    not(FixB2WaitsForPinned) or Pinned.forall(r => rd.get(r).mark >= wal.length()),
  }

  def Rule3B(c: Set[Version], lwm: int, ckptMax: int, floor: int): bool = and {
    c.size() == 1,
    val v = AnyVersion(c)
    and {
      v.e == Inf, v.b != 0, Resolved(v.b),
      v.mat != 0, v.mat <= floor, lwm == Inf,
      not(GuardB3InCkptMax) or v.b <= ckptMax,
    },
  }

  def AfterRule2B(c: Set[Version], lwm: int, ckptMax: int, floor: int): Set[Version] =
    val afterRule1 = c.filter(v => not(v.b == 0 and v.e == Inf))
    afterRule1.filter(v => not(Rule2B(v, afterRule1, lwm, ckptMax, floor)))

  def GcChainB(c: Set[Version], lwm: int, ckptMax: int, floor: int): Set[Version] =
    if (Rule3B(AfterRule2B(c, lwm, ckptMax, floor), lwm, ckptMax, floor)) Set()
    else AfterRule2B(c, lwm, ckptMax, floor)

  action UnchangedForGc = all {
    clock' = clock, inflight' = inflight, lastCommitted' = lastCommitted, llog' = llog,
    wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk, rd' = rd, writes' = writes,
    logged' = logged, err' = err,
  }

  action Gc(k: str): bool = all {
    not(GcSamplesFirst),
    GcChain(k, Lwm, GcFloor) != chain.get(k),
    chain' = chain.set(k, GcChain(k, Lwm, GcFloor)),
    ck' = AfterGc(k, GcChain(k, Lwm, GcFloor)),
    UnchangedForGc,
    UnchangedRowVars,
  }

  // sample_gc_lwm under the clock lock, and the floor, before any chain lock.
  action GcSample: bool = all {
    GcSamplesFirst,
    gcs.pc == "idle",
    gcs' = { pc: "sampled", lwm: Lwm, floor: GcFloor },
    ending' = ending,
    fin' = fin, UnchangedWal,
    chain' = chain,
    ck' = ck,
    UnchangedForGc,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    UnchangedFullScan,
  }

  // gc_chain_now under the chain lock, with the sampled values. An lwm of
  // "no reader" is computed again, because a reader may have begun since.
  action GcApply(k: str): bool = {
    val lwm = if (GuardGcRechecksIdleLwm and gcs.lwm == Inf) Lwm else gcs.lwm
    all {
      gcs.pc == "sampled",
      GcChain(k, lwm, gcs.floor) != chain.get(k),
      chain' = chain.set(k, GcChain(k, lwm, gcs.floor)),
      ck' = AfterGc(k, GcChain(k, lwm, gcs.floor)),
      UnchangedForGc,
      UnchangedRowVars,
    }
  }

  action GcEnd: bool = all {
    gcs.pc == "sampled",
    gcs' = { pc: "idle", lwm: 0, floor: 0 },
    ending' = ending,
    fin' = fin, UnchangedWal,
    chain' = chain,
    ck' = ck,
    UnchangedForGc,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    UnchangedFullScan,
  }

  // The prune of finalized_tx_states, in two steps. The collect reads the
  // TxIDs that the chains name (collect_referenced_txids). That includes the
  // markers of Preparing writers: such a writer can finish and leave txs
  // before the apply, and then the filter keeps its TxID for one more round
  // (the replay found this). The apply drops
  // every finalized TxID that is not referenced and not in txs. The engine
  // prunes only at checkpoint Finalize and at VACUUM. Any time gives more
  // orders, which is sound for a safety check. With one key, an atomic collect
  // equals the per-chain collect.
  action FinPruneCollect: bool = all {
    ModelFinalizedPrune,
    fin.pc == "idle",
    ending' = ending,
    fin' = { ...fin, pc: "collected",
             ref: fin.unrewritten.union(InflightTs).filter(t => Keys.exists(k =>
                    chain.get(k).exists(v => v.b == t or v.e == t))) },
    clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
    llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
    writes' = writes, logged' = logged, err' = err,
    aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
    UnchangedFullScan, UnchangedWal,
    gcs' = gcs,
  }

  action FinPruneApply: bool = {
    val drop = fin.finalized.filter(t =>
      (not(GuardPruneReferenced) or not(fin.ref.contains(t))) and not(fin.retiring.contains(t)))
    all {
      fin.pc == "collected",
      ending' = ending,
      fin' = { ...fin, finalized: fin.finalized.exclude(drop), pruned: fin.pruned.union(drop),
               pc: "idle", ref: Set(),
               fired: fin.fired or (GuardPruneReferenced and fin.finalized.exists(t => fin.ref.contains(t))) },
      clock' = clock, chain' = chain, inflight' = inflight, lastCommitted' = lastCommitted,
      llog' = llog, wal' = wal, nBackfill' = nBackfill, db' = db, dbMeta' = dbMeta,
      durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
      writes' = writes, logged' = logged, err' = err,
      aborted' = aborted, readDeps' = readDeps, dirty' = dirty, lateMarks' = lateMarks,
      UnchangedFullScan, UnchangedWal,
      gcs' = gcs,
    }
  }

  def AfterGc(k: str, remaining: Set[Version]): CkState = {
    ...ck, seen: ck.seen
      .union(if (Mode == "blocking") Set("gcDroppedB") else Set())
      .union(if (Mode == "blocking" and Registered != Set()
                 and chain.get(k).exclude(remaining).exists(v => v.e != Inf))
               Set("b2DropWithReader") else Set())
      .union(if (EarlyStampedDrop(k, remaining)) Set("earlyStampGcWithReader") else Set())
      .union(if (EarlyStampedDropAfterFailure(k, remaining)) Set("earlyStampGcAfterFailure") else Set()),
  }

  def EarlyStampedDrop(k: str, remaining: Set[Version]): bool = and {
    FixStampAtPagerCommit, Registered != Set(), ck.frame > 0,
    Set("committed", "publishing", "published", "backfilled", "truncateDecided", "truncated").contains(ck.pc),
    chain.get(k).exclude(remaining).exists(v => v.mat == ck.frame),
  }

  def EarlyStampedDropAfterFailure(k: str, remaining: Set[Version]): bool = and {
    FixStampAtPagerCommit, Registered != Set(), ck.seen.contains("failedEarlyStamp"),
    ck.completed, ck.frame == 0, ck.wset.keys() == Set(),
    chain.get(k).exclude(remaining).exists(v => v.mat > 0),
  }

  // ---------------------------------------------------------------------------
  // Specification

  // Each pick has a name, so `quint run --mbt` records it. A set can be empty, so a pick from it sits behind a check.
  action Next = any {
    nondet k = Keys.oneOf()
    nondet isDelete = Bool.oneOf()
    WritePrepare(k, isDelete),
    all {
      inflight != Set(),
      nondet i = inflight.oneOf()
      any { WriteMarkDirty(i), WriteLogAppend(i), WriteFinish(i), WriteCommitEnd(i), WriteAbort(i) },
    },
    all {
      ending != Set(),
      nondet e = ending.oneOf()
      any { WriteRewriteTxId(e), WriteFinalize(e) },
    },
    all {
      lateMarks != Set(),
      nondet m = lateMarks.oneOf()
      WriteLateMark(m),
    },
    all {
      Readers != Set(),
      nondet r = Readers.oneOf()
      any {
        ReaderPin(r),
        ReaderBegin(r),
        nondet k = Keys.oneOf()
        ReaderReadStart(r, k),
        ReaderReadEnd(r),
        ReaderEnd(r),
        nondet k = Keys.oneOf()
        ReaderUpdate(r, k),
      },
    },
    nondet at = Set("collect", "writing", "committed", "publishing", "published", "backfilled", "truncateDecided", "truncated", "prune", "clear", "restarted", "sweep").oneOf()
    CheckpointFail(at),
    CheckpointStart,
    CheckpointBlocking,
    CheckpointBlockingStop,
    CheckpointBlockingFail,
    nondet k = Keys.oneOf()
    CheckpointCollect(k),
    CheckpointBeginPager,
    CheckpointCommit,
    CheckpointPublish,
    CheckpointPublishBoundary,
    CheckpointBackfill,
    CheckpointRestart,
    CheckpointFinalSweep,
    CheckpointTruncateDecide,
    CheckpointTruncateApply,
    CheckpointStamp,
    all {
      ck.cand != Set(),
      nondet c = ck.cand.oneOf()
      CheckpointPrune(c),
    },
    CheckpointPruneDone,
    CheckpointClearFullScan,
    nondet k = Keys.oneOf()
    Gc(k),
    GcSample,
    nondet k = Keys.oneOf()
    GcApply(k),
    GcEnd,
    all { fin.retiring != Set(), nondet t = fin.retiring.oneOf() WriteRemoveTx(t) },
    all { fin.unrewritten != Set(), nondet u = fin.unrewritten.oneOf() WriteRewrite(u) },
    FinPruneCollect,
    FinPruneApply,
  }

  // ---------------------------------------------------------------------------
  // Properties

  // A reader that depended on a writer that aborted must abort too
  // (abort_now), so its reads do not count. A read whose writers are still
  // Preparing is not decided yet.
  val ReadsCorrect: bool =
    if (GuardReadersAbortOnDependency)
      err.forall(e => e.deps.intersect(aborted.union(InflightTs)) != Set())
    else err == Set() and readDeps.intersect(aborted) == Set()

  // Every key with a committed change in (old, snap] is in the frame. This is
  // the property that the dirty-key map must keep.
  val CollectsEveryChange: bool =
    ck.pc == "committed" implies
      Keys.forall(k => ChangedSince(chain.get(k), ck.old, ck.snap)
                         implies ck.wset.keys().contains(k))

  // Crash recovery: read the B-tree through every WAL frame, then replay the
  // logical log records above the boundary stored in the B-tree.
  val RecoveredMeta: int = if (wal == List()) dbMeta else Frame(wal.length()).meta

  def Recovered(k: str): int =
    val replay = llog.filter(l => l.k == k and l.ts > RecoveredMeta)
    if (replay == Set()) BtreeAt(k, wal.length())
    else replay.fold({ ts: -1, k: k, v: 0 }, (a, l) => if (l.ts > a.ts) l else a).v

  val NoStrandedVersions: bool =
    (ck.pc == "idle" and ck.completed) implies
      Keys.forall(k => chain.get(k).forall(v =>
        (Resolved(LastEvent(v)) and LastEvent(v) <= durable) implies v.mat != 0))

  val RecoveryCorrect: bool = Keys.forall(k => Recovered(k) == LatestIn(logged, k, Inf))

  // The WAL rule that the B-tree side of every read depends on: no pinned
  // reader has a read mark below the backfilled frames.
  val BackfillBelowReaders: bool = Pinned.forall(r => nBackfill <= rd.get(r).mark)

  // backfillFloor is at or below every pinned read mark. So the reader marks
  // in the "code" GC floor never lower it: that floor equals backfillFloor.
  val BackfillFloorBelowReaders: bool = and {
    backfillFloor <= nBackfill,
    Pinned.forall(r => backfillFloor <= rd.get(r).mark),
  }

  // GC never drops a version stamped above the read mark of a pinned reader.
  val GcKeepsVersionsAboveReaders: bool =
    Keys.forall(k => Pinned.union(Registered).forall(r =>
      chain.get(k).exclude(GcChain(k, Lwm, GcFloor)).forall(v => v.mat <= rd.get(r).mark)))

  // A pinned reader never loses a version it can see. A reader outside txs
  // reads at the would-be begin clock + 1. Only checked with no Preparing
  // writer below that begin.
  def ReadFor(k: str, b: int, m: int): int =
    val vis = LookVis(chain.get(k), b, m)
    if (vis != None) vis else if (LookValid(chain.get(k), b, m)) BtreeAt(k, m) else 0

  val PinnedReaderKeepsVisible: bool =
    Pinned.forall(r =>
      val b = if (Registered.contains(r)) rd.get(r).b else clock + 1
      InflightTs.forall(t => t > b) implies
        Keys.forall(k => ReadFor(k, b, EffMark(r)) == Oracle(k, b)))

  // No pinned reader holds a mark of an older WAL sequence.
  val NoReaderCrossesRestart: bool = Pinned.forall(r => rd.get(r).seq == walSeq)

  // First committer wins: no write of k between an update's begin and its commit.
  val NoLostUpdate: bool =
    rmw.filter(u => writes.exists(w => w.ts == u.ts)).forall(u =>
      not(writes.exists(w => w.k == u.k and u.b < w.ts and w.ts < u.ts)))
  // No version names a TxID that both txs and finalized_tx_states have lost.
  val TxIdsResolve: bool =
    Keys.forall(k => chain.get(k).forall(v => not(Lost(v.b)) and not(Lost(v.e))))

  val TypeOK: bool = and {
    rmw.forall(u => u.b < u.ts and u.ts <= MaxTs),
    Set("committed", "publishing").contains(ck.pc) implies ck.frame > 0,
    ck.pagerOwned == (ck.pc == "writing"),
    clock.in(0.to(MaxTs)),
    nBackfill.in(0.to(wal.length())),
    walSeq.in(0.to(wal.length())),
    genStart.keys() == 0.to(walSeq),
    Readers.forall(r => rd.get(r).seq <= walSeq),
    wal.length() <= MaxCheckpoints,
    durable <= lastCommitted,
    Keys.forall(k => chain.get(k).forall(v => and {
      v.b.in(0.to(MaxTs)),
      v.e.in(1.to(MaxTs).union(Set(Inf))),
      v.mat.in(0.to(wal.length())),
    })),
  }

  // ---------------------------------------------------------------------------
  // Reachability checks. Each one must be violated, which proves that the
  // model reaches the state.

  val Safety: bool = and {
    TypeOK, ReadsCorrect, RecoveryCorrect, BackfillBelowReaders,
    BackfillFloorBelowReaders, GcKeepsVersionsAboveReaders, NoStrandedVersions,
    NoLostUpdate,
  }

  // Updates.
  val NeverUpdateCommits: bool = rmw == Set()
  val NeverUpdateConflict: bool = not(ck.seen.contains("wwConflict"))
  val NeverConflictByEndOnly: bool = not(ck.seen.contains("wwEndOnly"))
  val NeverConflictByCurrentOnly: bool = not(ck.seen.contains("wwCurrentOnly"))
  val NeverConflictAfterGc: bool = not(ck.seen.contains("wwAfterGc"))
  // Finalized TxID states. A prune ran while the writer's version still exists (the model stores timestamps, not TxID markers).
  val NeverPrunesWithVersion: bool =
    not(fin.pruned.exists(t => Keys.exists(k => chain.get(k).exists(v => v.b == t or v.e == t))))
  // The referenced filter kept a TxID that the prune would drop without the filter.
  val NeverPruneGuardFires: bool = not(fin.fired)

  val NeverCleanupPublishes: bool = not(ck.seen.contains("cleanupPublished"))
  val NeverGcEarlyStampAfterFailure: bool = not(ck.seen.contains("earlyStampGcAfterFailure"))
  val NeverGcEarlyStampWithReader: bool = not(ck.seen.contains("earlyStampGcWithReader"))

  // Mode B.
  val BlockingStoreEmpty: bool = not(ck.seen.contains("blockingLeftVersions"))
  val NeverGcDropsB: bool = not(ck.seen.contains("gcDroppedB"))
  val NeverFallsThrough: bool = not(ck.seen.contains("fellThrough"))
  val NeverBlockingDropsSuperseded: bool = not(ck.seen.contains("b2DropWithReader"))
  val NeverBlockingDropsCurrent: bool = not(ck.seen.contains("b3Drop"))
  val NeverBlockingFailsAfterPublish: bool = not(ck.seen.contains("blockingFailedPublished"))
  // Gap 22: the TxID rewrite resets the stamp of a version that a pass stamped.
  val NeverRewritesStamped: bool = not(ck.seen.contains("rewroteStamped"))
  val NeverStampAtRestart: bool = not(ck.seen.contains("stampedAtRestart"))

  // WAL restart.
  val NeverRestart: bool = walSeq == 0
  val NeverSweepWithUnregistered: bool = not(ck.seen.contains("sweepWithR5"))
  val NeverReadAfterRestart: bool = not(ck.seen.contains("readAfterRestart"))

  val NeverFailsAfterPublish: bool = not(ck.seen.contains("failedPublished"))
  val NeverRepairsVersions: bool = not(ck.seen.contains("repairedVersions"))
  val NeverLosesAppendAtTruncate: bool = not(ck.seen.contains("truncateLostAppend"))

  val NeverDropsCurrentRow: bool =
    not(Keys.exists(k => chain.get(k) == Set() and LatestIn(writes, k, Inf) != 0))
  val NeverTruncatesLog: bool = not(llog == Set() and logged != Set())
  val NeverReadsBtreeAtOldMark: bool =
    not(Readers.exists(r => and {
      rd.get(r).pc == "reading", rd.get(r).mark < wal.length(), rd.get(r).mark > 0,
    }))
  val NeverBackfills: bool = nBackfill == 0
  // A pinned reader has a read mark below the stamp of a version.
  val NeverStampedAboveReader: bool =
    not(Pinned.exists(r => Keys.exists(k => chain.get(k).exists(v => v.mat > rd.get(r).mark))))
  // A retained read mark can be below backfillFloor. The code floor still
  // counts registered snapshots after their pager pin disappears.
  val NeverReaderMarkBelowBackfillFloor: bool =
    not(Pinned.union(Registered).exists(r => rd.get(r).mark < backfillFloor))
  // After a rollback, a current version that the B-tree already has is left
  // with materialized_at = ORIGIN, and no later checkpoint stamps it again.
  val NeverLeavesUnstampedCurrent: bool =
    not(and {
      ck.pc == "idle", inflight == Set(), nCk == MaxCheckpoints,
      Keys.exists(k => chain.get(k).exists(v =>
        v.e == Inf and v.b != 0 and v.b <= durable and v.mat == 0)),
    })
}
