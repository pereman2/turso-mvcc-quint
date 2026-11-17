//! Driver for traces of `MvccPassiveSchema.qnt`: spec object `o` is a table
//! `o(k INTEGER PRIMARY KEY, v INTEGER)`, and its one row has key 1 and the
//! spec commit timestamp of its insert as value. The engine picks root pages
//! and table ids itself, so the driver compares what recovery sees, not the
//! numbers. A reader begins with `BEGIN CONCURRENT` and checks only its scans of
//! sqlite_schema. Its table reads (ReaderOpen, ReaderRead) run no engine
//! operation.

use std::collections::{BTreeMap, HashMap};

use super::itf::{Itf, Step};
use super::*;

/// The DDL transaction between DdlExec and DdlFinish.
struct Ddl {
    tx_id: u64,
    commit: Option<crate::Statement>,
}

/// A spec reader. The engine pins the WAL mark and begins in one step, so
/// the engine reader starts at ReaderBegin.
enum Reader {
    Pinned { mark: i64 },
    Active,
}

pub(super) struct SchemaDriver {
    db: MvccTestDbNoConn,
    io: Arc<dyn IO>,
    ck: Checkpointer,
    ddl_conn: Arc<Connection>,
    ddl_stop: Arc<StopAt>,
    ddl: Option<Ddl>,
    writer: Arc<Connection>,
    readers: HashMap<String, (Arc<Connection>, Reader)>,
    /// The rowid of the sqlite_schema row and the table id of each created
    /// spec table.
    schema_rowids: HashMap<String, i64>,
    table_ids: HashMap<String, MVTableId>,
    /// The lwm and the floor that GcSample took for the GC call in progress.
    gc_sample: Option<(u64, WalPos)>,
}

/// The owner of the pass, or "" in a trace from before the owner path.
fn ck_owner(step: &Step) -> &str {
    match step.var("ck") {
        Itf::Rec(fields) => fields.get("owner").map_or("", |o| o.str()),
        _ => "",
    }
}

impl Driver for SchemaDriver {
    fn run_step(&mut self, _index: usize, step: &Step) -> StepOutcome {
        match step.action.as_str() {
            "DdlExec" => self.ddl_exec(step)?,
            "DdlPrepare" => self.ddl_prepare()?,
            "DdlFinish" => self.ddl_finish(step)?,
            "WriteRow" => self.write_row(step)?,
            "ReaderPrepare" | "ReaderOpen" | "ReaderRead" => {}
            "ReaderPin" => self.reader_pin(step),
            "ReaderBegin" => self.reader_begin(step)?,
            "ReaderReadCatalog" => self.reader_read_catalog(step)?,
            "ReaderEnd" => self.reader_end(step),
            "GcCatalog" => self.gc_catalog(step)?,
            "Gc" => self.gc_row(step)?,
            "GcSample" => self.gc_sample(),
            "GcApply" => self.gc_apply(step, false)?,
            "GcApplyCatalog" => self.gc_apply(step, true)?,
            "GcEnd" => self.gc_sample = None,
            "GcIndexPhase"
            | "InnerCommitCheckpoint"
            | "CheckpointPublishRoots"
            | "CheckpointPublishHeader"
            | "CheckpointPublishSchema"
            | "CheckpointPublishGen" => {
                return refuse(format!("no engine operation for {}", step.action));
            }
            "CheckpointStart" => {
                if ck_owner(step) != "" {
                    return refuse("a checkpoint on the connection of a spec reader");
                }
                self.ck.start(usize::MAX)
            }
            "CheckpointObj" => self.checkpoint_obj(step)?,
            "CheckpointCommit" => self.checkpoint_commit(step)?,
            "CheckpointPublish" => self
                .ck
                .step_until(|state| state == CheckpointState::CheckpointWal),
            "CheckpointBackfill" => self
                .ck
                .step_until(|state| state == CheckpointState::TruncateLogicalLog),
            // CheckpointFinish runs the logical log truncate with the rest of the pass.
            "CheckpointTruncateLog" => {}
            "CheckpointFinish" => self.ck.finish(),
            other => return refuse(format!("no engine operation for {other}")),
        }
        self.check_cookie()?;
        self.check_catalog_chains(step)?;
        self.check_recovery(step)
    }
}

impl SchemaDriver {
    pub(super) fn new() -> Self {
        let db = MvccTestDbNoConn::new_with_random_db_passive();
        let setup = db.connect();
        setup
            .execute("PRAGMA mvcc_checkpoint_threshold = -1")
            .unwrap();
        setup.execute("PRAGMA mvcc_gc_threshold = -1").unwrap();
        // The spec never gives a table a temporary id -P for a page P. Two
        // dropped tables leave free pages above the metadata table and move
        // the next temporary id below them, so the engine does not either.
        for sql in [
            "CREATE TABLE pad1(x)",
            "CREATE TABLE pad2(x)",
            "PRAGMA wal_checkpoint(TRUNCATE)",
            "DROP TABLE pad1",
            "DROP TABLE pad2",
            "PRAGMA wal_checkpoint(TRUNCATE)",
        ] {
            setup.execute(sql).unwrap();
        }
        setup.close().unwrap();
        let ck = Checkpointer::new(&db, db.get_mvcc_store());
        let (ddl_conn, ddl_stop) = connect_with_stop(&db);
        let writer = db.connect();
        Self {
            io: ck.io.clone(),
            db,
            ck,
            ddl_conn,
            ddl_stop,
            ddl: None,
            writer,
            readers: HashMap::new(),
            schema_rowids: HashMap::new(),
            table_ids: HashMap::new(),
            gc_sample: None,
        }
    }

    fn ddl_exec(&mut self, step: &Step) -> StepOutcome {
        let table = step.pick("o").str();
        let sql = match step.pick("kind").str() {
            "create" => format!("CREATE TABLE {table}(k INTEGER PRIMARY KEY, v INTEGER)"),
            "drop" => format!("DROP TABLE {table}"),
            kind => return refuse(format!("no engine operation for DDL {kind}")),
        };
        self.ddl_conn.execute("BEGIN").unwrap();
        self.ddl_conn.execute(&sql).unwrap();
        self.ddl = Some(Ddl {
            tx_id: self.ddl_conn.get_mv_tx_id().unwrap(),
            commit: None,
        });
        Ok(())
    }

    fn ddl_prepare(&mut self) -> StepOutcome {
        let ddl = self.ddl.as_mut().unwrap();
        self.ddl_stop.set(
            CommitYieldPoint::CommitValidation.point(),
            Some(commit_yield_key(ddl.tx_id)),
        );
        let mut commit = self.ddl_conn.prepare("COMMIT").unwrap();
        assert!(
            step_statement(&mut commit, &self.ddl_stop, &self.io),
            "COMMIT of the DDL did not stop after it took its timestamp"
        );
        ddl.commit = Some(commit);
        Ok(())
    }

    fn ddl_finish(&mut self, step: &Step) -> StepOutcome {
        let mut commit = self.ddl.take().unwrap().commit.unwrap();
        self.ddl_stop.clear();
        assert!(
            !step_statement(&mut commit, &self.ddl_stop, &self.io),
            "COMMIT of the DDL must finish"
        );
        let table = step.var("ddl").field("o").str();
        let table = if table == "none" {
            // DdlFinish resets ddl. The finished DDL is the newest ddlLog record.
            step.var("ddlLog")
                .items()
                .iter()
                .max_by_key(|l| l.field("ts").int())
                .unwrap()
                .field("o")
                .str()
        } else {
            table
        };
        if !self.schema_rowids.contains_key(table) {
            let rows = query_rows(
                &self.writer,
                &format!("SELECT rowid, rootpage FROM sqlite_schema WHERE name = '{table}'"),
            )
            .unwrap();
            if let Some(row) = rows.first() {
                self.schema_rowids
                    .insert(table.to_string(), row[0].as_int().unwrap());
                let table_id = self
                    .ck
                    .mv
                    .get_table_id_from_root_page(row[1].as_int().unwrap());
                self.table_ids.insert(table.to_string(), table_id);
            }
        }
        Ok(())
    }

    fn reader_pin(&mut self, step: &Step) {
        let name = step.pick("r").str();
        let mark = step.var("rd").get_str(name).field("mark").int();
        let conn = match self.readers.remove(name) {
            Some((conn, _)) => conn,
            None => self.db.connect(),
        };
        self.readers
            .insert(name.to_string(), (conn, Reader::Pinned { mark }));
    }

    /// A begin that the spec refuses (Busy or SchemaUpdated) leaves the
    /// reader idle and runs nothing.
    fn reader_begin(&mut self, step: &Step) -> StepOutcome {
        let name = step.pick("r").str();
        let wal_len = step.var("wal").items().len() as i64;
        let began = step.var("rd").get_str(name).field("pc").str() == "active";
        let (conn, reader) = self.readers.get_mut(name).unwrap();
        let Reader::Pinned { mark } = *reader else {
            panic!("ReaderBegin of a reader that is not pinned");
        };
        if !began {
            self.readers.remove(name);
            return Ok(());
        }
        if mark != wal_len {
            return refuse("a checkpoint frame came between the pin and the begin of a reader");
        }
        conn.execute("BEGIN CONCURRENT").unwrap();
        query_rows(conn, "SELECT count(*) FROM sqlite_schema").unwrap();
        *reader = Reader::Active;
        Ok(())
    }

    /// CatalogReadsCorrect: the reader's scan of sqlite_schema returns each
    /// spec table that exists at its begin once, and no other spec table.
    fn reader_read_catalog(&mut self, step: &Step) -> StepOutcome {
        let name = step.pick("r").str();
        let begin = step.var("rd").get_str(name).field("b").int();
        let (conn, _) = &self.readers[name];
        let mut got: BTreeMap<String, i64> = BTreeMap::new();
        for row in query_rows(conn, "SELECT name FROM sqlite_schema WHERE type = 'table'").unwrap()
        {
            *got.entry(row[0].to_string()).or_default() += 1;
        }
        let mut want = BTreeMap::new();
        for (table, cat) in step.var("cat").entries() {
            let (c, d) = (cat.field("c").int(), cat.field("d").int());
            if c != 0 && c < begin && d >= begin {
                want.insert(table.str().to_string(), 1);
            }
        }
        got.retain(|table, _| {
            step.var("cat")
                .entries()
                .iter()
                .any(|(t, _)| t.str() == table)
        });
        if got != want {
            return fail(
                Failure::CatalogRead,
                format!("reader {name} at begin {begin} scanned {got:?}, spec oracle {want:?}"),
            );
        }
        Ok(())
    }

    fn reader_end(&mut self, step: &Step) {
        if let Some((conn, Reader::Active)) = self.readers.remove(step.pick("r").str()) {
            conn.execute("ROLLBACK").unwrap();
        }
    }

    /// One pass of gc_version_chain over the sqlite_schema row of a table,
    /// with the floors of gc_incremental.
    fn gc_catalog(&mut self, step: &Step) -> StepOutcome {
        let table = step.pick("o").str();
        let rowid = self.schema_rowids[table];
        self.gc_chain(
            table,
            RowID::new(SQLITE_SCHEMA_MVCC_TABLE_ID, RowKey::Int(rowid)),
        )
    }

    /// The version chain of the sqlite_schema row of each created table is
    /// empty exactly when the spec says that GC dropped it (scat.gone). The
    /// engine has no reader for a spec reader that pinned a mark and did not
    /// begin, so its GC floor can be higher. A trace with such a reader below
    /// the newest frame is refused when the two differ.
    fn check_catalog_chains(&self, step: &Step) -> StepOutcome {
        // Traces from before CatalogReads have no scat.
        if !step.vars.contains_key("scat") {
            return Ok(());
        }
        let wal_len = step.var("wal").items().len() as i64;
        let pinned_below = step
            .var("rd")
            .entries()
            .iter()
            .any(|(_, r)| r.field("pc").str() == "pinned" && r.field("mark").int() < wal_len);
        for (table, rowid) in &self.schema_rowids {
            let row_id = RowID::new(SQLITE_SCHEMA_MVCC_TABLE_ID, RowKey::Int(*rowid));
            let engine_gone = self
                .ck
                .mv
                .rows
                .get(&row_id)
                .is_none_or(|entry| entry.value().read().is_empty());
            let spec_gone = step.var("scat").get_str(table).field("gone").bool();
            if engine_gone == spec_gone {
                continue;
            }
            if pinned_below {
                return refuse("GC ran while a reader pinned a mark but did not begin");
            }
            // The engine backfills every frame it can, so its floor is higher
            // when the spec backfill stopped early.
            let n_backfill = step.var("nBackfill").int();
            if n_backfill < wal_len {
                return refuse("the spec backfill stopped before the last frame");
            }
            let kind = if spec_gone {
                Failure::GcKept
            } else {
                Failure::GcDropped
            };
            return fail(
                kind,
                format!("sqlite_schema row of {table}: engine chain empty {engine_gone}, spec gone {spec_gone}"),
            );
        }
        Ok(())
    }

    /// The same pass over the one row (key 1) of a table.
    fn gc_row(&mut self, step: &Step) -> StepOutcome {
        let table = step.pick("o").str();
        let table_id = self.table_ids[table];
        let mv = &self.ck.mv;
        let floor = mv.compute_min_reader_mark().min(*mv.backfill_floor.read());
        if mv.rootpage_gc_protected(&table_id, floor) {
            return refuse("rootpage_gc_protected keeps the row of a table");
        }
        self.gc_chain(table, RowID::new(table_id, RowKey::Int(1)))
    }

    fn gc_chain(&mut self, table: &str, row_id: RowID) -> StepOutcome {
        let mv = &self.ck.mv;
        let lwm = mv.sample_gc_lwm();
        let floor = mv.compute_min_reader_mark().min(*mv.backfill_floor.read());
        self.gc_chain_with(table, row_id, lwm, floor)
    }

    fn gc_chain_with(
        &mut self,
        table: &str,
        row_id: RowID,
        lwm: u64,
        floor: WalPos,
    ) -> StepOutcome {
        let mv = &self.ck.mv;
        let ckpt_max = mv.durable_txid_max.load(Ordering::SeqCst);
        if let Some(entry) = mv.rows.get(&row_id) {
            let mut versions = entry.value().write();
            mv.gc_chain_now(&mut versions, lwm, ckpt_max, floor, true);
            if !versions.is_empty() {
                return fail(
                    Failure::GcKept,
                    format!(
                        "GC kept {row_id:?} of {table}: {:?}, lwm {lwm}, floor {floor:?}, ckpt_max {ckpt_max}",
                        &*versions
                    ),
                );
            }
        }
        Ok(())
    }

    /// GcSample: the lwm and the floor of gc_incremental, before any chain lock.
    fn gc_sample(&mut self) {
        let mv = &self.ck.mv;
        let lwm = mv.sample_gc_lwm();
        let floor = mv.compute_min_reader_mark().min(*mv.backfill_floor.read());
        self.gc_sample = Some((lwm, floor));
    }

    /// GcApply and GcApplyCatalog: one chain with the values of GcSample.
    fn gc_apply(&mut self, step: &Step, catalog: bool) -> StepOutcome {
        let (lwm, floor) = self.gc_sample.expect("GcApply without GcSample");
        let table = step.pick("o").str();
        let row_id = if catalog {
            RowID::new(
                SQLITE_SCHEMA_MVCC_TABLE_ID,
                RowKey::Int(self.schema_rowids[table]),
            )
        } else {
            let table_id = self.table_ids[table];
            if self.ck.mv.rootpage_gc_protected(&table_id, floor) {
                return refuse("rootpage_gc_protected keeps the row of a table");
            }
            RowID::new(table_id, RowKey::Int(1))
        };
        self.gc_chain_with(table, row_id, lwm, floor)
    }

    fn write_row(&mut self, step: &Step) -> StepOutcome {
        let table = step.pick("o").str();
        let ts = step.var("ins").get_str(table).field("ts").int();
        self.writer
            .execute(format!("INSERT INTO {table} VALUES (1, {ts})"))
            .unwrap();
        Ok(())
    }

    /// The engine collects every object in one pass over the dirty keys, so
    /// the last CheckpointObj of a pass runs the whole collection. A commit
    /// between two CheckpointObj steps is above the snapshot, so it changes
    /// nothing that the pass collects.
    fn checkpoint_obj(&mut self, step: &Step) -> StepOutcome {
        if step.var("ck").field("todo").items().is_empty() {
            self.ck
                .step_until(|state| state != CheckpointState::CollectTableRows);
        }
        Ok(())
    }

    fn checkpoint_commit(&mut self, step: &Step) -> StepOutcome {
        let spec_wrote = step.var("ck").field("frame").int() != 0;
        let wrote = self.ck.commit();
        if wrote != spec_wrote {
            return fail(
                Failure::Frame,
                format!("spec wrote a frame: {spec_wrote}, engine: {wrote}"),
            );
        }
        Ok(())
    }

    /// CookieNotBehind: the schema cookie in the global header is at least
    /// the version of the shared schema.
    fn check_cookie(&self) -> StepOutcome {
        let header = self.ck.mv.global_header.read().unwrap().schema_cookie.get();
        let schema = self.db.get_db().schema.lock().schema_version;
        if header < schema {
            return fail(
                Failure::CookieBehind,
                format!("header cookie {header}, shared schema version {schema}"),
            );
        }
        Ok(())
    }

    /// RecoveryCorrect of a state where it holds: after a crash, every table
    /// with a logged CREATE and no logged DROP exists, with its row if the
    /// row was written.
    fn check_recovery(&self, step: &Step) -> StepOutcome {
        let ddl_log = step.var("ddlLog").items();
        let logged = |table: &str, kind: &str| {
            ddl_log
                .iter()
                .any(|l| l.field("o").str() == table && l.field("kind").str() == kind)
        };
        let mut want = BTreeMap::new();
        for (table, ins) in step.var("ins").entries() {
            let table = table.str();
            if logged(table, "create") && !logged(table, "drop") {
                let ts = ins.field("ts").int();
                want.insert(table.to_string(), (ts != 0).then_some(ts));
            }
        }
        let tables: Vec<String> = step
            .var("ins")
            .entries()
            .iter()
            .map(|(table, _)| table.str().to_string())
            .collect();
        let path = self.db.path.as_ref().unwrap();
        let got = match crash_probe(path, |conn| recovered_tables(conn, &tables)) {
            Recovery::Read(got) => got,
            Recovery::Error(err) => return fail(Failure::RecoveryError, err),
            Recovery::Panic(msg) => return fail(Failure::RecoveryPanic, msg),
        };
        if got != want {
            return fail(
                Failure::RecoveryRows,
                format!("recovered {got:?}, spec logged {want:?}"),
            );
        }
        Ok(())
    }
}

/// The spec tables in `tables` that exist, each with the value of its row.
fn recovered_tables(
    conn: &Arc<Connection>,
    tables: &[String],
) -> crate::Result<BTreeMap<String, Option<i64>>> {
    let mut recovered = BTreeMap::new();
    for row in query_rows(conn, "SELECT name FROM sqlite_schema WHERE type = 'table'")? {
        let name = row[0].to_string();
        if tables.contains(&name) {
            let rows = query_rows(conn, &format!("SELECT v FROM {name}"))?;
            let value = rows.first().map(|row| row[0].as_int().unwrap());
            recovered.insert(name, value);
        }
    }
    Ok(recovered)
}

/// #11502: a row logged while the first checkpoint of its table runs keeps
/// the temporary table id. After a crash, recovery knows the table only by
/// its page, so the row is lost. When the fix lands, this trace stops
/// failing and the test must expect Conforms.
#[test]
fn issue_11502_trace_loses_row_on_recovery() {
    let replayed = replay(
        "MvccPassiveSchema-issue11502",
        include_str!("traces/MvccPassiveSchema-issue11502.itf.json"),
        Expect::Violation {
            step: 8,
            kind: Failure::RecoveryRows,
        },
        &mut SchemaDriver::new(),
    );
    assert_eq!(replayed, Replay::Done);
}

/// #11499: the checkpoint stages the header at its pager commit, a CREATE
/// commits with the next cookie, and the publish writes the staged header
/// with the old cookie. When the fix lands, this trace stops failing and the
/// test must expect Conforms.
#[test]
fn issue_11499_trace_puts_header_cookie_behind() {
    let replayed = replay(
        "MvccPassiveSchema-issue11499",
        include_str!("traces/MvccPassiveSchema-issue11499.itf.json"),
        Expect::Violation {
            step: 11,
            kind: Failure::CookieBehind,
        },
        &mut SchemaDriver::new(),
    );
    assert_eq!(replayed, Replay::Done);
}

/// Traces of the design with catalog reads. Each one reaches the state of
/// a reachability check, and the engine must follow it.
/// - reachCatalogNewer: a reader scans sqlite_schema while the newest frame
///   has a table created after its begin (the shape of #8093).
/// - reachCatalogGenerations: a reader scans sqlite_schema while the newest
///   frame has a table created after the drop of a table it sees, and not
///   the dropped one (the shape of #8094).
/// - reachCatalogFromBtree: GC drops the sqlite_schema version of a table,
///   and a reader then finds the table in the B-tree.
/// - reachCatalogGcDropped: GC drops the sqlite_schema chain of a dropped
///   table (Rule 2).
/// - reachCatalogTomb: a DROP runs on a table whose sqlite_schema chain GC
///   dropped, so the engine inserts a tombstone.
const CATALOG_TRACES: [(&str, &str); 5] = [
    (
        "MvccPassiveSchema-reachCatalogNewer",
        include_str!("traces/MvccPassiveSchema-reachCatalogNewer.itf.json"),
    ),
    (
        "MvccPassiveSchema-reachCatalogGenerations",
        include_str!("traces/MvccPassiveSchema-reachCatalogGenerations.itf.json"),
    ),
    (
        "MvccPassiveSchema-reachCatalogFromBtree",
        include_str!("traces/MvccPassiveSchema-reachCatalogFromBtree.itf.json"),
    ),
    (
        "MvccPassiveSchema-reachCatalogGcDropped",
        include_str!("traces/MvccPassiveSchema-reachCatalogGcDropped.itf.json"),
    ),
    (
        "MvccPassiveSchema-reachCatalogTomb",
        include_str!("traces/MvccPassiveSchema-reachCatalogTomb.itf.json"),
    ),
];

#[test]
fn catalog_traces_conform() {
    for (name, trace) in CATALOG_TRACES {
        let replayed = replay(name, trace, Expect::Conforms, &mut SchemaDriver::new());
        assert_eq!(replayed, Replay::Done, "{name} was refused");
    }
}

/// Replays every schema trace in the folder `MBT_TRACES` and prints the
/// result of each one. Run it with `cargo test mbt_tests -- --ignored`.
#[test]
#[ignore]
fn schema_traces_from_folder() {
    let folder = std::env::var("MBT_TRACES").expect("set MBT_TRACES to a folder of traces");
    let mut paths: Vec<_> = std::fs::read_dir(folder)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.to_string_lossy().ends_with(".itf.json"))
        .collect();
    paths.sort();
    for path in &paths {
        let trace = std::fs::read_to_string(path).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let result = std::panic::catch_unwind(|| {
            replay(&name, &trace, Expect::Conforms, &mut SchemaDriver::new())
        });
        match result {
            Ok(Replay::Done) => println!("{name}: conforms"),
            Ok(Replay::Refused) => println!("{name}: refused"),
            Err(_) => println!("{name}: failed"),
        }
    }
}
