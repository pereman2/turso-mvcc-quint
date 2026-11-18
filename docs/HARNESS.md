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
| `mbt_tests/rows.rs` | The actions of `MvccPassiveCheckpoint`, for the passive flag and for mode B |
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

## Mode B traces

The row driver also replays the traces of the modules `mbtBlocking` and
`mbtBlockingPin` (`make traces SPECS=MvccPassiveCheckpoint MBT=mbtBlocking`).
`RowDriver::new_blocking` opens the database with the passive flag off. A B
pass is one spec step. The driver creates a `CheckpointStateMachine` with
`CheckpointMode::Truncate`, steps it to the publish window and records the new
frame, then steps it to the end. It fails with `Failure::CheckpointResult`
when the engine result differs from the spec.

- `RowDriver::gc` calls `gc_chain_now` on one chain, not `gc_incremental`. So
  the replay skips the gate try lock, the empty slot unlink and the stuck-`lwm`
  early return of `gc_incremental`. The sample of `lwm` is the engine one
  (`sample_gc_lwm`).
- After each `Gc` step and each B pass, `check_chains` compares the number of
  versions of every key in the engine (the chain in `rows`) with the size of
  `chain[k]` in the spec. A difference fails with `Failure::Chain`. The count
  includes committed versions, Preparing versions and the begin-None marker of
  a row that only the B-tree had. This replaces the old check "the store is
  empty after a pass", so a failed pass followed by a successful one replays
  right. After a failed pass, a successful pass can leave versions in both,
  and the check compares them.
- `CheckpointBlockingFail` must return `Busy`. The driver cannot inject an I/O
  error at `CheckpointWal`, so it refuses such a trace when no reader is
  pinned. Every failed pass in the replay comes from a pager pin that holds no
  gate (`pager.begin_read_tx()`, the `PagerPinsWithoutGate` path).
- In mode B the driver also scans the table (`SELECT k, v FROM t`) at each
  read, to reach the other look of the dual cursor. The crash copy opens with
  the flag off.
- The spec `Lwm` counts the begin tick of a writer that is not finished when
  `WriterBeginTicks` is on, as the engine does (`compute_lwm`). Before that
  change, 19 of 300 traces of `mbtBlockingPin` failed the chain check at a
  `Gc` step, because the spec dropped a version that the engine kept for an
  unfinished writer.

Run on 2026-11-17 at the pinned rev 0c9fe0dd9:

- 60 fresh traces of `mbtBlocking`: `60 traces: 60 replayed, 0 refused, 0
  failed`. 300 fresh traces of `mbtBlockingPin` (`PagerPinsWithoutGate` and
  `FixB2WaitsForPinned` on): `300 traces: 300 replayed, 0 refused, 0 failed`.
  These traces have 61 and 81 states.
- 8 committed traces in `generated_blocking_row_traces_conform`. Three are
  directed: `rows-blocking-gc-read-13` (a `Gc` drop while a reader is open,
  then a read of that key), `rows-blocking-pin-171` (the same, and a failed pass
  followed by a successful one that leaves a version) and
  `rows-blocking-fail-then-pass-220` (a failed pass, then a successful one that
  leaves a version).
- The bug trace of `blockingPagerPin`: the engine fails at step 16 with
  `WrongRead`.
- The negative control for the chain check, the bug trace of `blockingNoB2Keep`:
  the engine fails at step 11 with `Chain`. The spec drops the delete marker
  at the `Gc` step and the engine keeps it.
- All of `mbt_tests`: 14 passed, 5 ignored.

The engine has no fix of `FixB2WaitsForPinned`. The fixed spec allows no
`Gc` step while a stale pin exists, so these traces never run the engine GC
inside the bug window. In the 300 traces, 850 states had a stale pin, and
none of the 167 `Gc` steps ran in one (a review run). Only the bug trace of
`blockingPagerPin` tests the engine inside that window.

The `Lwm` change also changes the passive trace module `mbt`, which has
`WriterBeginTicks` on. 80 fresh `mbt` traces replay at the pinned rev with 0
refused and 0 failed (a review run). The checked passive modules have it off,
so their results do not change.

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
`rootpage_gc_protected` holds. `GcSample`, `GcApply` and `GcApplyCatalog`
do the same in steps: the driver samples the lwm and the floor at `GcSample`
and uses them at each apply step. After every step, the driver checks that the
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

## Sync traces

The sync tests need the cargo feature `conn_raw_api`, because the engine
builds the object map only with it. Run them with
`harness/run-in-turso.sh -- --features conn_raw_api mbt_tests::schema`.

| Test | Trace | Expect | What the engine does |
|---|---|---|---|
| `sync_traces_conform` | `reachMapsPageId` | Conforms | A row record carries `-page`, and the object map names its table |
| `sync_traces_conform` | `reachStableIdChanges` | Conforms | A row record carried the temporary id, and the `rootpage` column now holds the page. The rootpage check runs at step 24 (`CheckpointPublish`) |
| `rowid_cache_traces_conform` | `reachRowidAcrossPublish`, `reachRowidPendingPair` | Conforms | Each spec writer is a connection with `BEGIN CONCURRENT` and an `INSERT` with no rowid. `last_insert_rowid()` must equal the spec rowid `wr[w].n` at each `RowAlloc`. The cache survives the checkpoint publish (`Failure::Rowid` otherwise). Run it with `mbt_tests::schema::rowid_cache` |
| `map_in_pass_trace_conforms_until_issue_11502` | `reachMapsInPass` | `RecoveryRows` at step 19 | A row commits with its temporary id while a pass that creates its B-tree is open. The object map names the table. After a crash, recovery loses the row (#11502) |
| `issue_8004_sync_trace_fails_insert` | `issue8004Sync` | `ObjectMap` at step 18 | The `INSERT` fails with `Corrupt`, and the spec has `omap = "-"` at that step |

`write_row` turns on portable changes on the writer connection when the
spec records an object map. Two checks follow.

- The engine agrees with the spec (`Failure::ObjectMapSpec`). A successful
  `INSERT` needs `omap[table] == table` in the spec. An `INSERT` that fails
  with "cannot resolve user data table id" needs `omap[table] == "-"`. Any
  other error panics, as before. After a successful `INSERT`,
  `portable.rs` reads the newest commit frame twice: its row records
  (`StreamingLogicalLogReader::next_frame`) and its object map
  (`next_portable_changes`). The two commit timestamps must be equal, and
  the frame must have one table row record. Its table id must have the form
  of the spec record: the engine temporary id of the table, or `-page` of its
  engine binding.
- The promise holds (`Failure::ObjectMap`). The `INSERT` succeeds, the object
  map resolves that exact record id to the table, and no entry names another
  table. This is `ObjectMapCorrect`, as the recovery check is
  `RecoveryCorrect`.

After every step of a trace with `omap`, `check_root_columns` reads
`SELECT name, rootpage FROM sqlite_schema WHERE type = 'table'` on a probe
connection (`Failure::RootPage`). Each table that is live in the spec has a
row, and no other spec table does. Its `rootpage` has the form of `RootCol`:
the engine temporary id of the table, or the engine page of its binding. All
live tables, also the internal ones, have distinct `abs(rootpage)`. The check
skips a state with a `Preparing` DDL. `sync_traces_conform` prints the steps
that it checked and asserts that step 24 of `reachStableIdChanges` is one of
them (`docs/logs/gap12/r3-replay.log`).

The sync modules turn `CatalogReads` on, so `check_catalog_chains` compares
the catalog GC of the engine with the spec after every step, as for the
catalog traces. The trace `reachMapsInPass` also hits #11502, because a row
that commits during the first pass of its table is the #11502 shape. Some
other seeds of the reach modules hit #11502 too: 3 of 8 seeds of
`reachMapsPageId` and 1 of 8 of `reachStableIdChanges`, in a replay before
the rootpage check (`docs/logs/gap12/seeds.log`). The kept traces are
seed 1. An `issue11501Sync` trace cannot replay, because the driver pads ids
so that the engine never makes the collision. The Rust test in
`harness/repro/sync-object-map-11501.patch` covers that path.

## Bug traces

| Variant | Trace | Engine result |
|---|---|---|
| `issue11502` | 8 steps | Fails at step 8: after a crash, `t2` exists without its row |
| `issue11499` | 11 steps | Fails at step 11: the publish writes the header cookie 1 while the shared schema has version 2 |
| `blockingPagerPin` | 17 steps | Fails at step 16 with `WrongRead`: GC drops a delete after a B pass failed with `Busy`, and a reader with an old mark reads the deleted row |

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

## Traces of the mode T, owner and GC-in-steps variants

| Trace | Engine result |
|---|---|
| `reachBeginMidPublish`, `ownerCatalog` | Refused: the driver has no mode T publish steps and no checkpoint on a reader's connection |
| `reachGcWithPinned` | Refused at the `GcApply` step: `rootpage_gc_protected` holds in the engine |
| `reachGcAfterBegin` | Not replayed to the `GcApply` step. The traces that `quint run` found stop first at the existing `GcDropped` hole at `CheckpointFinish` or at the refusal of a frame between a pin and a begin. So this run does not show that the engine rechecks the lwm |
| 200 random `gcSample` and `gcSampleCatalog` traces | Most conform. The rest fail with `CookieBehind` (#11499) or `RecoveryRows` (#11502), or `GcDropped` at `CheckpointFinish`, or are refused. Random traces of the old spec `main` fail the same ways |

## WAL restart (gaps 1, 4, 9)

With `ModelWalRestart`, the row driver checks the restart for write after
each `CheckpointBeginPager` step: the engine checkpoint sequence
(`get_checkpoint_seq`) changed if and only if the spec `walSeq` changed
(`checkpoint_begin_pager` in `rows.rs`). Traces from before the constant have
no `walSeq`, and the check skips them. The module `mbtRestart` has the replay
constants with the restart on. The mode T steps stay refused
(`CheckpointRestart`, `CheckpointFinalSweep` have no engine step). The mode T
restart and the final sweep are checked by the probe patch
`harness/repro/wal-restart-floor.patch` (three tests, turso main 9cf2de2d8, see
`harness/repro/README.md`).

## Traces of `ReaderUpdate` (gap 7)

The driver `RowDriver::new_with_updates()` makes readers use `BEGIN CONCURRENT`.
The step `ReaderUpdate` runs an UPSERT, then steps `COMMIT` to
`WaitForDependencies` (after the commit check). The engine decides the
write-write conflict there, and the driver compares it with the spec
(`rmw` gained a row, or not). After a commit that passed, the connection is a
writer under the spec timestamp, and the reader gets a new connection at its
next `ReaderPin`. Failure kind: `Conflict`. The test
`update_witness_traces_conform` replays `ww-<witness>.itf.json` in
`harness/mbt_tests/traces/`, made with `make bug-traces` from the modules
`mbtUpdate*` (the `mbt` constants with `MaxCheckpoints = 2`, 1 key, `Updates = true`).

| Trace | Engine result |
|---|---|
| `ww-reachUpdateCommits` (update at step 28) | Conforms |
| `ww-reachUpdateConflict` (update at step 5) | Conforms: the engine reports the conflict |
| `ww-reachConflictByEndOnly` (update at step 19) | Conforms: the engine reports the conflict |
| `ww-reachConflictAfterGc` (update at step 38) | Conforms: the engine reports the conflict |
| `ww-reachConflictByCurrentOnly` (update at step 5) | Conforms: the engine reports the conflict. The spec leaves out the commit-dependency path. See `DESIGN-rows.md`, "Write-write conflicts and GC" |

Regression replay after the spec got the new variable: 100 fresh traces of
`mbt` and 100 of `mbtBlocking`, before and after, each `100 traces: 100
replayed, 0 refused, 0 failed`. Random traces never hold `ReaderUpdate`,
because those modules have `Updates = false`.

## Limits

- The schema driver supports DDL CREATE and DROP, row writes, the
  checkpoint, catalog scans, catalog GC and row GC. A reader begins with
  `BEGIN CONCURRENT` and checks only its scans of `sqlite_schema`. Its table
  reads (`ReaderOpen`, `ReaderRead`) run nothing. ALTER is not mapped. The
  driver runs an inner `ReaderBegin` as a normal begin, which is right only
  with `FixInnerTxChecks` on.
  So it does not replay the main configuration of the schema spec, or the bug
  traces that need table reads (`issue11501`, `issue11500`).
- The driver refuses the mode T publish steps (`CheckpointPublishRoots`,
  `CheckpointPublishHeader`, `CheckpointPublishSchema`,
  `CheckpointPublishGen`), a checkpoint on a reader's connection
  (`ck.owner`), `InnerCommitCheckpoint` and `GcIndexPhase`. The `Checkpointer`
  runs only passive passes, and the engine runs the mode T window in one call.
- The sequence spec has no driver yet (`setvalRace`).
- The engine picks page numbers and table ids itself. The schema driver
  compares what recovery sees, not the numbers.
- The lost INSERT of #11499 comes from the statement retry loop, which the
  spec does not model. Its Rust test in the issue stays.
