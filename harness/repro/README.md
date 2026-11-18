# Engine reproducers

Each patch here adds Rust tests to a turso checkout. Each test reproduces a
row of `docs/FINDINGS.md` and fails on turso main.

## group-commit-rows-21-22.patch

The patch applies to turso main at `ae2cb7388`. It adds three tests to
`core/mvcc/database/group_commit_sync_mode_tests.rs`, with `FaultIo`. This
test IO wraps `MemoryIO` and keeps the bytes of each file as of the last
fsync. A test opens a copy of the files as a crash leaves them.

| Test | Row | Expected | Actual on ae2cb7388 |
|---|---|---|---|
| `dropped_full_commit_seen_by_reader_survives_power_loss` | 21 | A row that a reader saw survives a power loss | The reader sees `[1]`, a power loss recovers `[]` |
| `waiter_dropped_between_owner_check_and_log_tx_stays_rolled_back` | 22 | The rolled-back waiter stays rolled back after a restart | `[1]` before the restart, `[1, 2]` after it |
| `waiter_dropped_while_leader_marks_its_record_stays_rolled_back` | 22 | The same | `[1]` before the restart, `[1, 2]` after it |

The row 21 test changes no engine code. The two row 22 tests need the
test-only hook that the patch adds to `core/mvcc/database/mod.rs`
(`race_hooks`, `#[cfg(test)]`). The engine has no yield point in either
window, so no test on unmodified turso can stop there.

To run the tests, use a turso checkout with no local changes:

```bash
git -C <turso> checkout ae2cb7388
git -C <turso> apply <this repo>/harness/repro/group-commit-rows-21-22.patch
cd <turso>
cargo test -p turso_core --lib group_commit_sync_mode_tests -- --nocapture
```

Each of the three tests failed in 3 of 3 runs.

## mode-b-pager-pin.patch

The patch applies to turso main at `2827d0cc1`. It adds three tests to
`core/mvcc/database/tests.rs`. They run with the flag
`experimental_mvcc_passive_checkpoint` off (mode B). They change no engine code.

| Test | Row or gap | Expected | Actual on 2827d0cc1 |
|---|---|---|---|
| `probe_mode_b_pager_pin_after_failed_publish` | Row 24 | A reader that pinned its read mark before a DELETE reads no row | It reads the deleted row `(1, 'a')` |
| `probe_mode_b_pager_pin_after_failed_publish_no_gc` | Row 24, control | The same steps without `gc_incremental` read no row | Passes |
| `probe_mode_b_stamp_after_restart` | Gap 14 | The WAL position after each pass is not `(0, 0)`. The test prints `rows_versions` and does not assert it | Passes. It prints `(3, 0)`, `(4, 0)` and `(5, 0)` |

The row 24 test pins the read mark with `pager.begin_read_tx()`, the same call
as `maybe_reparse_schema` (`core/connection.rs:1413`). No test through a public
API stops in that window.

```bash
git -C <turso> checkout 2827d0cc1
git -C <turso> apply <this repo>/harness/repro/mode-b-pager-pin.patch
cd <turso>
cargo test -p turso_core --lib probe_mode_b -- --nocapture --test-threads=1
```

## sync-object-map-11501.patch

The patch applies to turso main at `ae2cb7388`. It adds one test to
`tests/integration/mvcc/database.rs`. The test builds the state of issue
#11501: `sqlite_schema` has `t6` with `rootpage` 10 and `t7` with `rootpage`
-10. It turns portable changes on, runs `INSERT INTO t6`, and decodes the
object map of that commit frame. The test changes no engine code.

| Test | Row | Expected | Actual on ae2cb7388 |
|---|---|---|---|
| `portable_object_map_names_the_written_table_when_a_temp_id_equals_its_page` | 26 | The object map of the commit names `t6` | The object map is `[{ mv_table_id: -10, name: "t7" }]`, so a push sends the row of `t6` as a row of `t7` |

To run the test, use a turso checkout with no local changes:

```bash
git -C <turso> checkout ae2cb7388
git -C <turso> apply <this repo>/harness/repro/sync-object-map-11501.patch
cd <turso>
cargo test -p core_tester --test integration_tests portable_object_map_names_the_written_table_when_a_temp_id_equals_its_page -- --nocapture
```

The test failed in 3 of 3 runs, with `left: "t7"` and `right: "t6"`.

## sync-object-map-8004.patch

The patch applies to turso main at `ae2cb7388`. It adds one test to
`tests/integration/mvcc/database.rs`. The test pads the ids so that the
temporary id of `t1` is not `-(its page)`. A passive checkpoint stops before
its publish (a yield injector at `BeforePublishWindow`). `conn2` runs
`BEGIN; CREATE TABLE t2(x)`. The checkpoint publishes the page of `t1` and
stops again (`AfterDurableBoundaryAdvanced`). `conn2` commits and installs its
old copy of the schema (#8004). The checkpoint finishes, and its GC drops the
`sqlite_schema` versions of `t1`. Then three connections turn portable
changes on and run `INSERT INTO t1`. The test changes no engine code.

| Test | Row | Expected | Actual on ae2cb7388 |
|---|---|---|---|
| `portable_insert_after_stale_schema_install_and_catalog_gc` | 27 | Each `INSERT INTO t1` succeeds | `conn1`, `conn2` and a new `conn3` get `Corrupt("portable changes cannot resolve user data table id MVTableId(-4)")`. After one more checkpoint, a new connection succeeds |

To run the test, use a turso checkout with no local changes:

```bash
git -C <turso> checkout ae2cb7388
git -C <turso> apply <this repo>/harness/repro/sync-object-map-8004.patch
cd <turso>
cargo test -p core_tester --test integration_tests portable_insert_after_stale_schema_install_and_catalog_gc -- --nocapture
```

The test failed in 3 of 3 runs.

## commitend-rewrite-leak.patch

The patch applies to turso main at `9cf2de2d8`. It adds three tests to
`core/mvcc/database/tests.rs` and changes no engine code. A group commit
follower F is between `CommitEnd` and `FinalizeCommit` (its rewrite yields after
1024 rows). A later commit B finishes, and a passive pass stamps the rows of F.
Then the rewrite resets the stamps and GC never drops the rows (gap 22).

| Test | Gap | Expected | Actual on 9cf2de2d8 |
|---|---|---|---|
| `group_commit_rewrite_window_keeps_checkpoint_stamps` | 22 | No row version of `t` stays in `mv_store.rows` after the reader ends and three more passes | 76 versions stay |
| `out_of_order_commit_rewrite_window_keeps_checkpoint_stamps` | 22 | The same, without group commit: A waits in `BuildLogRecord`, B commits to the end, then the pass runs in the window of A | 76 versions stay |
| `serialized_commit_rewrite_window_keeps_checkpoint_stamps` | 22, control | The same steps without group commit leave none | Passes, 0 left |

The test uses the SQL of public API only for the data. To place F in the window
it steps each `COMMIT` and holds `pager_commit_lock` by hand until the leader and
F are both queued (as `commit_parks_once_while_another_transaction_holds_the_commit_lock` does).
It reads `MvStore::rows` to count versions.

```bash
git -C <turso> checkout 9cf2de2d8
git -C <turso> apply <this repo>/harness/repro/commitend-rewrite-leak.patch
cd <turso>
cargo test -p turso_core --lib rewrite_window_keeps_checkpoint_stamps -- --nocapture --test-threads=1
```

The group commit test and the out of order test failed in 3 of 3 runs each, with 76 versions left each time.

## gap7-preparing-delete-25a.patch

The patch applies to turso main at `9cf2de2d8`. It adds two tests to
`core/mvcc/database/tests.rs` for row 25a. They change no engine code. They
use turso's own yield hook `Connection::set_yield_injector`
(`#[cfg(any(test, injected_yields))]`) to stop A's COMMIT at
`WaitForDependencies`, so A stays Preparing.

| Test | Expected | Actual on 9cf2de2d8 |
|---|---|---|
| `preparing_delete_below_begin_does_not_abort_a_later_insert` | B's COMMIT waits for A, then both commit and the table holds `(1, 'new')` | B's COMMIT fails with `Err(WriteWriteConflict)` while A is `Preparing(6)` and B began at 7 |
| `preparing_delete_below_begin_control_after_writer_commits` | B commits after A finished its COMMIT | B commits |

To run the tests, use a turso checkout with no local changes:

```bash
git -C <turso> checkout 9cf2de2d8
git -C <turso> apply <this repo>/harness/repro/gap7-preparing-delete-25a.patch
cd <turso>
cargo test -p turso_core --lib preparing_delete_below_begin -- --test-threads=1
```

The first test failed in 10 of 10 runs. The control passed in 10 of 10.
The patch also applies to turso main at `624ed32dbb`. There the first test
failed in 3 of 3 runs with the same error, and the control passed in 3 of 3.

Duplicate search, `gh issue list -R tursodatabase/turso --state all --search`
on 2026-11-18: "WriteWriteConflict preparing", "WriteWriteConflict preparing
delete", "write-write conflict commit dependency", "spurious write write
conflict MVCC", "check_version_conflicts", "mvcc write write conflict" and
"false conflict BEGIN CONCURRENT delete insert". The nearest issues are #5954,
#6014 and #6338, with different causes. No duplicate.

## passive-checkpoint-normal-power-loss.patch

The patch applies to turso main at `740300d9d`. It adds three tests to
`tests/integration/mvcc/checkpoint.rs`, with the shared `UnreliableIo`
(`durable_files()` is the power-loss image). It changes no engine code. The
flag `experimental_mvcc_passive_checkpoint` is on and `PRAGMA synchronous=NORMAL`
is set on the checkpointing connection.

| Test | Expected | Actual on 740300d9d | Actual on 3fcfb6fc9 |
|---|---|---|---|
| `passive_checkpoint_under_normal_with_pinned_reader_keeps_committed_row_after_power_loss` | After a power loss the row `42` is still there | The read gives `[]` | The read gives `[]` |
| `passive_checkpoint_under_normal_with_pinned_reader_keeps_fsynced_row_after_power_loss` | Same, with a `synchronous=FULL` commit of `42` before the checkpoint | The read gives `[]` | Passes |
| `passive_checkpoint_power_loss_controls_keep_committed_row` | `synchronous=FULL` with a pinned reader, and NORMAL with no pinned reader, keep `42` | Passes | Passes |

A second connection holds `BEGIN` plus a `SELECT`. The passive backfill then
copies no frame, so nothing fsyncs the WAL. The checkpoint truncates and fsyncs
the logical log. The WAL frames with the row stay unsynced and the log is empty.
In the second test the log record was durable, and the checkpoint still loses
the row.

```bash
git -C <turso> checkout 740300d9d
git -C <turso> apply <this repo>/harness/repro/passive-checkpoint-normal-power-loss.patch
cd <turso>
cargo test -p core_tester --test integration_tests passive_checkpoint_ -- --nocapture --test-threads=1
```

Each of the two failing tests failed in 3 of 3 runs on 740300d9d. On 3fcfb6fc9
the patch applies as is, and each test gives the same result in 3 of 3 runs.
The FULL-commit test passes there because turso commit d52ed55ca removed the
log fsync after the checkpoint truncate. The power loss now drops the
truncate too, so the durable log keeps the frame. A probe that fsyncs the WAL
in the Busy arm before `TruncateLogicalLog` when `sync_mode != Off` makes all
three pass. The probe covers only the Busy arm and is not a full fix. A pass
that returns OK with 0 frames copied (the reader mark sits at `nbackfills`,
`wal.rs:1209-1230`, `core/mvcc/database/checkpoint.rs:3344-3347`) also leaves
the WAL unsynced.


```diff
--- a/core/mvcc/database/checkpoint.rs
+++ b/core/mvcc/database/checkpoint.rs
@@ -3320,6 +3320,14 @@ CheckpointStateMachine
                         self.checkpoint_result =
                             Some(CheckpointResult::new(max_frame, nbackfills, 0));
                         self.state = CheckpointState::TruncateLogicalLog;
+                        if self.sync_mode != SyncMode::Off {
+                            if let Some(wal) = self.pager.wal.as_ref() {
+                                let c = wal.sync(crate::io::FileSyncType::Fsync)?;
+                                if !c.succeeded() {
+                                    return Ok(TransitionResult::Io(IOCompletions(c)));
+                                }
+                            }
+                        }
                         Ok(TransitionResult::Continue)
                     }
                     Err(e) => Err(*e),
```

Duplicate search, `gh issue list -R tursodatabase/turso --state all --search`
on 2026-11-18: "synchronous NORMAL", "power loss", "logical log truncate" and
"passive checkpoint busy". The nearest issues are #7952 (closed, the backfill
fsync that this path skips), #11507 and #12005 (other causes). No duplicate.

## mvcc-log-fsync-error-commits.patch

The patch applies to turso main at `624ed32db`. It adds a new file
`core/mvcc/database/log_fsync_error_tests.rs` and registers it in
`core/mvcc/database/tests.rs`. It changes no engine code. The tests use a
`FaultIo` like the one in `group-commit-rows-21-22.patch`, plus a switch that
makes one fsync of the `-log` file fail. Row 30.

| Test | Expected | Actual on 624ed32db |
|---|---|---|
| `failed_log_fsync_must_not_leave_visible_but_lost_row` | After the INSERT returns an error, a new reader does not see pk 1, or a power loss restores it | The reader sees `[1]`, a power loss recovers `[]`, and a second INSERT fails with a UNIQUE error |
| `dropped_plain_commit_must_not_leave_visible_but_lost_row` | The same, for a plain COMMIT dropped at `LogRecordMarkedWritten` | The reader sees `[1]`, a power loss recovers `[]` |

```bash
git -C <turso> checkout 624ed32db
git -C <turso> apply <this repo>/harness/repro/mvcc-log-fsync-error-commits.patch
cd <turso>
cargo test -p turso_core --lib log_fsync_error_tests -- --nocapture --test-threads=1
```

Both tests failed in 3 of 3 runs on `624ed32db`. On 2026-11-18 the patch also
applied to turso main `3fcfb6fc98` on a clean checkout. The command below ran 3
times there, and each run gave 0 passed and 2 failed, with the same values.

```bash
cargo test -j6 -p turso_core --lib log_fsync_error_tests -- --nocapture --test-threads=1

## wal-restart-floor.patch

The patch applies to turso main at `9cf2de2d8`. It adds three probes to
`core/mvcc/database/tests.rs` (passive flag on). Each one prints and asserts
literal values. They pass on main. They check the facts that the row spec
`ModelWalRestart` relies on (gaps 1, 4, 9).

| Test | Gap | Expected and actual on 9cf2de2d8 |
|---|---|---|
| `probe_t_pager_pin_before_pass_busy` | 4 | A pager pin with no MVCC tx, then `PRAGMA wal_checkpoint(TRUNCATE)`: `Err(Busy)`, and a later read gives `b` |
| `probe_t_r5_reader_after_restart` | 9 | After a T checkpoint the WAL position is `(s+1, 0)` (`(3, 0)` to `(4, 0)`). A reader that pins then has `rows_versions = 0` and reads `b` |
| `probe_p_restart_blocked_by_db_file_reader` | 1 | Four passive checkpoints with a database file reader open: sequence stays 2. The reader makes the backfill fail on read lock 0 (wal.rs:2221), so condition 4 of wal.rs:5367 keeps the restart off. The single-reader upgrade rule (wal.rs:371) is shown by code reading only. The same rounds with no reader: 2, 3, 4, 5 |

```bash
git -C <turso> checkout 9cf2de2d8
git -C <turso> apply <this repo>/harness/repro/wal-restart-floor.patch
cd <turso>
cargo test -p turso_core --lib probe_ -- --nocapture --test-threads=1
```
