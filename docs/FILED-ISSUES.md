# Turso issues filed from this model

Engine bugs found by the Quint model or harness and filed on tursodatabase/turso after Pere approved them.

| date | issue | title | labels | found by | trace / writeup |
| --- | --- | --- | --- | --- | --- |
| 2026-11-17 | [#11998](https://github.com/tursodatabase/turso/issues/11998) | MVCC: a read-only open fails after a passive checkpoint and a clean close | mvcc, wal, correctness | bug hunter (leadA, recovery spec) | [MvccRecovery-leadA.itf.json](../harness/mbt_tests/traces/MvccRecovery-leadA.itf.json), [FINDINGS.md](FINDINGS.md#engine-bug-read-only-open-after-a-passive-checkpoint) |
| 2026-11-17 | [#12000](https://github.com/tursodatabase/turso/issues/12000) | MVCC: a group-commit waiter that rolls back after the leader wrote its record comes back after restart | mvcc, durability, transactions, correctness | gap 8 thread (group commit spec, `dropResurrects`) | [DESIGN-group-commit.md](DESIGN-group-commit.md), [FINDINGS.md](FINDINGS.md) row 20 |
| 2026-11-17 | [#12005](https://github.com/tursodatabase/turso/issues/12005) | MVCC: a dropped FULL COMMIT seen by a reader is lost after power loss | mvcc, durability, transactions, correctness | gap 8 group commit thread | [group-commit-rows-21-22.patch](../harness/repro/group-commit-rows-21-22.patch), [FINDINGS.md](FINDINGS.md) row 21, [a7673cfce1](https://github.com/pereman2/turso-mvcc-quint/commit/a7673cfce1) |
