// -*- mode: Bluespec; -*-
/**
 * Turso MVCC passive checkpoint: schema changes, table ids, root pages and
 * recovery.
 *
 * This specification models how a passive checkpoint creates and destroys
 * the B-trees of tables while DDL commits, row writes and readers run at the
 * same time, and how recovery rebuilds the tables after a crash. See
 * DESIGN-schema.md next to this file for the design in prose and for the
 * mapping to the Rust code in core/mvcc/database/checkpoint_state_machine.rs,
 * core/mvcc/database/mod.rs and core/mvcc/cursor.rs.
 *
 * Identities are the ones of the code.
 *   A CREATE gives the table a negative temporary table id from
 *   get_next_table_id. The sqlite_schema row stores that id as rootpage.
 *   A checkpoint gives the table a positive root page from the free pages,
 *   so pages are reused. A logical log record of a row carries -root when
 *   the table has a root page, else the temporary id (canonical_log_id).
 *   Recovery maps root page P to table id -P (bootstrap), then replays the
 *   log records above the boundary.
 *
 * Each table has at most one row, inserted by its own commit after CREATE.
 * The row value is the commit timestamp of the insert.
 *
 * Actors.
 *   DDL      one exclusive schema change at a time: Exec (copy the shared
 *            schema and change the copy), Prepare (take a commit timestamp),
 *            Finish (publish the header cookie and the shared schema).
 *   Writers  insert the row of a table in one atomic commit.
 *   Readers  compile a statement against the shared schema, pin a WAL read
 *            mark, begin, open a cursor (root page -> table id), read, end.
 *   The checkpoint runs one pass at a time: snapshot, process each table,
 *            commit one WAL frame, publish, backfill, stamp and GC bindings.
 *   GC       drops the row version once every reader can read the B-tree.
 *
 * A WAL frame holds the full image of every page and the B-tree catalog
 * (the sqlite_schema rows in the B-tree). A page is free, or is the whole
 * B-tree of one table.
 *
 * Constants named Guard* switch off one special case of the code each.
 * Constants named Fix* switch on a fix for an open issue. The main
 * configuration is the design: every guard and every fix on.
 *
 * Feature constants add parts that the main configuration leaves out to
 * keep it small. Their off value gives the model without the part.
 *   Indexes  objects that are indexes of the table IdxTable. CREATE INDEX
 *            runs while the table has no row, so every index row comes
 *            from a table insert. DROP TABLE runs after its indexes are
 *            dropped.
 *   Alters   ALTER TABLE ADD COLUMN: a second version of the sqlite_schema
 *            row with the same rowid and a new version id (#8077).
 *   CatalogReads  a reader scans sqlite_schema through the dual cursor,
 *            and GC drops the versions of sqlite_schema rows (#8093,
 *            #8094). Each object is one row of sqlite_schema. GC drops the
 *            whole chain of a row in one step. A scan is one atomic step.
 *            The catalog configurations keep Alters off.
 *   SyncObjectMap  each row commit records the object map of its logical
 *            log frame: the name that the map gives to the table id of the
 *            row record (populate_portable_changes, mod.rs:2781). A sync
 *            client keys a table by the absolute value of its rootpage
 *            column (read_logical_replay_table_map). The sync
 *            configurations have no ALTER and no indexes, and a row commit
 *            has one data record. They turn CatalogReads on, because the
 *            last lookup of the map reads the sqlite_schema versions that
 *            catalog GC drops.
 *
 *   Mode     "truncateFlagOn": each explicit pass is a TRUNCATE checkpoint
 *            with the passive flag on. Its publish runs in four steps that
 *            other actors can interleave (CheckpointPublishRoots).
 *   CheckpointOwnerReaders  a checkpoint can run on the connection of an
 *            open reader: an explicit one between statements, or the
 *            auto-checkpoint of a nextval inner commit (InnerCommitCheckpoint).
 *   GcSamplesFirst  a GC call samples lwm and the floor, then drops chains
 *            in later steps (GcSample, GcApply, GcApplyCatalog, GcEnd).
 *
 * Not modeled: row updates and deletes, more than one ALTER per table,
 * writes through a stale root page other than a read, readers without a WAL
 * mark, logical log truncation, aborts, VACUUM, multi-page B-trees, WAL
 * restart and the final blocking GC sweep of mode T, and a prepare inside
 * the passive publish window (begin_tx rechecks the generation there).
 *
 * Notes on the Quint code:
 *   - Objs and Readers are strings. The model checker sees every order of
 *     them.
 *   - Max, Min and "the first element of a set that matches" use fold.
 *   - Lists start at index 0. WAL frame numbers still start at 1: frame i
 *     is wal[i - 1] (see Frame).
 *   - Every action assigns every variable.
 *   - "val" is a keyword in Quint, so the field of a page and of a version
 *     is "value".
 *   - A record type has one set of fields. Each kind of err record uses
 *     only some of the fields of ErrRec, and the other fields hold "" or 0.
 *   - Each argument that a step picks comes from a named nondet.
 *     `quint run --mbt` then records the action and its picks in the
 *     trace. "to" is a built-in name in Quint, so the backfill pick is
 *     named upTo.
 */
module MvccPassiveSchema {
  const Objs: Set[str]          // Table names.
  const Pages: Set[int]         // Page numbers that can be a root page (integers > 1).
  const Readers: Set[str]       // Reader connections.
  const MaxTs: int              // Bound on the logical clock.
  const FixPublishFailedCommit: bool
  const FixStampAtPagerCommit: bool
  const FixCleanupPublishes: bool
  const CheckpointFailures: bool // A pass can stop before it finishes.
  const MaxCheckpoints: int     // Bound on the number of checkpoint passes.
  const Indexes: Set[str]       // Objects that are indexes of IdxTable. Set() = no indexes.
  const IdxTable: str           // The table that the indexes belong to.
  const Alters: bool            // true: ALTER TABLE ADD COLUMN is possible.
  const CatalogReads: bool      // true: readers scan sqlite_schema, and GC drops its versions.
  const Mode: str               // "passive", or "truncateFlagOn": every explicit pass is
                                // PRAGMA wal_checkpoint(TRUNCATE) with the passive flag on.
                                // The auto-checkpoint is passive in both (mod.rs:3700-3708).
  const CheckpointOwnerReaders: bool // a checkpoint can run on the connection of an open reader
  const GcSamplesFirst: bool    // GC samples lwm and the floor, then applies the rules per chain
  const SyncObjectMap: bool     // true: each row commit records its object map (portable changes).

  // Special cases of the code today. true in the main configuration.
  const GuardMatCheck: bool          // is_btree_readable_at: materialized_at <= read_mark
  const GuardCoversBegin: bool       // is_btree_readable_at: binding.begin <= begin_ts
  const GuardCoversEnd: bool         // is_btree_readable_at: begin_ts < binding.end
  const GuardRetireOnDestroy: bool   // BTreeDestroy retires the binding, not removes it
  const GuardBindingGcLwm: bool      // gc_rootpage_entries drops a binding only at end <= lwm
  const GuardAllocRetiresStale: bool // record_rootpage_alloc retires a stale live owner
  const GuardOpenFallback: bool      // MvccLazyCursor::new: unmapped root -> SchemaUpdated
  const GuardBusyOnUnpublished: bool // begin_tx: Busy while a DDL has an unpublished cookie
  const GuardGenerationGate: bool    // begin_tx: SchemaUpdated when schema_generation moved
  const GuardCookieCheck: bool       // Transaction opcode: header cookie = statement cookie
  const GuardPatchKeepsEnd: bool     // publish patches the schema row payload, keeps end (#7956)
  const GuardEndedCreated: bool      // publish adds ended created roots to dropped roots (#7956)
  const GuardFreedOnly: bool         // publish clears only freed roots from dropped roots (#7957)
  const GuardRefreshRoot: bool       // is_btree_allocated: a negative root takes the binding's page (#8537)
  const GuardCatalogGcFloor: bool    // GC of a sqlite_schema version: materialized_at <= floor
  const GuardCatalogGcLwm: bool      // GC of a sqlite_schema version: Rule 2 e <= lwm, Rule 3 idle
  const GuardFrozenMark: bool        // every statement of a transaction reads pages at the
                                     // WAL mark that its begin pinned
  const GuardGcRechecksIdleLwm: bool // gc_chain_now computes lwm again when the sample was MAX

  // Fixes for open issues. false is the code today.
  const FixDisjointIds: bool     // temporary ids never equal -P for a page P (#11501)
  const FixPersistIds: bool      // the B-tree keeps each table's temporary id, and
                                 // recovery maps it to the table too (#11502)
  const FixHeaderCookieMax: bool // the publish never lowers the header cookie (#11499)
  const FixInnerTxChecks: bool   // an inner transaction checks the schema like a begin (#11500)
  const FixDdlRebases: bool      // a DDL commit changes only its own table in the shared
                                 // schema instead of installing its copy (#8004)
  const FixAlterPatch: bool      // the publish patches every version of the schema row that
                                 // carries the temporary id, and only a DROP ends the root (#8077)
  const FixAlterRecovery: bool   // recovery maps the temporary id of a replayed schema row
                                 // update to the table's page (needs FixPersistIds)
  const FixRefuseCheckpointOwner: bool // a checkpoint refuses a connection with an open snapshot
  const FixPermanentLogId: bool  // a row record keeps the table's permanent id, and core writes
                                 // that id into the object map (SIMPLIFY.md step 3, needs
                                 // FixPersistIds)

  pure val Inf = 1000   // "no end timestamp", "no reader"
  pure val None = -1    // "no visible version"

  // The kinds of a DDL statement. TLC enumerates a set of strings in the
  // order in which the strings first appear in the spec, so this definition
  // comes first to fix that order.
  pure val DdlKinds: Set[str] = Set("create", "drop", "alter")

  pure val NoObj = "free"   // owner of a free page
  pure val Gone = -2        // oracle value: the table does not exist at this snapshot

  // The create and drop commit timestamps of the sqlite_schema row of an
  // object. 0 / Inf = none. With Alters: a = ALTER commit timestamp (0 =
  // none), r1 and r2 = rootpage column of version 1 [c, a) and version 2
  // [a, d).
  type Cat = { c: int, d: int, a: int, r1: int, r2: int }
  // mark: with CatalogReads, the WAL mark that the DDL transaction pinned at
  // its begin. The passive backfill stops at it. 0 otherwise.
  type Ddl = { pc: str, o: str, kind: str, ts: int, hdr: int, sch: str -> int, dr: Set[int],
               mark: int }
  type Version = { b: int, e: int, value: int, mat: int }
  type Ins = { ts: int, id: int }
  // A RootEntry of table_id_to_rootpage. in = false: no entry.
  type Bind = { in: bool, root: int, begin: int, end: int, mat: int }
  // The version store chain of the sqlite_schema row of an object. gone: GC
  // dropped it. mat: materialized_at of its newest state (0 = not stamped).
  // tomb: a DROP or ALTER ran after GC dropped the chain, so the chain starts
  // with a tombstone (begin = None) and has no version older than that DDL.
  type SCat = { gone: bool, mat: int, tomb: bool }
  type Cell = { own: str, value: int }
  type Image = { img: int -> Cell, bcat: str -> int, meta: int }
  type Op = { op: str, o: str, p: int, t: int }
  type CkState = { pc: str, snap: int, old: int, todo: Set[str], img: int -> Cell,
                   bcat: str -> int, ops: Set[Op], created: Set[str], written: Set[str],
                   freed: Set[int], dirty: bool, frame: int, hdr: int, cv2: Set[str],
                   pending: Set[Op], history: Set[str], owner: str, auto: bool }
  // mark: the WAL mark that begin pinned (the gate of is_btree_readable_at).
  // pm: the WAL mark that page reads use. It equals mark with GuardFrozenMark.
  // unpinned: a checkpoint on this reader's connection ended its WAL read
  // lock (pager.rs:3474-3475). Its MVCC snapshot stays in txs.
  type RdState = { pc: str, o: str, root: int, gen: int, cookie: int, mark: int, pm: int,
                   b: int, tid: str, unpinned: bool }
  type LogRec = { o: str, kind: str, ts: int, root: int }
  type ErrRec = { kind: str, reader: str, o: str, b: int, tid: str, mark: int, got: int,
                  want: int, btree: str, snap: int }
  type CkVerRec = { skip: bool, b: int, e: int, root: int, v: int }
  // The sample of one gc_incremental call. at: the clock at the sample.
  // idle: compute_lwm was MAX. floor: compute_min_reader_mark().min(backfill_floor).
  type GcState = { pc: str, at: int, lwm: int, idle: bool, floor: int }

  var clock: int                 // Last timestamp taken from the logical clock.
  var lastCommitted: int         // last_committed_tx_ts.
  var cat: str -> Cat            // cat[o]: the sqlite_schema row of o (see Cat).
  var ddl: Ddl                   // The exclusive DDL transaction.
  var cookie: int                // Schema cookie in the global header.
  var pubCookie: int             // Schema cookie of the shared schema (its version).
  var gen: int                   // MvStore::schema_generation.
  var pub: str -> int            // Database::schema: root of o: 0 (none), its temporary
                                 // id (negative) or a page.
  var droppedRoots: Set[int]     // Database::schema.dropped_root_pages.
  var nextId: int                // MvStore::next_table_id.
  var tid: str -> int            // tid[o]: the temporary table id that CREATE gave o.
  var chain: str -> Set[Version] // chain[o]: versions of the row of o in the version store.
  var ins: str -> Ins            // ins[o]: [ts, id] of the row insert and its log record id.
  var scat: str -> SCat          // scat[o]: the version store chain of the sqlite_schema row of o.
                                 // An index row comes with the insert of its table row.
  var omap: str -> str           // omap[o]: with SyncObjectMap, the name that the object map of
                                 // the commit of o's row gives to the table id of its record.
                                 // "" = not recorded, "-" = no name (the commit fails),
                                 // "?" = more than one name.
  var bind: str -> Bind          // table_id_to_rootpage: bind[o] is the RootEntry of tid[o].
  var wal: List[Image]           // WAL frames. Frame i is wal[i - 1].
  var nBackfill: int             // WAL frames 1..nBackfill are in the database file.
  var db: Image                  // The database file.
  var durable: int               // durable_txid_max.
  var backfillFloor: int         // backfill_floor.
  var ck: CkState                // State of the running checkpoint pass.
  var nCk: int                   // Number of checkpoint passes started.
  var rd: str -> RdState         // rd[r]: state of reader r.
  var ddlLog: Set[LogRec]        // History: finished DDL commits (in the logical log).
  var seen: Set[str]             // History: outcomes that the reachability checks look for.
  var err: Set[ErrRec]           // History: wrong reads and panics.
  var gcs: GcState               // The GC sample when GC runs in steps (GcSamplesFirst).

  // ---------------------------------------------------------------------------
  // Helpers

  pure def Max(S: Set[int]): int = S.fold(-Inf - 1, (a, x) => if (x > a) x else a)
  pure def Min(S: Set[int]): int = S.fold(Inf + 1, (a, x) => if (x < a) x else a)

  pure val NoBind: Bind = { in: false, root: 0, begin: 0, end: Inf, mat: 0 }
  pure val NoCat: Cat = { c: 0, d: Inf, a: 0, r1: 0, r2: 0 }
  pure val NoIns: Ins = { ts: 0, id: 0 }
  pure val NoSCat: SCat = { gone: false, mat: 0, tomb: false }

  // An ErrRec with only the fields that every kind has.
  pure def ErrOf(kind: str, reader: str, o: str, b: int): ErrRec =
    { kind: kind, reader: reader, o: o, b: b, tid: "", mark: 0, got: 0, want: 0,
      btree: "", snap: 0 }

  // A timestamp is resolved when its commit left the Preparing state.
  def Resolved(t: int): bool = not(ddl.pc == "preparing" and ddl.ts == t)

  // The table exists at snapshot b. Readers see Preparing commits too, as in
  // MvccPassiveCheckpoint.qnt, because every prepared commit finishes.
  def LiveAt(o: str, b: int): bool =
    cat.get(o).c != 0 and cat.get(o).c < b and not(cat.get(o).d < b)

  def Oracle(o: str, b: int): int =
    if (not(LiveAt(o, b))) Gone
    else if (ins.get(o).ts != 0 and ins.get(o).ts < b) ins.get(o).ts
    else 0

  pure val FreeCell: Cell = { own: NoObj, value: 0 }

  pure val EmptyImg: Image = { img: Pages.mapBy(p => FreeCell),
                               bcat: Objs.mapBy(o => 0),
                               meta: 0 }

  // WAL frame number i, counted from 1.
  def Frame(i: int): Image = wal[i - 1]

  // The B-tree through WAL read mark m. Backfill never passes a pinned mark,
  // so the frame at m is the newest image this reader can see.
  def BtreeAt(m: int): Image = if (m == 0) db else Frame(m)

  val LastImg: Image = if (wal == List()) db else Frame(wal.length())

  pure def FreePages(img: int -> Cell): Set[int] = Pages.filter(p => img.get(p).own == NoObj)

  val Pinned: Set[str] = Readers.filter(r => and {
    Set("pinned", "active", "open").contains(rd.get(r).pc), not(rd.get(r).unpinned),
  })
  val Registered: Set[str] = Readers.filter(r => Set("active", "open").contains(rd.get(r).pc))

  val Lwm: int = if (Registered == Set()) Inf else Min(Registered.map(r => rd.get(r).b))

  // The GC floor of gc_incremental: registered readers' marks and backfill_floor.
  val GcFloor: int = Min(Registered.map(r => rd.get(r).mark).union(Set(backfillFloor)))

  // Idle records carry no stale fields, so idle states merge.
  pure val IdleCk: CkState = {
    pc: "idle", snap: 0, old: 0, todo: Set(), img: EmptyImg.img, bcat: EmptyImg.bcat,
    ops: Set(), created: Set(), written: Set(), freed: Set(), dirty: false, frame: 0,
    hdr: 0, cv2: Set(), pending: Set(), history: Set(), owner: "", auto: false,
  }

  pure val IdleDdl: Ddl = { pc: "none", o: "none", kind: "none", ts: 0, hdr: 0,
                            sch: Objs.mapBy(o => 0), dr: Set(), mark: 0 }

  pure val IdleRd: RdState = { pc: "idle", o: "none", root: 0, gen: 0, cookie: 0, mark: 0,
                               pm: 0, b: 0, tid: "none", unpinned: false }

  pure val IdleGc: GcState = { pc: "idle", at: 0, lwm: 0, idle: false, floor: 0 }

  pure def KindOf(o: str): str = if (Indexes.contains(o)) "index" else "table"
  pure def TableOf(o: str): str = if (Indexes.contains(o)) IdxTable else o

  // Live indexes of table o.
  def LiveIndexes(o: str): Set[str] =
    Indexes.filter(i => TableOf(i) == o and cat.get(i).c != 0 and cat.get(i).d == Inf)

  // ---------------------------------------------------------------------------
  // Initial state

  action Init = all {
    // The catalog parts do not model ALTER. With both on, no state exists.
    not(CatalogReads and Alters),
    // The sync parts do not model ALTER or index rows.
    not(SyncObjectMap and (Alters or Indexes != Set())),
    clock' = 0,
    lastCommitted' = 0,
    cat' = Objs.mapBy(o => NoCat),
    ddl' = IdleDdl,
    cookie' = 0,
    pubCookie' = 0,
    gen' = 0,
    pub' = Objs.mapBy(o => 0),
    droppedRoots' = Set(),
    // Page 1 is sqlite_schema, so the code starts at -2. The fix takes ids
    // from a range that no page number reaches.
    nextId' = if (FixDisjointIds) -100 else -2,
    tid' = Objs.mapBy(o => 0),
    chain' = Objs.mapBy(o => Set()),
    ins' = Objs.mapBy(o => NoIns),
    scat' = Objs.mapBy(o => NoSCat),
    omap' = Objs.mapBy(o => ""),
    bind' = Objs.mapBy(o => NoBind),
    wal' = List(),
    nBackfill' = 0,
    db' = EmptyImg,
    durable' = 0,
    backfillFloor' = 0,
    ck' = IdleCk,
    nCk' = 0,
    rd' = Readers.mapBy(r => IdleRd),
    ddlLog' = Set(),
    seen' = Set(),
    err' = Set(),
    gcs' = IdleGc,
  }

  // Keeps the schema variables as they are.
  action UnchangedSchemaVars = all {
    cat' = cat, ddl' = ddl, cookie' = cookie, pubCookie' = pubCookie, gen' = gen,
    pub' = pub, droppedRoots' = droppedRoots, nextId' = nextId, tid' = tid,
    ddlLog' = ddlLog,
  }

  // Keeps the row variables as they are.
  action UnchangedRowVars = all { chain' = chain, ins' = ins, scat' = scat, omap' = omap }

  // Keeps the store variables as they are.
  action UnchangedStoreVars = all {
    bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, gcs' = gcs,
  }

  // ---------------------------------------------------------------------------
  // DDL: CREATE TABLE and DROP TABLE

  // The statement runs: the connection copies the shared schema and changes
  // the copy. CREATE takes a temporary id and inserts a live binding with no
  // root page. DROP of a table with a page records the page in
  // dropped_root_pages (op_drop_table, core/vdbe/execute.rs). ALTER TABLE
  // ADD COLUMN updates the sqlite_schema row: it ends version 1 and writes
  // version 2 with the rootpage column that it read from version 1
  // (translate_update_for_schema_change, core/translate/alter.rs).
  // CREATE INDEX needs a live table with no row. DROP TABLE needs its indexes
  // dropped first.
  action DdlExec(o: str, kind: str): bool = all {
    ddl.pc == "none",
    if (kind == "create") and {
      cat.get(o).c == 0, pub.get(o) == 0,
      Indexes.contains(o) implies and {
        cat.get(TableOf(o)).c != 0, cat.get(TableOf(o)).d == Inf,
        pub.get(TableOf(o)) != 0, ins.get(TableOf(o)).ts == 0,
      },
    }
    else if (kind == "drop") and {
      pub.get(o) != 0, cat.get(o).d == Inf,
      LiveIndexes(o) == Set(),
    }
    else and {
      kind == "alter",
      Alters, not(Indexes.contains(o)),
      pub.get(o) != 0, cat.get(o).c != 0, cat.get(o).d == Inf, cat.get(o).a == 0,
    },
    cat' = if (kind == "create" and Alters) cat.setBy(o, x => { ...x, r1: nextId })
           else if (kind == "alter") cat.setBy(o, x => { ...x, r2: x.r1 })
           else cat,
    ddl' = { pc: "exec", o: o, kind: kind, ts: 0, hdr: cookie,
             mark: if (CatalogReads) wal.length() else 0,
             sch: pub.set(o, if (kind == "create") nextId else 0),
             dr: if (kind == "drop" and pub.get(o) > 0) droppedRoots.union(Set(pub.get(o)))
                 else droppedRoots },
    tid' = if (kind == "create") tid.set(o, nextId) else tid,
    nextId' = if (kind == "create") nextId - 1 else nextId,
    bind' = if (kind == "create") bind.set(o, { ...NoBind, in: true }) else bind,
    clock' = clock, lastCommitted' = lastCommitted, cookie' = cookie,
    pubCookie' = pubCookie, gen' = gen, pub' = pub, droppedRoots' = droppedRoots,
    ddlLog' = ddlLog, chain' = chain, ins' = ins, omap' = omap,
    // The statement writes a version of the sqlite_schema row with a TxID,
    // and the stamp goes back to none (mod.rs:10989-11002). A chain that GC
    // dropped gets a tombstone for the B-tree row (mod.rs:5759-5809).
    scat' = if (CatalogReads)
              scat.set(o, { ...NoSCat,
                            tomb: kind != "create" and (scat.get(o).gone or scat.get(o).tomb) })
            else scat,
    wal' = wal, nBackfill' = nBackfill, db' = db,
    durable' = durable, backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd,
    gcs' = gcs,
    seen' = if (CatalogReads and kind != "create" and scat.get(o).gone)
              seen.union(Set("CatalogTomb")) else seen,
    err' = err,
  }

  action DdlPrepare: bool = {
    val ts = clock + 1
    all {
      ddl.pc == "exec",
      clock < MaxTs,
      clock' = ts,
      ddl' = { ...ddl, pc: "preparing", ts: ts },
      cat' = cat.setBy(ddl.o, x =>
               if (ddl.kind == "create") { ...x, c: ts }
               else if (ddl.kind == "drop") { ...x, d: ts }
               else { ...x, a: ts }),
      lastCommitted' = lastCommitted, cookie' = cookie, pubCookie' = pubCookie,
      gen' = gen, pub' = pub, droppedRoots' = droppedRoots, nextId' = nextId, tid' = tid,
      ddlLog' = ddlLog, chain' = chain, ins' = ins, omap' = omap,
      // The commit rewrites the TxID of its version, which resets the stamp.
      scat' = if (CatalogReads) scat.setBy(ddl.o, x => { ...x, mat: 0 }) else scat,
      UnchangedStoreVars, rd' = rd, seen' = seen, err' = err,
    }
  }

  // publish_committed_tx publishes the header with the cookie of the DDL's own
  // header plus one. The connection then publishes its schema
  // (publish_schema_if_newer). The model does both in one step. The log
  // record of a CREATE carries the sqlite_schema row with rootpage = its
  // temporary id. The record of an ALTER carries version 2 as it is at commit.
  // An ALTER does not change the root, so with FixDdlRebases it leaves the
  // shared root of its table alone.
  action DdlFinish: bool = all {
    ddl.pc == "preparing",
    lastCommitted' = Max(Set(lastCommitted, ddl.ts)),
    cookie' = ddl.hdr + 1,
    pubCookie' = ddl.hdr + 1,
    if (not(FixDdlRebases)) all {
      pub' = ddl.sch,
      droppedRoots' = ddl.dr,
    }
    else all {
      pub' = if (ddl.kind == "alter") pub else pub.set(ddl.o, ddl.sch.get(ddl.o)),
      droppedRoots' = if (ddl.kind == "drop" and pub.get(ddl.o) > 0)
                        droppedRoots.union(Set(pub.get(ddl.o)))
                      else droppedRoots,
    },
    ddlLog' = ddlLog.union(Set({ o: ddl.o, kind: ddl.kind, ts: ddl.ts,
                                 root: if (ddl.kind == "alter") cat.get(ddl.o).r2
                                       else tid.get(ddl.o) })),
    ddl' = IdleDdl,
    clock' = clock, cat' = cat, gen' = gen, nextId' = nextId, tid' = tid,
    UnchangedRowVars, UnchangedStoreVars, rd' = rd, seen' = seen, err' = err,
  }

  // ---------------------------------------------------------------------------
  // Writers

  // canonical_log_id: -root when the table has a root page, else its id.
  // With FixPermanentLogId the record keeps the permanent id.
  def LogId(o: str): int =
    if (FixPermanentLogId) tid.get(o)
    else if (bind.get(o).in and bind.get(o).root > 0) -bind.get(o).root
    else tid.get(o)

  pure def Abs(n: int): int = if (n < 0) -n else n

  // The rootpage column of the current sqlite_schema version of table o:
  // its temporary id until the publish patches in its page
  // (publish_checkpointed_schema_roots). The sync configurations have no
  // ALTER, so the row has one version.
  def RootCol(o: str): int =
    if (bind.get(o).in and bind.get(o).root > 0) bind.get(o).root else tid.get(o)

  // A table whose CREATE committed and whose DROP did not.
  def LiveTable(o: str): bool = and {
    not(Indexes.contains(o)), cat.get(o).c != 0, Resolved(cat.get(o).c),
    not(cat.get(o).d != Inf and Resolved(cat.get(o).d)),
  }

  // table_name_for_rootpage (mod.rs:679, mod.rs:662): the connection schema,
  // then the shared schema, each first by rootpage == r and then by
  // rootpage == -r. The model has one schema for both, the shared one.
  def SchemaNames(r: int): Set[str] = {
    val tables = Objs.filter(y => not(Indexes.contains(y)))
    val exact = tables.filter(y => pub.get(y) == r)
    if (exact != Set()) exact else tables.filter(y => pub.get(y) == -r)
  }

  // table_name_for_rootpage_in_mvcc_schema (mod.rs:692): the sqlite_schema
  // versions with no end whose rootpage is r or -r. A chain that catalog GC
  // dropped has no version (the row is only in the B-tree).
  def CatNames(r: int): Set[str] =
    Objs.filter(y => and {
      not(Indexes.contains(y)), cat.get(y).c != 0, cat.get(y).d == Inf,
      not(scat.get(y).gone),
      RootCol(y) == r or RootCol(y) == -r,
    })

  def NamesFor(r: int): Set[str] = if (SchemaNames(r) != Set()) SchemaNames(r) else CatNames(r)

  // populate_portable_changes (mod.rs:2781-3013) for a commit whose one
  // data record carries table id x. The code reads x as a rootpage first.
  // If no schema knows it, the binding of id x gives the page
  // (rootpage_for_table_id, mod.rs:2919-2932). With FixPermanentLogId, core
  // writes the table that owns id x. The set holds every name the code can
  // pick. Set() means "cannot resolve user data table id" (mod.rs:2999).
  //
  // The binding branch needs a table y with tid[y] == x and a page. A record
  // carries tid[o] only while o has no page (LogId), so y == o has no page.
  // With FixDisjointIds a record id -page is never a temporary id, so no
  // other y matches. So with FixDisjointIds the branch cannot fire, and
  // NeverMapsFromBinding checks that in the sync modules that pass. With
  // FixDisjointIds off it is not checked.
  def MapNames(x: int): Set[str] =
    if (FixPermanentLogId) Objs.filter(y => tid.get(y) == x)
    else if (NamesFor(x) != Set()) NamesFor(x)
    else Objs.filter(y => tid.get(y) == x and bind.get(y).in and bind.get(y).root > 0)
           .map(y => NamesFor(bind.get(y).root)).flatten()

  // "-" for no name, the name for one, "?" for more than one.
  def MapName(x: int): str =
    if (MapNames(x) == Set()) "-" else MapNames(x).fold("", (a, n) => if (a == "") n else "?")

  // INSERT of the one row of table o, as one atomic commit. The same commit
  // inserts the row of each live index of o, and the same log record carries
  // the index rows with the index's own id.
  action WriteRow(o: str): bool = {
    val ts = clock + 1
    val ws = Set(o).union(LiveIndexes(o))
    all {
      ddl.pc == "none",
      not(Indexes.contains(o)),
      cat.get(o).c != 0, cat.get(o).d == Inf, pub.get(o) != 0,
      ins.get(o).ts == 0,
      clock < MaxTs,
      clock' = ts,
      lastCommitted' = Max(Set(lastCommitted, ts)),
      chain' = Objs.mapBy(x =>
                 if (ws.contains(x)) Set({ b: ts, e: Inf, value: ts, mat: 0 })
                 else chain.get(x)),
      ins' = Objs.mapBy(x => if (ws.contains(x)) { ts: ts, id: LogId(x) } else ins.get(x)),
      scat' = scat,
      // The object map of this commit (populate_portable_changes).
      omap' = if (SyncObjectMap) omap.set(o, MapName(LogId(o))) else omap,
      // MapInPass: the row commits with its temporary id while a pass that
      // creates its B-tree runs, before the publish. MapFromCatalog: no
      // schema knows the record id, and the sqlite_schema versions give the
      // name. MapFromBinding: the binding branch of MapNames gives it.
      seen' = if (not(SyncObjectMap)) seen
              else seen
                .union(if (Set("collect", "committed").contains(ck.pc)
                           and InWindow(cat.get(o).c) and LogId(o) == tid.get(o))
                         Set("MapInPass") else Set())
                .union(if (not(FixPermanentLogId) and SchemaNames(LogId(o)) == Set()
                           and CatNames(LogId(o)) != Set())
                         Set("MapFromCatalog") else Set())
                .union(if (not(FixPermanentLogId) and NamesFor(LogId(o)) == Set()
                           and MapNames(LogId(o)) != Set())
                         Set("MapFromBinding") else Set()),
      UnchangedSchemaVars, UnchangedStoreVars, rd' = rd, err' = err,
    }
  }

  // ---------------------------------------------------------------------------
  // Readers

  action UnchangedForReaders = all {
    clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars,
    UnchangedRowVars, UnchangedStoreVars,
  }

  // The Transaction opcode: compile against the shared schema and take
  // schema_generation (mvcc_begin_schema_generation).
  action ReaderPrepare(r: str, o: str): bool = all {
    rd.get(r).pc == "idle",
    pub.get(o) != 0,
    rd' = rd.setBy(r, x => { ...x, pc: "prepared", o: o, root: pub.get(o), gen: gen,
                             cookie: pubCookie }),
    UnchangedForReaders, seen' = seen, err' = err,
  }

  action ReaderPin(r: str): bool = all {
    rd.get(r).pc == "prepared",
    rd' = rd.setBy(r, x => { ...x, pc: "pinned", mark: wal.length(), pm: wal.length() }),
    UnchangedForReaders, seen' = seen, err' = err,
  }

  // begin_tx under the clock lock, then the cookie check of the Transaction
  // opcode. An inner transaction (nextval: op_sequence_begin_inner_tx) starts
  // a new snapshot with the old compiled program and, in the code today,
  // checks neither the generation nor the cookie (#11500).
  action ReaderBegin(r: str, inner: bool): bool = {
    val checks = not(inner) or FixInnerTxChecks
    all {
      rd.get(r).pc == "pinned",
      clock < MaxTs,
      if (checks and GuardGenerationGate and rd.get(r).gen != gen) all {
        rd' = rd.set(r, IdleRd),
        seen' = seen.union(Set("SchemaUpdatedGen")),
        clock' = clock,
      }
      else if (GuardBusyOnUnpublished and ddl.pc == "preparing") all {
        rd' = rd.set(r, IdleRd),
        seen' = seen.union(Set("Busy")),
        clock' = clock,
      }
      else if (checks and GuardCookieCheck and rd.get(r).cookie != cookie) all {
        rd' = rd.set(r, IdleRd),
        seen' = seen.union(Set("SchemaUpdatedCookie")),
        clock' = clock,
      }
      else all {
        clock' = clock + 1,
        rd' = rd.setBy(r, x => { ...x, pc: "active", b: clock + 1 }),
        // Mode T: the begin runs between two parts of the publish.
        seen' = if (MidPublish) seen.union(Set("BeginMidPublish")) else seen,
      },
      lastCommitted' = lastCommitted, UnchangedSchemaVars, UnchangedRowVars,
      UnchangedStoreVars, err' = err,
    }
  }

  // try_get_table_id_from_root_page_at: a negative root is the table id. A
  // page maps to the binding with that root that is live or ends after b,
  // the one with the lowest end.
  def OwnersAt(p: int, b: int): Set[str] =
    Objs.filter(x => and {
      bind.get(x).in, bind.get(x).root == p,
      bind.get(x).end == Inf or b < bind.get(x).end,
    })

  // CHOOSE x \in Objs : tid[x] = id
  def TidOwner(id: int): str =
    Objs.fold("", (a, x) => if (a == "" and tid.get(x) == id) x else a)

  // CHOOSE x \in cands : \A y \in cands : bind[x].end <= bind[y].end
  def LowestEnd(cands: Set[str]): str =
    cands.fold("", (a, x) =>
      if (a == "" and cands.forall(y => bind.get(x).end <= bind.get(y).end)) x else a)

  // Each open is a new statement of the transaction. Without GuardFrozenMark
  // its page reads use the newest WAL frame, while is_btree_readable_at still
  // uses the mark of the begin.
  def NewPm(r: str): int = if (GuardFrozenMark) rd.get(r).pm else wal.length()

  action ReaderOpen(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "active",
    if (rd.get(r).root < 0) all {
      rd' = rd.setBy(r, x => { ...x, pc: "open", pm: NewPm(r), tid: TidOwner(x.root) }),
      seen' = seen, err' = err,
    }
    else {
      val cands = OwnersAt(rd.get(r).root, rd.get(r).b)
      if (cands == Set()) all {
        rd' = rd.set(r, IdleRd),
        seen' = seen.union(Set("SchemaUpdatedOpen")),
        err' = if (GuardOpenFallback and not(LiveAt(rd.get(r).o, rd.get(r).b))) err
               else err.union(Set(ErrOf(if (GuardOpenFallback) "spurious" else "panic",
                                        r, rd.get(r).o, rd.get(r).b))),
      }
      else all {
        rd' = rd.setBy(r, x => { ...x, pc: "open", pm: NewPm(r), tid: LowestEnd(cands) }),
        seen' = seen, err' = err,
      }
    },
    UnchangedForReaders,
  }

  // is_btree_readable_at.
  def Readable(x: str, b: int, m: int): bool = and {
    bind.get(x).in, bind.get(x).root > 0,
    GuardCoversBegin implies bind.get(x).begin <= b,
    GuardCoversEnd implies (bind.get(x).end == Inf or b < bind.get(x).end),
    GuardMatCheck implies bind.get(x).mat <= m,
  }

  pure def Visible(c: Set[Version], b: int): Set[Version] = c.filter(v => v.b < b and b < v.e)

  // (CHOOSE v \in c : TRUE).val
  pure def AnyValue(c: Set[Version]): int =
    c.fold({ b: -1, e: 0, value: 0, mat: 0 }, (a, x) => if (a.b == -1) x else a).value

  // A scan through the dual cursor: the version store side reads the chain of
  // the resolved table id. The B-tree side opens the B-tree when the binding
  // is readable, and returns the row it finds there unless the chain shadows
  // it. A page of another table, or a free page, is a wrong read. Seeking a
  // negative page is the pager panic of #8537.
  action ReaderRead(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "open",
    {
      val o = rd.get(r).o
      val x = rd.get(r).tid
      val b = rd.get(r).b
      val m = rd.get(r).mark
      val vis = Visible(chain.get(x), b)
      val rdbl = Readable(x, b, m)
      val page = if (rd.get(r).root > 0) rd.get(r).root
                 else if (GuardRefreshRoot) bind.get(x).root
                 else rd.get(r).root
      val bt = if (Pages.contains(page)) BtreeAt(rd.get(r).pm).img.get(page) else FreeCell
      val btOk = not(rdbl) or bt.own == o
      val res = if (vis != Set()) AnyValue(vis)
                else if (rdbl and bt.own == o) bt.value
                else 0
      val want = Oracle(o, b)
      val ok = btOk and x == o and res == want
      all {
        err' = (if (rdbl and page < 0) Set(ErrOf("panic", r, o, b)) else Set())
               .union(if (ok) err
                      else err.union(Set({ kind: "read", reader: r, o: o, b: b, tid: x,
                                           mark: m, got: res, want: want, btree: bt.own,
                                           snap: 0 }))),
        seen' = seen.union(
                  if (rdbl and Pages.contains(page) and LastImg.img.get(page).own != o)
                    Set("ReadOldOwner")
                  else Set()),
      }
    },
    rd' = rd.setBy(r, x => { ...x, pc: "active" }),
    UnchangedForReaders,
  }

  // The sqlite_schema row of x is in the version store.
  def InCatStore(x: str): bool = cat.get(x).c != 0 and not(scat.get(x).gone)

  // The newest DDL timestamp of the row of x, Preparing or not.
  def CatLast(x: str): int = {
    val ts = Set(cat.get(x).c, cat.get(x).a, cat.get(x).d).filter(t => t != 0 and t != Inf)
    if (ts == Set()) 0 else Max(ts)
  }

  // The version store has a version of x that is visible at b. After a
  // tombstone, only versions from the newest DDL on are in the store.
  def CatStoreVisible(x: str, b: int): bool = and {
    InCatStore(x), LiveAt(x, b),
    not(scat.get(x).tomb and b < CatLast(x)),
    // A tombstone of a DDL that has not taken its timestamp is all that the
    // chain has, and it is never visible.
    not(scat.get(x).tomb and ddl.pc == "exec" and ddl.o == x),
  }

  // is_btree_invalidating_version: a version visible at b, or one that ended
  // before b, hides the B-tree row. A version that begins after b does not.
  def CatShadows(x: str, b: int): bool =
    InCatStore(x) and or {
      CatStoreVisible(x, b),
      cat.get(x).d != Inf and cat.get(x).d < b,
      cat.get(x).a != 0 and cat.get(x).a < b,
    }

  // The number of rows of x that a scan of sqlite_schema returns at
  // snapshot b with page reads at WAL mark m: the visible version from the
  // version store, plus the B-tree row unless the chain hides it.
  def CatRows(x: str, b: int, m: int): int =
    (if (CatStoreVisible(x, b)) 1 else 0)
    + (if (BtreeAt(m).bcat.get(x) != 0 and not(CatShadows(x, b))) 1 else 0)

  // A new statement of an active reader scans sqlite_schema through the dual
  // cursor (SELECT ... FROM sqlite_schema, #8093, #8094). The sqlite_schema
  // B-tree (page 1) is always readable. The scan is one atomic step.
  action ReaderReadCatalog(r: str): bool = all {
    CatalogReads,
    ck.owner != r or ck.pc == "idle",
    rd.get(r).pc == "active",
    {
      val b = rd.get(r).b
      val m = NewPm(r)
      val got = Objs.filter(x => CatRows(x, b, m) > 0)
      val wrong = Objs.filter(x => CatRows(x, b, m) != (if (LiveAt(x, b)) 1 else 0))
      // Two generations: the scan returns an object and one that was created
      // at or after its drop, as a DROP and a CREATE of one name.
      val gens = tuples(got, got).filter(((x, y)) =>
                   x != y and cat.get(x).d != Inf and cat.get(y).c >= cat.get(x).d)
      all {
        err' = err
          .union(wrong.map(x => { kind: "catalog", reader: r, o: x, b: b, tid: "", mark: m,
                                  got: CatRows(x, b, m),
                                  want: if (LiveAt(x, b)) 1 else 0,
                                  btree: "", snap: 0 }))
          .union(gens.map(((x, y)) => { ...ErrOf("catalog-gen", r, x, b), tid: y, mark: m })),
        seen' = seen
          .union(if (Objs.exists(x => cat.get(x).c > b and LastImg.bcat.get(x) != 0))
                   Set("CatalogNewer") else Set())
          .union(if (tuples(Objs, Objs).exists(((x, y)) => and {
                       x != y, LiveAt(x, b), cat.get(x).d != Inf,
                       cat.get(y).c >= cat.get(x).d, cat.get(y).c > b,
                       LastImg.bcat.get(x) == 0, LastImg.bcat.get(y) != 0,
                     }))
                   Set("CatalogGenerations") else Set())
          .union(if (Objs.exists(x => LiveAt(x, b) and not(CatStoreVisible(x, b))
                                      and BtreeAt(m).bcat.get(x) != 0))
                   Set("CatalogFromBtree") else Set()),
      }
    },
    rd' = rd,
    UnchangedForReaders,
  }

  action ReaderEnd(r: str): bool = all {
    ck.owner != r or ck.pc == "idle",
    Set("prepared", "pinned", "active", "open").contains(rd.get(r).pc),
    rd' = rd.set(r, IdleRd),
    UnchangedForReaders, seen' = seen, err' = err,
  }

  // ---------------------------------------------------------------------------
  // Checkpoint

  val SnapshotTs: int =
    if (ddl.pc == "preparing") Min(Set(lastCommitted, ddl.ts - 1)) else lastCommitted

  action UnchangedForCheckpoint = all {
    clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars,
    UnchangedRowVars, rd' = rd, seen' = seen, gcs' = gcs,
  }

  // An explicit checkpoint (Connection::checkpoint, PRAGMA wal_checkpoint)
  // can run on the connection of a reader between two statements of its
  // transaction. begin_explicit_checkpoint refuses only an active statement
  // (connection.rs:2590). The owner then runs nothing until the pass stops.
  action CheckpointStart: bool = {
    nondet owner = (if (CheckpointOwnerReaders) Readers.filter(r => rd.get(r).pc == "active")
                    else Set()).union(Set("")).oneOf()
    all {
      (FixRefuseCheckpointOwner and owner != "") implies
        not(Pinned.union(Registered).contains(owner)),
      ck.pc == "idle",
      ck.pending == Set(),
      nCk < MaxCheckpoints,
      ck' = { ...IdleCk, pc: "collect", snap: SnapshotTs, old: durable, todo: Objs,
              img: LastImg.img, bcat: LastImg.bcat, history: ck.history, owner: owner },
      nCk' = nCk + 1,
      bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
      backfillFloor' = backfillFloor,
      UnchangedForCheckpoint, err' = err,
    }
  }

  def InWindow(t: int): bool = t != 0 and t != Inf and Resolved(t) and ck.old < t and t <= ck.snap

  // resolve_dropped_binding: the binding that owned page p at the drop.
  def DroppedOwners(p: int, d: int): Set[str] =
    Objs.filter(x => and {
      bind.get(x).in, bind.get(x).root == p, bind.get(x).begin < d, d <= bind.get(x).end,
    })

  // The row of o, if its insert is in this window, goes to page p.
  def WithRow(img: int -> Cell, o: str, p: int): int -> Cell =
    if (InWindow(ins.get(o).ts)) img.setBy(p, c => { ...c, value: ins.get(o).ts }) else img

  // One sqlite_schema row and the table's row, in the WriteRow state. The
  // order of tables is free, which covers every write_set order.
  action CheckpointObj(o: str): bool = all {
    ck.pc == "collect",
    ck.todo.contains(o),
    cat.get(o).a == 0,
    {
      val c = cat.get(o).c
      val d = cat.get(o).d
      val createdIn = InWindow(c)
      val droppedIn = InWindow(d)
      val rowIn = InWindow(ins.get(o).ts)
      val todo = ck.todo.exclude(Set(o))
      // The four cases exclude each other. An if chain, not an any, keeps
      // the name of this action in the traces of `quint run --mbt`.
      // Created and dropped in this window: no B-tree, remove the binding.
      if (createdIn and droppedIn)
        ck' = { ...ck, todo: todo,
                ops: ck.ops.union(Set({ op: "remove", o: o, p: 0, t: 0 })) }
      // SpecialWrite::BTreeCreate, with a drop after snap clamped to live.
      else if (createdIn and not(droppedIn)) {
        nondet p = FreePages(ck.img).oneOf()
        ck' = { ...ck, todo: todo,
                img: WithRow(ck.img.set(p, { own: o, value: 0 }), o, p),
                bcat: ck.bcat.set(o, p),
                ops: ck.ops.union(Set({ op: "alloc", o: o, p: p, t: 0 })),
                created: ck.created.union(Set(o)),
                written: ck.written.union(if (rowIn) Set(o) else Set()),
                dirty: true }
      }
      // SpecialWrite::BTreeDestroy of a checkpointed table.
      else if (not(createdIn) and droppedIn) {
        val p = ck.bcat.get(o)
        val xs = if (Pages.contains(p)) DroppedOwners(p, d) else Set()
        if (xs == Set()) ck' = { ...ck, todo: todo }
        else {
          nondet x = xs.oneOf()
          ck' = { ...ck, todo: todo,
                  img: ck.img.set(p, FreeCell),
                  bcat: ck.bcat.set(o, 0),
                  ops: ck.ops.union(Set({ op: if (GuardRetireOnDestroy) "retire" else "remove",
                                          o: x, p: p, t: d })),
                  freed: ck.freed.union(Set(p)),
                  dirty: true }
        }
      }
      // A table that is already in the B-tree: write its row.
      else if (rowIn and Pages.contains(ck.bcat.get(o)))
        ck' = { ...ck, todo: todo,
                img: WithRow(ck.img, o, ck.bcat.get(o)),
                written: ck.written.union(Set(o)),
                dirty: true }
      else ck' = { ...ck, todo: todo }
    },
    bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint, err' = err,
  }

  /* A table with an ALTER has two versions of its sqlite_schema row:
     v1 = [c, a) with rootpage r1 and v2 = [a, d) with rootpage r2.
     maybe_get_checkpointable_versions (checkpoint_state_machine.rs:1078)
     walks them oldest first. A timestamp of a commit that is not finished is
     no timestamp. A begin after snap skips the version. An end after snap is
     clamped to live. A version is collected when it is a live insert after
     old, a delete of a row that the B-tree has, or a delete of a schema row
     that the B-tree does not have. When an ended version is followed by a
     version with the same B-tree identity (same rootpage), only the newer one
     stays (is_schema_metadata_only_rewrite). */
  def Eff(t: int): int = if (t != 0 and t != Inf and Resolved(t)) t else 0

  def CkVer(b: int, e: int, root: int, v: int): CkVerRec = {
    val bt = Eff(b)
    val et = if (Eff(e) > ck.snap) 0 else Eff(e)
    { skip: bt > ck.snap or (bt == 0 and et == 0), b: bt, e: et, root: root, v: v }
  }

  // exists_in_db_file after version x.
  def ExistsAfter(ex: bool, x: CkVerRec): bool =
    if (x.skip) ex
    else (ex or (ck.old != 0 and x.b != 0 and x.b <= ck.old))
         and not(ck.old != 0 and x.e != 0 and x.e <= ck.old)

  def ShouldCk(ex: bool, x: CkVerRec): bool = {
    val ex1 = ExistsAfter(ex, x)
    and {
      not(x.skip),
      or {
        x.e == 0 and (ck.old == 0 or x.b > ck.old),
        x.e != 0 and ex1,
        not(ex1) and (ck.old == 0 or x.e > ck.old),
      },
    }
  }

  def CkList(o: str): List[CkVerRec] = {
    val v1 = CkVer(cat.get(o).c, cat.get(o).a, cat.get(o).r1, 1)
    val v2 = CkVer(cat.get(o).a, cat.get(o).d, cat.get(o).r2, 2)
    val L1 = if (ShouldCk(false, v1)) [v1] else []
    if (not(ShouldCk(ExistsAfter(false, v1), v2))) L1
    else if (L1 != [] and v1.e != 0 and v1.root == v2.root) [v2]
    else L1.append(v2)
  }

  // The special write of one collected version (collect_table_row_versions).
  // A delete with a negative root removes the binding. A delete with a page
  // destroys the B-tree of the binding that owned the page at the delete. A
  // live version with a negative root creates a B-tree. A live version with a
  // page is a plain ALTER: the B-tree catalog row is rewritten.
  def CkStep(k: CkState, x: CkVerRec, o: str): Set[CkState] =
    if (x.e != 0 and x.root < 0)
      Set({ ...k, ops: k.ops.union(Set({ op: "remove", o: o, p: 0, t: 0 })) })
    else if (x.e != 0) {
      val p = x.root
      val xs = if (Pages.contains(p)) DroppedOwners(p, x.e) else Set()
      if (xs == Set()) Set(k)
      else xs.map(y => { ...k, img: k.img.set(p, FreeCell),
                         bcat: k.bcat.set(o, 0),
                         ops: k.ops.union(Set({ op: "retire", o: y, p: p, t: x.e })),
                         freed: k.freed.union(Set(p)),
                         dirty: true })
    }
    else if (x.root < 0)
      FreePages(k.img).map(p => { ...k, img: k.img.set(p, { own: o, value: 0 }),
                                  bcat: k.bcat.set(o, p),
                                  ops: k.ops.union(Set({ op: "alloc", o: o, p: p, t: 0 })),
                                  created: k.created.union(Set(o)),
                                  cv2: if (x.v == 2) k.cv2.union(Set(o)) else k.cv2,
                                  dirty: true })
    else Set(k)

  // Rows of a table that this pass destroys are not written.
  def CkRows(k: CkState, o: str): CkState =
    if (and {
          InWindow(ins.get(o).ts), Pages.contains(k.bcat.get(o)),
          not(k.ops.exists(op => Set("remove", "retire").contains(op.op) and op.o == o)),
        })
      { ...k, img: WithRow(k.img, o, k.bcat.get(o)), written: k.written.union(Set(o)),
        dirty: true }
    else k

  action CheckpointObjAlter(o: str): bool = all {
    ck.pc == "collect",
    ck.todo.contains(o),
    cat.get(o).a != 0,
    {
      val L = CkList(o)
      val k0 = { ...ck, todo: ck.todo.exclude(Set(o)) }
      val ks1 = if (L.length() >= 1) CkStep(k0, L[0], o) else Set(k0)
      val ks2 = if (L.length() >= 2) ks1.map(k => CkStep(k, L[1], o)).flatten() else ks1
      // A B-tree destroy for an object that is not dropped at snap.
      val bad = L.indices().exists(i => L[i].e != 0 and L[i].root > 0
                                        and not(cat.get(o).d <= ck.snap))
      all {
        nondet k = ks2.oneOf()
        ck' = CkRows(k, o),
        err' = if (bad) err.union(Set({ ...ErrOf("destroy-live", "", o, 0), snap: ck.snap }))
               else err,
      }
    },
    bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint,
  }

  // The pager commit also stages the page 1 header with the cookie of now
  // (CommitPagerTxn).
  // BeginPagerTxn reuses the owner's WAL read lock (csm.rs:2653-2661). If the
  // owner's snapshot is not the newest frame, begin_write_tx fails with
  // BusySnapshot, and the pass stops before it owns a pager transaction. An
  // auto-checkpoint drops that error (mod.rs:3755-3760). pager.commit_tx
  // ends the connection's WAL read lock (pager.rs:3474-3475), which is the
  // owner's pin. The owner's MVCC snapshot stays in txs.
  action CheckpointCommit: bool = {
    val boundary = Max(Set(ck.old, ck.snap))
    val write = ck.dirty or boundary > ck.old
    val owned = ck.owner != "" and Pinned.contains(ck.owner)
    val stale = write and owned and rd.get(ck.owner).mark != wal.length()
    all {
      ck.pc == "collect",
      ck.todo == Set(),
      if (stale) all {
        wal' = wal,
        ck' = { ...IdleCk, history: ck.history },
        rd' = rd, chain' = chain, scat' = scat,
      } else all {
        wal' = if (write) wal.append({ img: ck.img, bcat: ck.bcat, meta: boundary }) else wal,
        ck' = { ...ck, pc: "committed", hdr: cookie,
                frame: if (write) wal.length() + 1 else 0,
                history: if (ck.auto and write and owned and Registered.contains(ck.owner))
                           ck.history.union(Set("autoOwnerCommit"))
                         else ck.history },
        rd' = if (write and owned) rd.setBy(ck.owner, x => { ...x, unpinned: true }) else rd,
        chain' = if (FixStampAtPagerCommit and write) Objs.mapBy(o =>
          if (ck.written.contains(o)) chain.get(o).map(v =>
            if (v.b <= ck.snap) { ...v, mat: wal.length() + 1 } else v)
          else chain.get(o)) else chain,
        scat' = if (FixStampAtPagerCommit and write) StampCatalog(wal.length() + 1) else scat,
      },
      bind' = bind, nBackfill' = nBackfill, db' = db, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk, gcs' = gcs,
      clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars,
      ins' = ins, omap' = omap, seen' = seen,
      err' = err,
    }
  }

  // apply_checkpoint_publish_window, under the clock lock: Retire and Remove,
  // then Alloc (record_rootpage_alloc) with materialized_at = frame, then the
  // staged header, then publish_checkpointed_schema_roots.
  def RetireOf(x: str): Set[Op] = ck.ops.filter(op => op.op == "retire" and op.o == x)

  // CHOOSE op \in ops : TRUE
  pure def AnyOp(ops: Set[Op]): Op =
    ops.fold({ op: "", o: "", p: 0, t: 0 }, (a, x) => if (a.op == "") x else a)

  val AfterRetire: str -> Bind =
    Objs.mapBy(x =>
      if (ck.ops.exists(op => op.op == "remove" and op.o == x)) NoBind
      else if (RetireOf(x) != Set()) { ...bind.get(x), end: AnyOp(RetireOf(x)).t }
      else bind.get(x))

  def AllocOf(x: str): Set[Op] = ck.ops.filter(op => op.op == "alloc" and op.o == x)
  val AllocPages: Set[int] = ck.ops.filter(op => op.op == "alloc").map(op => op.p)

  val AfterAlloc: str -> Bind =
    Objs.mapBy(x =>
      if (AllocOf(x) != Set())
        { in: true, root: AnyOp(AllocOf(x)).p, begin: ck.snap, end: Inf, mat: ck.frame }
      else if (GuardAllocRetiresStale and AfterRetire.get(x).end == Inf
               and AllocPages.contains(AfterRetire.get(x).root))
        { ...AfterRetire.get(x), end: ck.snap }
      else AfterRetire.get(x))

  // bump_next_table_id_below: ids handed out later stay below -page.
  val BumpedId: int =
    Min(Set(nextId).union(ck.ops.filter(op => op.op == "alloc").map(op => -op.p - 1)))

  // The drop of a created table has an end stamp (TxID or timestamp) when the
  // DROP statement already ran.
  def EndSet(o: str): bool =
    cat.get(o).d != Inf or (ddl.pc != "none" and ddl.o == o and ddl.kind == "drop")

  // An ALTER that ran ended version 1 of the row.
  def AlterRan(o: str): bool =
    cat.get(o).a != 0 or (ddl.pc != "none" and ddl.o == o and ddl.kind == "alter")

  // The patched version has an end: version 1 when an ALTER or a DROP ran,
  // version 2 when a DROP ran. FixAlterPatch counts only a DROP.
  def Ended(o: str): bool = or {
    EndSet(o),
    Alters and not(FixAlterPatch) and not(ck.cv2.contains(o)) and AlterRan(o),
  }

  // The publish patches the payload of the version that the create collected
  // (existing.id == vid). FixAlterPatch also patches every other version of
  // the row that still carries the temporary id.
  def PatchCat(o: str, page: int): Cat = {
    val pr1 = not(ck.cv2.contains(o)) or (FixAlterPatch and cat.get(o).r1 == tid.get(o))
    val pr2 = ck.cv2.contains(o) or (FixAlterPatch and cat.get(o).r2 == tid.get(o))
    { ...cat.get(o), r1: if (pr1) page else cat.get(o).r1,
                     r2: if (pr2) page else cat.get(o).r2 }
  }

  // Passive: apply_passive_publish_window_ordered runs the whole window in
  // the clock callback (csm.rs:2208-2228), and begin_tx takes the same clock
  // (mod.rs:6760). So no begin falls inside the window.
  action CheckpointPublish: bool = all {
    Mode == "passive",
    ck.pc == "committed",
    ApplyCheckpointPublish("published", false),
  }

  /* Mode T: the checkpoint calls apply_checkpoint_publish_window with no
     clock wrapper (csm.rs:3321-3324). It took blocking_checkpoint_lock
     before the pager commit (csm.rs:3246-3252), and begin_tx does not take
     that lock with the passive flag on (mod.rs:6729). So a begin_tx, a
     statement prepare or a DDL on another thread can run between the four
     parts below. Each part takes its own lock.
       CheckpointPublishRoots   root map ops, staged allocs made visible, and
                                durable_txid_max (csm.rs:2169-2190). A STAGED
                                binding is never readable (mod.rs:10695-10712),
                                and GC keeps the chain until the stamp, so a read
                                between the alloc and the visible mark answers
                                as before the alloc. The model merges them.
       CheckpointPublishHeader  the staged page 1 header (csm.rs:2194-2199).
       CheckpointPublishSchema  the sqlite_schema payload patch (csm.rs:2029-2063)
                                and Database::schema under its mutex
                                (csm.rs:2075-2136). With Alters off and
                                GuardPatchKeepsEnd on the patch changes no
                                modeled variable, so the model merges them.
       CheckpointPublishGen     schema_generation (csm.rs:2137-2147). */
  val MidPublish: bool = Set("roots", "header", "schema").contains(ck.pc)

  action CheckpointPublishRoots: bool = all {
    Mode == "truncateFlagOn",
    ck.pc == "committed",
    bind' = AfterAlloc,
    nextId' = BumpedId,
    durable' = Max(Set(ck.old, ck.snap)),
    ck' = { ...ck, pc: "roots", pending: Set(),
            history: if (ck.pending != Set() and ck.history.contains("failedCommitted"))
                       ck.history.union(Set("repairedRoots"))
                     else ck.history },
    clock' = clock, lastCommitted' = lastCommitted, cat' = cat, ddl' = ddl, cookie' = cookie,
    pubCookie' = pubCookie, gen' = gen, pub' = pub, droppedRoots' = droppedRoots, tid' = tid,
    ddlLog' = ddlLog, UnchangedRowVars, wal' = wal, nBackfill' = nBackfill, db' = db,
    backfillFloor' = backfillFloor, nCk' = nCk, gcs' = gcs, rd' = rd, seen' = seen, err' = err,
  }

  action CheckpointPublishHeader: bool = all {
    Mode == "truncateFlagOn",
    ck.pc == "roots",
    cookie' = if (FixHeaderCookieMax) Max(Set(cookie, ck.hdr)) else ck.hdr,
    ck' = { ...ck, pc: "header" },
    clock' = clock, lastCommitted' = lastCommitted, cat' = cat, ddl' = ddl,
    pubCookie' = pubCookie, gen' = gen, pub' = pub, droppedRoots' = droppedRoots,
    nextId' = nextId, tid' = tid, ddlLog' = ddlLog, UnchangedRowVars, bind' = bind,
    wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk, gcs' = gcs, rd' = rd, seen' = seen, err' = err,
  }

  // publish_checkpointed_schema_roots reads the bindings and the shared
  // schema as they are now, not as they were at the pager commit.
  action CheckpointPublishSchema: bool = {
    val ended = ck.created.filter(x => Ended(x)).map(o => bind.get(o).root)
    val owned = Objs.exists(o => pub.get(o) < 0 and bind.get(o).in and bind.get(o).root > 0)
    val publish = ck.created != Set() or droppedRoots != Set() or owned
    val dr1 = if (GuardFreedOnly) droppedRoots.exclude(ck.freed) else Set()
    all {
      Mode == "truncateFlagOn",
      ck.pc == "header",
      cat' = Objs.mapBy(o => {
               val c1 = if (Alters and ck.created.contains(o)) PatchCat(o, bind.get(o).root)
                        else cat.get(o)
               if (not(GuardPatchKeepsEnd) and ck.created.contains(o)) { ...c1, d: Inf } else c1
             }),
      pub' = Objs.mapBy(o =>
               if (pub.get(o) < 0 and bind.get(o).in and bind.get(o).root > 0) bind.get(o).root
               else pub.get(o)),
      droppedRoots' = if (not(publish)) droppedRoots
                      else dr1.union(if (GuardEndedCreated) ended else Set()),
      // With nothing to publish the code returns before the generation bump.
      ck' = { ...ck, pc: if (publish) "schema" else "published" },
      clock' = clock, lastCommitted' = lastCommitted, ddl' = ddl, cookie' = cookie,
      pubCookie' = pubCookie, gen' = gen, nextId' = nextId, tid' = tid, ddlLog' = ddlLog,
      UnchangedRowVars, bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db,
      durable' = durable, backfillFloor' = backfillFloor, nCk' = nCk, gcs' = gcs, rd' = rd,
      seen' = seen, err' = err,
    }
  }

  action CheckpointPublishGen: bool = all {
    Mode == "truncateFlagOn",
    ck.pc == "schema",
    gen' = gen + 1,
    ck' = { ...ck, pc: "published" },
    clock' = clock, lastCommitted' = lastCommitted, cat' = cat, ddl' = ddl, cookie' = cookie,
    pubCookie' = pubCookie, pub' = pub, droppedRoots' = droppedRoots, nextId' = nextId,
    tid' = tid, ddlLog' = ddlLog, UnchangedRowVars, bind' = bind, wal' = wal,
    nBackfill' = nBackfill, db' = db, durable' = durable, backfillFloor' = backfillFloor,
    nCk' = nCk, gcs' = gcs, rd' = rd, seen' = seen, err' = err,
  }

  action ApplyCheckpointPublish(nextPc: str, failed: bool): bool = {
    val nb = AfterAlloc
    val ended = ck.created.filter(x => Ended(x)).map(o => nb.get(o).root)
    val owned = Objs.exists(o => pub.get(o) < 0 and nb.get(o).in and nb.get(o).root > 0)
    val publish = ck.created != Set() or droppedRoots != Set() or owned
    val dr1 = if (GuardFreedOnly) droppedRoots.exclude(ck.freed) else Set()
    all {
      bind' = nb,
      // Without GuardPatchKeepsEnd the collected clone replaces the
      // row, and its end is the clamped "live" one.
      cat' = Objs.mapBy(o => {
               val c1 = if (Alters and ck.created.contains(o)) PatchCat(o, nb.get(o).root)
                        else cat.get(o)
               if (not(GuardPatchKeepsEnd) and ck.created.contains(o)) { ...c1, d: Inf } else c1
             }),
      pub' = Objs.mapBy(o =>
               if (pub.get(o) < 0 and nb.get(o).in and nb.get(o).root > 0) nb.get(o).root
               else pub.get(o)),
      droppedRoots' = if (not(publish)) droppedRoots
                      else dr1.union(if (GuardEndedCreated) ended else Set()),
      gen' = if (publish) gen + 1 else gen,
      nextId' = BumpedId,
      cookie' = if (FixHeaderCookieMax) Max(Set(cookie, ck.hdr)) else ck.hdr,
      durable' = Max(Set(ck.old, ck.snap)),
      ck' = { ...ck, pc: nextPc, pending: Set(), ops: if (failed) Set() else ck.ops,
        history: if (ck.pending != Set() and ck.history.contains("failedCommitted"))
                   ck.history.union(Set("repairedRoots"))
                 else if (failed and ck.frame > 0 and ck.ops.exists(op => op.op == "alloc"))
                   ck.history.union(Set("failedCommitted", "cleanupPublished"))
                 else ck.history },
      clock' = clock, lastCommitted' = lastCommitted, ddl' = ddl, pubCookie' = pubCookie,
      tid' = tid, ddlLog' = ddlLog, UnchangedRowVars, wal' = wal, nBackfill' = nBackfill,
      db' = db, backfillFloor' = backfillFloor, nCk' = nCk, rd' = rd, seen' = seen,
      err' = err, gcs' = gcs,
    }
  }

  // PASSIVE WAL checkpoint: never past the lowest pinned read mark.
  action CheckpointBackfill: bool = {
    // With CatalogReads, an open DDL transaction holds its WAL mark too, as
    // WritersPinMarks of MvccPassiveCheckpoint.qnt. backfill_floor and so
    // catalog GC depend on it.
    val ddlMark = if (CatalogReads and ddl.pc != "none") Set(ddl.mark) else Set()
    val limit = Min(Pinned.map(r => rd.get(r).mark).union(Set(wal.length())).union(ddlMark))
    all {
      ck.pc == "published",
      // TRUNCATE copies every frame and restarts the WAL, so it needs every
      // read lock free. checkpoint_wal passes Busy up in this mode
      // (csm.rs:3386-3405). WAL restart is not modeled.
      Mode == "truncateFlagOn" implies not(TruncateBusy),
      nondet upTo = (if (Mode == "truncateFlagOn") Set(wal.length())
                     else nBackfill.to(limit)).oneOf()
      all {
        db' = if (upTo > nBackfill) Frame(upTo) else db,
        nBackfill' = upTo,
      },
      ck' = { ...ck, pc: "backfilled" },
      bind' = bind, wal' = wal, durable' = durable, backfillFloor' = backfillFloor,
      nCk' = nCk,
      UnchangedForCheckpoint, err' = err,
    }
  }

  action CheckpointTruncateLog: bool = all {
    ck.pc == "backfilled",
    ck' = { ...ck, pc: "truncated" },
    bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint, err' = err,
  }

  // The newest committed event of the sqlite_schema row of o: its drop, its
  // ALTER, or its create. 0 when none.
  def CatTerm(o: str): int = {
    val ts = Set(cat.get(o).c, cat.get(o).a, cat.get(o).d)
               .filter(t => t != 0 and t != Inf and Resolved(t))
    if (ts == Set()) 0 else Max(ts)
  }

  // stamp_chain_materialized on the sqlite_schema rows of this pass: a row
  // whose newest event is in the window is in the B-tree at this frame. A
  // drop after the snapshot leaves the row unstamped. So does an open DDL
  // on the row, whose version still carries its TxID.
  def StampCatalog(frame: int): str -> SCat =
    if (not(CatalogReads) or frame == 0) scat
    else Objs.mapBy(o =>
      if (and {
            InWindow(CatTerm(o)), not(scat.get(o).gone),
            not(ddl.pc != "none" and ddl.o == o),
          })
        { ...scat.get(o), mat: frame }
      else scat.get(o))

  // The sqlite_schema chains after the stamp and the GC of CheckpointFinish.
  val FinishCatalog: str -> SCat = {
    val st = StampCatalog(ck.frame)
    val ddlMark = if (CatalogReads and ddl.pc != "none") Set(ddl.mark) else Set()
    // gc_floor_reader_mark (csm.rs:2237-2250): the marks in txs and the
    // pager pins. An owner whose pin the pager commit ended is still in txs.
    val floor = Min(Pinned.union(Registered).map(r => rd.get(r).mark)
                      .union(Set(nBackfill)).union(ddlMark))
    Objs.mapBy(o =>
      if (CatalogReads and CatGcOk(o, st.get(o), floor)) { ...NoSCat, gone: true }
      else st.get(o))
  }

  // TruncateWal and the stamp: set backfill_floor, stamp the row versions
  // that this pass wrote, and drop retired bindings (gc_rootpage_entries).
  action CheckpointFinish: bool = all {
    ck.pc == "truncated",
    backfillFloor' = nBackfill,
    chain' = Objs.mapBy(o =>
               if (ck.written.contains(o))
                 chain.get(o).map(v => if (v.b <= ck.snap) { ...v, mat: ck.frame } else v)
               else chain.get(o)),
    // GcTableRows and the passive Finalize sweep run the same rules on every
    // row, with the pager-pinned readers and the new backfill_floor as the
    // floor (gc_floor_reader_mark, checkpoint_state_machine.rs:2237-2250).
    scat' = FinishCatalog,
    seen' = if (Objs.exists(o => FinishCatalog.get(o).gone and not(scat.get(o).gone)
                                 and CatDropped(o)))
              seen.union(Set("CatalogGcDropped")) else seen,
    bind' = Objs.mapBy(x =>
              if (bind.get(x).in and bind.get(x).end != Inf
                  and (not(GuardBindingGcLwm) or bind.get(x).end <= Lwm))
                NoBind
              else bind.get(x)),
    ck' = { ...IdleCk, history: ck.history },
    clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars, ins' = ins,
    omap' = omap,
    wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable, nCk' = nCk,
    rd' = rd, err' = err, gcs' = gcs,
  }

  // Readers or a DDL hold a WAL read lock, so a TRUNCATE backfill fails.
  val TruncateBusy: bool = Pinned != Set() or (CatalogReads and ddl.pc != "none")

  action CheckpointFail(at: str): bool = all {
    CheckpointFailures or (Mode == "truncateFlagOn" and at == "published" and TruncateBusy),
    ck.pc == at,
    if (FixCleanupPublishes and at == "committed") ApplyCheckpointPublish("idle", true)
    else all {
      ck' = { ...ck, pc: "idle", ops: Set(),
        pending: if (FixPublishFailedCommit and at == "committed") ck.ops else ck.pending,
        history: if (at == "committed" and ck.frame > 0
                     and ck.ops.exists(op => op.op == "alloc"
                       and Frame(ck.frame).img.get(op.p).own == op.o))
                   ck.history.union(Set("failedCommitted")) else ck.history },
      bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
      backfillFloor' = backfillFloor, nCk' = nCk,
      UnchangedForCheckpoint, err' = err,
    },
  }

  action CheckpointResumePublish: bool = all {
    FixPublishFailedCommit,
    ck.pc == "idle",
    ck.pending != Set(),
    ck' = { ...ck, pc: "committed", ops: ck.pending },
    bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, nCk' = nCk,
    UnchangedForCheckpoint, err' = err,
  }

  // ---------------------------------------------------------------------------
  // Garbage collection of the version store

  // Rule 3: drop the last current version when the B-tree has it for every
  // reader and no reader is open.
  action Gc(o: str): bool = all {
    not(GcSamplesFirst),
    chain.get(o) != Set(),
    chain.get(o).forall(v => v.mat != 0 and v.mat <= GcFloor),
    Lwm == Inf,
    chain' = chain.set(o, Set()),
    clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars, ins' = ins,
    scat' = scat, omap' = omap, UnchangedStoreVars, rd' = rd, seen' = seen, err' = err,
  }

  // gc_version_chain on the sqlite_schema row of o (table id -1). The model
  // drops the whole chain in one step. Rule 2 drops a dropped row once no
  // reader began before the drop. Rule 3 drops a live row only when no reader
  // is open. Both need the newest state in the B-tree for every reader. An
  // open DDL transaction holds the lwm below MAX (mod.rs:7995-8007), so GC
  // waits for it.
  def CatDropped(o: str): bool = cat.get(o).d != Inf and Resolved(cat.get(o).d)

  // An open DDL transaction began after every committed drop, so it never
  // holds Rule 2 back. Its own row has no stamp (DdlExec).
  def CatGcOkWith(o: str, x: SCat, floor: int, lwm: int, idle: bool): bool = {
    val d = cat.get(o).d
    val dropped = CatDropped(o)
    and {
      cat.get(o).c != 0,
      not(x.gone),
      x.mat != 0,
      GuardCatalogGcFloor implies x.mat <= floor,
      GuardCatalogGcLwm implies (if (dropped) d <= lwm else idle),
    }
  }

  // compute_lwm == MAX: no registered reader and no open DDL transaction.
  val NoTx: bool = Lwm == Inf and ddl.pc == "none"

  def CatGcOk(o: str, x: SCat, floor: int): bool = CatGcOkWith(o, x, floor, Lwm, NoTx)

  action GcCatalog(o: str): bool = {
    all {
      CatalogReads,
      not(GcSamplesFirst),
      // compute_min_reader_mark counts the read mark of an open DDL. The
      // backfill limit already keeps backfillFloor at or below it.
      CatGcOk(o, scat.get(o), Min(Set(GcFloor).union(
        if (ddl.pc != "none") Set(ddl.mark) else Set()))),
      scat' = scat.set(o, { ...NoSCat, gone: true }),
      seen' = if (CatDropped(o)) seen.union(Set("CatalogGcDropped")) else seen,
      clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars, chain' = chain,
      ins' = ins, omap' = omap, UnchangedStoreVars, rd' = rd, err' = err,
    }
  }

  /* gc_incremental in steps (GcSamplesFirst).
     GcSample      sample_gc_lwm under the clock lock (mod.rs:8244, 8139-8145),
                   then durable_txid_max and the floor (mod.rs:8261-8266),
                   before any chain lock.
     GcApply       one chain under its write lock with the sampled values
                   (mod.rs:8282-8290). gc_chain_now computes a sampled MAX
                   again, without the clock lock (mod.rs:8162-8166).
     GcIndexPhase  gc_index_incremental keeps the lwm and reads the floor
                   again (mod.rs:8307, 8356-8358).
     GcEnd         the call returns. The budget of MAX_CHAINS_PER_GC chains
                   (mod.rs:8019, 8278, 8366, 8382) only limits how many
                   chains one call visits. The rest wait for a later call
                   with a new sample (cursors at mod.rs:8302, 8404). A model
                   call may apply to any subset of chains, so every budget
                   and cursor position is a model run.
     Rule 1 (aborted versions) and Rule 2 (ended versions, mod.rs:8591-8620)
     find nothing in a row chain of this spec: a row is inserted once and
     never updated, deleted or rolled back. The sqlite_schema chain of a
     dropped table is Rule 2 (CatGcOkWith). rootpage_gc_protected
     (mod.rs:8282, 8372) is left out, as for Gc (StampsAtOrAfterBinding). */
  // compute_min_reader_mark counts the read mark of an open DDL transaction.
  val DdlMarks: Set[int] = if (CatalogReads and ddl.pc != "none") Set(ddl.mark) else Set()
  val GcFloorNow: int = Min(Set(GcFloor).union(DdlMarks))

  val GcIdleNow: bool = if (GuardGcRechecksIdleLwm and gcs.idle) NoTx else gcs.idle
  val GcLwmNow: int = if (GuardGcRechecksIdleLwm and gcs.idle) Lwm else gcs.lwm

  // Outcomes of a GC step that drops a chain, for the reachability checks.
  val GcSeen: Set[str] =
    (if (Registered.exists(r => rd.get(r).b > gcs.at)) Set("GcAfterBegin") else Set())
      .union(if (Readers.exists(r => rd.get(r).pc == "pinned")) Set("GcWithPinned") else Set())

  action UnchangedForGc = all {
    clock' = clock, lastCommitted' = lastCommitted, UnchangedSchemaVars, ins' = ins,
    omap' = omap, bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
    backfillFloor' = backfillFloor, ck' = ck, nCk' = nCk, rd' = rd, err' = err,
  }

  action GcSample: bool = all {
    GcSamplesFirst,
    gcs.pc == "idle",
    // Only Rule 2 of a sqlite_schema chain reads the lwm value. Without
    // CatalogReads the sample keeps 0, so TLC does not split states on it.
    gcs' = { pc: "sampled", at: clock, lwm: if (CatalogReads) Lwm else 0, idle: NoTx,
             floor: GcFloorNow },
    chain' = chain, scat' = scat, seen' = seen,
    UnchangedForGc,
  }

  // Rule 3 on the row chain of o.
  action GcApply(o: str): bool = all {
    if (Indexes.contains(o)) gcs.pc == "index" else gcs.pc == "sampled",
    chain.get(o) != Set(),
    chain.get(o).forall(v => v.mat != 0 and v.mat <= gcs.floor),
    GcIdleNow,
    chain' = chain.set(o, Set()),
    seen' = seen.union(GcSeen),
    scat' = scat, gcs' = gcs,
    UnchangedForGc,
  }

  // Rule 2 or Rule 3 on the sqlite_schema chain of o (table id -1, a table chain).
  action GcApplyCatalog(o: str): bool = all {
    CatalogReads,
    gcs.pc == "sampled",
    CatGcOkWith(o, scat.get(o), gcs.floor, GcLwmNow, GcIdleNow),
    scat' = scat.set(o, { ...NoSCat, gone: true }),
    seen' = seen.union(GcSeen).union(if (CatDropped(o)) Set("CatalogGcDropped") else Set()),
    chain' = chain, gcs' = gcs,
    UnchangedForGc,
  }

  action GcIndexPhase: bool = all {
    Indexes != Set(),
    gcs.pc == "sampled",
    gcs' = { ...gcs, pc: "index", floor: GcFloorNow },
    chain' = chain, scat' = scat, seen' = seen,
    UnchangedForGc,
  }

  action GcEnd: bool = all {
    Set("sampled", "index").contains(gcs.pc),
    gcs' = IdleGc,
    chain' = chain, scat' = scat, seen' = seen,
    UnchangedForGc,
  }

  // ---------------------------------------------------------------------------
  // Owner path: an inner transaction commits on a reader's connection

  // A statement of reader r calls nextval. The inner transaction
  // (op_sequence_begin_inner_tx, execute.rs:14356-14420) commits a sequence
  // row, which this spec does not model. Its CommitStateMachine runs on r's
  // connection, removes the inner tx and starts the auto-checkpoint there
  // (mod.rs:3698-3721), while r's outer snapshot stays in txs. The inner
  // begin returns Busy during an unpublished DDL commit, as ReaderBegin.
  // With FixRefuseCheckpointOwner the commit starts no checkpoint, and the
  // commit alone changes nothing that this spec models, so the action is off.
  action InnerCommitCheckpoint(r: str): bool = {
    val c = clock + 1
    all {
      CheckpointOwnerReaders,
      not(FixRefuseCheckpointOwner),
      Mode == "passive",
      Set("active", "open").contains(rd.get(r).pc),
      not(GuardBusyOnUnpublished and ddl.pc == "preparing"),
      clock < MaxTs,
      ck.pc == "idle", ck.pending == Set(), nCk < MaxCheckpoints,
      clock' = c,
      lastCommitted' = Max(Set(lastCommitted, c)),
      ck' = { ...IdleCk, pc: "collect", owner: r, auto: true,
              snap: if (ddl.pc == "preparing") Min(Set(c, ddl.ts - 1)) else c,
              old: durable, todo: Objs, img: LastImg.img, bcat: LastImg.bcat,
              history: ck.history },
      nCk' = nCk + 1,
      UnchangedSchemaVars, UnchangedRowVars,
      bind' = bind, wal' = wal, nBackfill' = nBackfill, db' = db, durable' = durable,
      backfillFloor' = backfillFloor, gcs' = gcs, rd' = rd, seen' = seen, err' = err,
    }
  }

  // ---------------------------------------------------------------------------
  // Specification

  // The order of the nondets gives the order in which TLC visits the
  // successors of a state. It decides only how many states TLC has found
  // when it stops at a violation.
  action Next = any {
    nondet kind = DdlKinds.oneOf()
    nondet o = Objs.oneOf()
    DdlExec(o, kind),
    DdlPrepare,
    DdlFinish,
    nondet o = Objs.oneOf()
    WriteRow(o),
    all {
      Readers != Set(),
      nondet r = Readers.oneOf()
      any {
        nondet o = Objs.oneOf()
        ReaderPrepare(r, o),
        ReaderPin(r),
        nondet inner = Bool.oneOf()
        ReaderBegin(r, inner),
        ReaderOpen(r),
        ReaderRead(r),
        ReaderReadCatalog(r),
        ReaderEnd(r),
        InnerCommitCheckpoint(r),
      },
    },
    nondet at = Set("collect", "committed", "published", "backfilled", "truncated").oneOf()
    CheckpointFail(at),
    CheckpointResumePublish,
    CheckpointStart,
    nondet o = Objs.oneOf()
    CheckpointObj(o),
    nondet o = Objs.oneOf()
    CheckpointObjAlter(o),
    CheckpointCommit,
    CheckpointPublish,
    CheckpointPublishRoots,
    CheckpointPublishHeader,
    CheckpointPublishSchema,
    CheckpointPublishGen,
    CheckpointBackfill,
    CheckpointTruncateLog,
    CheckpointFinish,
    nondet o = Objs.oneOf()
    Gc(o),
    nondet o = Objs.oneOf()
    GcCatalog(o),
    GcSample,
    nondet o = Objs.oneOf()
    GcApply(o),
    nondet o = Objs.oneOf()
    GcApplyCatalog(o),
    GcIndexPhase,
    GcEnd,
  }

  // ---------------------------------------------------------------------------
  // Properties

  // A reader reads only its own table's pages, and gets the row of its table
  // at begin_ts.
  val ReadsCorrect: bool = not(err.exists(e => e.kind == "read"))

  // A scan of sqlite_schema returns one row for each object that exists at
  // the reader's snapshot, and no other row (#8093).
  val CatalogReadsCorrect: bool = not(err.exists(e => e.kind == "catalog"))

  // A scan of sqlite_schema never returns a dropped object together with an
  // object created at or after the drop (#8094).
  val CatalogNoTwoGenerations: bool = not(err.exists(e => e.kind == "catalog-gen"))

  // No reader hits a panic (unmapped page, negative page), and no open fails
  // for a table that the reader's snapshot sees.
  val OpenCorrect: bool = not(err.exists(e => Set("panic", "spurious").contains(e.kind)))

  // No page has two live bindings, and no two tables share a temporary id.
  val NoSharedOwner: bool = and {
    tuples(Objs, Objs).forall(((x, y)) =>
      (x != y and bind.get(x).in and bind.get(y).in and bind.get(x).root > 0
       and bind.get(x).root == bind.get(y).root)
      implies not(bind.get(x).end == Inf and bind.get(y).end == Inf)),
    tuples(Objs, Objs).forall(((x, y)) =>
      (x != y and tid.get(x) != 0) implies tid.get(x) != tid.get(y)),
  }

  // The header cookie is never behind the shared schema. Otherwise every new
  // statement fails its cookie check (#11499).
  val CookieNotBehind: bool = cookie >= pubCookie

  /* Crash recovery (bootstrap and logical log replay in mod.rs).
     1. Each table in the B-tree catalog of the newest frame with page P gets
        table id -P.
     2. DDL records above the boundary replay in order. A CREATE record whose
        negative rootpage is already the id of a table with a page panics
        ("has both a negative root page and a positive root page").
     3. A row record above the boundary goes to the table whose id it
        carries. A record that carries a temporary id of a table that is now
        in the B-tree finds no table, unless the B-tree keeps that id.
     4. An ALTER record above the boundary carries the new sqlite_schema row.
        With a page as rootpage, recovery checks that the page is the table's.
        With a negative rootpage that is already the id of a table with a
        page, recovery panics, as for a CREATE. With a negative rootpage that
        no table has, the row gets a new empty table id, and the table loses
        its B-tree page. */
  val Boot: str -> int = LastImg.bcat
  val Meta: int = LastImg.meta

  def BootOwner(id: int): Set[str] =
    Objs.filter(x => Pages.contains(Boot.get(x))
                     and (-Boot.get(x) == id or (FixPersistIds and tid.get(x) == id)))

  val ReplayedCreates: Set[LogRec] = ddlLog.filter(l => l.ts > Meta and l.kind == "create")

  val RecoveryPanics: bool = ReplayedCreates.exists(l => BootOwner(l.root) != Set())

  def RowTarget(o: str): Set[str] = {
    val id = ins.get(o).id
    if (BootOwner(id) != Set()) BootOwner(id)
    else ReplayedCreates.filter(l2 => l2.root == id).map(l => l.o)
  }

  def Replay(o: str): Set[LogRec] = ddlLog.filter(l => l.o == o and l.ts > Meta)

  // CHOOSE l \in Replay(o) : \A l2 \in Replay(o) : l2.ts <= l.ts
  def LastReplay(o: str): LogRec =
    Replay(o).fold({ o: "", kind: "", ts: -1, root: 0 }, (a, l) =>
      if (a.ts == -1 and Replay(o).forall(l2 => l2.ts <= l.ts)) l else a)

  def RecoveredLive(o: str): bool =
    if (Replay(o) != Set()) LastReplay(o).kind != "drop"
    else Pages.contains(Boot.get(o))

  // FixAlterRecovery: a negative rootpage that bootstrap maps to the same
  // table (FixPersistIds) is an update of that table.
  def AlterReplayOk(l: LogRec): bool =
    if (l.root > 0) Boot.get(l.o) == l.root
    else if (BootOwner(l.root) != Set()) FixAlterRecovery and BootOwner(l.root) == Set(l.o)
    else not(Pages.contains(Boot.get(l.o)))

  def LoggedLive(o: str): bool = and {
    ddlLog.exists(l => l.o == o and l.kind == "create"),
    not(ddlLog.exists(l => l.o == o and l.kind == "drop")),
  }

  // The row of a live table after recovery: from its log record when that is
  // above the boundary, else from its B-tree page.
  def RowRecovered(o: str): bool =
    if (ins.get(o).ts == 0) true
    else if (ins.get(o).ts > Meta) RowTarget(o) == Set(o)
    else Pages.contains(Boot.get(o)) and LastImg.img.get(Boot.get(o)).value == ins.get(o).ts

  val RecoveryCorrect: bool = and {
    not(RecoveryPanics),
    ddlLog.forall(l => (l.kind == "alter" and l.ts > Meta) implies AlterReplayOk(l)),
    Objs.forall(o => RecoveredLive(o) == LoggedLive(o)),
    Objs.forall(o => LoggedLive(o) implies RowRecovered(o)),
    Objs.forall(o => Pages.contains(Boot.get(o)) implies LastImg.img.get(Boot.get(o)).own == o),
    Pages.forall(p => LastImg.img.get(p).own != NoObj
                      implies Boot.get(LastImg.img.get(p).own) == p),
  }

  // A log record and a root page resolve to an object of the same kind and
  // the same table: no table row lands in an index B-tree, and no index row
  // lands in a table B-tree (#7960).
  pure def SameObj(x: str, o: str): bool = KindOf(x) == KindOf(o) and TableOf(x) == TableOf(o)

  val KindsMatch: bool = and {
    Objs.forall(o => ins.get(o).ts > Meta implies RowTarget(o).forall(x => SameObj(x, o))),
    Readers.forall(r => rd.get(r).pc == "open" implies SameObj(rd.get(r).tid, rd.get(r).o)),
  }

  // No checkpoint destroys the B-tree of an object that is not dropped at its
  // snapshot (#8077).
  val NoLiveDestroy: bool = not(err.exists(e => e.kind == "destroy-live"))

  // Every stamped version of an object has a stamp at or after the frame of
  // the object's B-tree binding. GC drops only versions stamped at or below
  // the floor, so a binding above the floor keeps every version of its object
  // without a separate guard (rootpage_gc_protected).
  val StampsAtOrAfterBinding: bool =
    Objs.forall(o => (bind.get(o).in and bind.get(o).root > 0) implies
                     chain.get(o).forall(v => v.mat == 0 or v.mat >= bind.get(o).mat))

  // GC is never enabled on an object whose binding is above the floor. The
  // guard rootpage_gc_protected blocked GC in that state.
  val GcNeverRunsUnderNewerBinding: bool =
    not(Objs.exists(o => and {
      chain.get(o) != Set(),
      bind.get(o).in,
      or {
        and {
          chain.get(o).forall(v => v.mat != 0 and v.mat <= GcFloor),
          Lwm == Inf, bind.get(o).mat > GcFloor,
        },
        // A sampled GC call applies its older floor.
        and {
          gcs.pc != "idle",
          chain.get(o).forall(v => v.mat != 0 and v.mat <= gcs.floor),
          GcIdleNow, bind.get(o).mat > gcs.floor,
        },
      },
    }))

  // The current sqlite_schema row of a live table points at its live B-tree.
  // A negative rootpage is right only while the table has no page.
  def NewestRoot(o: str): int =
    if (cat.get(o).a != 0 and Resolved(cat.get(o).a)) cat.get(o).r2 else cat.get(o).r1

  // A publish has started and has not reached the shared schema yet.
  val PublishPending: bool = Set("committed", "roots", "header").contains(ck.pc)

  val SchemaRowCurrent: bool =
    not(PublishPending) implies
      Objs.forall(o =>
        (Alters and cat.get(o).c != 0 and Resolved(cat.get(o).c) and cat.get(o).d == Inf)
        implies and {
          NewestRoot(o) > 0 implies (bind.get(o).in and bind.get(o).root == NewestRoot(o)
                                     and bind.get(o).end == Inf),
          NewestRoot(o) < 0 implies not(bind.get(o).in and bind.get(o).root > 0),
        })

  // integrity_check: every allocated page of the published B-tree is a root of
  // the shared schema (a negative root resolves through its binding) or is in
  // dropped_root_pages. Checked when no publish is pending.
  def SchemaRoot(p: int): bool =
    Objs.exists(o => or {
      pub.get(o) == p,
      pub.get(o) < 0 and bind.get(o).in and bind.get(o).root == p,
    })

  val NoLeakedPages: bool =
    1.to(wal.length()).forall(i => Pages.forall(p =>
      Frame(i).img.get(p).own != NoObj implies Objs.exists(o => Frame(i).bcat.get(o) == p)))

  val PagesAccounted: bool =
    (not(PublishPending) and ck.pending == Set()) implies
      Pages.forall(p => LastImg.img.get(p).own != NoObj
                        implies (SchemaRoot(p) or droppedRoots.contains(p)))

  // Sync push: the object map of the commit of each row names the table of
  // the row. The client decodes the row with that name
  // (decode_recovery_ops_to_logical_txn, database_sync_operations.rs:1319).
  // A wrong name sends the row to another table. No name drops the row on
  // the client, or fails the commit in core.
  val ObjectMapCorrect: bool =
    SyncObjectMap implies
      Objs.forall(o => (not(Indexes.contains(o)) and ins.get(o).ts != 0) implies omap.get(o) == o)

  // Sync pull: read_logical_replay_table_map (database_sync_operations.rs:2588)
  // keys each table by the absolute value of its rootpage column. No two
  // live tables get the same stable id.
  val StableIdsDistinct: bool =
    SyncObjectMap implies
      tuples(Objs, Objs).forall(((x, y)) =>
        (x != y and LiveTable(x) and LiveTable(y)) implies Abs(RootCol(x)) != Abs(RootCol(y)))

  val TypeOK: bool = and {
    0.to(MaxTs).contains(clock),
    0.to(wal.length()).contains(nBackfill),
    wal.length() <= MaxCheckpoints,
    Pinned.forall(r => nBackfill <= rd.get(r).mark),
  }

  // ---------------------------------------------------------------------------
  // Reachability checks. Each one must be violated.

  // An object with versions has a binding above the floor, so
  // rootpage_gc_protected would skip it.
  val Safety: bool = and {
    TypeOK, ReadsCorrect, OpenCorrect, NoSharedOwner, RecoveryCorrect, PagesAccounted,
    CookieNotBehind, KindsMatch, NoLiveDestroy, SchemaRowCurrent,
    StampsAtOrAfterBinding, GcNeverRunsUnderNewerBinding, NoLeakedPages,
  }

  val NeverCleanupPublishes: bool = not(ck.history.contains("cleanupPublished"))

  val NeverFailsBeforePublish: bool = not(ck.history.contains("failedCommitted"))
  val NeverRepairsRoots: bool = not(ck.history.contains("repairedRoots"))

  val NeverRootGuardFires: bool =
    not(Objs.exists(o => chain.get(o) != Set() and bind.get(o).in and bind.get(o).mat > GcFloor))

  val NeverReusesPage: bool =
    not(tuples(1.to(wal.length()), 1.to(wal.length())).exists(((i, j)) =>
      Pages.exists(p => and {
        Frame(i).img.get(p).own != NoObj, Frame(j).img.get(p).own != NoObj,
        Frame(i).img.get(p).own != Frame(j).img.get(p).own,
      })))
  val NeverSchemaUpdatedCookie: bool = not(seen.contains("SchemaUpdatedCookie"))
  val NeverSchemaUpdatedGen: bool = not(seen.contains("SchemaUpdatedGen"))
  val NeverBusy: bool = not(seen.contains("Busy"))
  val NeverReadsOldOwner: bool = not(seen.contains("ReadOldOwner"))
  // A catalog scan runs while the newest frame has the row of a table that
  // the reader's snapshot does not see (the shape of #8093).
  val NeverCatalogNewer: bool = not(seen.contains("CatalogNewer"))
  // A catalog scan runs while the newest frame has the next generation of a
  // table that the reader sees, and not the old one (the shape of #8094).
  val NeverCatalogGenerations: bool = not(seen.contains("CatalogGenerations"))
  // GC drops the sqlite_schema chain of a dropped table (Rule 2).
  val NeverCatalogGcDropped: bool = not(seen.contains("CatalogGcDropped"))
  // A DROP runs on a table whose sqlite_schema chain GC dropped, so the
  // chain gets a tombstone.
  val NeverCatalogTomb: bool = not(seen.contains("CatalogTomb"))
  // A catalog scan returns a row from the B-tree because GC dropped its
  // versions from the version store.
  val NeverCatalogFromBtree: bool = not(seen.contains("CatalogFromBtree"))
  // A row record carries the id -page: the table had its page at the commit.
  val NeverMapsPageId: bool =
    not(Objs.exists(o => ins.get(o).ts != 0 and ins.get(o).id != tid.get(o)))
  // A row commits with its temporary id while a pass that creates its
  // B-tree runs, before the publish.
  val NeverMapsInPass: bool = not(seen.contains("MapInPass"))
  // A row commit finds its name only in the sqlite_schema versions: no
  // schema knows the record id.
  val NeverMapsFromCatalog: bool = not(seen.contains("MapFromCatalog"))
  // The binding branch of MapNames gives the name. It must hold in the sync
  // modules with FixDisjointIds (see MapNames).
  val NeverMapsFromBinding: bool = not(seen.contains("MapFromBinding"))
  // The stable id of a live table changed after a row record carried its
  // temporary id: the rootpage column now holds its page (SYNC.md question 2).
  val NeverStableIdChanges: bool =
    not(Objs.exists(o => and {
      LiveTable(o), ins.get(o).ts != 0, ins.get(o).id == tid.get(o), RootCol(o) > 0,
    }))
  // Recovery replays a row record above the boundary.
  val NeverReplaysRow: bool =
    not(Objs.exists(o => LoggedLive(o) and ins.get(o).ts > Meta and Meta > 0))
  // Mode T: a reader begins between two parts of the publish.
  val NeverBeginsMidPublish: bool = not(seen.contains("BeginMidPublish"))
  // An inner commit's auto-checkpoint commits a frame on the connection of a
  // reader that is still in txs and still pinned.
  val NeverAutoCheckpointOnReader: bool = not(ck.history.contains("autoOwnerCommit"))
  // GC drops a chain after a reader began between the sample and the drop.
  val NeverGcAfterBegin: bool = not(seen.contains("GcAfterBegin"))
  // GC drops a chain while a reader pinned a WAL mark and is not in txs yet.
  val NeverGcWithPinned: bool = not(seen.contains("GcWithPinned"))
  // A negative schema root with a root page outlives the publish.
  val NeverOwnedNegative: bool =
    ck.pc == "idle" implies
      not(Objs.exists(o => pub.get(o) < 0 and bind.get(o).in and bind.get(o).root > 0))
}
