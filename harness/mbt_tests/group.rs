//! Driver for traces of `MvccGroupCommit.qnt`. Spec transaction number i (in
//! name order) is one connection that inserts row pk = i + 1 in
//! `BEGIN CONCURRENT` and steps its `COMMIT`. The database runs on
//! `ShadowIo`, which keeps the bytes of each file as of its last fsync, so a
//! probe can open the files as a power loss leaves them.
//!
//! The engine runs some spec actions of one commit without a point where the
//! driver can stop it. The driver steps the engine to its next stop and then
//! consumes the spec actions of the same transaction up to the matching spec
//! state. A trace that runs another transaction in between is refused.

use std::collections::{BTreeMap, BTreeSet};

use super::itf::{Itf, Step};
use super::*;
use crate::io::{File, FileId, FileSyncType};
use crate::mvcc::database::{CommitYieldPoint, TransactionState};
use crate::{
    Buffer, Clock, Completion, ConnectOpts, Database, EngineDialect, MemoryIO, MonotonicInstant,
    OpenFlags, SyncMode, WallClockInstant,
};

/// The bytes of one file: as the OS shows them, and as of the last fsync.
#[derive(Debug, Default)]
struct Shadow {
    current: Vec<u8>,
    durable: Vec<u8>,
}

/// A `MemoryIO` that keeps a `Shadow` of each file.
#[derive(Default)]
struct ShadowIo {
    inner: MemoryIO,
    files: Mutex<BTreeMap<String, Arc<Mutex<Shadow>>>>,
}

impl ShadowIo {
    fn mark_all_durable(&self) {
        for shadow in self.files.lock().values() {
            let mut shadow = shadow.lock();
            shadow.durable = shadow.current.clone();
        }
    }

    /// The files as a process crash (`durable == false`) or a power loss
    /// (`durable == true`) leaves them.
    fn snapshot(&self, durable: bool) -> BTreeMap<String, Vec<u8>> {
        self.files
            .lock()
            .iter()
            .map(|(path, shadow)| {
                let shadow = shadow.lock();
                let bytes = if durable {
                    &shadow.durable
                } else {
                    &shadow.current
                };
                (path.clone(), bytes.clone())
            })
            .collect()
    }
}

impl Clock for ShadowIo {
    fn current_time_monotonic(&self) -> MonotonicInstant {
        self.inner.current_time_monotonic()
    }
    fn current_time_wall_clock(&self) -> WallClockInstant {
        self.inner.current_time_wall_clock()
    }
}

impl IO for ShadowIo {
    fn open_file(
        &self,
        path: &str,
        flags: OpenFlags,
        direct: bool,
    ) -> crate::Result<Arc<dyn File>> {
        let inner = self.inner.open_file(path, flags, direct)?;
        let shadow = self
            .files
            .lock()
            .entry(path.to_string())
            .or_default()
            .clone();
        Ok(Arc::new(ShadowFile { inner, shadow }))
    }
    fn remove_file(&self, path: &str) -> crate::Result<()> {
        self.files.lock().remove(path);
        self.inner.remove_file(path)
    }
    fn file_id(&self, path: &str) -> crate::Result<FileId> {
        self.inner.file_id(path)
    }
}

struct ShadowFile {
    inner: Arc<dyn File>,
    shadow: Arc<Mutex<Shadow>>,
}

impl File for ShadowFile {
    fn lock_file(&self, exclusive: bool) -> crate::Result<()> {
        self.inner.lock_file(exclusive)
    }
    fn unlock_file(&self) -> crate::Result<()> {
        self.inner.unlock_file()
    }
    fn pread(&self, pos: u64, c: Completion) -> crate::Result<Completion> {
        self.inner.pread(pos, c)
    }
    fn pwrite(&self, pos: u64, buffer: Arc<Buffer>, c: Completion) -> crate::Result<Completion> {
        {
            let mut shadow = self.shadow.lock();
            let data = buffer.as_slice();
            let start = pos as usize;
            let end = start + data.len();
            if shadow.current.len() < end {
                shadow.current.resize(end, 0);
            }
            shadow.current[start..end].copy_from_slice(data);
        }
        self.inner.pwrite(pos, buffer, c)
    }
    fn sync(&self, c: Completion, sync_type: FileSyncType) -> crate::Result<Completion> {
        {
            let mut shadow = self.shadow.lock();
            shadow.durable = shadow.current.clone();
        }
        self.inner.sync(c, sync_type)
    }
    fn size(&self) -> crate::Result<u64> {
        self.inner.size()
    }
    fn truncate(&self, len: u64, c: Completion) -> crate::Result<Completion> {
        self.shadow.lock().current.truncate(len as usize);
        self.inner.truncate(len, c)
    }
}

/// Turso shares one database per path in a process, so each driver opens
/// its own path.
static NEXT_DB: crate::sync::atomic::AtomicU64 = crate::sync::atomic::AtomicU64::new(0);

/// Writes `files` to a new folder, opens the database there and reads the
/// primary keys of `t`.
fn probe_files(db_path: &str, files: &BTreeMap<String, Vec<u8>>) -> Recovery<BTreeSet<i64>> {
    let folder = tempfile::TempDir::new().unwrap();
    for (path, bytes) in files {
        if path.ends_with("-tshm") {
            continue;
        }
        std::fs::write(folder.path().join(path), bytes).unwrap();
    }
    let copy = folder.path().join(db_path);
    let opened = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> crate::Result<_> {
        let io = Arc::new(crate::io::PlatformIO::new()?);
        let db = Database::open_file_with_flags(
            io,
            copy.to_str().unwrap(),
            OpenFlags::default(),
            crate::DatabaseOpts::new(),
            None,
            Arc::new(EngineDialect),
        )?;
        let conn = db.connect(ConnectOpts::new())?;
        let rows = query_rows(&conn, "SELECT pk FROM t")?;
        Ok(rows
            .iter()
            .map(|row| row[0].as_int().expect("pk is an integer"))
            .collect())
    }));
    match opened {
        Ok(Ok(rows)) => Recovery::Read(rows),
        Ok(Err(err)) => Recovery::Error(err.to_string()),
        Err(payload) => Recovery::Panic(
            payload
                .downcast_ref::<String>()
                .cloned()
                .or_else(|| payload.downcast_ref::<&str>().map(|s| s.to_string()))
                .unwrap_or_default(),
        ),
    }
}

/// Where a stepped COMMIT gave control back to the driver.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum EngineStop {
    /// Parked in `AwaitGroupCommit`.
    Parked,
    /// The leader issued `log_tx` for another transaction's record.
    Issued,
    /// The leader marked its own record written.
    MarkedOwn,
    Done,
    /// The statement was dropped and its cleanup ran.
    Dropped,
}

/// Yields at the two group commit yield points and records which one fired.
#[derive(Debug, Default)]
struct GroupStops {
    fired: Mutex<Option<EngineStop>>,
}

impl GroupStops {
    fn take(&self) -> Option<EngineStop> {
        self.fired.lock().take()
    }
}

impl YieldInjector for GroupStops {
    fn should_yield(&self, _instance_id: u64, _selection_key: u64, point: YieldPoint) -> bool {
        let stop = if point == CommitYieldPoint::LogicalLogWriteIssued.point() {
            EngineStop::Issued
        } else if point == CommitYieldPoint::LogRecordMarkedWritten.point() {
            EngineStop::MarkedOwn
        } else {
            return false;
        };
        *self.fired.lock() = Some(stop);
        true
    }
}

struct Writer {
    pk: i64,
    full: bool,
    stops: Arc<GroupStops>,
    commit: Option<crate::Statement>,
    tx_id: u64,
    acked: bool,
}

/// The promises that a replay checks on the engine, besides conformance.
#[derive(Debug, Clone, Copy, Default)]
pub(super) struct Promises {
    /// A Committed FULL transaction survives a power loss.
    pub(super) committed_durable: bool,
    /// A process crash replays no rolled-back transaction.
    pub(super) no_rolled_back_replay: bool,
}

pub(super) struct GroupDriver {
    db_path: String,
    io: Arc<ShadowIo>,
    db: Arc<Database>,
    reader: Arc<Connection>,
    writers: BTreeMap<String, Writer>,
    promises: Promises,
    /// The driver holds the pager commit lock while the spec lock is free, so
    /// that a COMMIT parks where the spec has it wait.
    gate: bool,
    /// A transaction whose engine is ahead of the spec, and the stop it
    /// reached.
    pending: Option<(String, EngineStop)>,
}

/// The spec transactions with SyncMode FULL in every configuration that the
/// committed traces use (MvccGroupCommitConfigs.qnt).
const FULL_TXS: [&str; 2] = ["a", "c"];

impl GroupDriver {
    pub(super) fn new(promises: Promises) -> Self {
        let io = Arc::new(ShadowIo::default());
        let db_path = format!("group-{}.db", NEXT_DB.fetch_add(1, Ordering::Relaxed));
        let db = Database::open_file(io.clone(), &db_path, Arc::new(EngineDialect)).unwrap();
        let setup = db.connect(ConnectOpts::new()).unwrap();
        for sql in [
            "PRAGMA journal_mode = 'mvcc'",
            "CREATE TABLE t(pk INTEGER PRIMARY KEY, v INTEGER)",
            "PRAGMA mvcc_checkpoint_threshold = -1",
            "PRAGMA mvcc_group_commit = on",
        ] {
            setup.execute(sql).unwrap();
        }
        io.mark_all_durable();
        let reader = db.connect(ConnectOpts::new()).unwrap();
        Self {
            db_path,
            io,
            db,
            reader,
            writers: BTreeMap::new(),
            promises,
            gate: false,
            pending: None,
        }
    }

    fn start_writers(&mut self, step: &Step) {
        let names: Vec<String> = step
            .var("txs")
            .entries()
            .iter()
            .map(|(name, _)| name.str().to_string())
            .collect();
        for (i, name) in names.into_iter().enumerate() {
            let conn = self.db.connect(ConnectOpts::new()).unwrap();
            let stops = Arc::new(GroupStops::default());
            conn.set_yield_injector(Some(stops.clone()));
            let full = FULL_TXS.contains(&name.as_str());
            conn.set_sync_mode(if full {
                SyncMode::Full
            } else {
                SyncMode::Normal
            });
            let pk = i as i64 + 1;
            conn.execute("BEGIN CONCURRENT").unwrap();
            conn.execute(format!("INSERT INTO t VALUES ({pk}, 1)"))
                .unwrap();
            let tx_id = conn.get_mv_tx_id().unwrap();
            let commit = conn.prepare("COMMIT").unwrap();
            self.writers.insert(
                name,
                Writer {
                    pk,
                    full,
                    stops,
                    commit: Some(commit),
                    tx_id,
                    acked: false,
                },
            );
        }
        self.take_gate().unwrap();
    }

    fn take_gate(&mut self) -> StepOutcome {
        if !self.gate {
            let mv = self.db.get_mv_store().clone().unwrap();
            if !mv.commit_coordinator.pager_commit_lock.write() {
                return fail(
                    Failure::CommitLock,
                    "the spec lock is free, but the engine commit lock is held",
                );
            }
            self.gate = true;
        }
        Ok(())
    }

    fn release_gate(&mut self) {
        if self.gate {
            let mv = self.db.get_mv_store().clone().unwrap();
            mv.commit_coordinator.unlock_pager_commit_lock();
            self.gate = false;
        }
    }

    /// Steps the COMMIT of `t` to its next stop.
    fn step_commit(&mut self, t: &str) -> std::result::Result<EngineStop, Stop> {
        let io = self.io.clone();
        let db = self.db.clone();
        let w = self.writers.get_mut(t).unwrap();
        let commit = w.commit.as_mut().expect("the COMMIT statement was dropped");
        w.stops.take();
        let mut ios = 0;
        for _ in 0..STEP_LIMIT {
            match commit.step() {
                Ok(StepResult::Done) => {
                    w.acked = true;
                    return Ok(EngineStop::Done);
                }
                Ok(StepResult::Yield) => {
                    if let Some(stop) = w.stops.take() {
                        return Ok(stop);
                    }
                    ios = 0;
                }
                Ok(StepResult::IO) => {
                    ios += 1;
                    if ios >= 3 {
                        let mv = db.get_mv_store().clone().unwrap();
                        if mv.commit_coordinator.parked_tickets().is_empty() {
                            return Err(Stop::Failed {
                                kind: Failure::TxState,
                                detail: format!(
                                    "COMMIT of {t} waits on I/O, but no commit is parked"
                                ),
                            });
                        }
                        return Ok(EngineStop::Parked);
                    }
                    io.step().unwrap();
                }
                Ok(other) => panic!("COMMIT step gave {other:?}"),
                Err(err) => {
                    return Err(Stop::Failed {
                        kind: Failure::TxState,
                        detail: format!("COMMIT of {t} failed: {err}"),
                    })
                }
            }
        }
        panic!("COMMIT of {t} did not stop in {STEP_LIMIT} steps");
    }

    /// The engine stop that matches the spec state of `t` after `step`.
    fn spec_stop(step: &Step, t: &str) -> Option<EngineStop> {
        let x = step.var("txs").get_str(t);
        let owner = |ticket: i64| -> String {
            step.var("recs")
                .get(&Itf::Int(ticket))
                .field("tx")
                .str()
                .to_string()
        };
        match x.field("pc").str() {
            "await" => Some(EngineStop::Parked),
            "done" => Some(EngineStop::Done),
            // The engine runs Drop and DropFinish in one cleanup.
            "dropping" | "dropped" => Some(EngineStop::Dropped),
            "issued" if owner(x.field("writing").int()) != t => Some(EngineStop::Issued),
            _ if step.action == "MarkWritten"
                && step.var("log").items().last().map(|f| f.field("tx").str()) == Some(t) =>
            {
                Some(EngineStop::MarkedOwn)
            }
            _ => None,
        }
    }

    /// Moves `pending` forward with a spec step of its transaction. Returns
    /// true when the spec reached the engine stop.
    fn consume(step: &Step, t: &str, stop: EngineStop) -> std::result::Result<bool, Stop> {
        match Self::spec_stop(step, t) {
            Some(s) if s == stop => Ok(true),
            // The engine passes AwaitGroupCommit without a park when the lock
            // is free, so a spec "await" is not a stop then.
            Some(EngineStop::Parked) | None => Ok(false),
            Some(s) => Err(Stop::Failed {
                kind: Failure::TxState,
                detail: format!("the spec stops {t} at {s:?}, the engine at {stop:?}"),
            }),
        }
    }

    fn pks(frames: &[Itf], writers: &BTreeMap<String, Writer>) -> BTreeSet<i64> {
        frames
            .iter()
            .map(|f| writers[f.field("tx").str()].pk)
            .collect()
    }

    /// The state of `t` in the engine, with the names of the spec.
    fn engine_state(&self, t: &str) -> &'static str {
        let mv = self.db.get_mv_store().clone().unwrap();
        let w = &self.writers[t];
        let state = mv.txs.get(&w.tx_id).map(|e| e.value().state.load());
        match state {
            Some(TransactionState::Committed(_)) => "Committed",
            Some(TransactionState::Aborted | TransactionState::Terminated) => "RolledBack",
            Some(_) => "Preparing",
            None => {
                let rows = query_rows(
                    &self.reader,
                    &format!("SELECT pk FROM t WHERE pk = {}", w.pk),
                )
                .unwrap();
                if rows.is_empty() {
                    "RolledBack"
                } else {
                    "Committed"
                }
            }
        }
    }

    fn check(&self, step: &Step) -> StepOutcome {
        let mv = self.db.get_mv_store().clone().unwrap();
        let grp = step.var("grp");
        let coordinator = &mv.commit_coordinator;
        for (name, engine, spec) in [
            (
                "durable_through",
                coordinator.durable_through(),
                grp.field("durable").int(),
            ),
            (
                "written_through",
                coordinator.written_through(),
                grp.field("written").int(),
            ),
        ] {
            if engine as i64 != spec {
                return fail(
                    Failure::Watermark,
                    format!("{name} is {engine} in the engine, {spec} in the spec"),
                );
            }
        }
        let mut committed_full = BTreeSet::new();
        let mut rolled_back = BTreeSet::new();
        let mut acked_full = BTreeSet::new();
        for (t, w) in &self.writers {
            let x = step.var("txs").get_str(t);
            // DropFinish has not run in the spec, but the engine cleanup has.
            // ReplaySegments runs DropFinish next, so grp.issued is still the
            // value that it reads.
            let spec = if x.field("pc").str() == "dropping" {
                if grp.field("issued").str() == t {
                    "Preparing"
                } else {
                    "RolledBack"
                }
            } else {
                x.field("st").str()
            };
            let engine = self.engine_state(t);
            if engine != spec {
                return fail(
                    Failure::TxState,
                    format!("{t} is {engine} in the engine, {spec} in the spec"),
                );
            }
            if engine == "Committed" && w.full {
                committed_full.insert(w.pk);
            }
            if engine == "RolledBack" {
                rolled_back.insert(w.pk);
            }
            if w.acked && w.full {
                acked_full.insert(w.pk);
            }
        }

        let mut spec_file = Self::pks(step.var("log").items(), &self.writers);
        spec_file.extend(Self::pks(step.var("unadvanced").items(), &self.writers));
        let spec_disk = Self::pks(step.var("disk").items(), &self.writers);

        let crash_rows = match probe_files(&self.db_path, &self.io.snapshot(false)) {
            Recovery::Read(rows) => rows,
            Recovery::Error(err) => return fail(Failure::RecoveryError, err),
            Recovery::Panic(msg) => return fail(Failure::RecoveryPanic, msg),
        };
        if crash_rows != spec_file {
            return fail(
                Failure::RecoveryRows,
                format!(
                    "a process crash recovers {crash_rows:?}, the spec file holds {spec_file:?}"
                ),
            );
        }
        let power_rows = match probe_files(&self.db_path, &self.io.snapshot(true)) {
            Recovery::Read(rows) => rows,
            Recovery::Error(err) => return fail(Failure::RecoveryError, err),
            Recovery::Panic(msg) => return fail(Failure::RecoveryPanic, msg),
        };
        if power_rows != spec_disk {
            return fail(
                Failure::RecoveryRows,
                format!("a power loss recovers {power_rows:?}, the spec disk holds {spec_disk:?}"),
            );
        }

        if !acked_full.is_subset(&power_rows) {
            return fail(
                Failure::AckNotDurable,
                format!("FULL commits {acked_full:?} returned success, a power loss recovers {power_rows:?}"),
            );
        }
        if self.promises.committed_durable && !committed_full.is_subset(&power_rows) {
            return fail(
                Failure::CommittedNotDurable,
                format!("FULL commits {committed_full:?} are Committed, a power loss recovers {power_rows:?}"),
            );
        }
        if self.promises.no_rolled_back_replay
            && !(crash_rows.is_disjoint(&rolled_back) && power_rows.is_disjoint(&rolled_back))
        {
            return fail(
                Failure::RolledBackReplayed,
                format!(
                    "rolled-back {rolled_back:?}, a process crash recovers {crash_rows:?}, \
                     a power loss recovers {power_rows:?}"
                ),
            );
        }
        Ok(())
    }
}

impl Driver for GroupDriver {
    fn finish(&mut self) -> StepOutcome {
        match &self.pending {
            Some((t, stop)) => refuse(format!(
                "the trace ends while the engine ran {t} ahead to {stop:?}"
            )),
            None => Ok(()),
        }
    }

    fn run_step(&mut self, _index: usize, step: &Step) -> StepOutcome {
        if self.writers.is_empty() {
            self.start_writers(step);
        }
        let t = step.pick("t").str().to_string();
        if let Some((p, stop)) = self.pending.clone() {
            if p != t {
                return refuse(format!(
                    "{} runs while the engine runs {p} to {stop:?} in one step",
                    step.action
                ));
            }
            if step.action == "Drop" {
                return refuse(format!("{t} drops inside an engine step"));
            }
            if !Self::consume(step, &t, stop)? {
                return Ok(());
            }
            self.pending = None;
        } else {
            let x = step.var("txs").get_str(&t);
            match step.action.as_str() {
                "Drop" => {
                    let commit = self.writers.get_mut(&t).unwrap().commit.take();
                    drop(commit);
                    if !Self::consume(step, &t, EngineStop::Dropped)? {
                        self.pending = Some((t, EngineStop::Dropped));
                        return Ok(());
                    }
                }
                "DropFinish" => {}
                // The parked engine commit runs this step together with End.
                "Await" if x.field("pc").str() == "end" && !x.field("led").bool() => {}
                action => {
                    if action == "Await" && step.var("lock").str() == t {
                        self.release_gate();
                    }
                    let stop = self.step_commit(&t)?;
                    if !Self::consume(step, &t, stop)? {
                        self.pending = Some((t, stop));
                        return Ok(());
                    }
                }
            }
        }
        if step.var("lock").str().is_empty() {
            self.take_gate()?;
        }
        self.check(step)
    }
}

/// The reachability events in the last state of a trace.
fn seen_events(trace: &str) -> BTreeSet<String> {
    let steps = itf::parse_trace(trace);
    steps
        .last()
        .unwrap()
        .var("seen")
        .items()
        .iter()
        .map(|e| e.str().to_string())
        .collect()
}

/// Traces of the mbt module from `make traces SPECS=MvccGroupCommit`, with
/// ReplaySegments on.
const GENERATED_GROUP_TRACES: &[(&str, &str)] = &[
    ("group-28", include_str!("traces/group-28.itf.json")),
    ("group-63", include_str!("traces/group-63.itf.json")),
    ("group-105", include_str!("traces/group-105.itf.json")),
    ("group-14", include_str!("traces/group-14.itf.json")),
    ("group-0", include_str!("traces/group-0.itf.json")),
    ("group-1", include_str!("traces/group-1.itf.json")),
    ("group-10", include_str!("traces/group-10.itf.json")),
    ("group-100", include_str!("traces/group-100.itf.json")),
];

/// The reachability events that the replayed traces must cover together.
/// A change that refuses more traces drops some of them.
const COVERED_EVENTS: &[&str] = &[
    "abandon",
    "abandonCommit",
    "abandonRollback",
    "batch2",
    "dropCommit",
    "normalLeaderSyncs",
    "retry",
    "rollbackWritten",
    "skipDropped",
    "syncPrefix",
];

#[test]
fn generated_group_traces_conform() {
    let mut covered = BTreeSet::new();
    let mut replayed = 0;
    for (name, trace) in GENERATED_GROUP_TRACES {
        let mut driver = GroupDriver::new(Promises::default());
        if replay(name, trace, Expect::Conforms, &mut driver) == Replay::Done {
            replayed += 1;
            covered.extend(seen_events(trace));
        }
    }
    assert_eq!(
        replayed,
        GENERATED_GROUP_TRACES.len(),
        "a generated trace was refused"
    );
    for event in COVERED_EVENTS {
        assert!(
            covered.contains(*event),
            "no replayed trace reaches {event}"
        );
    }
}

/// A trace that ends while the engine is ahead of the spec is refused, not
/// counted as replayed: its last spec state was never checked.
#[test]
fn trace_that_ends_inside_an_engine_step_is_refused() {
    let full = include_str!("traces/group-committed-not-durable.itf.json");
    let mut json: serde_json::Value = serde_json::from_str(full).unwrap();
    json["states"].as_array_mut().unwrap().truncate(3);
    let prefix = json.to_string();
    let mut driver = GroupDriver::new(Promises::default());
    let replayed = replay("group-prefix", &prefix, Expect::Conforms, &mut driver);
    assert_eq!(replayed, Replay::Refused);
}

/// `dropCommitsUnsynced` on the engine: a FULL COMMIT drops after its record
/// is written, and cleanup makes it Committed with no fsync.
#[test]
fn dropped_commit_is_committed_before_fsync() {
    let mut driver = GroupDriver::new(Promises {
        committed_durable: true,
        no_rolled_back_replay: false,
    });
    let replayed = replay(
        "group-committed-not-durable",
        include_str!("traces/group-committed-not-durable.itf.json"),
        Expect::Violation {
            step: 7,
            kind: Failure::CommittedNotDurable,
        },
        &mut driver,
    );
    assert_eq!(replayed, Replay::Done);
}

/// `dropResurrects` on the engine: a waiter rolls back after the leader
/// issued its record, and a crash replays it.
#[test]
fn rolled_back_waiter_is_replayed_after_crash() {
    let mut driver = GroupDriver::new(Promises {
        committed_durable: false,
        no_rolled_back_replay: true,
    });
    let replayed = replay(
        "group-rolled-back-replayed",
        include_str!("traces/group-rolled-back-replayed.itf.json"),
        Expect::Violation {
            step: 8,
            kind: Failure::RolledBackReplayed,
        },
        &mut driver,
    );
    assert_eq!(replayed, Replay::Done);
}

#[test]
#[ignore]
fn group_traces_from_folder() {
    let folder = std::env::var("MBT_TRACES").expect("set MBT_TRACES to a folder of traces");
    let mut paths: Vec<_> = std::fs::read_dir(folder)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| {
            let name = path.to_string_lossy();
            name.contains("MvccGroupCommit") && name.ends_with(".itf.json")
        })
        .collect();
    paths.sort();
    let (mut done, mut refused) = (0, 0);
    for path in &paths {
        let trace = std::fs::read_to_string(path).unwrap();
        let name = path.file_name().unwrap().to_string_lossy().to_string();
        let mut driver = GroupDriver::new(Promises::default());
        match replay(&name, &trace, Expect::Conforms, &mut driver) {
            Replay::Done => {
                done += 1;
                let events = seen_events(&trace);
                println!("{name}: replayed, events {events:?}");
            }
            Replay::Refused => refused += 1,
        }
    }
    println!("{done} traces replayed, {refused} refused");
}
