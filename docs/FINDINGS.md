# Findings

This file lists each claim that the docs in this folder make about a bug or a simplification, with a verdict and the evidence for it. Each verdict has one of the six meanings in the list below. "Reproduced" means that a variant fails for an issue that people had already reported, and "found" means that the model showed a bug first and a Rust test confirms it. The limits of these results are in [Scope and limits](../specs/README.md#scope-and-limits).

- Held up: the model showed the bug first, and a Rust test confirms it.
- Found by Rust or code reading: a Rust run or a code read showed it. The model came later or not at all.
- Refuted: a Rust run showed that the model result is wrong.
- Unverified: a lead without a Rust test.
- Reproduced known issue: people reported the issue before the model existed. A variant fails in the same way, but the model did not discover the issue.
- Simplification evidence: a result that supports a code deletion. It is not a bug.

A claim that has no Rust test stays a lead. Every result is evidence within the bounds of the model, not proof.

Counts: 4 held up, 6 found by Rust or code reading, 1 refuted, 7 unverified, 11 reproduced known issues (in 4 rows), and 1 simplification evidence.

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
| 17 | #8087 and #8537: the model reproduces two older issues. The docs also mention #8091 to #8094. | `DESIGN-schema.md`, Open issues | Reproduced known issue | `noFrozenMark` reproduces #8087. #8537 shows up only with its fix (S16) switched off (`issue8537`, `OpenCorrect`). #8091 to #8094 are already fixed in the code. #8091 and #8092 are not verified one by one. #8093 and #8094 cannot be expressed, because the model has no catalog reads and no GC of `sqlite_schema`. |
| 18 | #7480 and #9749: the recovery spec reproduces two older issues. | PR #11832 | Reproduced known issue | `issue7480` and `issue9749` fail `OpenSucceeds`, and both fixed variants pass. The spec is `MvccRecovery.qnt` in PR #11832. It is not merged. [PR #11832](https://github.com/tursodatabase/turso/pull/11832) |
| 19 | #11794: `rootpage_gc_protected` never changes a GC decision. | PR #11794 | Simplification evidence | This is the strongest case in the repo: a reachability check, a negative control, an inductive invariant at the main constants, spec-first runs and a Rust assertion over 200 seeds. Larger bounds (step 6 of "How to delete a guard") were not run. This is evidence for a deletion, not a bug. [PR #11794](https://github.com/tursodatabase/turso/pull/11794) |
| 20 | A waiter rolls back after the group commit leader issued its log record, and a restart brings its row back. | `DESIGN-group-commit.md`, Invariants | Found by Rust or code reading | A code read during the design of the spec found it, and the Rust test came before the TLC run. Variant `dropResurrects` breaks `RecoveryNoRolledBack` (243 states), likely on its one-transaction path, which the replay cannot reach. Leader a issues the record of waiter b, b drops, then a drops. b rolls back, but its frame stays after the log offset with a valid CRC. The replay of `group-rolled-back-replayed.itf.json` fails at step 8 with `RolledBackReplayed`. A Rust test with two connections shows no rows before the restart and row 2 after it, at the pinned rev 0c9fe0dd94 and 3 of 3 runs on turso main at ae2cb7388. The test is not in this repo: the body of the commit that added this row gives it. The replay runs at the pinned rev. |
| 21 | A COMMIT that drops after its record is written becomes `Committed` before any fsync, so readers see a commit that a power loss loses. | `DESIGN-group-commit.md`, Invariants | Unverified | Variant `dropCommitsUnsynced` breaks `CommittedDurable` (402 states). The replay of `group-committed-not-durable.itf.json` fails at step 7 with `CommittedNotDurable` on a test IO that drops unsynced bytes. No COMMIT returned success, so this is a read of data that a power loss can lose, not a lost acknowledged commit. No test with a real reader. |
| 22 | Two thread races also roll back a transaction whose frame is in the log: a drop between the owner check and `log_tx`, and a drop between the read of `log_appended` and `abandon_if_issued`. | `DESIGN-group-commit.md`, Invariants | Unverified | `dropResurrects` and the reachability checks `NeverWriteRolledBack` and `NeverRollbackWritten` reach these states in the model. The replay cannot reach them, because the engine has no yield point there. No threaded Rust test. |
| 23 | A dropped COMMIT does not wait for its own `log_tx` write. If that write lands after the next leader wrote at the same offset, it overwrites an acknowledged frame. | `DESIGN-group-commit.md`, Not modeled | Unverified | A code read: cleanup discards the pending write (`mod.rs:1850-1852`) and rollback releases the lock. It needs an async backend such as io_uring. Not modeled, and no test. |

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
- 2026-11-17, recovery spec, lead `leadA`. Reproduced on turso main as the
  engine bug above.
- 2026-11-17, recovery spec, leads `idea2` and `idea2Passive`. Reproduced on
  turso main with an I/O fault. This is the known bug of open PR #11835, so
  it is in finding 5, not a new report.
