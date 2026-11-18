//! Driver for traces of `MvccPassiveCheckpoint.qnt`: one table
//! `t(k INTEGER PRIMARY KEY, v INTEGER)`, where spec key `kN` is rowid N and a
//! row value is the spec commit timestamp of its write.

use std::collections::{BTreeMap, HashMap};
use std::ops::Bound;

use super::itf::{Itf, Step};
use super::*;
use crate::LimboError;

struct Writer {
    conn: Arc<Connection>,
    stop: Arc<StopAt>,
    commit: crate::Statement,
    tx_id: u64,
    logged: bool,
    /// The connection belongs to a reader (`ReaderUpdate`), so it does not
    /// go back to the pool of writer connections.
    reader_owned: bool,
}

enum ReaderState {
    Idle,
    /// The reader holds a pager read mark and has no MVCC transaction yet.
    /// `begin_fresh_mvcc_tx` adopts a read mark that the caller holds.
    Pinned,
    Active {
        key: i64,
    },
}

struct Reader {
    conn: Arc<Connection>,
    /// Set when the driver replays `ReaderUpdate` steps.
    stop: Option<Arc<StopAt>>,
    state: ReaderState,
}

pub(super) struct RowDriver {
    pub(super) db: MvccTestDbNoConn,
    io: Arc<dyn IO>,
    pub(super) mv: Arc<Store>,
    pub(super) table_id: MVTableId,
    pub(super) ck: Checkpointer,
    free_writers: Vec<(Arc<Connection>, Arc<StopAt>)>,
    /// Writers between WritePrepare and WriteFinish, by spec commit timestamp.
    writers: HashMap<i64, Writer>,
    /// Writers that stopped before `remove_tx` (spec `fin.retiring`), by spec
    /// commit timestamp.
    retiring: HashMap<i64, Writer>,
    /// Writers between `CommitEnd` and `FinalizeCommit` (spec `ending`), by
    /// spec commit timestamp. They hold `Committed(end_ts)` in `txs`. They
    /// hold the pager commit lock only without group commit.
    ending: HashMap<i64, Writer>,
    /// Engine TxID of each spec commit timestamp.
    tx_ids: BTreeMap<i64, u64>,
    /// The TxIDs that `FinPruneCollect` saw in the version chains.
    referenced: rustc_hash::FxHashSet<u64>,
    /// A checkpoint ran `Finalize` since the last `FinPruneApply`. The engine
    /// prunes there with its own set, and the spec does not model that prune.
    finalize_ran: bool,
    /// The trace models the finalized TxID states (ModelFinalizedPrune):
    /// a WriteFinish put its writer in `fin.retiring`.
    models_fin: bool,
    readers: HashMap<String, Reader>,
    /// Engine commit timestamp of each spec commit timestamp. Spec timestamp 0
    /// maps to the durable boundary after setup.
    engine_ts: BTreeMap<i64, u64>,
    /// Engine WAL frame of each spec frame, counted across WAL restarts.
    /// Index 0 is the empty WAL.
    frames: Vec<u64>,
    /// Frames in the WAL generations before each checkpoint sequence.
    frames_before_seq: BTreeMap<u32, u64>,
    /// Checkpoint sequence and max frame of the WAL at the last look.
    last_wal: (u32, u64),
    /// Mode B: the passive checkpoint flag is off, and a pass is one spec step.
    blocking: bool,
    /// Readers use `BEGIN CONCURRENT` and can run `ReaderUpdate`.
    updates: bool,
}

impl Driver for RowDriver {
    fn run_step(&mut self, _index: usize, step: &Step) -> StepOutcome {
        match step.action.as_str() {
            "WritePrepare" => self.write_prepare(step)?,
            "WriteLogAppend" => self.write_log_append(step)?,
            "WriteFinish" => self.write_finish(step)?,
            "WriteCommitEnd" => self.write_commit_end(step)?,
            "WriteRewriteTxId" => self.write_rewrite_txid(step)?,
            "WriteFinalize" => self.write_finalize(step)?,
            "WriteRemoveTx" => self.write_remove_tx(step)?,
            "FinPruneCollect" => self.fin_prune_collect(),
            "FinPruneApply" => self.fin_prune_apply(),
            "ReaderPin" => self.reader_pin(step)?,
            "ReaderBegin" => self.reader_begin(step)?,
            "ReaderReadStart" => self.reader_read_start(step)?,
            "ReaderReadEnd" => self.reader_read_end(step)?,
            "ReaderEnd" => self.reader_end(step)?,
            "ReaderUpdate" => self.reader_update(step)?,
            "CheckpointBlocking" => self.checkpoint_blocking(step, false)?,
            "CheckpointBlockingFail" => self.checkpoint_blocking(step, true)?,
            "CheckpointStart" => self.checkpoint_start(step)?,
            "CheckpointCollect" => self.checkpoint_collect(step)?,
            "CheckpointBeginPager" => self.checkpoint_begin_pager(step)?,
            "CheckpointCommit" => self.checkpoint_commit(step)?,
            "CheckpointPublish" => self
                .ck
                .step_until(|state| state == CheckpointState::CheckpointWal),
            "CheckpointBackfill" => self.checkpoint_backfill(step)?,
            "CheckpointTruncateLog" => self
                .ck
                .step_until(|state| state == CheckpointState::TruncateWal),
            "CheckpointTruncateDecide" => self.checkpoint_truncate_decide(step)?,
            "CheckpointStamp" => {
                self.finalize_ran = true;
                self.ck.finish()
            }
            "Gc" => self.gc(step)?,
            other => return refuse(format!("no engine operation for {other}")),
        }
        if self.blocking
            && matches!(
                step.action.as_str(),
                "Gc" | "CheckpointBlocking" | "CheckpointBlockingFail"
            )
        {
            self.check_chains(step)?;
        }
        self.check(step)?;
        self.check_finalized(step)?;
        if step.action == "FinPruneApply" {
            self.finalize_ran = false;
        }
        if step.action.starts_with("Write") || step.action.starts_with("Checkpoint") {
            self.check_recovery(step)?;
        }
        Ok(())
    }
}

impl RowDriver {
    pub(super) fn new() -> Self {
        Self::with_schema(&["CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER)"])
    }

    /// A driver for mode B: the passive checkpoint flag is off.
    pub(super) fn new_blocking() -> Self {
        Self::with_mode(
            &["CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER)"],
            true,
            false,
        )
    }

    /// A driver for traces with `ReaderUpdate` steps: readers use `BEGIN
    /// CONCURRENT`.
    pub(super) fn new_with_updates() -> Self {
        Self::with_mode(
            &["CREATE TABLE t(k INTEGER PRIMARY KEY, v INTEGER)"],
            false,
            true,
        )
    }

    /// A driver for table `t` of `schema`, which must have an integer
    /// primary key `k` and an integer column `v`.
    pub(super) fn with_schema(schema: &[&str]) -> Self {
        Self::with_mode(schema, false, false)
    }

    fn with_mode(schema: &[&str], blocking: bool, updates: bool) -> Self {
        let db = if blocking {
            MvccTestDbNoConn::new_with_random_db()
        } else {
            MvccTestDbNoConn::new_with_random_db_passive()
        };
        let setup = db.connect();
        for sql in schema {
            setup.execute(sql).unwrap();
        }
        setup
            .execute("PRAGMA mvcc_checkpoint_threshold = -1")
            .unwrap();
        setup.execute("PRAGMA mvcc_gc_threshold = -1").unwrap();
        setup.execute("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
        let root = get_rows(
            &setup,
            "SELECT rootpage FROM sqlite_schema WHERE name = 't'",
        )[0][0]
            .as_int()
            .unwrap();
        setup.close().unwrap();

        let mv = db.get_mvcc_store();
        let table_id = mv.get_table_id_from_root_page(root);
        let ck = Checkpointer::new(&db, mv.clone());
        let io = ck.io.clone();
        let mut driver = Self {
            db,
            io,
            mv,
            table_id,
            ck,
            free_writers: Vec::new(),
            writers: HashMap::new(),
            retiring: HashMap::new(),
            ending: HashMap::new(),
            tx_ids: BTreeMap::new(),
            referenced: Default::default(),
            finalize_ran: false,
            models_fin: false,
            readers: HashMap::new(),
            engine_ts: BTreeMap::new(),
            frames: Vec::new(),
            frames_before_seq: BTreeMap::new(),
            last_wal: (0, 0),
            blocking,
            updates,
        };
        driver
            .engine_ts
            .insert(0, driver.mv.durable_txid_max.load(Ordering::SeqCst));
        let (seq, max_frame) = driver.wal_position();
        driver.frames_before_seq.insert(seq, 0);
        driver.last_wal = (seq, max_frame);
        driver.frames.push(max_frame);
        driver
    }

    fn write_prepare(&mut self, step: &Step) -> StepOutcome {
        let key = spec_key(step.pick("k"));
        let is_delete = step.pick("isDelete").bool();
        let ts = step.var("clock").int();
        let old = latest_in(step.var("writes"), key, ts);
        let sql = if is_delete {
            format!("DELETE FROM t WHERE k = {key}")
        } else if old != 0 {
            format!("UPDATE t SET v = {ts} WHERE k = {key}")
        } else {
            format!("INSERT INTO t VALUES ({key}, {ts})")
        };
        self.prepare_commit(&sql, ts);
        Ok(())
    }

    /// Runs `sql` in a `BEGIN CONCURRENT` transaction and steps its `COMMIT`
    /// until it has taken its commit timestamp. `ts` is the spec timestamp.
    pub(super) fn prepare_commit(&mut self, sql: &str, ts: i64) {
        let (conn, stop) = self
            .free_writers
            .pop()
            .unwrap_or_else(|| connect_with_stop(&self.db));
        conn.execute("BEGIN CONCURRENT").unwrap();
        conn.execute(sql).unwrap();
        let tx_id = conn.get_mv_tx_id().unwrap();
        stop.set(
            CommitYieldPoint::CommitValidation.point(),
            Some(commit_yield_key(tx_id)),
        );
        let mut commit = conn.prepare("COMMIT").unwrap();
        assert!(
            step_statement(&mut commit, &stop, &self.io),
            "COMMIT did not stop after it took its timestamp"
        );
        let end_ts = match self.mv.txs.get(&tx_id).unwrap().value().state.load() {
            TransactionState::Preparing(end_ts) => end_ts,
            other => panic!("a stopped COMMIT must be Preparing, got {other:?}"),
        };
        self.engine_ts.insert(ts, end_ts);
        self.tx_ids.insert(ts, tx_id);
        self.writers.insert(
            ts,
            Writer {
                conn,
                stop,
                commit,
                tx_id,
                logged: false,
                reader_owned: false,
            },
        );
    }

    pub(super) fn write_log_append(&mut self, step: &Step) -> StepOutcome {
        let ts = step.pick("i").field("ts").int();
        assert!(
            !self.writers.values().any(|w| w.logged) && self.ending.is_empty(),
            "two writers between log append and finish: without group commit the engine holds \
             pager_commit_lock, and LogAppendOneAtATime of the spec rules this out"
        );
        let writer = self.writers.get_mut(&ts).unwrap();
        writer.stop.set(
            CommitYieldPoint::LogRecordMarkedWritten.point(),
            Some(commit_yield_key(writer.tx_id)),
        );
        assert!(
            step_statement(&mut writer.commit, &writer.stop, &self.io),
            "COMMIT did not stop after its log record was written"
        );
        writer.logged = true;
        Ok(())
    }

    pub(super) fn write_finish(&mut self, step: &Step) -> StepOutcome {
        let ts = step.pick("i").field("ts").int();
        let writer = self.writers.remove(&ts).unwrap();
        self.finish_writer(step, ts, writer)
    }

    /// CommitEnd: the writer is `Committed(end_ts)` in `txs`. The COMMIT stops
    /// at the first entry into `step_rewrite_live_versions`, before it
    /// rewrites any row version (test hook `RewriteLiveVersionsStart`).
    fn write_commit_end(&mut self, step: &Step) -> StepOutcome {
        let ts = step.pick("i").field("ts").int();
        let mut writer = self.writers.remove(&ts).unwrap();
        assert!(writer.logged, "WriteCommitEnd needs a logged writer");
        writer.stop.set(
            CommitYieldPoint::RewriteLiveVersionsStart.point(),
            Some(commit_yield_key(writer.tx_id)),
        );
        assert!(
            step_statement(&mut writer.commit, &writer.stop, &self.io),
            "COMMIT did not stop at the start of the TxID rewrite"
        );
        match self.mv.txs.get(&writer.tx_id).unwrap().value().state.load() {
            TransactionState::Committed(end_ts) if end_ts == self.engine_ts[&ts] => {}
            other => panic!("a COMMIT at RewriteLiveVersionsStart must be Committed, got {other:?}"),
        }
        self.ending.insert(ts, writer);
        Ok(())
    }

    /// The TxID rewrite: the COMMIT runs until the rewrite is done, which is
    /// the yield point after the pager commit lock is released. Then every
    /// version of the writer's key has `materialized_at == ORIGIN` if and only if the
    /// spec says `mat == 0`. The engine and the spec must agree on how many
    /// versions of the key keep a stamp.
    fn write_rewrite_txid(&mut self, step: &Step) -> StepOutcome {
        let i = step.pick("e").field("i");
        let ts = i.field("ts").int();
        let key = spec_key(i.field("k"));
        let writer = self.ending.get_mut(&ts).unwrap();
        writer.stop.set(
            CommitYieldPoint::BeforeGlobalHeaderUpdate.point(),
            Some(commit_yield_key(writer.tx_id)),
        );
        assert!(
            step_statement(&mut writer.commit, &writer.stop, &self.io),
            "COMMIT did not stop after the TxID rewrite"
        );
        let spec = step
            .var("chain")
            .get_str(&format!("k{key}"))
            .items()
            .iter()
            .filter(|v| v.field("mat").int() != 0)
            .count();
        let engine = self.mv.rows.get(&self.row_id(key)).map_or(0, |entry| {
            entry
                .value()
                .read()
                .iter()
                .filter(|v| v.materialized_at != crate::mvcc::database::WalPos::ORIGIN)
                .count()
        });
        if spec != engine {
            return fail(
                Failure::Chain,
                format!(
                    "k{key} after the TxID rewrite: spec has {spec} stamped versions, \
                     engine has {engine}"
                ),
            );
        }
        Ok(())
    }

    /// FinalizeCommit: the rest of the old WriteFinish.
    fn write_finalize(&mut self, step: &Step) -> StepOutcome {
        let ts = step.pick("e").field("i").field("ts").int();
        let writer = self.ending.remove(&ts).unwrap();
        self.finish_writer(step, ts, writer)
    }

    fn finish_writer(&mut self, step: &Step, ts: i64, mut writer: Writer) -> StepOutcome {
        // With ModelFinalizedPrune the spec splits the end of the commit:
        // WriteFinish stops before remove_tx and WriteRemoveTx runs it.
        // Every trace has `fin`, so key on `fin.retiring`.
        let split = step
            .vars
            .get("fin")
            .is_some_and(|fin| fin.field("retiring").items().iter().any(|t| t.int() == ts));
        if split {
            self.models_fin = true;
            writer.stop.set(
                CommitYieldPoint::BeforeFinishCommittedTx.point(),
                Some(commit_yield_key(writer.tx_id)),
            );
            assert!(
                step_statement(&mut writer.commit, &writer.stop, &self.io),
                "COMMIT did not stop before remove_tx"
            );
            self.retiring.insert(ts, writer);
            return Ok(());
        }
        writer.stop.clear();
        assert!(
            !step_statement(&mut writer.commit, &writer.stop, &self.io),
            "COMMIT must finish"
        );
        drop(writer.commit);
        if !writer.reader_owned {
            self.free_writers.push((writer.conn, writer.stop));
        }
        Ok(())
    }

    /// `remove_tx`: the writer leaves `txs` and enters `finalized_tx_states`.
    fn write_remove_tx(&mut self, step: &Step) -> StepOutcome {
        let ts = step.pick("t").int();
        let mut writer = self.retiring.remove(&ts).unwrap();
        writer.stop.clear();
        assert!(
            !step_statement(&mut writer.commit, &writer.stop, &self.io),
            "COMMIT must finish"
        );
        drop(writer.commit);
        self.free_writers.push((writer.conn, writer.stop));
        let tx_id = self.tx_ids[&ts];
        if !self.mv.finalized_tx_states.contains_key(&tx_id) {
            return fail(
                Failure::Finalized,
                format!("WriteRemoveTx: TxID {tx_id} of ts {ts} is not in finalized_tx_states"),
            );
        }
        Ok(())
    }

    /// `collect_referenced_txids` over every chain, under read locks.
    fn fin_prune_collect(&mut self) {
        self.referenced.clear();
        self.finalize_ran = false;
        for entry in self.mv.rows.iter() {
            let versions = entry.value().read();
            Store::collect_referenced_txids(&versions, &mut self.referenced);
        }
        for outer in self.mv.index_rows.iter() {
            for inner in outer.value().iter() {
                let versions = inner.value().read();
                Store::collect_referenced_txids(&versions, &mut self.referenced);
            }
        }
    }

    fn fin_prune_apply(&mut self) {
        let referenced = std::mem::take(&mut self.referenced);
        self.mv.prune_finalized_tx_states(&referenced);
    }

    /// The engine cache must be inside the spec set. It is not equal, because
    /// the engine also prunes at each checkpoint Finalize and the spec does
    /// not. After `FinPruneApply` the sets are equal, unless a checkpoint
    /// finalized between the collect and the apply. Then the engine prune used
    /// a newer set than the spec collect.
    /// Traces without ModelFinalizedPrune skip the check: their spec cache
    /// stays empty while the engine fills it at each remove_tx.
    fn check_finalized(&self, step: &Step) -> StepOutcome {
        if !self.models_fin {
            return Ok(());
        }
        let Some(fin) = step.vars.get("fin") else {
            return Ok(());
        };
        let spec: std::collections::BTreeSet<u64> = fin
            .field("finalized")
            .items()
            .iter()
            .map(|t| self.tx_ids[&t.int()])
            .collect();
        let engine: std::collections::BTreeSet<u64> = self
            .mv
            .finalized_tx_states
            .iter()
            .map(|entry| *entry.key())
            .collect();
        let ok = if step.action == "FinPruneApply" && !self.finalize_ran {
            engine == spec
        } else {
            engine.is_subset(&spec)
        };
        if !ok {
            return fail(
                Failure::Finalized,
                format!(
                    "{}: spec finalized TxIDs {spec:?}, engine finalized_tx_states {engine:?}",
                    step.action
                ),
            );
        }
        Ok(())
    }

    pub(super) fn reader_pin(&mut self, step: &Step) -> StepOutcome {
        let name = step.pick("r").str().to_string();
        let mark = step.var("rd").get_str(&name).field("mark").int();
        let db = &self.db;
        let updates = self.updates;
        let reader = self.readers.entry(name.clone()).or_insert_with(|| {
            if updates {
                let (conn, stop) = connect_with_stop(db);
                Reader {
                    conn,
                    stop: Some(stop),
                    state: ReaderState::Idle,
                }
            } else {
                Reader {
                    conn: db.connect(),
                    stop: None,
                    state: ReaderState::Idle,
                }
            }
        });
        let pager = reader.conn.pager.load();
        pager.begin_read_tx().unwrap();
        let pinned = pager.wal.as_ref().unwrap().get_max_frame();
        reader.state = ReaderState::Pinned;
        let pinned = self.counted_frame(self.last_wal.0, pinned);
        if self.frames.get(mark as usize) != Some(&pinned) {
            return fail(
                Failure::Frame,
                format!(
                    "reader {name} pinned spec mark {mark}, engine frame {pinned}, frames {:?}",
                    self.frames
                ),
            );
        }
        Ok(())
    }

    pub(super) fn reader_begin(&mut self, step: &Step) -> StepOutcome {
        let reader = self.readers.get_mut(step.pick("r").str()).unwrap();
        let ReaderState::Pinned = reader.state else {
            panic!("ReaderBegin of a reader that is not pinned");
        };
        let begin = if self.updates {
            "BEGIN CONCURRENT"
        } else {
            "BEGIN"
        };
        reader.conn.execute(begin).unwrap();
        get_rows(&reader.conn, "SELECT count(*) FROM t");
        reader.state = ReaderState::Active { key: 0 };
        Ok(())
    }

    /// The engine read is one step, so the driver reads at both looks of the
    /// spec read. The oracle is the same at both, because every later commit
    /// timestamp is above the begin of the reader.
    fn reader_read_start(&mut self, step: &Step) -> StepOutcome {
        let key = spec_key(step.pick("k"));
        let name = step.pick("r").str();
        let reader = self.readers.get_mut(name).unwrap();
        reader.state = ReaderState::Active { key };
        self.read_and_compare(step, name)
    }

    fn reader_read_end(&mut self, step: &Step) -> StepOutcome {
        self.read_and_compare(step, step.pick("r").str())
    }

    fn read_and_compare(&self, step: &Step, name: &str) -> StepOutcome {
        let reader = &self.readers[name];
        let ReaderState::Active { key } = reader.state else {
            panic!("a read of a reader that is not active");
        };
        let begin = step.var("rd").get_str(name).field("b").int();
        let want = latest_in(step.var("writes"), key, begin);
        let rows = get_rows(&reader.conn, &format!("SELECT v FROM t WHERE k = {key}"));
        let got = rows.first().map_or(0, |row| row[0].as_int().unwrap());
        if got != want {
            return fail(
                Failure::WrongRead,
                format!(
                    "reader {name} read k{key} at begin {begin}: got {got}, spec oracle {want}"
                ),
            );
        }
        if self.blocking {
            // A scan goes through the other look of the dual cursor.
            let writes = step.var("writes");
            let mut want_rows: BTreeMap<i64, i64> = BTreeMap::new();
            for write in writes.items() {
                let k = spec_key(write.field("k"));
                let v = latest_in(writes, k, begin);
                if v != 0 {
                    want_rows.insert(k, v);
                }
            }
            let got_rows: BTreeMap<i64, i64> = get_rows(&reader.conn, "SELECT k, v FROM t")
                .iter()
                .map(|row| (row[0].as_int().unwrap(), row[1].as_int().unwrap()))
                .collect();
            if got_rows != want_rows {
                return fail(
                    Failure::WrongRead,
                    format!(
                        "reader {name} scanned at begin {begin}: got {got_rows:?}, spec oracle {want_rows:?}"
                    ),
                );
            }
        }
        Ok(())
    }

    /// The connection of reader `name` while its transaction is open.
    pub(super) fn reader_conn(&self, name: &str) -> &Arc<Connection> {
        let reader = &self.readers[name];
        assert!(
            matches!(reader.state, ReaderState::Active { .. }),
            "reader {name} has no open transaction"
        );
        &reader.conn
    }

    pub(super) fn reader_end(&mut self, step: &Step) -> StepOutcome {
        let reader = self.readers.get_mut(step.pick("r").str()).unwrap();
        if let ReaderState::Active { .. } = reader.state {
            reader.conn.execute("ROLLBACK").unwrap();
        }
        let pager = reader.conn.pager.load();
        if pager.holds_read_lock() {
            pager.end_read_tx();
        }
        reader.state = ReaderState::Idle;
        Ok(())
    }

    /// A reader updates one key and commits, as one spec step. The engine
    /// decides the write-write conflict here: in the statement or in the
    /// commit check. The spec step added a version, or it did not. After a
    /// commit that passed the check, the connection moves to `writers` in the
    /// Preparing state under the spec commit timestamp. The reader leaves
    /// `readers`, so its next `ReaderPin` makes a new connection.
    fn reader_update(&mut self, step: &Step) -> StepOutcome {
        if !self.updates {
            return refuse("ReaderUpdate needs a driver with BEGIN CONCURRENT readers");
        }
        let name = step.pick("r").str().to_string();
        let key = spec_key(step.pick("k"));
        let ts = step.var("clock").int();
        let begin = step.var("rd").get_str(&name).field("b").int();
        // The spec step committed when it added `{ k, b, ts: clock }` to rmw.
        let committed = step.var("rmw").items().iter().any(|u| {
            spec_key(u.field("k")) == key
                && u.field("b").int() == begin
                && u.field("ts").int() == ts
        });
        let (conn, stop) = {
            let reader = &self.readers[&name];
            let ReaderState::Active { .. } = reader.state else {
                panic!("ReaderUpdate of a reader that is not active");
            };
            (reader.conn.clone(), reader.stop.clone().unwrap())
        };
        let value = if committed { ts } else { ts + 1 };
        let sql = format!(
            "INSERT INTO t VALUES ({key}, {value}) ON CONFLICT(k) DO UPDATE SET v = excluded.v"
        );
        let mut conflict = None;
        let mut prepared = None;
        match conn.execute(&sql) {
            Err(LimboError::WriteWriteConflict) => conflict = Some("the statement"),
            Err(err) => {
                return fail(Failure::Conflict, format!("the update failed with {err:?}"));
            }
            Ok(_) => {
                let tx_id = conn.get_mv_tx_id().unwrap();
                stop.set(
                    CommitYieldPoint::WaitForDependencies.point(),
                    Some(commit_yield_key(tx_id)),
                );
                let mut commit = conn.prepare("COMMIT").unwrap();
                match step_statement_result(&mut commit, &stop, &self.io) {
                    Ok(true) => prepared = Some((commit, tx_id)),
                    Ok(false) => panic!("COMMIT finished before its commit dependencies wait"),
                    Err(LimboError::WriteWriteConflict) => conflict = Some("the commit check"),
                    Err(err) => {
                        return fail(Failure::Conflict, format!("the commit failed with {err:?}"));
                    }
                }
            }
        }
        if conflict.is_some() == committed {
            return fail(
                Failure::Conflict,
                format!(
                    "reader {name} updated k{key} at begin {begin}: spec committed {committed}, \
                     engine conflict {conflict:?}"
                ),
            );
        }
        match prepared {
            Some((commit, tx_id)) => {
                self.readers.remove(&name);
                let end_ts = match self.mv.txs.get(&tx_id).unwrap().value().state.load() {
                    TransactionState::Preparing(end_ts) => end_ts,
                    other => panic!("a stopped COMMIT must be Preparing, got {other:?}"),
                };
                self.engine_ts.insert(ts, end_ts);
                self.writers.insert(
                    ts,
                    Writer {
                        conn,
                        stop,
                        commit,
                        tx_id,
                        logged: false,
                        reader_owned: true,
                    },
                );
            }
            None => {
                // The statement or the commit rolled back, or the test does.
                self.readers.get_mut(&name).unwrap().state = ReaderState::Idle;
                let _ = conn.execute("ROLLBACK");
                let pager = conn.pager.load();
                if pager.holds_read_lock() {
                    pager.end_read_tx();
                }
            }
        }
        Ok(())
    }

    pub(super) fn checkpoint_start(&mut self, step: &Step) -> StepOutcome {
        self.ck.start(1);
        let spec_snap = step.var("ck").field("snap").int();
        let snap = self.ck.sm().snapshot_ts_for_test();
        if let Some(commit) = self.commit_on_other_side(spec_snap, snap) {
            return fail(
                Failure::Snapshot,
                format!("spec snapshot {spec_snap}, engine {snap}: {commit}"),
            );
        }
        Ok(())
    }

    /// Visits the dirty keys of the engine up to the spec key, one per step.
    /// The engine visits only dirty keys, so a spec key that is not dirty is
    /// a no-op.
    fn checkpoint_collect(&mut self, step: &Step) -> StepOutcome {
        self.collect_up_to(spec_key(step.pick("k")));
        self.check_collected(step)
    }

    fn collect_up_to(&mut self, key: i64) {
        let target = self.row_id(key);
        let table_start = self.row_id(i64::MIN);
        loop {
            let ck = self.ck.sm();
            if ck.state_for_test() != CheckpointState::CollectTableRows {
                return;
            }
            let lower = match ck.last_collected_table_key_for_test() {
                Some(last) if last.table_id == self.table_id => Bound::Excluded(last.clone()),
                _ => Bound::Included(table_start.clone()),
            };
            let dirty_up_to_target = self
                .mv
                .checkpoint_dirty_table_keys
                .range((lower, Bound::Included(target.clone())))
                .next()
                .is_some();
            if !dirty_up_to_target {
                return;
            }
            let before = ck.last_collected_table_key_for_test().cloned();
            let ck = self.ck.sm.as_mut().unwrap();
            match ck.step(&()).unwrap() {
                TransitionResult::Io(io) => io.wait(self.io.as_ref()).unwrap(),
                TransitionResult::Continue => {}
                TransitionResult::Done(_) => panic!("checkpoint finished during collection"),
            }
            if ck.state_for_test() != CheckpointState::CollectTableRows {
                return;
            }
            let after = ck.last_collected_table_key_for_test().cloned();
            assert_ne!(before, after, "a collect step must visit a key");
            assert!(
                after.as_ref().is_some_and(|key| *key <= target),
                "the checkpoint visited {after:?}, after the spec key {target:?}"
            );
        }
    }

    /// The engine write set equals the spec `ck.wset` on the keys that the
    /// spec visited. A spec value of 0 is a delete, which the engine leaves
    /// out when the row was never in the B-tree.
    fn check_collected(&self, step: &Step) -> StepOutcome {
        let ck = step.var("ck");
        let todo: Vec<i64> = ck.field("todo").items().iter().map(spec_key).collect();
        let spec: BTreeMap<i64, bool> = ck
            .field("wset")
            .entries()
            .iter()
            .map(|(key, value)| (spec_key(key), value.int() == 0))
            .collect();
        let engine: BTreeMap<i64, bool> = self
            .ck
            .sm()
            .collected_table_rows_for_test()
            .into_iter()
            .filter(|(row_id, _)| row_id.table_id == self.table_id)
            .map(|(row_id, is_delete)| (row_id.row_id.to_int_or_panic(), is_delete))
            .collect();
        for key in spec.keys().chain(engine.keys()) {
            if todo.contains(key) {
                continue;
            }
            let same = match (spec.get(key), engine.get(key)) {
                (Some(spec_delete), Some(engine_delete)) => spec_delete == engine_delete,
                (Some(true), None) => true,
                _ => false,
            };
            if !same {
                return fail(
                    Failure::Collect,
                    format!(
                        "k{key}: spec deletes {:?}, engine deletes {:?}",
                        spec.get(key),
                        engine.get(key)
                    ),
                );
            }
        }
        Ok(())
    }

    /// The engine begins the pager transaction after the collection. A pass
    /// with nothing to write skips the pager commit and the publish.
    fn checkpoint_begin_pager(&mut self, step: &Step) -> StepOutcome {
        match step.var("ck").field("pc").str() {
            "writing" => self.ck.step_until(|state| {
                !matches!(
                    state,
                    CheckpointState::CollectTableRows
                        | CheckpointState::CollectIndexRows
                        | CheckpointState::BeginPagerTxn
                )
            }),
            "published" => self
                .ck
                .step_until(|state| state == CheckpointState::CheckpointWal),
            other => return refuse(format!("CheckpointBeginPager to {other}")),
        }
        Ok(())
    }

    /// The engine decides and truncates the logical log in one step.
    fn checkpoint_truncate_decide(&mut self, step: &Step) -> StepOutcome {
        if step.var("ck").field("pc").str() != "truncated" {
            return refuse("the truncate decision and its I/O are separate steps");
        }
        self.ck
            .step_until(|state| state == CheckpointState::TruncateWal);
        Ok(())
    }

    pub(super) fn checkpoint_commit(&mut self, step: &Step) -> StepOutcome {
        let spec_wrote = step.var("ck").field("frame").int() != 0;
        let wrote = self.ck.commit();
        if wrote != spec_wrote {
            return fail(
                Failure::Frame,
                format!("spec wrote a frame: {spec_wrote}, engine: {wrote}"),
            );
        }
        if wrote {
            let max_frame = self.max_frame();
            self.frames.push(max_frame);
        }
        Ok(())
    }

    /// A mode B pass, one spec step. `fails` is a pass that stops at
    /// `CheckpointWal` after its publish, because a pager reader holds a WAL
    /// read mark. The test cannot inject an I/O error there, so it refuses
    /// such a trace when no reader is pinned.
    fn checkpoint_blocking(&mut self, step: &Step, fails: bool) -> StepOutcome {
        if !self.blocking {
            return refuse("a mode B action in a trace for the passive flag");
        }
        let pinned = step
            .var("rd")
            .entries()
            .iter()
            .any(|(_, state)| state.field("pinned").bool());
        if fails && !pinned {
            return refuse("CheckpointBlockingFail without a pinned reader needs an I/O error");
        }
        let spec_wrote = step.var("wal").items().len() > self.frames.len() - 1;
        self.ck.start_blocking();
        let wrote = self.ck.commit();
        if wrote != spec_wrote {
            return fail(
                Failure::Frame,
                format!("spec wrote a frame: {spec_wrote}, engine: {wrote}"),
            );
        }
        if wrote {
            let max_frame = self.max_frame();
            self.frames.push(max_frame);
        }
        match (fails, self.ck.run_to_end()) {
            (false, Ok(())) | (true, Err(crate::LimboError::Busy)) => {}
            (false, Err(err)) => {
                return fail(
                    Failure::CheckpointResult,
                    format!("the spec pass succeeds, the engine pass returned {err}"),
                );
            }
            (true, other) => {
                return fail(
                    Failure::CheckpointResult,
                    format!("the spec pass stops after its publish, the engine returned {other:?}"),
                );
            }
        }
        Ok(())
    }

    /// Mode B: compares the number of versions of every key. The engine count
    /// is the length of the chain in `rows`. It includes committed versions,
    /// Preparing versions and the begin-None marker of a row that only the
    /// B-tree had. The spec count is the size of `chain[k]`, which has the same
    /// kinds of versions. With no failed pass before it, a pass that succeeds
    /// empties every chain in both, so this check also covers
    /// BlockingStoreEmpty. After a failed pass, the versions left are compared.
    fn check_chains(&self, step: &Step) -> StepOutcome {
        for (key, versions) in step.var("chain").entries() {
            let key = spec_key(key);
            let spec = versions.items().len();
            let (engine, dump) =
                self.mv
                    .rows
                    .get(&self.row_id(key))
                    .map_or((0, String::new()), |entry| {
                        let versions = entry.value().read();
                        (
                            versions.len(),
                            versions
                                .iter()
                                .map(|v| format!("[{:?} {:?}]", v.begin(), v.end()))
                                .collect::<String>(),
                        )
                    });
            if spec != engine {
                return fail(
                    Failure::Chain,
                    format!(
                        "k{key}: spec chain has {spec} versions, engine chain has {engine} {dump}, \
                         lwm {}, durable_txid_max {}",
                        self.mv.sample_gc_lwm(),
                        self.mv.durable_txid_max.load(Ordering::SeqCst)
                    ),
                );
            }
        }
        Ok(())
    }

    pub(super) fn checkpoint_backfill(&mut self, _step: &Step) -> StepOutcome {
        self.ck
            .step_until(|state| state == CheckpointState::TruncateLogicalLog);
        Ok(())
    }

    /// One pass of gc_incremental over the chain of one key.
    fn gc(&mut self, step: &Step) -> StepOutcome {
        let row_id = self.row_id(spec_key(step.pick("k")));
        let lwm = self.mv.sample_gc_lwm();
        let ckpt_max = self.mv.durable_txid_max.load(Ordering::SeqCst);
        let floor = self
            .mv
            .compute_min_reader_mark()
            .min(*self.mv.backfill_floor.read());
        if self.mv.rootpage_gc_protected(&row_id.table_id, floor) {
            return Ok(());
        }
        if let Some(entry) = self.mv.rows.get(&row_id) {
            let mut versions = entry.value().write();
            self.mv
                .gc_chain_now(&mut versions, lwm, ckpt_max, floor, true);
        }
        Ok(())
    }

    pub(super) fn check(&mut self, step: &Step) -> StepOutcome {
        let spec_durable = step.var("durable").int();
        let durable = self.mv.durable_txid_max.load(Ordering::SeqCst);
        if let Some(commit) = self.commit_on_other_side(spec_durable, durable) {
            return fail(
                Failure::Durable,
                format!("spec durable {spec_durable}, engine {durable}: {commit}"),
            );
        }

        let wal_len = step.var("wal").items().len();
        let max_frame = self.max_frame();
        if self.frames.get(wal_len) != Some(&max_frame) {
            return fail(
                Failure::Frame,
                format!(
                    "spec has {wal_len} frames, engine max frame {max_frame}, frames {:?}",
                    self.frames
                ),
            );
        }
        let backfilled = {
            let pager = self.ck.conn.pager.load();
            self.counted_frame(self.last_wal.0, pager.wal_backfill_frame().unwrap())
        };
        let floor = *self.mv.backfill_floor.read();
        let floor = self.counted_frame(floor.checkpoint_seq, floor.frame);
        for (name, spec, engine) in [
            ("nBackfill", step.var("nBackfill").int(), backfilled),
            ("backfillFloor", step.var("backfillFloor").int(), floor),
        ] {
            if self.frames.get(spec as usize) != Some(&engine) {
                return fail(
                    Failure::Backfill,
                    format!(
                        "spec {name} {spec}, engine frame {engine}, frames {:?}",
                        self.frames
                    ),
                );
            }
        }

        let spec_log_empty = step.var("llog").items().is_empty();
        let log_empty = self.mv.storage.logical_log_offset() == 0;
        if spec_log_empty != log_empty {
            return fail(
                Failure::LogicalLog,
                format!("spec log empty: {spec_log_empty}, engine log empty: {log_empty}"),
            );
        }
        Ok(())
    }

    /// RecoveryCorrect: a crash now recovers the latest logged value of
    /// every key.
    fn check_recovery(&self, step: &Step) -> StepOutcome {
        let logged = step.var("logged");
        let mut want: BTreeMap<i64, i64> = BTreeMap::new();
        for write in logged.items() {
            want.entry(spec_key(write.field("k"))).or_insert(0);
        }
        let want: BTreeMap<i64, i64> = want
            .into_keys()
            .map(|key| (key, latest_in(logged, key, i64::MAX)))
            .filter(|(_, value)| *value != 0)
            .collect();
        let path = self.db.path.as_ref().unwrap();
        let got = match crash_probe_with_flag(path, !self.blocking, |conn| {
            query_rows(conn, "SELECT k, v FROM t")
        }) {
            Recovery::Read(rows) => rows
                .iter()
                .map(|row| (row[0].as_int().unwrap(), row[1].as_int().unwrap()))
                .collect::<BTreeMap<_, _>>(),
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

    /// A spec commit that is at or below `spec_ts` while its engine commit
    /// is above `engine_ts`, or the other way. Engine and spec timestamps
    /// differ, so the test compares only their order with the commits.
    fn commit_on_other_side(&self, spec_ts: i64, engine_ts: u64) -> Option<String> {
        self.engine_ts
            .iter()
            .find(|(&spec, &engine)| (spec <= spec_ts) != (engine <= engine_ts))
            .map(|(spec, engine)| format!("commit {spec} (engine {engine}) is on the other side"))
    }

    /// The max frame of the WAL, counted across WAL restarts. A restart
    /// starts a new checkpoint sequence after every frame was backfilled.
    fn max_frame(&mut self) -> u64 {
        let (seq, max_frame) = self.wal_position();
        let (last_seq, last_max) = self.last_wal;
        if seq != last_seq {
            assert!(seq > last_seq, "the WAL checkpoint sequence went back");
            let before = self.frames_before_seq[&last_seq] + last_max;
            self.frames_before_seq.insert(seq, before);
        }
        self.last_wal = (seq, max_frame);
        self.counted_frame(seq, max_frame)
    }

    fn counted_frame(&self, seq: u32, frame: u64) -> u64 {
        self.frames_before_seq[&seq] + frame
    }

    fn wal_position(&self) -> (u32, u64) {
        let pager = self.ck.conn.pager.load();
        let wal = pager.wal.as_ref().unwrap();
        (wal.get_checkpoint_seq(), wal.get_max_frame_in_wal())
    }

    fn row_id(&self, key: i64) -> RowID {
        RowID::new(self.table_id, RowKey::Int(key))
    }
}

/// Spec key `kN` is rowid N.
fn spec_key(key: &Itf) -> i64 {
    key.str()
        .strip_prefix('k')
        .and_then(|n| n.parse().ok())
        .unwrap_or_else(|| panic!("spec key {key:?} is not kN"))
}

/// The value of key `key` after the writes with a timestamp below `ts`, as
/// LatestIn of the spec. 0 means no row.
fn latest_in(writes: &Itf, key: i64, ts: i64) -> i64 {
    writes
        .items()
        .iter()
        .filter(|w| spec_key(w.field("k")) == key && w.field("ts").int() < ts)
        .max_by_key(|w| w.field("ts").int())
        .map_or(0, |w| w.field("v").int())
}

#[test]
fn hand_written_row_trace_conforms() {
    let mut driver = RowDriver::new();
    let replayed = replay(
        "rows-hand",
        include_str!("traces/rows-hand.itf.json"),
        Expect::Conforms,
        &mut driver,
    );
    assert_eq!(replayed, Replay::Done);
}

/// Traces of the mbt module from `make traces`. In rows-196 a backfill runs
/// between the pin and the begin of a reader.
const GENERATED_ROW_TRACES: [(&str, &str); 7] = [
    ("rows-23", include_str!("traces/rows-23.itf.json")),
    ("rows-66", include_str!("traces/rows-66.itf.json")),
    ("rows-83", include_str!("traces/rows-83.itf.json")),
    ("rows-102", include_str!("traces/rows-102.itf.json")),
    ("rows-104", include_str!("traces/rows-104.itf.json")),
    ("rows-186", include_str!("traces/rows-186.itf.json")),
    ("rows-196", include_str!("traces/rows-196.itf.json")),
];

/// Traces of `mbtRewrite` (gap 22): a checkpoint step runs between
/// `WriteCommitEnd` and `WriteRewriteTxId`. In rewrite-window-15 that step is
/// `CheckpointStamp`. The replay compares the stamped versions after the
/// rewrite.
const REWRITE_WINDOW_TRACES: [(&str, &str); 2] = [
    (
        "rewrite-window-11",
        include_str!("traces/rewrite-window-11.itf.json"),
    ),
    (
        "rewrite-window-15",
        include_str!("traces/rewrite-window-15.itf.json"),
    ),
];

#[test]
fn rewrite_window_traces_conform() {
    for (name, trace) in REWRITE_WINDOW_TRACES {
        assert_eq!(
            replay(name, trace, Expect::Conforms, &mut RowDriver::new()),
            Replay::Done,
            "{name} did not replay"
        );
    }
}

/// Steps `stmt` like `step_statement`, and returns the error of the engine.
fn step_statement_result(
    stmt: &mut crate::Statement,
    stop: &StopAt,
    io: &Arc<dyn IO>,
) -> Result<bool, LimboError> {
    for _ in 0..STEP_LIMIT {
        match stmt.step()? {
            StepResult::IO | StepResult::Yield => {
                if stop.fired() {
                    return Ok(true);
                }
                io.step().unwrap();
            }
            StepResult::Row => {}
            StepResult::Done => return Ok(false),
            other => panic!("unexpected statement step result {other:?}"),
        }
    }
    panic!("statement did not stop in {STEP_LIMIT} steps");
}

#[test]
fn generated_row_traces_conform() {
    let mut replayed = 0;
    for (name, trace) in GENERATED_ROW_TRACES {
        if replay(name, trace, Expect::Conforms, &mut RowDriver::new()) == Replay::Done {
            replayed += 1;
        }
    }
    assert!(
        replayed == GENERATED_ROW_TRACES.len(),
        "only {replayed} traces replayed: a change to the driver or the engine refuses more traces"
    );
}

/// Witness traces of `ReaderUpdate` (gap 7), from `make bug-traces` of the
/// modules `mbtUpdate*` with `Updates = true`. The engine decides each
/// write-write conflict inside the spec step.
const UPDATE_WITNESS_TRACES: [(&str, &str); 5] = [
    (
        "ww-reachUpdateCommits",
        include_str!("traces/ww-reachUpdateCommits.itf.json"),
    ),
    (
        "ww-reachUpdateConflict",
        include_str!("traces/ww-reachUpdateConflict.itf.json"),
    ),
    (
        "ww-reachConflictByEndOnly",
        include_str!("traces/ww-reachConflictByEndOnly.itf.json"),
    ),
    (
        "ww-reachConflictByCurrentOnly",
        include_str!("traces/ww-reachConflictByCurrentOnly.itf.json"),
    ),
    (
        "ww-reachConflictAfterGc",
        include_str!("traces/ww-reachConflictAfterGc.itf.json"),
    ),
];

#[test]
fn update_witness_traces_conform() {
    let mut replayed = 0;
    for (name, trace) in UPDATE_WITNESS_TRACES {
        if replay(
            name,
            trace,
            Expect::Conforms,
            &mut RowDriver::new_with_updates(),
        ) == Replay::Done
        {
            replayed += 1;
        }
    }
    assert!(
        replayed == UPDATE_WITNESS_TRACES.len(),
        "only {replayed} traces replayed: the engine and the spec disagree on a ReaderUpdate"
    );
}

/// Replays every trace in the folder `MBT_TRACES`, for new traces from
/// `make traces`. Run it with `cargo test mbt_tests -- --ignored`.
#[test]
#[ignore]
fn row_traces_from_folder() {
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
            replay(&name, &trace, Expect::Conforms, &mut RowDriver::new())
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

/// Replays every trace in the folder `MBT_TRACES` on the mode B engine (the
/// passive flag off), for the traces of `make traces SPECS=MvccPassiveCheckpoint MBT=mbtBlocking`. Run it
/// with `cargo test mbt_tests -- --ignored`.
#[test]
#[ignore]
fn blocking_row_traces_from_folder() {
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
            replay(
                &name,
                &trace,
                Expect::Conforms,
                &mut RowDriver::new_blocking(),
            )
        });
        match result {
            Ok(Replay::Done) => println!("TRACE {name}: replayed"),
            Ok(Replay::Refused) => {
                refused += 1;
                println!("TRACE {name}: refused");
            }
            Err(_) => {
                failed += 1;
                println!("TRACE {name}: failed");
            }
        }
    }
    println!(
        "{} traces: {} replayed, {refused} refused, {failed} failed",
        paths.len(),
        paths.len() - refused - failed
    );
    assert_eq!(failed, 0);
}

/// The bug trace of the variant `blockingPagerPin`: a pager reader pins a WAL
/// read mark and holds no gate, so a pass fails after its publish, GC drops
/// the delete, and the reader reads the old B-tree row. The step number is
/// the read of that reader.
#[test]
fn blocking_pager_pin_trace_shows_wrong_read() {
    let replayed = replay(
        "MvccPassiveCheckpoint-blockingPagerPin",
        include_str!("traces/MvccPassiveCheckpoint-blockingPagerPin.itf.json"),
        Expect::Violation {
            step: 16,
            kind: Failure::WrongRead,
        },
        &mut RowDriver::new_blocking(),
    );
    assert_eq!(replayed, Replay::Done);
}

/// Traces of the mbtBlocking module from `make traces SPECS=MvccPassiveCheckpoint
/// MBT=mbtBlocking`. After each `Gc` and each B pass, the replay compares the
/// version count of every key with the spec chain (`check_chains`).
///
/// Directed traces, from `make traces` of the modules `mbtBlocking` and
/// `mbtBlockingPin` (the second one has `PagerPinsWithoutGate`):
/// - rows-blocking-gc-read-13: a `Gc` step drops a superseded version while a
///   reader is open, and the reader then reads that key.
/// - rows-blocking-pin-171: the same, and a `CheckpointBlockingFail` is
///   followed by a `CheckpointBlocking` that leaves a version in the store.
/// - rows-blocking-fail-then-pass-220: a `CheckpointBlockingFail`, then a
///   `CheckpointBlocking` that leaves a version in the store.
/// The failed pass comes from a pager pin that holds no gate, because the
/// driver cannot inject an I/O error.
const GENERATED_BLOCKING_ROW_TRACES: [(&str, &str); 8] = [
    (
        "rows-blocking-7",
        include_str!("traces/rows-blocking-7.itf.json"),
    ),
    (
        "rows-blocking-15",
        include_str!("traces/rows-blocking-15.itf.json"),
    ),
    (
        "rows-blocking-24",
        include_str!("traces/rows-blocking-24.itf.json"),
    ),
    (
        "rows-blocking-32",
        include_str!("traces/rows-blocking-32.itf.json"),
    ),
    (
        "rows-blocking-39",
        include_str!("traces/rows-blocking-39.itf.json"),
    ),
    (
        "rows-blocking-gc-read-13",
        include_str!("traces/rows-blocking-gc-read-13.itf.json"),
    ),
    (
        "rows-blocking-pin-171",
        include_str!("traces/rows-blocking-pin-171.itf.json"),
    ),
    (
        "rows-blocking-fail-then-pass-220",
        include_str!("traces/rows-blocking-fail-then-pass-220.itf.json"),
    ),
];

#[test]
fn generated_blocking_row_traces_conform() {
    let mut replayed = 0;
    for (name, trace) in GENERATED_BLOCKING_ROW_TRACES {
        if replay(
            name,
            trace,
            Expect::Conforms,
            &mut RowDriver::new_blocking(),
        ) == Replay::Done
        {
            replayed += 1;
        }
    }
    assert!(
        replayed == GENERATED_BLOCKING_ROW_TRACES.len(),
        "only {replayed} traces replayed: a change to the driver or the engine refuses more traces"
    );
}

/// Negative control for the chain check. The bug trace of the variant
/// `blockingNoB2Keep` has a `Gc` step where the spec drops the delete marker
/// of a row that only the B-tree has. The engine keeps it (the keep clause of
/// Rule 2, B form). So the version counts differ at that step.
#[test]
fn blocking_no_b2_keep_trace_fails_the_chain_check() {
    let replayed = replay(
        "MvccPassiveCheckpoint-blockingNoB2Keep",
        include_str!("traces/MvccPassiveCheckpoint-blockingNoB2Keep.itf.json"),
        Expect::Violation {
            step: 11,
            kind: Failure::Chain,
        },
        &mut RowDriver::new_blocking(),
    );
    assert_eq!(replayed, Replay::Done);
}
