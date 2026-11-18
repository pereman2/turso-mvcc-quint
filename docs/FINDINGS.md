# Findings

This file lists each claim that the docs in this folder make about a bug or a simplification, with a verdict and the evidence for it. Each verdict has one of the six meanings in the list below. "Reproduced" means that a variant fails for an issue that people had already reported, and "found" means that the model showed a bug first and a Rust test confirms it. The limits of these results are in [Scope and limits](../specs/README.md#scope-and-limits).

- Held up: the model showed the bug first, and a Rust test confirms it.
- Found by Rust or code reading: a Rust run or a code read showed it. The model came later or not at all.
- Refuted: a Rust run showed that the model result is wrong.
- Unverified: a lead without a Rust test.
- Reproduced known issue: people reported the issue before the model existed. A variant fails in the same way, but the model did not discover the issue.
- Simplification evidence: a result that supports a code deletion. It is not a bug.

A claim that has no Rust test stays a lead. Every result is evidence within the bounds of the model, not proof.

Counts: 8 held up, 8 found by Rust or code reading, 2 refuted, 4 unverified, 11 reproduced known issues (in 5 rows), and 1 simplification evidence.

The state counts below come from the docs in this folder. `make bug-traces ONLY=<variant>` writes the trace of a variant to `traces/bugs/<Spec>-<variant>.itf.json`. The trace files are not in git.

| Id | Claim | Source | Verdict | Evidence |
|----|-------|--------|---------|----------|
| 1 | #11750: a `setval` during a checkpoint is lost, and `nextval` repeats values. | `DESIGN-sequences.md`, Findings 1 | Held up | Variant `setvalRace` breaks `CompactionKeepsCurrent`. The Rust test of the issue fails 3 of 3 runs on main at 719fcc411. Variant `setvalFixed` passes (4,376,693 states). The fix is not verified in Rust. [Issue #11750](https://github.com/tursodatabase/turso/issues/11750) |
| 2 | #11751: an ALTER during the first checkpoint of a table loses its rows after a crash. | `DESIGN-schema.md`, Findings 6 | Held up | Variant `noAlterRecovery` breaks `RecoveryCorrect`. The Rust test fails 3 of 3 runs. It shows lost rows, or the #11501 panic when no pages are free. [Issue #11751](https://github.com/tursodatabase/turso/issues/11751) |
| 3 | #11749: a rolled-back UPDATE keeps a checkpointed version in memory. | `DESIGN-rows.md`, Findings 1 | Held up | The reachability check `NeverLeavesUnstampedCurrent` fails in `aborts`. This is not an invariant violation. The Rust test shows `materialized_at` reset to `ORIGIN`. It is a memory leak, not a correctness bug. [Issue #11749](https://github.com/tursodatabase/turso/issues/11749) |
| 4 | #11831: a checkpoint on the connection of an open transaction breaks its snapshot. | `SIMPLIFY.md` step 4, PR #11794 | Found by Rust or code reading | A Rust run found it while the step 4 check ran. It was modeled afterwards (`CheckpointOnReaderConnection`, commit 80e4c9532). The step 4 check found the bug, not the model. [PR #11831](https://github.com/tursodatabase/turso/pull/11831) |
| 5 | #11835: a checkpoint that stops partway strands versions and leaks root pages. | PR #11837 | Found by Rust or code reading | PR #11837 says that the specs missed bugs that Rust reproduces. Variants `failedPublish` and `failedCommit` came afterwards. The fix is open PR #11835. On turso main at ae2cb7388 the bug remains: in a Rust probe with `QueuedIo::fault_after(".db", Sync, 0)`, a passive or blocking checkpoint fails at its database sync after the publish, and the version of the row stays in the store through three later checkpoints (3 of 3 runs, recovery spec `idea2` and `idea2Passive`, invariant `NoLeak`). [PR #11837](https://github.com/tursodatabase/turso/pull/11837) |
| 6 | #11836: a TRUNCATE checkpoint with the flag on purges sequence chains under an open reader. | `MODEL-GAPS.md`, gap 1 | Found by Rust or code reading | It began as a code-reading lead that was "not verified with a test". The Rust fix came first (Nov 14, 03:11 CET). Variant `truncateFlagOn` came after it (03:53 CET). [PR #11836](https://github.com/tursodatabase/turso/pull/11836) |
| 7 | #11833: VACUUM panics with an open passive reader. | PR #11833 | Found by Rust or code reading | Neither the PR nor any spec mentions the model. [PR #11833](https://github.com/tursodatabase/turso/pull/11833) |
| 8 | The publish drain bit (`checkpoint_publish_in_progress`) is dead code. | `MODEL-GAPS.md`, mechanism table | Found by Rust or code reading | It comes from a code read with `rg`, not from a model run. No test shows it. It stays a lead. |
| 9 | The GC floor can be one number: `backfill_floor` alone is a safe floor. | `DESIGN.md`, Findings 1, and `SIMPLIFY.md` step 4 | Refuted | TLC passed `floorBackfill`. Then a Rust run of `Connection::checkpoint` on the connection of an open reader moved `backfill_floor` above the mark of that reader. The model had no such path. With the path added, `ownCheckpointGcBackfillFloor` fails, and a simulator assertion fired in 46 of 200 seeds. [PR #11794](https://github.com/tursodatabase/turso/pull/11794) |
| 10 | Rule 3 can run under load if a read looks at the chain once. | `DESIGN.md`, Findings 2 | Unverified | `rule3UnderLoadOneLook` passes with 1 key (20,771,050 states). The model does not model a real scan over the skip list. That needs its own design and model. |
| 11 | The `begin_tx` window between `wal_pos()` and the clock lock is real. | `DESIGN.md`, Findings 3, rule R5 | Unverified | `floorRegistered` fails `ReadsCorrect` (109,005 states). This is a real counterexample of the model. No Rust test shows it. |
| 12 | #11834: a failed log truncate loses the next commit. | PR #11832 | Unverified | PR #11832 lists `logTruncError`, which fails `RecoveryCorrect`, and says that a Rust test fails on main. The model commit (Nov 13, 23:23 CET) came before the Rust fix (Nov 14, 00:47 CET). Which one came first in discovery is not recorded. The spec is not merged. [PR #11834](https://github.com/tursodatabase/turso/pull/11834) |
| 13 | Lead A: a read-only open of a closed passive database fails ("bug 9"). | PR #11832 | Held up | `leadA` fails `OpenSucceeds`. The Rust test in [Engine bug: read-only open after a passive checkpoint](#engine-bug-read-only-open-after-a-passive-checkpoint) fails 3 of 3 runs on turso main at ae2cb7388. The fix waits on design decision D1. [PR #11832](https://github.com/tursodatabase/turso/pull/11832) |
| 14 | Six schema special cases (S2, S3, S6, S7, S10, S14) and the guards of `SIMPLIFY.md` step 5 are not needed. | `DESIGN-schema.md`, Findings 3, and `SIMPLIFY.md` step 5 | Unverified | TLC finds no error with the guard off. The docs say that this means "not shown needed at these bounds", not "safe to delete". The variants are `noCoversBegin`, `noCoversEnd`, `noAllocRetiresStale`, `noOpenFallback`, `noGenerationGate`, `noRootGcProtect`, `noSkipCycle` and `blockingNoPurge`. |
| 15 | #11499, #11500, #11501 and #11502: the model "caught" four issues. | `DESIGN-schema.md`, Open issues | Reproduced known issue | Mikael Francoeur filed all four on Nov 5, a week before the spec PR. Variants `issue11499` (`CookieNotBehind`), `issue11500` (`ReadsCorrect`), `issue11501` and `issue11502` (`RecoveryCorrect`) fail. The replay in PR #11779 confirms the #11502 trace (row lost at step 8) and the #11499 trace (cookie behind at step 11) on the engine. #11500: read side only. #11499: the lost INSERT is a retry-loop bug that the model leaves out. [PR #11748](https://github.com/tursodatabase/turso/pull/11748) |
| 16 | #8004, #7960 and #8077: the model "caught" three older issues. | `DESIGN-schema.md`, Open issues | Reproduced known issue | Older open issues. Variants `issue8004` (`PagesAccounted`), `issue7960` (`KindsMatch`), and `issue8077` with `issue8077Row` (`NoLiveDestroy`, `SchemaRowCurrent`) fail. For #7960, TLC found the mirror image of the reported direction. |
| 17 | #8087 and #8537: the model reproduces two older issues. The docs also mention #8091 to #8094. | `DESIGN-schema.md`, Open issues | Reproduced known issue | `noFrozenMark` reproduces #8087. #8537 shows up only with its fix (S16) switched off (`issue8537`, `OpenCorrect`). The Rust tests of #8091 to #8094 pass at 24c03ed9a (`DESIGN-schema.md`). #8091 and #8092 are not verified one by one. `issue8093` (`CatalogReadsCorrect`) and `issue8094` (`CatalogNoTwoGenerations`) show the symptoms of #8093 and #8094 with `GuardFrozenMark` off. The cause is not shown, because the fixing commits are not identified. The engine returns the correct rows in the trace of each shape at 0c9fe0dd9, but both issues are still open on GitHub. |
| 18 | #7480 and #9749: the recovery spec reproduces two older issues. | PR #11832 | Reproduced known issue | `issue7480` and `issue9749` fail `OpenSucceeds`, and both fixed variants pass. The spec is `MvccRecovery.qnt` in PR #11832. It is not merged. [PR #11832](https://github.com/tursodatabase/turso/pull/11832) |
| 19 | #11794: `rootpage_gc_protected` never changes a GC decision. | PR #11794 | Simplification evidence | This is the strongest case in the repo: a reachability check, a negative control, an inductive invariant at the main constants, spec-first runs and a Rust assertion over 200 seeds. Larger bounds (step 6 of "How to delete a guard") were not run. This is evidence for a deletion, not a bug. [PR #11794](https://github.com/tursodatabase/turso/pull/11794) |
| 20 | A waiter rolls back after the group commit leader issued its log record, and a restart brings its row back. | `DESIGN-group-commit.md`, Invariants | Found by Rust or code reading | A code read during the design of the spec found it, and the Rust test came before the TLC run. Variant `dropResurrects` breaks `RecoveryNoRolledBack` (243 states), likely on its one-transaction path, which the replay cannot reach. Leader a issues the record of waiter b, b drops, then a drops. b rolls back, but its frame stays after the log offset with a valid CRC. The replay of `group-rolled-back-replayed.itf.json` fails at step 8 with `RolledBackReplayed`. A Rust test with two connections shows no rows before the restart and row 2 after it, at the pinned rev 0c9fe0dd94 and 3 of 3 runs on turso main at ae2cb7388. The test is not in this repo: the body of the commit that added this row gives it. The replay runs at the pinned rev. Filed as [#12000](https://github.com/tursodatabase/turso/issues/12000). |
| 21 | A COMMIT that drops after its record is written becomes `Committed` before any fsync, so readers see a commit that a power loss loses. | `DESIGN-group-commit.md`, Invariants | Held up | Variant `dropCommitsUnsynced` breaks `CommittedDurable` (402 states). The replay of `group-committed-not-durable.itf.json` fails at step 7 with `CommittedNotDurable`. The Rust test `dropped_full_commit_seen_by_reader_survives_power_loss` in `harness/repro/group-commit-rows-21-22.patch` drops a FULL COMMIT at `LogRecordMarkedWritten`. A new reader then sees `[1]`, and the files as a power loss leaves them recover `[]`. It fails 3 of 3 runs on turso main at ae2cb7388. The test changes no engine code. No COMMIT returned success, so this is a read of data that a power loss loses, not a lost acknowledged commit. |
| 22 | Two thread races also roll back a transaction whose frame is in the log: a drop between the owner check and `log_tx`, and a drop between the read of `log_appended` and `abandon_if_issued`. | `DESIGN-group-commit.md`, Invariants | Held up | `dropResurrects` and the reachability checks `NeverWriteRolledBack` and `NeverRollbackWritten` reach these states in the model. Neither window has a yield point in the engine, so no test on unmodified turso can stop there. `harness/repro/group-commit-rows-21-22.patch` adds a test-only hook (`race_hooks`, `#[cfg(test)]`) at each window, which runs the other connection's code there. With it, `waiter_dropped_between_owner_check_and_log_tx_stays_rolled_back` and `waiter_dropped_while_leader_marks_its_record_stays_rolled_back` show rows `[1]` before a restart and `[1, 2]` after it, 3 of 3 runs each on turso main at ae2cb7388. In both cases the frame of the rolled-back waiter is past the log offset, so a later commit does not overwrite it. On real threads the windows are a few instructions wide. |
| 23 | A dropped COMMIT does not wait for its own `log_tx` write. If that write lands after the next leader wrote at the same offset, it overwrites an acknowledged frame. | `DESIGN-group-commit.md`, Not modeled | Refuted | `Statement::drop` calls `reset_best_effort`, and `reset_internal` waits for every in-flight completion except a park before the commit cleanup runs (`core/statement.rs:1518-1529` at ae2cb7388). A test IO that held the log write of the dropped COMMIT made the drop block in `IOCompletions::wait` (a stack sample on turso main at ae2cb7388), so the rollback and the lock release come after the write lands. Another path that discards an in-flight write without the statement reset was not searched. |
| 24 | Mode B: a checkpoint that fails with `Busy` after its publish lets Rule 2 B drop a delete, and a pinned reader then reads the deleted row. | `DESIGN-rows.md`, section "Mode B". `MODEL-GAPS.md`, gap 2 and gap 24 | Unverified | Shown on main by a Rust probe with a direct pager pin (`pager.begin_read_tx()`). A trigger through a public API is not shown. Variant `blockingPagerPin` fails `ReadsCorrect`. The probe fails in 3 of 3 runs. See [the section below](#engine-bug-lead-a-failed-b-pass-and-a-pager-pin). |
| 25 | GC can hide a write-write conflict, so an update commits over a newer write. | `DESIGN-rows.md`, section "Write-write conflicts and GC". `MODEL-GAPS.md`, gap 7 | Refuted at these bounds | `updates` (1 key, 2 readers, 5 timestamps, 1 pass) finds no `NoLostUpdate` violation in 8,466,039 states. Each of `GuardGcWaitsForReaders` and `GuardRule2Lwm` alone is not shown needed. With both off, `NoLostUpdate` fails (`updatesNoRule2LwmNoGcWait`), and so it does with Rule 3 and no floor (`updatesNoIdleRule3NoGcWait`): the code has the guards. Rust check: the trace replay runs `ReaderUpdate` on the engine, and the engine decides the conflict. All 5 witnesses agree after one spec change: the first replay of `reachConflictByCurrentOnly` found that the engine gives no conflict for a Preparing write below the begin of the updater (commit dependency, mod.rs:11234-11248), so the spec leaves that path out. No lost update was shown on the engine. |
| 25a | A Preparing delete of a key below the begin of an updater gives a write-write conflict at the commit check that has no cause, so it aborts an insert that snapshot isolation allows. | `DESIGN-rows.md`, section "Write-write conflicts and GC". `MODEL-GAPS.md`, gap 7 | Found by Rust | On turso main `9cf2de2d8`, A deletes key 1 and stops in its COMMIT as `Preparing(6)` (mod.rs:3173, yield at mod.rs:3326-3327). B begins at 7, does not see the row, and takes a commit dependency on A (mod.rs:11148-11157). B inserts key 1. B's COMMIT runs the conflict check before it waits for A (mod.rs:3307-3327). For the old version the end is A's id, A is not Committed, so the check falls to the begin check and returns `WriteWriteConflict` (mod.rs:2231-2259, 2306-2314). `harness/repro/gap7-preparing-delete-25a.patch`: the test fails in 10 of 10 runs with `Err(WriteWriteConflict)`, and the control test (A commits first) passes in 10 of 10. On turso main `624ed32dbb` (2026-11-18, `mod.rs` unchanged) the test fails in 3 of 3 runs and the control passes in 3 of 3. It uses only turso's own `set_yield_injector` hook (`#[cfg(any(test, injected_yields))]`). No duplicate in tursodatabase/turso issues (searches in `harness/repro/README.md`). It cannot lose an update: B only aborts. |
| 26 | #11501 also breaks the push of sync. With `sqlite_schema` rows `t6 \| 10` and `t7 \| -10`, the object map of the commit of `INSERT INTO t6` names `t7`. | `SYNC.md`, open question 1, and `DESIGN-schema.md`, "Sync object map" | Reproduced known issue | Variant `issue11501Sync` breaks `ObjectMapCorrect`, and variant `issue11501StableId` breaks `StableIdsDistinct` (`docs/logs/gap12/r3-sync-tlc.log`). People reported #11501 before the model existed, for the recovery panic. The push symptom is new. Expected: the object map of the commit names `t6`. Actual: `[{ mv_table_id: -10, name: "t7" }]`. The Rust test `portable_object_map_names_the_written_table_when_a_temp_id_equals_its_page` in `harness/repro/sync-object-map-11501.patch` fails 3 of 3 runs on turso main at ae2cb7388 with `left: "t7"` and `right: "t6"` (`docs/logs/gap12/r3-repro-11501.log`). The test builds the state with SQL: one passive checkpoint while `conn2` has an open `BEGIN` with `CREATE TABLE t7`. Whether a client database can reach it through a pull is not verified. Not filed. |
| 27 | With portable changes on (sync), a plain `INSERT` fails with `Corrupt("portable changes cannot resolve user data table id")` on every connection. A DDL that copied the schema before a passive publish commits after it and installs its old copy (#8004), so the shared schema keeps the temporary root of a table with a page. Catalog GC at the end of the pass drops the `sqlite_schema` versions of that table. The row record carries `-page`, and no lookup of the object map finds it. | `DESIGN-schema.md`, "Sync object map", and `SYNC.md` | Found by Rust or code reading | Row 26 stays "Reproduced known issue": its state is the reported state of #11501, which `issue11501` already reproduced. This row is a path that no variant had shown, and a Rust run came first: the trace replay failed the `INSERT` of a `reachMapsPageId` trace of the design, and the model came later. Variant `issue8004Sync` breaks `ObjectMapCorrect` (`docs/logs/gap12/r3-sync-tlc.log`), and its trace fails on the engine at the step where the spec has `omap = "-"` (`issue_8004_sync_trace_fails_insert`, `docs/logs/gap12/r3-replay.log`). Expected: each `INSERT INTO t1` succeeds. Actual: `conn1`, `conn2` and a new `conn3` each get `Corrupt` for `MVTableId(-4)`. The Rust test `portable_insert_after_stale_schema_install_and_catalog_gc` in `harness/repro/sync-object-map-8004.patch` fails 3 of 3 runs on turso main at ae2cb7388 (`docs/logs/gap12/r3-repro-8004.log`). By code reading, a new connection resolves the root of the table but not the index `table_names_by_root_page` that the lookup reads. After one more checkpoint, a new connection succeeds. #8004 is known. The sync symptom is new. Not filed. |
| 28 | The TxID rewrite after `CommitEnd` resets the stamps that a passive checkpoint wrote in the window, after the pass pruned their dirty keys. It happens when a commit with a higher timestamp finishes first: commits out of timestamp order, or a group commit follower. GC never drops those versions, so they stay in memory until the key is written again. Reads and recovery stay correct. | `DESIGN-commit-rewrite.md`. `MODEL-GAPS.md`, gap 22 | Held up | Variants `rewriteGroupCommit` and `rewriteSerialized` fail `NoStrandedVersions`. The fixed variants (the rewrite keeps the stamp) find no error. Rust tests in `harness/repro/commitend-rewrite-leak.patch` on turso main 9cf2de2d8, and again on 624ed32dbb with the patch applied unchanged: `out_of_order_commit_rewrite_window_keeps_checkpoint_stamps` (SQL commits on two connections, no group commit) and `group_commit_rewrite_window_keeps_checkpoint_stamps` each leave 76 of 1100 row versions in 3 of 3 runs. The in-order control `serialized_commit_rewrite_window_keeps_checkpoint_stamps` leaves 0. Command: `cargo test -p turso_core --lib rewrite_window_keeps_checkpoint_stamps -- --nocapture --test-threads=1`. No open or closed turso issue covers it. |
| 29 | A passive checkpoint under `synchronous=NORMAL` with a pinned reader loses a row that a FULL commit made durable, after a power loss (second Rust test). It also loses the NORMAL commits. Losing a recent NORMAL commit alone matches SQLite NORMAL, but Turso's own comment says NORMAL still fsyncs on checkpoint (`mod.rs:3540`), and the checkpoint returned OK. The backfill copies no frame, so nothing fsyncs the WAL. The checkpoint still truncates and fsyncs the logical log. | `DESIGN-recovery.md`. `MODEL-GAPS.md`, gap 19 | Held up | Config `normalBackfillSkip` fails `NormalPrefix` in 9,314 states. `normalBackfillSkipFixed` (the checkpoint commit fsyncs the WAL) passes in 1,971,692 states. Rust tests in `harness/repro/passive-checkpoint-normal-power-loss.patch` on turso main `740300d9d`, with `UnreliableIo`: `passive_checkpoint_under_normal_with_pinned_reader_keeps_committed_row_after_power_loss` and `passive_checkpoint_under_normal_with_pinned_reader_keeps_fsynced_row_after_power_loss` fail in 3 of 3 runs with `left: []` and `right: [(42,)]` (checkpoint.rs:619). `wal_checkpoint(PASSIVE)` returns (0, 6, 3). At the crash the WAL holds unsynced data and the durable log has 0 bytes. The control test (FULL with a pinned reader, NORMAL with no reader) passes. A probe that fsyncs the WAL in the Busy arm before `TruncateLogicalLog` when `sync_mode != Off` makes all tests pass. Cause: pager.rs:4776, wal.rs:5093, checkpoint.rs:3306-3322 and 3279. No issue filed. No duplicate in tursodatabase/turso issues (searches in `harness/repro/README.md`). |

## Engine bug: read-only open after a passive checkpoint

Title: MVCC: a read-only open fails after a passive checkpoint and a clean close.

A database with `experimental_mvcc_passive_checkpoint` keeps WAL frames after
a passive checkpoint, because a passive checkpoint does not restart the WAL
and a clean close does not checkpoint. On the next open, startup treats any
WAL frame as an interrupted checkpoint (`RECOVERY_SEMANTICS.md` case 1). A
read-write open completes it. A read-only open cannot write, so it refuses
(`core/mvcc/database/mod.rs:9264-9268` at ae2cb7388). So a read-only open
fails for every passive database that ran a checkpoint since its last WAL
restart. The case table of `RECOVERY_SEMANTICS.md` has no read-only row.

- Expected: the read-only open succeeds and `SELECT id FROM t` returns 7,
  as it does after a blocking checkpoint.
- Actual: `Database::open_file_with_flags` returns
  `Corrupt("Cannot reconcile interrupted MVCC checkpoint in read-only mode")`.
- Scope: an automatic checkpoint (`PRAGMA mvcc_checkpoint_threshold = 1`)
  gives the same failure. A read-only open with the flag off also fails. With
  no checkpoint, the WAL is empty after close and the open succeeds. A
  database without the flag cannot reach the state, because its checkpoints
  restart the WAL and `PRAGMA wal_checkpoint(PASSIVE)` returns an error.
- Result: fails 3 of 3 runs on turso main at ae2cb7388. The WAL holds 12392
  bytes after the clean close.
- Trace: `harness/mbt_tests/traces/MvccRecovery-leadA.itf.json`, 14 steps of
  module `leadA` in `specs/MvccRecoveryConfigs.qnt`. One commit, one passive
  checkpoint to its end, then a close. Invariant `OpenSucceeds`.

The test goes in `tests/integration/mvcc/` of turso, with `mod probe;` in
`tests/integration/mvcc/mod.rs`. Run it with `cargo test -p core_tester
--test integration_tests read_only_open_after_passive_checkpoint`.

```rust
use super::checkpoint::get_rows;
use std::sync::Arc;
use turso_core::io::PlatformIO;
use turso_core::{ConnectOpts, Database, DatabaseOpts, OpenFlags, SessionRole};
use turso_sqlite::SqliteDialect;

fn open(path: &str, flags: OpenFlags) -> turso_core::Result<Arc<Database>> {
    Database::open_file_with_flags(
        Arc::new(PlatformIO::new().unwrap()),
        path,
        flags,
        DatabaseOpts::new().with_experimental_mvcc_passive_checkpoint(true),
        None,
        Arc::new(SqliteDialect),
    )
}

#[test]
fn read_only_open_after_passive_checkpoint_and_clean_close() {
    let dir = tempfile::TempDir::new().unwrap();
    let path = dir.path().join("ro_passive.db");
    let path = path.to_str().unwrap();
    {
        let db = open(path, OpenFlags::default()).unwrap();
        let conn = db.connect(ConnectOpts::new(SessionRole::Superuser)).unwrap();
        conn.execute("PRAGMA journal_mode = 'mvcc'").unwrap();
        conn.execute("CREATE TABLE t(id INTEGER PRIMARY KEY)").unwrap();
        conn.execute("INSERT INTO t VALUES (7)").unwrap();
        conn.execute("PRAGMA wal_checkpoint(PASSIVE)").unwrap();
        conn.close().unwrap();
    }
    let db = open(path, OpenFlags::default() | OpenFlags::ReadOnly)
        .expect("read-only open of a cleanly closed passive database");
    let conn = db.connect(ConnectOpts::new(SessionRole::Superuser)).unwrap();
    let rows = get_rows(&conn, "SELECT id FROM t");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0][0].as_int().unwrap(), 7);
}
```

## Engine bug lead: a failed B pass and a pager pin

Title: MVCC mode B: GC drops a delete after a checkpoint failed with `Busy`, and a pinned reader reads the deleted row.

Shown on turso main 2827d0cc1 by a Rust probe with a direct pager pin. A trigger through a
public API is not shown. Found by code reading and a Rust probe. The probe
fails in 3 of 3 runs (a fourth run at the time of this work failed too). The
variant `blockingPagerPin` shows the same shape (`ReadsCorrect` fails).

Why it happens (turso main 2827d0cc1):

1. The B checkpoint stores `durable_txid_max` in the publish window of
   `CommitPagerTxn` (ck.rs:3238-3243, store at ck.rs:2108-2110).
2. `CheckpointWal` then runs a TRUNCATE WAL checkpoint. It needs read mark 0
   exclusive (wal.rs:1161-1172) and read marks 1 to 4 for the restart
   (wal.rs:1239-1248). A reader holds one mark, so the call returns `Busy`.
   Only a passive checkpoint swallows that `Busy` (ck.rs:3306-3310).
3. Rule 2, B form, keeps a superseded version only when
   `*e > ckpt_max && (in_btree || !has_current)` (mod.rs:8657-8661). It has no
   stamp test. So `gc_incremental` drops the delete, because `e <= ckpt_max`.
4. The next `SELECT` of the pinned connection adopts the read mark that the
   connection holds (exec.rs:4350). The chain is empty, so it reads the B-tree
   at the old mark, which still has the row.

The probe opens the window with `pager.begin_read_tx()`, the same call as
`maybe_reparse_schema` (core/connection.rs:1413). The raw WAL API has no public
path: `wal_insert_begin` also takes the WAL write lock, so the checkpoint fails
before its publish. A real failure needs a second thread to run the failing
checkpoint and a third to run the GC inside the reparse window. A test of that
trigger is not written. The likely symptom is a stale `sqlite_schema` row. This
is not verified.

The probe test (append to `core/mvcc/database/tests.rs` on 2827d0cc1, run with
`cargo test -p turso_core --lib probe_mode_b -- --nocapture --test-threads=1`):

```rust
/// Gap 2, question 1: a pager read mark taken without the blocking gate (what
/// force_reparse_schema and maybe_reparse_schema do before reparse_schema
/// begins its MVCC tx). The B checkpoint gets Busy at CheckpointWal after its
/// publish. Rule 2 B form then drops the delete version (e <= ckpt_max, no
/// materialized_at test), and the reader adopts its old mark.
#[test]
fn probe_mode_b_pager_pin_after_failed_publish() {
    let db = MvccTestDbNoConn::new_with_random_db();
    let w = db.connect();
    let mv = db.get_mvcc_store();
    w.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)").unwrap();
    w.execute("INSERT INTO t VALUES (1, 'a')").unwrap();
    w.execute("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    println!("after ckpt 1: {:?}", mv.debug_gc_snapshot());

    let r = db.connect();
    let rp = r.pager.load().clone();
    rp.begin_read_tx().unwrap(); // pager pin, no gate, no MVCC tx
    println!("reader pinned at {:?}", rp.wal_pos());

    w.execute("DELETE FROM t WHERE k = 1").unwrap();
    let ck = w.execute("PRAGMA wal_checkpoint(TRUNCATE)");
    let snap = mv.debug_gc_snapshot();
    println!("ckpt 2 result: {ck:?}");
    println!("after ckpt 2: durable = {}, rows_versions = {}", snap.durable_txid_max, snap.rows_versions);

    let dropped = mv.gc_incremental(1000);
    println!("gc_incremental dropped {dropped}, rows_versions = {}", mv.debug_gc_snapshot().rows_versions);

    let rows = get_rows(&r, "SELECT k, v FROM t");
    println!("reader rows: {rows:?}");
    rp.end_read_tx();
    assert!(rows.is_empty(), "reader saw a row that was deleted before it began: {rows:?}");
}

/// Control for the probe above: the same steps without the GC. The tombstone
/// in the chain shadows the B-tree row, so the read is right.
#[test]
fn probe_mode_b_pager_pin_after_failed_publish_no_gc() {
    let db = MvccTestDbNoConn::new_with_random_db();
    let w = db.connect();
    let mv = db.get_mvcc_store();
    w.execute("CREATE TABLE t(k INTEGER PRIMARY KEY, v TEXT)").unwrap();
    w.execute("INSERT INTO t VALUES (1, 'a')").unwrap();
    w.execute("PRAGMA wal_checkpoint(TRUNCATE)").unwrap();
    let r = db.connect();
    let rp = r.pager.load().clone();
    rp.begin_read_tx().unwrap();
    w.execute("DELETE FROM t WHERE k = 1").unwrap();
    let ck = w.execute("PRAGMA wal_checkpoint(TRUNCATE)");
    println!("ckpt 2 result: {ck:?}, rows_versions = {}", mv.debug_gc_snapshot().rows_versions);
    let rows = get_rows(&r, "SELECT k, v FROM t");
    println!("reader rows without GC: {rows:?}");
    rp.end_read_tx();
    assert!(rows.is_empty());
}
```

Output of the failing test (Mac, 2026-11-17). The tests are in
`harness/repro/mode-b-pager-pin.patch`:

```text
reader pinned at (3, 0)
ckpt 2 result: Err(Busy)
after ckpt 2: durable = 9, rows_versions = 1
gc_incremental dropped 1, rows_versions = 0
reader rows: [[Numeric(Integer(1)), Text(Text { value: "a", subtype: Text })]]
panicked: reader saw a row that was deleted before it began
```

The control `probe_mode_b_pager_pin_after_failed_publish_no_gc` prints
`ckpt 2 result: Err(Busy), rows_versions = 1` and `reader rows without GC: []`.
So the GC step causes the wrong read.

A first idea was to make Rule 2, B form, need a stamp (`FixB2NeedsStamp`). It was
rejected. In mode B a version gets a stamp only inside a pass, so every version
that `gc_incremental` sees has no stamp. The fix stops all Rule 2 B drops
between passes. The model passed only because GC never ran.

The fix that the model supports is `FixB2WaitsForPinned`: Rule 2, B form, drops
nothing while a pinned read mark is below the WAL max frame. An engine form of
the fix must count every pager reader, also a reader on read slot 0.
`min_pinned_read_frame()` reads only slots 1 to 4 (wal.rs:916-927 on main
2827d0cc1). A reader that pins on a fully backfilled WAL takes slot 0
(wal.rs:1059-1065), and the reader of the probe is that case. So a fix that
uses only that function still drops the delete. This is by code reading.
`blockingPagerPinFixed`
finds `ReadsCorrect`, `RecoveryCorrect`, `TypeOK` and `BackfillBelowReaders`
true (2,009,967 states, 100 seconds). GC still drops versions with the fix:
`reachFixedGcDrops` fails `NeverGcDropsB` (400 states, 41 seconds), as
`reachMainGcDrops` does for `blockingMain` (461 states, 40 seconds). The cost:
while a stale pin exists, Rule 2 drops no superseded version of any key. After a failed
pass, versions also stay unstamped until their key changes again. This fix is
in the model only. It is not in the engine and not tried in Rust.

The trace replay of `blockingPagerPin` on the engine at the pinned rev
0c9fe0dd9 fails at step 16 with `WrongRead`
(`blocking_pager_pin_trace_shows_wrong_read`). That shape differs from the
probe: the row sits in an unbackfilled WAL frame, not in the database file.

## Exploration passes

Each pass lists what ran and every divergence between the engine and the
model. The engine is turso at the pin of `harness/Cargo.toml` unless a line
says otherwise.

- 2026-11-17, row spec, module `mbt`. 3300 fresh random traces of 60 to 80
  steps (seeds 0x1001 and 0x5eed2026 onward) and 280 witness traces (7
  predicates, 40 seeds each, about 50 steps). The witnesses are a read of a
  key whose B-tree at the read mark is stale, the same after two frames, a
  reader that begins after the publish on an older mark, a log truncate with
  a logged writer in flight, a truncate with a Preparing writer, a crash
  point in the middle of a checkpoint, and a backfill held by a reader. All
  3580 traces replay with no divergence. Before the driver fix of 84ceff4,
  44% of fresh traces were refused at the reader pin.
- 2026-11-17, row spec, the `mbt` constants with 3 keys, 3 readers, `MaxTs =
  14` and `MaxCheckpoints = 6`. 1800 fresh traces of 150 steps (271800
  states), with 284 reader begins on a mark below the WAL end and 2300 reads
  on a stale mark. All replay with no divergence.
- 2026-11-17, row spec, module `mbtBlocking` (mode B, the passive flag off).
  The replay compares the version count of every key with the spec chain
  after each `Gc` step and each B pass. 60 fresh traces of `mbtBlocking` and
  300 of `mbtBlockingPin` replay at the pinned rev with 0 refused and 0
  failed. Before the spec `Lwm` counted the begin tick of an unfinished
  writer, 19 of the 300 failed that check. The bug trace of `blockingPagerPin`
  fails at step 16 with `WrongRead`. The bug trace of `blockingNoB2Keep`
  fails at step 11 with `Chain`. 80 fresh passive `mbt` traces replay with 0
  failed after the `Lwm` change.
- 2026-11-17, recovery spec, lead `leadA`. Reproduced on turso main as the
  engine bug above.
- 2026-11-17, 17:43 to 20:49 CET, `scripts/explore.py`, 20 iterations at
  one heavy job at a time. Engine replay of fresh traces: 6384 row traces
  (768000 states) with 84 witness traces among them, 1800 index traces
  (181800 states), and 1499 group commit traces (50042 states). Simulation:
  about 1.25 million random runs over the six specs, main configurations,
  random no-error variants and copies with larger bounds. TLC of the main
  configurations: rows 17,344,980, index 52,815,276 and sequence 1,407,267
  distinct states, no error. Apalache to depth 3 to 8: group commit, schema
  and recovery, no error. No invariant violation. One divergence, a harness
  hole in the group commit replay (`MODEL-GAPS.md` item 23), fixed in
  6ee4dd5. Gap lead 22 (a checkpoint inside the TxID rewrite) does not
  show on turso main.
- 2026-11-17, recovery spec, leads `idea2` and `idea2Passive`. Reproduced on
  turso main with an I/O fault. This is the known bug of open PR #11835, so
  it is in finding 5, not a new report.
- 2026-11-18, 11:19 to 15:00 CET, long hunt from peristocles with the Mac
  over ssh, at one heavy job at a time in the shared slots. Engine: turso
  main `9cf2de2d8`, with `turso-hooks.patch` and `mbt_tests` ported to main
  in the Mac clone only (`checkpoint_state_machine.rs` is now
  `checkpoint.rs`, and `ConnectOpts::new` takes a `SessionRole`). The
  replay suite gives 18 passed, 0 failed. Pass 1 ran no job, because the
  gap threads held both slots for 80 minutes. Pass 2: 600 `mbtBlockingPin`
  and 600 `mbtBlocking` traces of 120 steps, and 5 witness traces of a
  checkpoint on the connection of an active reader (`mbt` with
  `CheckpointOnReaderConnection = "keepsMark"`, owner fix off), replay with
  0 refused and 0 failed. `quint run` of the row main configuration (2
  seeds) and the sequence main configuration (1 seed), 200,000 samples of
  80 steps each, finds no violation. Pass 3: 400 index and 400 group
  commit traces replay with 0 refused and 0 failed. `quint run`, 100,000
  samples of 80 steps, of the group commit, index and recovery main
  configurations (2 seeds each) and of the schema main configuration and
  `truncateFlagOn` (1 seed each), finds no violation. No TLC or Apalache
  run. Row 25a is now reproduced (above). No other divergence.
