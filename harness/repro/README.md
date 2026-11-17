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
