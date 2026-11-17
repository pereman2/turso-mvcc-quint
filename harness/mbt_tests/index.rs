//! Driver for traces of `MvccPassiveIndex.qnt`: table
//! `t(k INTEGER PRIMARY KEY, v INTEGER)` with index `i ON t(v)`. The spec row
//! is rowid 1, and spec index key x is the index entry (x, 1).

use std::collections::{BTreeMap, BTreeSet, HashMap};

use super::itf::{Itf, Step};
use super::rows::RowDriver;
use super::*;

const ROWID: i64 = 1;

pub(super) struct IndexDriver {
    rows: RowDriver,
    index_id: MVTableId,
    /// The index key that each reader looks up, from ReaderReadStart.
    lookups: HashMap<String, i64>,
    /// Lookups so far. Even lookups seek the index, odd lookups scan it.
    reads: usize,
}

/// A covering index seek, which checks the B-tree entry per key.
const SEEK: &str = "SELECT v FROM t INDEXED BY i WHERE v = ?";
/// A covering index scan, which checks the B-tree entries with the lockstep
/// `IndexShadowScan`.
const SCAN: &str = "SELECT v FROM t INDEXED BY i";

impl Driver for IndexDriver {
    fn run_step(&mut self, _index: usize, step: &Step) -> StepOutcome {
        match step.action.as_str() {
            "WritePrepare" => self.write_prepare(step),
            // The engine marks the dirty keys inside the COMMIT stretch that
            // WriteLogAppend steps through. Both happen before CommitEnd.
            "WriteMarkDirty" => Ok(()),
            "WriteLogAppend" => self.rows.write_log_append(step),
            "WriteFinish" => self.rows.write_finish(step),
            "ReaderPin" => self.rows.reader_pin(step),
            "ReaderBegin" => self.rows.reader_begin(step),
            "ReaderReadStart" => {
                let name = step.pick("r").str().to_string();
                self.lookups.insert(name, step.pick("x").int());
                Ok(())
            }
            "ReaderReadEnd" => self.reader_read_end(step),
            "ReaderEnd" => self.rows.reader_end(step),
            "CheckpointStart" => self.rows.checkpoint_start(step),
            "CheckpointCollectTable" => self.checkpoint_collect_table(step),
            "CheckpointCollectIndex" => self.checkpoint_collect_index(step),
            "CheckpointCommit" => self.rows.checkpoint_commit(step),
            "CheckpointPublish" => {
                self.rows
                    .ck
                    .step_until(|state| state == CheckpointState::CheckpointWal);
                Ok(())
            }
            "CheckpointBackfill" => self.rows.checkpoint_backfill(step),
            "CheckpointTruncateLog" => {
                self.rows
                    .ck
                    .step_until(|state| state == CheckpointState::TruncateWal);
                Ok(())
            }
            "CheckpointStampTable" => {
                self.rows
                    .ck
                    .step_until(|state| matches!(state, CheckpointState::GcIndexRows { .. }));
                Ok(())
            }
            "CheckpointStampIndex" => {
                self.rows.ck.finish();
                Ok(())
            }
            "GcTable" => {
                self.gc_table();
                Ok(())
            }
            "GcIndex" => {
                self.gc_index(step.pick("x").int());
                Ok(())
            }
            other => refuse(format!("no engine operation for {other}")),
        }?;
        self.rows.check(step)?;
        if step.action.starts_with("Write") || step.action.starts_with("Checkpoint") {
            self.check_recovery(step)?;
        }
        Ok(())
    }
}

impl IndexDriver {
    pub(super) fn new() -> Self {
        let rows = RowDriver::with_schema(&[
            "CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER)",
            "CREATE INDEX i ON t(v)",
        ]);
        let conn = rows.db.connect();
        let root = get_rows(&conn, "SELECT rootpage FROM sqlite_schema WHERE name = 'i'")[0][0]
            .as_int()
            .unwrap();
        for sql in [SEEK.replace('?', "1"), SCAN.to_string()] {
            let plan = get_rows(&conn, &format!("EXPLAIN QUERY PLAN {sql}"));
            assert!(
                format!("{plan:?}").contains("COVERING INDEX i"),
                "{sql} must read only the index: {plan:?}"
            );
        }
        conn.close().unwrap();
        let index_id = rows.mv.get_table_id_from_root_page(root);
        Self {
            rows,
            index_id,
            lookups: HashMap::new(),
            reads: 0,
        }
    }

    fn write_prepare(&mut self, step: &Step) -> StepOutcome {
        let v = step.pick("v").int();
        let ts = step.var("clock").int();
        let old = latest_value(step.var("writes"), ts);
        let sql = if v == 0 {
            format!("DELETE FROM t WHERE k = {ROWID}")
        } else if old != 0 {
            format!("UPDATE t SET v = {v} WHERE k = {ROWID}")
        } else {
            format!("INSERT INTO t VALUES ({ROWID}, {v})")
        };
        self.rows.prepare_commit(&sql, ts);
        Ok(())
    }

    /// IndexReadsCorrect: the lookup through the index finds the row exactly
    /// when the row has value x at the begin timestamp of the reader.
    fn reader_read_end(&mut self, step: &Step) -> StepOutcome {
        let name = step.pick("r").str();
        let x = self.lookups[name];
        let begin = step.var("rd").get_str(name).field("b").int();
        let want = latest_value(step.var("writes"), begin) == x;
        let sql = if self.reads % 2 == 0 {
            SEEK.replace('?', &x.to_string())
        } else {
            SCAN.to_string()
        };
        self.reads += 1;
        let conn = self.rows.reader_conn(name);
        let rows = get_rows(conn, &sql);
        let found: Vec<i64> = rows.iter().map(|row| row[0].as_int().unwrap()).collect();
        let row_value = latest_value(step.var("writes"), begin);
        let expected: Vec<i64> = if self.reads % 2 == 1 {
            // A seek of x finds only x.
            if want {
                vec![x]
            } else {
                vec![]
            }
        } else if row_value != 0 {
            vec![row_value]
        } else {
            vec![]
        };
        if found != expected {
            return fail(
                Failure::WrongRead,
                format!(
                    "reader {name} ran {sql} for v = {x} at begin {begin}: got {found:?}, spec {expected:?}"
                ),
            );
        }
        Ok(())
    }

    fn checkpoint_collect_table(&mut self, step: &Step) -> StepOutcome {
        self.rows
            .ck
            .step_until(|state| state == CheckpointState::CollectIndexRows);
        let spec = step.var("ck").field("row").int();
        let engine: Vec<bool> = self
            .rows
            .ck
            .sm()
            .collected_table_rows_for_test()
            .into_iter()
            .filter(|(row_id, _)| row_id.table_id == self.rows.table_id)
            .map(|(_, is_delete)| is_delete)
            .collect();
        let same = match (spec, engine.as_slice()) {
            // A delete of a row that the B-tree never had needs no write.
            (-1, []) | (0, []) | (0, [true]) => true,
            (v, [false]) => v > 0,
            _ => false,
        };
        if !same {
            return fail(
                Failure::Collect,
                format!("spec row write {spec}, engine deletes {engine:?}"),
            );
        }
        Ok(())
    }

    /// The engine index write set equals `ck.iw`, and the engine unwritten
    /// index keys equal `ck.iu`.
    fn checkpoint_collect_index(&mut self, step: &Step) -> StepOutcome {
        self.rows
            .ck
            .step_until(|state| state != CheckpointState::CollectIndexRows);
        let ck = step.var("ck");
        let spec_written: BTreeMap<i64, bool> = ck
            .field("iw")
            .entries()
            .iter()
            .map(|(key, value)| (key.int(), value.int() == 0))
            .collect();
        let spec_unwritten: BTreeSet<i64> = ck.field("iu").items().iter().map(Itf::int).collect();
        let sm = self.rows.ck.sm();
        let written: BTreeMap<i64, bool> = sm
            .collected_index_rows_for_test()
            .into_iter()
            .filter(|(row_id, _)| row_id.table_id == self.index_id)
            .map(|(row_id, is_delete)| (index_value(&row_id.row_id), is_delete))
            .collect();
        let unwritten: BTreeSet<i64> = sm
            .unwritten_index_rows_for_test()
            .into_iter()
            .filter(|(index_id, _)| *index_id == self.index_id)
            .map(|(_, key)| index_key_value(&key))
            .collect();
        if written != spec_written || unwritten != spec_unwritten {
            return fail(
                Failure::Collect,
                format!(
                    "index writes (key, delete): spec {spec_written:?}, engine {written:?}; \
                     unwritten keys: spec {spec_unwritten:?}, engine {unwritten:?}"
                ),
            );
        }
        Ok(())
    }

    fn gc_floor(&self) -> (u64, u64, WalPos) {
        let mv = &self.rows.mv;
        let lwm = mv.sample_gc_lwm();
        let ckpt_max = mv.durable_txid_max.load(Ordering::SeqCst);
        let floor = mv.compute_min_reader_mark().min(*mv.backfill_floor.read());
        (lwm, ckpt_max, floor)
    }

    /// One pass of gc_incremental over the chain of the row.
    fn gc_table(&mut self) {
        let (lwm, ckpt_max, floor) = self.gc_floor();
        let row_id = RowID::new(self.rows.table_id, RowKey::Int(ROWID));
        if let Some(entry) = self.rows.mv.rows.get(&row_id) {
            let mut versions = entry.value().write();
            self.rows
                .mv
                .gc_chain_now(&mut versions, lwm, ckpt_max, floor, true);
        }
    }

    /// One pass of gc_index_incremental over the chain of index key x.
    fn gc_index(&mut self, x: i64) {
        let (lwm, ckpt_max, floor) = self.gc_floor();
        let mv = &self.rows.mv;
        if mv.rootpage_gc_protected(&self.index_id, floor) {
            return;
        }
        let Some(index) = mv.index_rows.get(&self.index_id) else {
            return;
        };
        for entry in index.value().iter() {
            if index_key_value(entry.key()) == x {
                let mut versions = entry.value().write();
                mv.gc_chain_now(&mut versions, lwm, ckpt_max, floor, true);
            }
        }
    }

    /// RecoveryCorrect: a crash now recovers the row of the last logged
    /// commit, the index finds it, and the index has no other entry.
    fn check_recovery(&self, step: &Step) -> StepOutcome {
        let want = latest_value(step.var("logged"), i64::MAX);
        let path = self.rows.db.path.as_ref().unwrap();
        let recovered = crash_probe(path, |conn| {
            let row = query_rows(conn, "SELECT v FROM t")?;
            let index = query_rows(conn, SCAN)?;
            let check = query_rows(conn, "PRAGMA integrity_check")?;
            Ok((row, index, check))
        });
        let (row, index, check) = match recovered {
            Recovery::Read(read) => read,
            Recovery::Error(err) => return fail(Failure::RecoveryError, err),
            Recovery::Panic(msg) => return fail(Failure::RecoveryPanic, msg),
        };
        let values = |rows: &[Vec<crate::Value>]| -> Vec<i64> {
            rows.iter().map(|row| row[0].as_int().unwrap()).collect()
        };
        let want_rows = if want == 0 { vec![] } else { vec![want] };
        let ok = check.len() == 1 && check[0] == [crate::Value::build_text("ok")];
        if values(&row) != want_rows || values(&index) != want_rows || !ok {
            return fail(
                Failure::RecoveryRows,
                format!(
                    "recovered row {:?}, index {:?}, integrity {check:?}, spec logged {want_rows:?}",
                    values(&row),
                    values(&index)
                ),
            );
        }
        Ok(())
    }
}

/// The row value after the writes with a timestamp below `ts`. 0 = no row.
fn latest_value(writes: &Itf, ts: i64) -> i64 {
    writes
        .items()
        .iter()
        .filter(|w| w.field("ts").int() < ts)
        .max_by_key(|w| w.field("ts").int())
        .map_or(0, |w| w.field("v").int())
}

fn index_value(key: &RowKey) -> i64 {
    let RowKey::Record(record) = key else {
        panic!("an index row has a record key, got {key:?}");
    };
    index_key_value(record)
}

/// The indexed value v of the index record (v, rowid).
fn index_key_value(key: &SortableIndexKey) -> i64 {
    let mut values = key.key.iter().unwrap();
    match values.next().unwrap().unwrap() {
        crate::types::ValueRef::Numeric(crate::numeric::Numeric::Integer(v)) => v,
        other => panic!("index value {other:?} is not an integer"),
    }
}

/// Traces of the `mbt` module of `MvccPassiveIndex` and its copy `mbtMarker`. Together they run index
/// GC, an UPDATE that keeps the value of `v`, a pass with an unwritten index
/// key, index reads, and the delete of an entry that only the B-tree has.
const INDEX_TRACES: [(&str, &str); 5] = [
    ("index-27", include_str!("traces/index-27.itf.json")),
    ("index-112", include_str!("traces/index-112.itf.json")),
    ("index-150", include_str!("traces/index-150.itf.json")),
    ("index-154", include_str!("traces/index-154.itf.json")),
    ("index-marker", include_str!("traces/index-marker.itf.json")),
];

#[test]
fn generated_index_traces_conform() {
    let mut replayed = 0;
    for (name, trace) in INDEX_TRACES {
        if replay(name, trace, Expect::Conforms, &mut IndexDriver::new()) == Replay::Done {
            replayed += 1;
        }
    }
    assert!(
        replayed >= INDEX_TRACES.len(),
        "only {replayed} traces replayed: a change to the driver or the engine refuses more traces"
    );
}

/// Replays every trace in the folder `MBT_TRACES`. Run it with
/// `cargo test mbt_tests::index -- --ignored`.
#[test]
#[ignore]
fn index_traces_from_folder() {
    let folder = std::env::var("MBT_TRACES").expect("set MBT_TRACES to a folder of traces");
    let mut paths: Vec<_> = std::fs::read_dir(folder)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.to_string_lossy().ends_with(".itf.json"))
        .collect();
    paths.sort();
    let (mut refused, mut failed) = (0, 0);
    for path in &paths {
        let trace = std::fs::read_to_string(path).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let result = std::panic::catch_unwind(|| {
            replay(&name, &trace, Expect::Conforms, &mut IndexDriver::new())
        });
        match result {
            Ok(Replay::Done) => {}
            Ok(Replay::Refused) => refused += 1,
            Err(_) => failed += 1,
        }
    }
    println!(
        "{} traces: {} replayed, {refused} refused, {failed} failed",
        paths.len(),
        paths.len() - refused - failed
    );
    assert_eq!(failed, 0);
}
