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
