# Trace replay test

This file describes a test that replays Quint traces on the engine. A trace is
a list of spec actions with the state after each one. The test runs the same
actions on a real database and compares the state after each step.
`make traces` and `make bug-traces` write the traces (see `specs/README.md`).

The test can show two things:

- For a trace of a main configuration, the engine follows the design. Every
  check must hold (`Expect::Conforms`).
- For a trace of a bug variant, the engine has the bug that the model
  predicts. The engine must fail at the same step, with the same kind of
  failure (`Expect::Violation`). After the fix, the test fails, and the fix
  changes it to `Expect::Conforms`.

The replay shows that the code can follow the paths of the model. It never
tests paths that the code has and the model lacks. A replay that passes is
evidence for the paths of the model only. PR #11779 builds this test.

## Where the test lives

In turso, the test is a `#[cfg(test)]` module in
`core/mvcc/database/mbt_tests/`. Only a module inside `turso_core` can read the
private `MvStore` fields, the `pub(crate)` yield point enums and
`CheckpointStateMachine::state_for_test()`. The test also needs test-only hooks
in `checkpoint_state_machine.rs` that set the collect threshold and read the
collected rows. Turso does not have these hooks yet.

This repo keeps the module in `harness/mbt_tests/`.
`harness/run-in-turso.sh` copies it into a turso checkout at the pinned rev,
applies `harness/turso-hooks.patch` there, and runs it. The patch adds the
hooks and the `mod mbt_tests` line in `core/mvcc/database/tests.rs`. Quint runs
only offline, from `specs/Makefile`.

| File | Content |
|---|---|
| `mbt_tests/mod.rs` | The replay loop, the yield injector, the checkpoint driver and the crash probe |
| `mbt_tests/itf.rs` | The ITF parser, with `serde_json` |
| `mbt_tests/rows.rs` | The actions of `MvccPassiveCheckpoint` |
| `mbt_tests/schema.rs` | The actions of `MvccPassiveSchema` that the bug traces use |
| `mbt_tests/group.rs` | The actions of `MvccGroupCommit`, on a test IO that keeps the fsynced bytes of each file. `DESIGN-group-commit.md` describes it |
| `mbt_tests/index.rs` | The actions of `MvccPassiveIndex`. It reuses the row driver steps (`DESIGN-indexes.md`) |
| `mbt_tests/traces/*.itf.json` | The committed traces |

To run it from the root of this repo:

```bash
harness/run-in-turso.sh
```

To replay a folder of new row traces from `make traces`:

```bash
MBT_TRACES=$PWD/specs/traces harness/run-in-turso.sh -- \
  mbt_tests::rows::row_traces_from_folder -- --ignored --nocapture
```

## How a step maps to the engine

Each state of an ITF trace records the action (`mbt::actionTaken`) and the
values that the action picked (`mbt::nondetPicks`). The test driver reads both
and runs one engine operation.

- A writer uses its own connection with `BEGIN CONCURRENT`, one write and
  `COMMIT`. The test driver steps the `COMMIT` statement to a named
  `CommitYieldPoint` and stops there: `CommitValidation` for `WritePrepare`,
  `LogRecordMarkedWritten` for `WriteLogAppend`.
- A reader uses `BEGIN` and a `SELECT`, and ends with `ROLLBACK`. A read-only
  `COMMIT` waits for commit dependencies, so it cannot end a reader that
  read a Preparing writer.
- The checkpoint is a `CheckpointStateMachine` on its own connection. The test
  driver steps it until `state_for_test()` reaches the state that ends the
  spec action. `PRAGMA wal_checkpoint` does not work for this, because it
  runs the whole checkpoint inside one opcode.
- A test-only collect threshold of 1 makes the checkpoint yield after each
  key. A spec key that is not dirty in the engine is a no-op.
- Each connection has one `StopAt` yield injector. `StopAt` yields once at
  one yield point and one selection key.

Engine timestamps and WAL frame numbers differ from the spec values. The test
driver keeps a map from each spec commit to its engine timestamp, and from each
spec frame to the engine WAL frame. It compares order through these maps,
never raw numbers. A writer writes its spec commit timestamp as the row value,
so a read compares directly with the spec oracle. A passive WAL restarts at
frame 1 after a full backfill, so the driver counts frames across checkpoint
sequences.

## Checks after each step

| Spec value | Engine value |
|---|---|
| `ReadsCorrect` | The `SELECT` result in the reader transaction equals the spec oracle |
| `RecoveryCorrect` | The crash probe recovers the rows that the spec logged |
| `ck.snap`, `durable` | The checkpoint snapshot and `MvStore::durable_txid_max`, through the timestamp map |
| `wal`, `nBackfill`, `backfillFloor` | The WAL max frame, the backfilled frame and `MvStore::backfill_floor`, through the frame map |
| `llog = {}` | The logical log offset is 0 |
| `CookieNotBehind` | The global header cookie is at least the shared schema version (schema driver) |

The crash probe copies the database file, the `-wal` file and the `.db-log`
file to a new folder. Then it opens the copy with a new `Database` inside
`catch_unwind`. The running database does not change, so the probe can run
after any step. The probe models a process crash, not a power loss, which
matches `RecoveryCorrect`.

## Trace replay constants

Random traces of the row spec take steps that the engine never takes. Four
constants of `MvccPassiveCheckpoint.qnt` make the spec take only engine steps.
They are false in every model-checked module, which then has the same states
as before. The `mbt` module sets them, and `make traces` uses it.

| Constant | Engine behavior |
|---|---|
| `BackfillToLimit` | The passive backfill copies every frame up to the lowest read mark |
| `LogAppendOneAtATime` | A writer holds `pager_commit_lock` from its log write to its commit end |
| `WriterBeginTicks` | A writer takes a begin timestamp before its commit timestamp, so the snapshot below a Preparing writer is above the previous commit |
| `WritersPinMarks` | A `BEGIN CONCURRENT` writer holds a WAL read mark until its commit ends, and the backfill stops at it |

## Refused traces

Some engine steps contain several spec actions. The test driver refuses a
trace that splits such a step. A trace of the `mbt` module splits none of
them, so every such trace replays. Of 3300 traces of the `mbt` module, 3300
replay.

- A reader pins its WAL mark at `ReaderPin` with `Pager::begin_read_tx`. At
  `ReaderBegin` it runs `BEGIN` and a `SELECT`. `begin_fresh_mvcc_tx`
  (`core/vdbe/execute.rs`) adopts a read mark that the caller holds, so the
  engine begins the MVCC transaction on the pinned mark. `ReaderEnd` ends
  the pager read transaction.
- `CheckpointBeginPager` steps the engine past `BeginPagerTxn`. For an empty
  pass it steps to `CheckpointWal`, because the engine then skips the pager
  commit and the publish.
- The driver refuses `CheckpointTruncateDecide` when `SplitLogTruncate` is
  true, because the engine decides and truncates the logical log in one
  step. It refuses `CheckpointPublishBoundary` (mode T) and
  `CheckpointTruncateApply`, which have no engine operation.
- A spec read has two looks at the chain. The engine read is one statement,
  so the driver reads and compares at both `ReaderReadStart` and
  `ReaderReadEnd`. The oracle is the same at both, because every later
  commit timestamp is above the begin of the reader.

The schema driver runs the whole collection at the last `CheckpointObj` of a
pass. A commit between two `CheckpointObj` steps is above the snapshot, so it
changes nothing that the pass collects.

## Catalog traces

The test `catalog_traces_conform` replays one trace of each catalog
reachability check (`DESIGN-schema.md`, "Catalog reads and catalog GC")
with `Expect::Conforms`.

| Trace | What the engine does |
|---|---|
| `reachCatalogNewer` | A reader scans `sqlite_schema` while the newest frame has a table created after its begin (#8093). The scan does not return it |
| `reachCatalogGenerations` | A reader scans while the newest frame has a new table and not the dropped one that the reader sees (#8094). The scan returns only the old table |
| `reachCatalogFromBtree` | GC drops the `sqlite_schema` version of a table, and the reader's scan finds the table in the B-tree |
| `reachCatalogGcDropped` | GC drops the `sqlite_schema` chain of a dropped table (Rule 2) |
| `reachCatalogTomb` | A `DROP` runs on a table whose `sqlite_schema` chain GC dropped, and the engine inserts a tombstone. No scan follows, so the read path of a tombstone is checked only by TLC |

`ReaderReadCatalog` runs `SELECT name FROM sqlite_schema WHERE type =
'table'` in the reader transaction. It compares the count of each spec table
with the spec oracle (`CatalogRead`). `GcCatalog` runs `gc_chain_now` on the
`sqlite_schema` row of the table with the floors of `gc_incremental`. `Gc`
does the same on the row of the table, and refuses the trace when
`rootpage_gc_protected` holds. After every step, the driver checks that the
chain of each `sqlite_schema` row is empty exactly when the spec says that
GC dropped it (`GcKept`, `GcDropped`). This also covers the GC that the
engine runs at the end of a checkpoint pass. A spec reader that pinned a
mark below the newest frame and did not begin has no engine reader, so the
driver refuses a trace where this changes GC. The engine backfills every
frame it can, so the driver also refuses a trace where the spec backfill
stopped before the last frame and the GC results differ. Only
`reachCatalogTomb` runs a `GcCatalog` step, and it drops a live row
(Rule 3). Rule 2 on a dropped row runs only in the GC at the end of a
checkpoint pass (`reachCatalogGcDropped`). A `ReaderBegin` that the spec
refuses (Busy or SchemaUpdated) runs nothing.

A design trace can also hit #11499, which the engine at the pinned rev still
has: a DDL commits between the pager commit and the publish of a checkpoint,
and the publish puts the header cookie behind (`CookieBehind`). The first
`reachCatalogGcDropped` trace did this. The committed one comes from
`quint run --seed 11`. To check a folder of new schema traces:

```bash
MBT_TRACES=$PWD/specs/traces/bugs harness/run-in-turso.sh -- \
  mbt_tests::schema::schema_traces_from_folder -- --ignored --nocapture
```

## Bug traces

| Variant | Trace | Engine result |
|---|---|---|
| `issue11502` | 8 steps | Fails at step 8: after a crash, `t2` exists without its row |
| `issue11499` | 11 steps | Fails at step 11: the publish writes the header cookie 1 while the shared schema has version 2 |

On a fresh database, the engine gives a new table the temporary id -P and
then the page P. Recovery then finds the table by chance. The schema driver
setup frees two pages first. This keeps ids and pages apart, as the
`FixDisjointIds` rule of the spec does.

The shortest `issue11499` trace of `make bug-traces` has an empty checkpoint
pass. In the spec, `CheckpointPublish` writes the staged header cookie for
every pass. In the engine, a pass with an empty write set skips the header
and the publish. So that trace conforms in the engine, and the model
over-approximates the empty pass. The committed trace has a pass that writes
a frame. To find such a trace, check `CookieNotBehind or ck.frame == 0`
instead of `CookieNotBehind`.

## Limits

- The schema driver supports DDL CREATE and DROP, row writes, the
  checkpoint, catalog scans, catalog GC and row GC. A reader begins with
  `BEGIN CONCURRENT` and checks only its scans of `sqlite_schema`. Its table
  reads (`ReaderOpen`, `ReaderRead`) run nothing. ALTER is not mapped. The
  driver runs an inner `ReaderBegin` as a normal begin, which is right only
  with `FixInnerTxChecks` on.
  So it does not replay the main configuration of the schema spec, or the bug
  traces that need table reads (`issue11501`, `issue11500`).
- The sequence spec has no driver yet (`setvalRace`).
- The engine picks page numbers and table ids itself. The schema driver
  compares what recovery sees, not the numbers.
- The lost INSERT of #11499 comes from the statement retry loop, which the
  spec does not model. Its Rust test in the issue stays.
