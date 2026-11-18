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

The patch applies to turso main at `9cf2de2d8`. It adds two tests to
`core/mvcc/database/tests.rs` and changes no engine code. A group commit
follower F is between `CommitEnd` and `FinalizeCommit` (its rewrite yields after
1024 rows). A later commit B finishes, and a passive pass stamps the rows of F.
Then the rewrite resets the stamps and GC never drops the rows (gap 22).

| Test | Gap | Expected | Actual on 9cf2de2d8 |
|---|---|---|---|
| `group_commit_rewrite_window_keeps_checkpoint_stamps` | 22 | No row version of `t` stays in `mv_store.rows` after the reader ends and three more passes | 76 versions stay |
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

The group commit test failed in 3 of 3 runs, with 76 versions left each time.
