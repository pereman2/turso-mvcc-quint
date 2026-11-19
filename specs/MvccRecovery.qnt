// -*- mode: Bluespec; -*-
/**
 * Turso MVCC crash recovery.
 *
 * This specification models the files that a crash leaves behind and the
 * open of those files. It asks two questions. Does the database open, or
 * does it refuse with "Corrupt"? If it opens, does it give the committed
 * rows, now and after more commits and checkpoints? See DESIGN-recovery.md
 * next to this file for the design in prose and the map to the Rust code.
 *
 * Scope. SyncMode FULL (every commit fsyncs the log, and a pager commit
 * fsyncs the WAL) and SyncMode NORMAL (a commit does not fsync the log, and
 * the pager commit of a checkpoint does not fsync the WAL; only the backfill
 * does). Under NORMAL a crash can lose acknowledged commits, so the promise
 * is NormalPrefix: recovery gives the rows of one commit point, no older than
 * the last point that a WAL sync or a recovery made durable. A passive
 * backfill can copy no frame (a pinned reader or Busy). The checkpoint kinds are the ones that automatic
 * checkpoints, Connection::checkpoint and PRAGMA wal_checkpoint(PASSIVE or
 * TRUNCATE) start. An explicit FULL or RESTART checkpoint maps to TRUNCATE
 * (core/mvcc/database/checkpoint.rs:896-902 on turso main 740300d9d), so the
 * blocking kinds cover it.
 *
 * Files.
 *   DB file       B-tree rows and the meta row persistent_tx_ts_max. The
 *                 page cache (dbMem) and the fsynced copy (dbDisk) differ
 *                 between a backfill and its fsync.
 *   WAL           Frames written by checkpoints. walDisk counts the frames
 *                 that an fsync made durable. Recovery can stop between
 *                 truncating and syncing the WAL.
 *   Logical log   A header (None, Valid or Invalid) and one frame for each
 *                 commit. `file` is what the OS shows, `disk` is what an
 *                 fsync made durable. A frame that recovery cannot chain to
 *                 the header has ok = false, and replay stops before it.
 *
 * Actors.
 *   Commits      Four steps: CommitWrite submits the append (with the
 *                header when the writer offset is 0), CommitAppendDone, the
 *                log fsync CommitFsync, then CommitPublish acknowledges the
 *                commit and puts its versions in the store.
 *   Checkpoint   Three kinds. "blocking": the passive flag is off, the
 *                checkpoint is TRUNCATE and holds the blocking lock from the
 *                start. "passive": the flag is on. "truncflag": the flag is
 *                on and the user runs PRAGMA wal_checkpoint(TRUNCATE). Steps:
 *                Begin (snapshot and collect), Commit (pager commit of one
 *                WAL frame), Publish (durable_txid_max advances), Backfill,
 *                SyncDb, TruncLog (locked decision, writer reset and
 *                truncate submit), TruncDone (only for an async backend),
 *                TruncWal, Gc.
 *   Reader       NextWithReader lets one user reader pin the DB file or WAL,
 *                register a logical snapshot, and release both on end.
 *   CkFail       An error or an abandoned checkpoint at one of the steps
 *                Commit to TruncWal. The checkpoint stops without GC, and a
 *                committed WAL frame stays. A truncate error (only with
 *                LogTruncateErrors) keeps the writer offset but resets the
 *                running CRC, as the Unix backend does.
 *   Crash        Keeps fsynced data. An unsynced write is lost, kept or
 *                torn. A torn header write can tear the log header.
 *   Open         OpenStart decides to refuse or to continue, with two flags:
 *                the passive flag and read-only. Then the durable steps of
 *                recovery: backfill, DB fsync, header write, log fsync, and
 *                WAL truncate, WAL fsync, and replay. A crash can stop recovery.
 *
 * Invariants.
 *   RecoveryCorrect  Every open that succeeds gives the committed rows, and
 *                    reads stay correct while the system keeps running.
 *   OpenSucceeds     If the files hold every committed row, every open that
 *                    the user can pick succeeds, unless RECOVERY_SEMANTICS.md
 *                    states that refusal as intended (cases 3 and 5).
 *   OpenSucceedsStrict  The same with no stated refusals.
 *   NormalPrefix     Under NORMAL, every open that succeeds gives the rows of
 *                    one commit point between `floor` (the newest point that
 *                    the engine promised durable) and the last commit.
 *   NormalRecoveryStable  A successful retry of an interrupted NORMAL open
 *                    recovers the same timestamp and rows as the first open projected.
 *   NoLeak           After a checkpoint succeeds, the store keeps no chain
 *                    that the B-tree already holds in full. After a blocking
 *                    checkpoint, the store is empty.
 *
 * Not modeled: multiple readers, flag-on TRUNCATE with a reader, schema and
 * root pages, indexes, aborts, SyncMode OFF, mixed sync modes per connection,
 * a crash that keeps a middle part of the unsynced log or WAL, the commit-path GC
 * (gc_incremental), the header CRC retry at open, I/O errors at open, and
 * more than one commit in flight.
 */
module MvccRecovery {
  const Keys: Set[str]          // Row keys of one table.
  const MaxTs: int              // Bound on the commit timestamps.
  const MaxCheckpoints: int     // Bound on checkpoint passes.
  const MaxCrashes: int         // Bound on crashes.
  const MaxFails: int           // Bound on checkpoint errors.
  const InitFlag: bool          // The passive flag of the first process.
  const OpenFlags: Set[bool]    // Passive flags the user can pick at open.
  const OpenReadOnly: Set[bool] // Read-only choices the user can pick at open.
  // Checkpoint kinds that the configuration lets run. A scope choice, not a
  // list of every checkpoint mode of the code.
  const CheckpointKinds: Set[str]
  const CrashOnlyWhenIdle: bool // true: a crash only with no write in flight
                                // and no checkpoint (a clean close).
  const TornHeaderGarbage: bool // true: a torn header write can leave bytes
                                // that do not decode (Invalid). false: it
                                // leaves zeros or a short file (None).
  // true: the log truncate completes later than its submit, as with
  // io_uring (core/io/io_uring.rs:848). false: it completes in the submit
  // call, as with the Unix backend (core/io/unix.rs:500).
  const AsyncLogTruncate: bool
  const LogTruncateErrors: bool // true: the log truncate call can fail.
  const SyncMode: str           // "full" or "normal".
  // true: a passive backfill can copy no frame (a pinned reader or Busy,
  // core/mvcc/database/checkpoint.rs:3306-3322).
  const PassiveBackfillSkips: bool

  // Behavior switches and design ideas.
  const Fix9770: bool            // PR #9770: WAL frames + no log header
                                 // completes the checkpoint with the flag off (on current main).
  const FixBlockingStoreEmpty: bool // After a blocking checkpoint, stamp every
                                 // chain, so its GC empties the store.
  const RecoveryOneTs: bool      // Idea 1: replay gives every replayed
                                 // version one timestamp, the largest replayed one.
  const FixCkCommitSyncsWal: bool // The checkpoint pager commit fsyncs the WAL
                                 // also under NORMAL (pager.rs:4776 today
                                 // fsyncs only under FULL).
  const FixStampBelowBoundary: bool // A checkpoint stamps every version whose
                                 // last event is at or below the published
                                 // boundary, not only its write set.

  pure val Inf = 1000     // "no end timestamp"
  pure val NotWritten = -2

  /* A version is { b, e, v, mat, res }:
       b    begin timestamp, 0 for "begin None" (a tombstone over a B-tree row)
       e    end timestamp, Inf while current
       v    the row value, the commit timestamp of its write
       mat  WAL position of the terminal event, 0 when unstamped
       res  btree_resident */
  type Ver = { b: int, e: int, v: int, mat: int, res: bool }
  // A log frame: one commit of one key. v = 0 deletes. prev: the row
  // existed before, so the frame also ends the old version. ok: recovery can
  // chain its CRC to the header.
  type LogFrame = { ts: int, k: str, v: int, prev: bool, ok: bool }
  // A WAL frame: the value of each key, NotWritten for keys it does not write.
  type WalFrame = { w: str -> int, meta: int }
  type Log = {
    file: List[LogFrame], hfile: str,  // what the OS shows
    disk: List[LogFrame], hdisk: str,  // what an fsync made durable
    off0: bool,       // the writer offset is 0: the next append writes the header
    crcReset: bool,   // the running CRC restarted from a new salt at offset > 0
    maxApp: int,      // max_appended_commit_ts
    truncPend: bool,  // a truncate is submitted and not complete
    appSince: bool,   // a frame was appended after that submit
    hdrFlight: bool,  // recovery wrote the header and has not fsynced it
  }
  // walDisk: the number of WAL frames that an fsync made durable. Under FULL
  // it equals wal.length().
  // walBase: ordered position of frame 0 of this WAL generation.
  type Files = { wal: List[WalFrame], walDisk: int, walBase: int, nBackfill: int, dbMem: str -> int,
                 dbDisk: str -> int, metaMem: int, metaDisk: int }
  // stage: "submitted", "appended" (write complete), "synced" (fsync done).
  type Inflight = { on: bool, rec: LogFrame, hdr: bool, stage: str }
  type Ck = { pc: str, kind: str, snap: int, wset: str -> int, clears: bool,
              nonempty: bool, copiedThrough: int }
  // An open in progress. walHad and hdrWas are the files at OpenStart.
  // crash names the last crash: "tornFirstAppend" when it tore the header of
  // a first append while the WAL had frames.
  type RecoveryPoint = { ts: int, rows: str -> int }
  type Reader = { phase: str, mark: int, dbFile: bool, snapshot: RecoveryPoint }
  type OpenSt = { pc: str, f: bool, walHad: bool, hdrWas: str, crash: str,
                  expected: RecoveryPoint }
  type Counters = { ck: int, crash: int, fail: int }
  type Rebuild = { ok: bool, why: str, db: str -> int, meta: int, hdr: str,
                   chains: str -> Set[Ver], clock: int, replayMax: int }

  var mode: str                 // "run", "open" (recovery runs) or "down".
  var flag: bool                // Passive flag of the running process.
  var clock: int                // Last commit timestamp.
  var truth: str -> int         // Committed value of each key, 0 for absent.
  var store: str -> Set[Ver]    // Version store.
  var durable: int              // durable_txid_max in memory.
  var lg: Log
  var fs: Files
  var cm: Inflight
  var ck: Ck
  var reader: Reader
  var op: OpenSt
  var cnt: Counters
  var leakSnap: int             // The snapshot of the checkpoint that the last
                                // step ended with success, -1 for none.
  var replayTop: int            // Largest replayed timestamp of the last open.
  var seen: Set[str]            // Events, for the reachability checks.
  // Used under NORMAL only. Under FULL they keep their start value.
  var hist: int -> (str -> int) // The committed rows after each timestamp.
  var floor: int                // The newest timestamp made durable by a WAL sync
                                // or recovered at open.

  // ---------------------------------------------------------------- helpers

  pure def maxOf(s: Set[int]): int = s.fold(0, (a, x) => if (x > a) x else a)

  pure def applyFrames(db: str -> int, frames: List[WalFrame]): str -> int =
    frames.foldl(db, (acc, f) =>
      acc.keys().mapBy(k => if (f.w.get(k) == NotWritten) acc.get(k) else f.w.get(k)))

  pure def lastMeta(m: int, frames: List[WalFrame]): int =
    frames.foldl(m, (acc, f) => f.meta)

  // The frames before the first frame whose CRC does not chain.
  pure def validPrefix(l: List[LogFrame]): List[LogFrame] =
    l.foldl({ out: List(), stop: false }, (acc, r) =>
      if (acc.stop or not(r.ok)) { ...acc, stop: true }
      else { ...acc, out: acc.out.append(r) }).out

  pure def hasFrame(l: List[LogFrame], r: LogFrame): bool = l.select(x => x == r).length() > 0

  // The value of a key at timestamp t. A chain with an event at or before t
  // decides. Otherwise the B-tree value `base` shows.
  pure def readAt(chain: Set[Ver], base: int, t: int): int =
    val vis = chain.filter(x => x.b > 0 and x.b <= t and x.e > t)
    if (vis != Set()) {
      val top = maxOf(vis.map(x => x.b))
      maxOf(vis.filter(x => x.b == top).map(x => x.v))
    } else if (chain.exists(x => x.e <= t)) 0
    else base

  // One log frame applied to a chain, by the commit path or by replay.
  // tsUsed is the begin and end timestamp that the frame gets.
  pure def applyRec(chain: Set[Ver], r: LogFrame, tsUsed: int): Set[Ver] =
    val cur = chain.filter(x => x.b > 0 and x.b < tsUsed and x.e == Inf)
    val afterDel =
      if (not(r.prev)) chain
      else if (cur != Set())
        chain.map(x => if (cur.contains(x)) { ...x, e: tsUsed, mat: 0 } else x)
      else chain.union(Set({ b: 0, e: tsUsed, v: 0, mat: 0, res: true }))
    if (r.v == 0) afterDel
    else {
      // insert_version_raw keeps one version for one begin timestamp.
      afterDel.filter(x => not(x.b == tsUsed and x.b > 0))
        .union(Set({ b: tsUsed, e: Inf, v: r.v, mat: 0, res: false }))
    }

  pure def terminal(x: Ver): int = if (x.e < Inf) x.e else x.b

  pure def stamp(chain: Set[Ver], snap: int, pos: int): Set[Ver] =
    chain.map(x => if (terminal(x) <= snap) { ...x, mat: pos } else x)

  pure def gcChain(chain: Set[Ver], ckptMax: int, passive: bool, gcFloor: int, lwm: int): Set[Ver] =
    val materialized = chain.filter(x => x.mat > 0 and x.mat <= gcFloor)
    val hasCurrent = chain.exists(x => x.b > 0 and x.e == Inf)
    val r2 = chain.filter(x =>
      if (x.e < Inf and x.e <= lwm) {
        if (passive) not(materialized.contains(x))
        else x.e > ckptMax and (x.res or (x.b > 0 and x.b <= ckptMax) or not(hasCurrent))
      } else true)
    val r3 = r2.filter(x =>
      x.b > 0 and x.e == Inf and materialized.contains(x) and (passive or x.b <= ckptMax))
    if (lwm == Inf and r2.size() == 1 and r3.size() == 1) Set() else r2

  // The startup decision and the state that an uninterrupted recovery
  // rebuilds from these files. `ignoreRefusals` gives the rows that the
  // files hold.
  pure def rebuild(f: bool, ro: bool, fix: bool, oneTs: bool, ignoreRefusals: bool,
                   ks: Set[str], wl: List[WalFrame], hd: str, frames: List[LogFrame],
                   db0: str -> int, meta0: int): Rebuild =
    val walHas = wl.length() > 0
    val why =
      if (walHas and ro) "readonly"
      else if (walHas and hd == "Invalid") "case3"
      else if (walHas and hd == "None" and not(f or fix)) "case2"
      else if (not(walHas) and hd == "Invalid") "case5"
      else ""
    val db1 = if (walHas) applyFrames(db0, wl) else db0
    val meta1 = if (walHas) lastMeta(meta0, wl) else meta0
    // Recovery writes a fresh header after it backfills the WAL.
    val hdr1 = if (walHas) "Valid" else hd
    // A log with no valid header has no frames to replay.
    val readable = if (hd == "Valid") validPrefix(frames) else List()
    val replay = readable.select(r => r.ts > meta1)
    val logMax = maxOf(readable.foldl(Set(), (s, r) => s.union(Set(r.ts))))
    val replayMax = maxOf(replay.foldl(Set(), (s, r) => s.union(Set(r.ts))))
    val chains = replay.foldl(ks.mapBy(k => Set()), (acc, r) =>
      acc.set(r.k, applyRec(acc.get(r.k), r, if (oneTs) replayMax else r.ts)))
    {
      ok: why == "" or ignoreRefusals,
      why: why,
      db: db1,
      meta: meta1,
      hdr: hdr1,
      chains: chains,
      clock: if (logMax > meta1) logMax else meta1,
      replayMax: replayMax,
    }

  pure def rebuildReads(rb: Rebuild, ks: Set[str]): str -> int =
    ks.mapBy(k => readAt(rb.chains.get(k), rb.db.get(k), rb.clock))

  val normal: bool = SyncMode == "normal"
  pure def maxI(a: int, b: int): int = if (a > b) a else b
  pure def minI(a: int, b: int): int = if (a < b) a else b

  // ------------------------------------------------------------ derived state

  val btree: str -> int = applyFrames(fs.dbMem, fs.wal)
  val reads: str -> int = Keys.mapBy(k => readAt(store.get(k), btree.get(k), clock))
  val walEnd: int = fs.walBase + fs.wal.length()
  val backfillFloor: int = fs.walBase + fs.nBackfill
  val lastAcked: int = if (cm.on) clock - 1 else clock
  val ckIdle: Ck = { pc: "idle", kind: "", snap: 0, wset: Keys.mapBy(k => NotWritten),
                     clears: false, nonempty: false, copiedThrough: 0 }
  val noOpen: OpenSt = { pc: "idle", f: false, walHad: false, hdrWas: "", crash: "",
                        expected: { ts: -1, rows: Keys.mapBy(k => 0) } }
  val readerIdle: Reader = { phase: "idle", mark: 0, dbFile: false,
                             snapshot: { ts: -1, rows: Keys.mapBy(k => 0) } }
  val readerHeld: bool = reader.phase != "idle"
  val readerActive: bool = reader.phase == "active"
  val readerLwm: int = if (readerActive) reader.snapshot.ts else Inf
  val readerGcFloor: int =
    if (readerActive or (readerHeld and not(reader.dbFile))) minI(backfillFloor, reader.mark)
    else backfillFloor
  val readerCopyLimit: int =
    if (not(readerHeld)) fs.wal.length()
    else if (reader.dbFile) fs.nBackfill
    else reader.mark - fs.walBase
  val readerBtree: str -> int =
    if (not(readerHeld) or reader.dbFile) fs.dbMem
    else applyFrames(fs.dbMem, fs.wal.slice(0, reader.mark - fs.walBase))
  val readerReads: str -> int =
    Keys.mapBy(k => readAt(store.get(k), readerBtree.get(k), reader.snapshot.ts))

  def openOutcome(f: bool, ro: bool): Rebuild =
    rebuild(f, ro, Fix9770, RecoveryOneTs, false, Keys, fs.wal, lg.hdisk, lg.disk,
            fs.dbDisk, fs.metaDisk)

  // The files hold every committed row: a rebuild that ignores refusals
  // gives the committed rows.
  val dataIntact: bool =
    rebuildReads(rebuild(true, false, true, false, true, Keys, fs.wal, lg.hdisk, lg.disk,
                         fs.dbDisk, fs.metaDisk), Keys) == truth

  // Commits wait for the blocking lock while a blocking checkpoint runs.
  val commitsBlocked: bool = ck.pc != "idle" and ck.kind == "blocking"

  // ------------------------------------------------------------------- init

  action Init = all {
    mode' = "run",
    flag' = InitFlag,
    clock' = 0,
    truth' = Keys.mapBy(k => 0),
    store' = Keys.mapBy(k => Set()),
    durable' = 0,
    lg' = { file: List(), hfile: "None", disk: List(), hdisk: "None", off0: true,
            crcReset: false, maxApp: 0, truncPend: false, appSince: false,
            hdrFlight: false },
    fs' = { wal: List(), walDisk: 0, walBase: 1, nBackfill: 0, dbMem: Keys.mapBy(k => 0),
            dbDisk: Keys.mapBy(k => 0), metaMem: 0, metaDisk: 0 },
    cm' = { on: false, rec: { ts: 0, k: "", v: 0, prev: false, ok: true }, hdr: false,
            stage: "" },
    ck' = ckIdle,
    reader' = readerIdle,
    op' = noOpen,
    cnt' = { ck: 0, crash: 0, fail: 0 },
    leakSnap' = -1,
    replayTop' = 0,
    seen' = Set(),
    hist' = Map(0 -> Keys.mapBy(k => 0)),
    floor' = 0,
  }

  // ---------------------------------------------------------------- reader

  action SetReader(state: Reader): bool = all {
    reader' = state,
    mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
    durable' = durable, lg' = lg, fs' = fs, cm' = cm, ck' = ck, op' = op, cnt' = cnt,
    leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen, hist' = hist, floor' = floor,
  }

  action ReaderPin = all {
    mode == "run",
    not(readerHeld),
    not(commitsBlocked),
    SetReader({ ...readerIdle, phase: "pinned", mark: walEnd, dbFile: backfillFloor == walEnd }),
  }

  action ReaderBegin = all {
    mode == "run",
    reader.phase == "pinned",
    not(cm.on),
    SetReader({ ...reader, phase: "active", snapshot: { ts: clock, rows: truth } }),
  }

  action ReaderEnd = all {
    mode == "run",
    readerHeld,
    SetReader(readerIdle),
  }

  // ---------------------------------------------------------------- commits

  // Submits the append. The header goes with it when the writer offset is 0
  // (logical_log.rs:717). After a truncate error the frame chains from a
  // new salt that the header on disk does not have.
  action CommitWrite(k: str, del: bool): bool = all {
    mode == "run",
    not(cm.on),
    not(commitsBlocked),
    clock < MaxTs,
    not(del) or truth.get(k) != 0,
    val ts = clock + 1
    val r = { ts: ts, k: k, v: if (del) 0 else ts, prev: truth.get(k) != 0,
              ok: lg.off0 or not(lg.crcReset) }
    all {
      clock' = ts,
      lg' = { ...lg,
              file: if (lg.off0) List(r) else lg.file.append(r),
              hfile: if (lg.off0) "Valid" else lg.hfile,
              off0: false,
              crcReset: if (lg.off0) false else lg.crcReset,
              maxApp: if (ts > lg.maxApp) ts else lg.maxApp,
              appSince: lg.appSince or lg.truncPend },
      cm' = { on: true, rec: r, hdr: lg.off0, stage: "submitted" },
      hist' = if (normal) hist.put(ts, truth.set(k, r.v)) else hist,
      floor' = floor,
      reader' = reader,
      mode' = mode, flag' = flag, truth' = truth, store' = store, durable' = durable,
      fs' = fs, ck' = ck, op' = op, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop, seen' = seen,
    }
  }

  action CommitAppendDone = all {
    mode == "run",
    cm.on and cm.stage == "submitted",
    all {
      hist' = hist, floor' = floor,
      cm' = { ...cm, stage: "appended" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, fs' = fs, ck' = ck, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  // The commit's own log fsync (core/mvcc/database/mod.rs:3542).
  action CommitFsync = all {
    mode == "run",
    cm.on and cm.stage == "appended",
    all {
      hist' = hist, floor' = floor,
      // Under NORMAL the commit skips the log fsync (mod.rs:3539-3546).
      lg' = if (normal) lg else { ...lg, disk: lg.file, hdisk: lg.hfile },
      cm' = { ...cm, stage: "synced" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, ck' = ck, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  // The commit is acknowledged and its versions enter the store
  // (core/mvcc/database/mod.rs:3629).
  action CommitPublish = all {
    mode == "run",
    cm.on and cm.stage == "synced",
    val r = cm.rec
    all {
      hist' = hist, floor' = floor,
      store' = store.set(r.k, applyRec(store.get(r.k), r, r.ts)),
      truth' = truth.set(r.k, r.v),
      cm' = { ...cm, on: false, stage: "" },
      leakSnap' = -1,
      seen' = if (ck.pc == "publish" and ck.nonempty) seen.union(Set("CommitInPublishWindow"))
              else seen,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, durable' = durable, lg' = lg, fs' = fs,
      ck' = ck, op' = op, cnt' = cnt, replayTop' = replayTop,
    }
  }

  // ------------------------------------------------------------- checkpoint

  // Takes the snapshot and collects every key that changed after the
  // durable boundary. The blocking kind holds the lock from here, so no
  // commit is in flight.
  action CkBegin(kind: str): bool = all {
    mode == "run",
    ck.pc == "idle",
    cnt.ck < MaxCheckpoints,
    CheckpointKinds.contains(kind),
    if (flag) kind != "blocking" else kind == "blocking",
    kind != "blocking" or (not(cm.on) and not(readerHeld)),
    val snap = lastAcked
    val changed = Keys.filter(k => store.get(k).exists(x =>
      (x.b > durable and x.b <= snap) or (x.e > durable and x.e <= snap)))
    val wset = Keys.mapBy(k =>
      if (changed.contains(k)) readAt(store.get(k), btree.get(k), snap) else NotWritten)
    all {
      hist' = hist, floor' = floor,
      ck' = { pc: "commit", kind: kind, snap: snap, wset: wset, clears: false,
              nonempty: changed != Set(), copiedThrough: 0 },
      cnt' = { ...cnt, ck: cnt.ck + 1 },
      leakSnap' = -1,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, fs' = fs, cm' = cm, op' = op, replayTop' = replayTop,
      seen' = seen,
    }
  }

  // Pager commit: one WAL frame with the rows and the meta row, fsynced
  // (checkpoint_state_machine.rs:3284). With an empty write set the code
  // skips the pager commit and the publish (line 2643).
  action CkCommit = all {
    mode == "run",
    ck.pc == "commit",
    all {
      // The pager commit fsyncs the WAL only under FULL (pager.rs:4776).
      fs' = if (ck.nonempty)
              { ...fs, wal: fs.wal.append({ w: ck.wset, meta: ck.snap }),
                walDisk: if (not(normal) or FixCkCommitSyncsWal) fs.wal.length() + 1
                         else fs.walDisk }
            else fs,
      ck' = { ...ck, pc: if (ck.nonempty) "publish" else "backfill" },
      hist' = hist,
      floor' = if (normal and ck.nonempty and FixCkCommitSyncsWal) maxI(floor, ck.snap) else floor,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  // The publish window advances durable_txid_max
  // (checkpoint_state_machine.rs:2188). It is a separate step for a crash,
  // an error or an abandoned checkpoint after the pager commit, and other
  // connections can commit while the pager commit I/O completes. The passive
  // publish retry on a busy publish flag (line 3299) cannot fire today: only
  // one flag-on checkpoint runs (line 2488), and only it sets the flag
  // (mod.rs:7957).
  action CkPublish = all {
    mode == "run",
    ck.pc == "publish",
    all {
      hist' = hist, floor' = floor,
      durable' = ck.snap,
      ck' = { ...ck, pc: "backfill" },
      seen' = if (replayTop > durable and ck.snap >= replayTop)
                seen.union(Set("CkOfReplayedRows")) else seen,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      lg' = lg, fs' = fs, cm' = cm, op' = op, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop,
    }
  }

  // SyncWal flushes the file, even if a pinned read mark caps the copy.
  action CkBackfillTo(upTo: int): bool = all {
    mode == "run",
    ck.pc == "backfill",
    fs.nBackfill <= upTo and upTo <= readerCopyLimit,
    val copied = upTo > fs.nBackfill
    val frames = fs.wal.slice(fs.nBackfill, upTo)
    all {
      fs' = if (copied)
              { ...fs, walDisk: fs.wal.length(), dbMem: applyFrames(fs.dbMem, frames),
                metaMem: lastMeta(fs.metaMem, frames) }
            else fs,
      ck' = { ...ck, pc: if (copied) "syncdb" else "trunclog", copiedThrough: upTo },
      hist' = hist,
      floor' = if (normal and copied) maxI(floor, lastMeta(fs.metaMem, fs.wal)) else floor,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  action CkBackfill = CkBackfillTo(readerCopyLimit)

  action CkBackfillPartial(upTo: int): bool = all {
    ck.kind == "passive",
    fs.nBackfill < upTo and upTo < fs.wal.length(),
    CkBackfillTo(upTo),
  }

  // A passive backfill that copies no frame: a reader pins the WAL at
  // nbackfills, or the backfill gets Busy under a DbFile reader. No file
  // changes. The checkpoint skips the DB fsync and goes on to the log
  // truncate (core/mvcc/database/checkpoint.rs:3322 and 3344-3347, also the WAL
  // fsync of wal.rs:5093 does not run: nothing to copy). BackfillSkipped
  // means that WAL frames existed. BackfillSkippedUnsynced means that some
  // of them were not durable.
  action CkBackfillNone = all {
    PassiveBackfillSkips,
    mode == "run",
    ck.pc == "backfill",
    ck.kind == "passive",
    all {
      ck' = { ...ck, pc: "trunclog" },
      seen' = seen
        .union(if (fs.wal.length() > 0) Set("BackfillSkipped") else Set())
        .union(if (fs.walDisk < fs.wal.length()) Set("BackfillSkippedUnsynced") else Set()),
      hist' = hist, floor' = floor,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, fs' = fs, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop,
    }
  }

  action CkSyncDb = all {
    mode == "run",
    ck.pc == "syncdb",
    all {
      hist' = hist, floor' = floor,
      fs' = { ...fs, dbDisk: fs.dbMem, metaDisk: fs.metaMem, nBackfill: ck.copiedThrough },
      ck' = { ...ck, pc: "trunclog" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  // Under the log write lock (core/mvcc/persistent_storage/mod.rs:230): the
  // decision, the truncate submit, and the writer reset of the offset and
  // max_appended_commit_ts (logical_log.rs:1058-1095). The blocking kind
  // clears the whole log. The flag-on kinds keep it if one frame is above
  // the snapshot.
  action CkTruncLog = all {
    mode == "run",
    ck.pc == "trunclog",
    val clears = ck.kind == "blocking" or lg.maxApp <= ck.snap
    all {
      hist' = hist, floor' = floor,
      lg' = if (not(clears)) lg
            else if (AsyncLogTruncate)
              { ...lg, off0: true, crcReset: false, maxApp: 0, truncPend: true, appSince: false }
            else { ...lg, file: List(), hfile: "None", off0: true, crcReset: false, maxApp: 0 },
      ck' = { ...ck, clears: clears,
              pc: if (clears and AsyncLogTruncate) "truncwait" else "truncwal" },
      seen' = if (clears) seen else seen.union(Set("LogRetained")),
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop,
    }
  }

  // An async truncate completes. If a newer append was submitted after the
  // truncate, the backend can run them in either order: eraseNew means that
  // the truncate ran last and erased the newer frame.
  action CkTruncDone(eraseNew: bool): bool = all {
    mode == "run",
    ck.pc == "truncwait",
    eraseNew implies lg.appSince,
    all {
      hist' = hist, floor' = floor,
      lg' = { ...lg, truncPend: false, appSince: false,
              file: if (lg.appSince and not(eraseNew)) lg.file else List(),
              hfile: if (lg.appSince and not(eraseNew)) lg.hfile else "None" },
      ck' = { ...ck, pc: "truncwal" },
      seen' = if (eraseNew) seen.union(Set("AppendErased")) else seen,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop,
    }
  }

  // The WAL truncate and its fsync, merged. The passive kind keeps the WAL.
  action CkTruncWal = all {
    mode == "run",
    ck.pc == "truncwal",
    all {
      fs' = if (ck.kind == "passive") fs
            else { ...fs, wal: List(), walDisk: 0, walBase: walEnd + 1, nBackfill: 0 },
      ck' = { ...ck, pc: "gc" },
      hist' = hist, floor' = floor,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, op' = op, cnt' = cnt,
      leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    }
  }

  // GcTableRows stamps the chains of the write set, then Finalize runs GC on
  // every chain. The model merges the GC batches into one step.
  action CkGc = all {
    mode == "run",
    ck.pc == "gc",
    val stampAll = FixBlockingStoreEmpty and ck.kind != "passive"
    val stamped = Keys.mapBy(k =>
      if (stampAll or ck.wset.get(k) != NotWritten) stamp(store.get(k), ck.snap, walEnd)
      else if (FixStampBelowBoundary) stamp(store.get(k), durable, walEnd)
      else store.get(k))
    // A chain outside the write set that only a fix stamped.
    val fixUsed = Keys.exists(k => ck.wset.get(k) == NotWritten
                                   and stamped.get(k) != store.get(k))
    val after = Keys.mapBy(k => gcChain(stamped.get(k), durable, flag, readerGcFloor, readerLwm))
    all {
      store' = after,
      ck' = ckIdle,
      leakSnap' = ck.snap,
      hist' = hist, floor' = floor,
      seen' = seen
        .union(if (fixUsed) Set("StampFixUsed") else Set())
        .union(if (ck.kind == "truncflag" and ck.nonempty) Set("TruncFlagDone") else Set()),
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, durable' = durable,
      lg' = lg, fs' = fs, cm' = cm, op' = op, cnt' = cnt, replayTop' = replayTop,
    }
  }

  // An error, Busy, or an abandoned checkpoint at one step. Cleanup
  // (checkpoint_state_machine.rs:1039) releases the locks and rolls back a
  // pager commit that did not finish. A committed WAL frame stays, and
  // after the publish durable_txid_max keeps its new value. A log truncate
  // error comes from the submit call (core/io/unix.rs:510): the writer
  // already restarted its running CRC from a new salt, but keeps its offset
  // and max_appended_commit_ts (logical_log.rs:1061-1075).
  action CkFail = all {
    mode == "run",
    cnt.fail < MaxFails,
    Set("commit", "publish", "backfill", "syncdb", "truncwait", "truncwal")
      .contains(ck.pc) or (ck.pc == "trunclog" and LogTruncateErrors),
    val truncErr = ck.pc == "trunclog" and (ck.kind == "blocking" or lg.maxApp <= ck.snap)
    val afterPublish = Set("backfill", "syncdb", "trunclog", "truncwait", "truncwal")
      .contains(ck.pc) and ck.nonempty
    all {
      hist' = hist, floor' = floor,
      lg' = if (truncErr) { ...lg, crcReset: true }
            else if (ck.pc == "truncwait") { ...lg, truncPend: false, appSince: false }
            else lg,
      ck' = ckIdle,
      cnt' = { ...cnt, fail: cnt.fail + 1 },
      seen' = seen
        .union(if (ck.pc == "publish" and ck.nonempty) Set("FailBeforePublish") else Set())
        .union(if (afterPublish and ck.kind == "blocking") Set("FailAfterPublishBlocking")
               else Set())
        .union(if (afterPublish and ck.kind != "blocking") Set("FailAfterPublishFlagOn")
               else Set())
        .union(if (truncErr) Set("TruncateError") else Set()),
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, cm' = cm, op' = op, leakSnap' = leakSnap,
      replayTop' = replayTop,
    }
  }

  // ------------------------------------------------------------ crash, open

  // logPick: "disk" keeps the fsynced log, "mem" keeps every write, "torn"
  // tears the unsynced write. dbMemKept: the DB file keeps the page cache,
  // or only the fsynced pages.
  // walMemKept selects the live WAL image over the last synced image.
  action Crash(logPick: str, dbMemKept: bool, walMemKept: bool): bool = all {
    mode == "run" or mode == "open",
    cnt.crash < MaxCrashes,
    val cleanClose = mode == "run" and not(cm.on) and ck.pc == "idle" and not(readerHeld)
    val walTruncatePending = op.pc == "syncwal"
    val writeOpen = cm.on and not(hasFrame(lg.disk, cm.rec))
    val tornHdr = logPick == "torn" and ((writeOpen and cm.hdr) or lg.hdrFlight)
    val frames = if (logPick == "mem") lg.file
                 else if (logPick == "torn")
                   (if (writeOpen) lg.file.select(r => r != cm.rec) else lg.file)
                 else lg.disk
    val hd = if (logPick == "mem") lg.hfile
             else if (tornHdr) (if (TornHeaderGarbage) "Invalid" else "None")
             else if (logPick == "torn") lg.hfile
             else lg.hdisk
    // The write in flight committed if replay can read its frame.
    val kept = cm.on and hd == "Valid" and hasFrame(validPrefix(frames), cm.rec)
    val dbm = if (dbMemKept) fs.dbMem else fs.dbDisk
    val meta = if (dbMemKept) fs.metaMem else fs.metaDisk
    val wal2 = if (not(walMemKept)) fs.wal.slice(0, fs.walDisk)
               else if (walTruncatePending) List()
               else fs.wal
    val lostAcked = lg.file.select(r => r.ts <= lastAcked and not(hasFrame(lg.disk, r))).length() > 0
    val tornFirstAppend = tornHdr and writeOpen and cm.hdr and fs.wal.length() > 0
    val tags = Set()
      .union(if (ck.kind == "blocking" and ck.nonempty and fs.wal.length() > 0
                 and Set("truncwait", "truncwal").contains(ck.pc) and hd == "None")
               Set("CrashBlockingTruncWal") else Set())
      .union(if (cleanClose) Set("CleanClose") else Set())
      .union(if (fs.wal.length() > 0 and hd == "None") Set("WalFramesNoLog") else Set())
      .union(if (normal and logPick == "disk"
                 and (lostAcked or (not(walTruncatePending) and wal2.length() < fs.wal.length())))
               Set("LostUnsynced") else Set())
      .union(if (mode == "open" and Set("fsynclog", "truncwal", "syncwal", "replay").contains(op.pc))
               Set("CrashInRecovery") else Set())
    all {
      not(CrashOnlyWhenIdle) or cleanClose,
      hist' = hist, floor' = floor,
      walMemKept implies (fs.walDisk < fs.wal.length() or walTruncatePending),
      logPick != "torn" or writeOpen or lg.hdrFlight,
      reader' = readerIdle,
      mode' = "down",
      truth' = if (kept) truth.set(cm.rec.k, cm.rec.v) else truth,
      lg' = { file: frames, hfile: hd, disk: frames, hdisk: hd, off0: true, crcReset: false,
              maxApp: 0, truncPend: false, appSince: false, hdrFlight: false },
      fs' = { ...fs, wal: wal2, walDisk: wal2.length(), walBase: 1, nBackfill: 0, dbMem: dbm, dbDisk: dbm,
              metaMem: meta, metaDisk: meta },
      cm' = { ...cm, on: false, stage: "" },
      store' = Keys.mapBy(k => Set()),
      ck' = ckIdle,
      op' = { ...noOpen, crash: if (tornFirstAppend) "tornFirstAppend" else "other",
              expected: op.expected },
      cnt' = { ...cnt, crash: cnt.crash + 1 },
      leakSnap' = -1,
      seen' = seen.union(tags),
      flag' = flag, clock' = clock, durable' = durable, replayTop' = replayTop,
    }
  }

  // The end of recovery: the state of the running process.
  action GoRun(f: bool, rb: Rebuild): bool = all {
    reader' = reader,
    mode' = "run",
    flag' = f,
    clock' = rb.clock,
    store' = rb.chains,
    durable' = rb.meta,
    // The writer offset is 0 only with no valid header. The open does not
    // restore max_appended_commit_ts.
    lg' = { ...lg, hfile: rb.hdr, hdisk: rb.hdr, off0: rb.hdr != "Valid", maxApp: 0,
            crcReset: false, truncPend: false, appSince: false, hdrFlight: false },
    fs' = { wal: List(), walDisk: 0, walBase: 1, nBackfill: 0, dbMem: rb.db, dbDisk: rb.db,
            metaMem: rb.meta, metaDisk: rb.meta },
    op' = noOpen,
    replayTop' = rb.replayMax,
    leakSnap' = -1,
    // Under NORMAL the open can give fewer commits than the process
    // acknowledged. What it gives is the committed state from now on.
    truth' = if (normal) rebuildReads(rb, Keys) else truth,
    hist' = if (normal) Map(rb.clock -> rebuildReads(rb, Keys)) else hist,
    floor' = if (normal) rb.clock else floor,
    cm' = cm, ck' = ck, cnt' = cnt,
  }

  // The startup decision of a read-write open with passive flag f
  // (maybe_complete_interrupted_checkpoint_nonblock, mod.rs:9179). A
  // read-only open does not continue, so the invariants check it on the down
  // state. With no WAL frames, replay follows at once.
  action OpenStart(f: bool): bool = all {
    mode == "down",
    OpenFlags.contains(f),
    OpenReadOnly.contains(false),
    val rb = openOutcome(f, false)
    val walHas = fs.wal.length() > 0
    val expected = if (normal and op.expected.ts < 0)
                     { ts: rb.clock, rows: rebuildReads(rb, Keys) }
                   else op.expected
    val tags = Set(if (f) "OpenFlagOn" else "OpenFlagOff")
      .union(if (lg.disk.select(r => r.ts > rb.meta).length() > 1) Set("ReplayMany") else Set())
    all {
      rb.ok,
      if (walHas) all {
        hist' = hist, floor' = floor,
        reader' = reader,
        mode' = "open",
        op' = { ...op, pc: "backfill", f: f, walHad: walHas, hdrWas: lg.hdisk,
                expected: expected },
        seen' = seen.union(tags),
        flag' = flag, clock' = clock, truth' = truth, store' = store, durable' = durable,
        lg' = lg, fs' = fs, cm' = cm, ck' = ck, cnt' = cnt, leakSnap' = leakSnap,
        replayTop' = replayTop,
      } else all {
        GoRun(f, rb),
        seen' = seen.union(tags),
      },
    }
  }

  // Recovery copies the WAL into the DB file (mod.rs:9278).
  action OpenBackfill = all {
    mode == "open",
    op.pc == "backfill",
    all {
      hist' = hist, floor' = floor,
      fs' = { ...fs, dbMem: applyFrames(fs.dbMem, fs.wal), metaMem: lastMeta(fs.metaMem, fs.wal) },
      op' = { ...op, pc: "syncdb" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, ck' = ck, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop, seen' = seen,
    }
  }

  // DB fsync (mod.rs:9295).
  action OpenSyncDb = all {
    mode == "open",
    op.pc == "syncdb",
    all {
      fs' = { ...fs, dbDisk: fs.dbMem, metaDisk: fs.metaMem },
      op' = { ...op, pc: "header" },
      hist' = hist, floor' = floor,
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, lg' = lg, cm' = cm, ck' = ck, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop, seen' = seen,
    }
  }

  // Header write (mod.rs:9341). A missing header becomes a fresh one with
  // no frames, and a crash can tear that write. A valid header is written
  // again with the same bytes (mod.rs:9228, logical_log.rs:988), so a crash
  // cannot change it.
  action OpenHeader = all {
    mode == "open",
    op.pc == "header",
    all {
      hist' = hist, floor' = floor,
      lg' = { ...lg, hfile: "Valid", file: if (lg.hfile == "Valid") lg.file else List(),
              hdrFlight: lg.hfile != "Valid" },
      op' = { ...op, pc: "fsynclog" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, cm' = cm, ck' = ck, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop, seen' = seen,
    }
  }

  // Log fsync (mod.rs:9372).
  action OpenFsyncLog = all {
    mode == "open",
    op.pc == "fsynclog",
    all {
      hist' = hist, floor' = floor,
      lg' = { ...lg, disk: lg.file, hdisk: lg.hfile, hdrFlight: false },
      op' = { ...op, pc: "truncwal" },
      reader' = reader,
      mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
      durable' = durable, fs' = fs, cm' = cm, ck' = ck, cnt' = cnt, leakSnap' = leakSnap,
      replayTop' = replayTop, seen' = seen,
    }
  }

  // Until WAL fsync, fs.wal holds the frames a power loss can bring back.
  action OpenTruncWal = all {
    mode == "open",
    op.pc == "truncwal",
    op' = { ...op, pc: "syncwal" },
    reader' = reader,
    mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
    durable' = durable, lg' = lg, fs' = fs, cm' = cm, ck' = ck, cnt' = cnt,
    leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    hist' = hist, floor' = floor,
  }

  action OpenSyncWal = all {
    mode == "open",
    op.pc == "syncwal",
    fs' = { ...fs, wal: List(), walDisk: 0 },
    op' = { ...op, pc: "replay" },
    reader' = reader,
    mode' = mode, flag' = flag, clock' = clock, truth' = truth, store' = store,
    durable' = durable, lg' = lg, cm' = cm, ck' = ck, cnt' = cnt,
    leakSnap' = leakSnap, replayTop' = replayTop, seen' = seen,
    hist' = hist, floor' = floor,
  }

  action OpenFinish = all {
    mode == "open",
    op.pc == "replay",
    val rb = openOutcome(op.f, false)
    // A repair: the open started on WAL frames with no log header, and it
    // ends with the WAL removed and the committed rows.
    val repaired = op.walHad and op.hdrWas == "None" and rebuildReads(rb, Keys) == truth
    all {
      GoRun(op.f, rb),
      seen' = seen
        .union(if (repaired) Set("OpenNoLogOk") else Set())
        .union(if (repaired and not(op.f)) Set("OpenNoLogFlagOffOk") else Set())
        .union(if (repaired and op.crash == "tornFirstAppend") Set("OpenAfterTornFirstAppendOk")
               else Set()),
    }
  }

  action NextShared = any {
    nondet k = Keys.oneOf()
    nondet del = Bool.oneOf()
    CommitWrite(k, del),
    CommitAppendDone,
    CommitFsync,
    CommitPublish,
    nondet kind = Set("blocking", "passive", "truncflag").oneOf()
    CkBegin(kind),
    CkCommit,
    CkPublish,
    CkBackfill,
    CkSyncDb,
    CkTruncLog,
    nondet eraseNew = Bool.oneOf()
    CkTruncDone(eraseNew),
    CkTruncWal,
    CkFail,
    nondet logPick = Set("disk", "mem", "torn").oneOf()
    nondet dbMemKept = Bool.oneOf()
    nondet walMemKept = Bool.oneOf()
    Crash(logPick, dbMemKept, walMemKept),
    nondet f = Bool.oneOf()
    OpenStart(f),
    OpenBackfill,
    OpenSyncDb,
    OpenHeader,
    OpenFsyncLog,
    OpenTruncWal,
    OpenSyncWal,
    OpenFinish,
  }

  action Next = any {
    NextShared,
    CkBackfillNone,
    CkGc,
  }

  action NextWithPartialBackfill = any {
    Next,
    nondet upTo = fs.nBackfill.to(fs.wal.length()).oneOf()
    CkBackfillPartial(upTo),
  }

  action NextWithReader = any {
    NextShared,
    ReaderPin,
    ReaderBegin,
    ReaderEnd,
    all { not(cm.on), CkGc },
  }

  // -------------------------------------------------------------- invariants

  val TypeOK: bool = Set("run", "open", "down").contains(mode) and clock <= MaxTs
    and 0 <= fs.nBackfill and fs.nBackfill <= fs.walDisk and fs.walDisk <= fs.wal.length()

  val ReaderSnapshotCorrect: bool =
    if (readerActive) reader.snapshot.ts >= 0 and reader.snapshot.ts <= lastAcked
                      and readerReads == reader.snapshot.rows
    else reader.snapshot == readerIdle.snapshot

  val ReaderPinCorrect: bool = readerHeld implies all {
    backfillFloor <= reader.mark and reader.mark <= walEnd,
    reader.dbFile implies backfillFloor == reader.mark,
    ck.pc == "syncdb" implies fs.walBase + ck.copiedThrough <= reader.mark,
  }

  val ReaderLifecycleCorrect: bool = all {
    Set("idle", "pinned", "active").contains(reader.phase),
    (mode != "run" or not(readerHeld)) implies reader == readerIdle,
    readerHeld implies not(commitsBlocked),
  }

  // Every open the user can pick that succeeds gives the committed rows.
  // While the system runs, reads give the committed rows.
  val RecoveryCorrect: bool =
    if (mode == "run") reads == truth
    else if (mode == "open") true
    else OpenFlags.forall(f => OpenReadOnly.forall(ro =>
      val rb = openOutcome(f, ro)
      rb.ok implies rebuildReads(rb, Keys) == truth))

  // While the system runs, reads give the committed rows. Fine under NORMAL.
  val RunCorrect: bool = mode == "run" implies reads == truth

  // The MVCC chain supplies any changes that the database file lacks.
  val DbFileReadsCorrect: bool =
    mode == "run" implies Keys.forall(k => readAt(store.get(k), fs.dbDisk.get(k), clock) == truth.get(k))

  // Under NORMAL a crash can lose acknowledged commits. An open that
  // succeeds still gives the rows of one commit point t, with floor <= t <=
  // clock. floor is the newest point that a WAL sync or a recovery made
  // durable. t = clock can be the commit in flight.
  val NormalPrefix: bool =
    if (mode != "down") true
    else OpenFlags.forall(f => OpenReadOnly.forall(ro =>
      val rb = openOutcome(f, ro)
      rb.ok implies
        hist.keys().exists(t => t >= floor and t <= clock
                                and hist.get(t) == rebuildReads(rb, Keys))))

  def matchesRecoveryPoint(rb: Rebuild): bool =
    rb.clock == op.expected.ts and rebuildReads(rb, Keys) == op.expected.rows

  val NormalRecoveryStable: bool =
    if (op.expected.ts < 0) true
    else if (mode == "open") {
      val rb = openOutcome(op.f, false)
      rb.ok and matchesRecoveryPoint(rb)
    } else OpenFlags.forall(f => OpenReadOnly.forall(ro =>
      val rb = openOutcome(f, ro)
      rb.ok implies matchesRecoveryPoint(rb)))

  // Refusals that RECOVERY_SEMANTICS.md states as intended.
  pure val StatedRefusals = Set("case3", "case5")

  val OpenSucceeds: bool =
    (mode == "down" and dataIntact) implies
      OpenFlags.forall(f => OpenReadOnly.forall(ro =>
        val rb = openOutcome(f, ro)
        rb.ok or StatedRefusals.contains(rb.why)))

  // OpenSucceedsStrict for files with WAL frames.
  val OpenSucceedsWithWal: bool =
    (mode == "down" and dataIntact and fs.wal.length() > 0) implies
      OpenFlags.forall(f => OpenReadOnly.forall(ro => openOutcome(f, ro).ok))

  val OpenSucceedsStrict: bool =
    (mode == "down" and dataIntact) implies
      OpenFlags.forall(f => OpenReadOnly.forall(ro => openOutcome(f, ro).ok))

  // After a checkpoint succeeds, no chain is left whose every version has its
  // last event at or below the snapshot: the B-tree holds that row, and GC
  // runs with no open snapshot. After a blocking checkpoint, this means that
  // the version store is empty.
  val NoLeak: bool =
    leakSnap >= 0 implies Keys.forall(k =>
      not(store.get(k) != Set() and store.get(k).forall(x => terminal(x) <= leakSnap)))

  // Reachability checks. Each must fail in a reach* configuration.

  // A blocking checkpoint committed rows to the WAL and truncated the log,
  // then a crash before the WAL truncate.
  val NeverCrashBetweenLogAndWalTruncate: bool = not(seen.contains("CrashBlockingTruncWal"))
  // A crash leaves WAL frames and no log header.
  val NeverWalFramesNoLog: bool = not(seen.contains("WalFramesNoLog"))
  // The files have WAL frames and a log header that does not decode.
  val NeverInvalidHeaderWithWal: bool =
    not(mode == "down" and fs.wal.length() > 0 and lg.hdisk == "Invalid")
  // A clean close leaves WAL frames.
  val NeverCleanCloseWithWal: bool =
    not(mode == "down" and seen.contains("CleanClose") and fs.wal.length() > 0)
  // A checkpoint with rows fails after its publish.
  val NeverFailAfterPublishBlocking: bool = not(seen.contains("FailAfterPublishBlocking"))
  val NeverFailAfterPublishFlagOn: bool = not(seen.contains("FailAfterPublishFlagOn"))
  // A checkpoint with rows fails after its pager commit and before its
  // publish: the WAL holds the frame and the boundary did not move.
  val NeverFailBeforePublish: bool = not(seen.contains("FailBeforePublish"))
  // A commit is acknowledged while a checkpoint with rows waits to publish.
  val NeverCommitInPublishWindow: bool = not(seen.contains("CommitInPublishWindow"))
  // A fix stamps a chain outside the write set (the repair runs).
  val NeverStampFixUsed: bool = not(seen.contains("StampFixUsed"))
  // An open that started on WAL frames and no log header finishes recovery
  // with the WAL removed and the committed rows (with the flag off).
  val NeverOpenNoLogOk: bool = not(seen.contains("OpenNoLogOk"))
  val NeverOpenNoLogFlagOffOk: bool = not(seen.contains("OpenNoLogFlagOffOk"))
  // The same after a crash that tore the header of a first append while the
  // WAL had frames.
  val NeverOpenAfterTornFirstAppendOk: bool = not(seen.contains("OpenAfterTornFirstAppendOk"))
  // One open replays two frames.
  val NeverReplayMany: bool = not(seen.contains("ReplayMany"))
  // A checkpoint after an open writes the replayed rows.
  val NeverCkOfReplayedRows: bool = not(seen.contains("CkOfReplayedRows"))
  // A passive backfill copies no frame while WAL frames exist.
  val NeverBackfillSkipped: bool = not(seen.contains("BackfillSkipped"))
  // The same while some WAL frame is not durable.
  val NeverBackfillSkippedUnsynced: bool = not(seen.contains("BackfillSkippedUnsynced"))
  // Under NORMAL a crash that keeps only fsynced data drops an acknowledged
  // log frame or an unsynced WAL frame.
  val NeverLostUnsynced: bool = not(seen.contains("LostUnsynced"))
  val NeverLogRetained: bool = not(seen.contains("LogRetained"))
  // A flag-on TRUNCATE checkpoint with rows finishes.
  val NeverTruncFlagDone: bool = not(seen.contains("TruncFlagDone"))
  // A crash after the recovery header write and before the WAL truncate.
  val NeverCrashInRecovery: bool = not(seen.contains("CrashInRecovery"))
  // An async truncate erases a newer append.
  val NeverAppendErased: bool = not(seen.contains("AppendErased"))
  // A log truncate fails after the writer restarted its CRC.
  val NeverTruncateError: bool = not(seen.contains("TruncateError"))
}
