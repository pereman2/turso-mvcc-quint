# turso-mvcc-quint

This repo holds Quint models of the MVCC passive checkpoint and crash recovery
in [turso](https://github.com/tursodatabase/turso). It also holds a test that
replays model traces on the turso engine. Quint is a specification language. Its specs
here run in the TLC model checker.

The specs state the design of the code in `core/mvcc/` of turso: version
chains, the logical log, the WAL, the checkpoint state machine, GC, table ids,
root pages, sequences and recovery. Each spec has variants that switch off one
rule of the design. A variant that fails shows that the rule is needed. A
variant that passes is a candidate to make the code simpler. The results are
evidence within the bounds of each model, not proof.

## Layout

| Path | Content |
|---|---|
| `specs/` | The Quint specs (`Mvcc*.qnt`), their configurations (`Mvcc*Configs.qnt`), the `Makefile` and a README for the make targets |
| `docs/` | The design documents, the findings, the gaps of the model, the simplification plan, and the design of the trace replay |
| `harness/` | The trace replay test (`harness/mbt_tests/`) and a small Rust crate that builds against a pinned turso |
| `.github/workflows/` | CI for the specs (`quint-spec.yml`) and for the replay test (`harness.yml`) |
| `.claude/skills/quint-modeling/` | A guide for agents that work on the specs |

Start with `docs/DESIGN.md`. `docs/FINDINGS.md` lists each claim about a bug
or a simplification with its verdict. `specs/README.md` lists what the specs
leave out.

## Run the Quint checks

You need Node.js, Java 17 or later, and Quint 0.33.1. Quint downloads
Apalache the first time that it model checks.

```bash
npm install -g @informalsystems/quint@0.33.1
cd specs
make typecheck
make variants WORKERS=4 ONLY="noSnapshotClamp noGcWait noBackfillStop setvalRace noDeferDeletes issue11501 issue11502 issue8004"
```

These are the commands that CI runs. They take about 4 minutes. `make check`
runs the main configurations, which take 3.5 to 17 minutes each. `make
variants` without `ONLY` runs every variant, which takes hours.
`specs/README.md` lists every target.

## Run the trace replay

The replay test reads private `turso_core` APIs, so it builds only as a module
inside `turso_core`. It also needs test-only hooks in
`core/mvcc/database/checkpoint_state_machine.rs` that turso does not have.
`harness/run-in-turso.sh` does these steps:

1. It clones turso to `harness/target/turso`, or uses the directory that you
   give it.
2. It checks out the pinned rev and applies `harness/turso-hooks.patch`.
3. It copies `harness/mbt_tests/` into `core/mvcc/database/` and runs
   `cargo test -p turso_core --lib mbt_tests`.

```bash
harness/run-in-turso.sh
```

If you give the script a turso directory, the script resets it to the pinned
rev. Do not give it a checkout with work in it.

The crate in `harness/` builds without that patch. `cargo test` checks that
every committed trace parses. `cargo test --features engine` also builds the
pinned `turso_core` from git and runs a smoke test of the passive checkpoint
through the public API.

```bash
cd harness
cargo test
cargo test --features engine
```

## How the harness depends on turso

`harness/Cargo.toml` pins `turso_core` and `turso_sqlite` as git dependencies
at rev `0c9fe0dd94c14a4f00106bffa9c9433d5965fd3a` of tursodatabase/turso.
That rev is the base of the source branches below. `run-in-turso.sh` reads the
rev from `harness/Cargo.toml`. If you move to a newer turso, change both revs
in `harness/Cargo.toml`. If `harness/turso-hooks.patch` then does not apply,
update it. Then run both commands above.

The patch is the test-only part of turso commit `caf210dfd` ("core/mvcc: let a
test collect one key per checkpoint step") and one `mod mbt_tests` line. It
changes no behavior outside `#[cfg(test)]`.

## Sources

The history of this repo comes from four branches of the fork
[pereman2/limbo](https://github.com/pereman2/limbo). `git filter-repo` kept
only the Quint files, the docs, the CI file, the skill and the replay test. It
moved them to the paths above.

| Branch | Turso PR | Head |
|---|---|---|
| `pere/formalize-mvcc-passive-checkpoint` | #11748 | `521a35fb525fae7f7dfee55327f6efb9eb8c1308` |
| `pere/mvcc-model-recovery` | #11832 | `769b1e9816dab13b6ae245158b4c5cafed1c34db` |
| `pere/mvcc-model-checkpoint-stops` | #11837, with the Quint commits of #11794 | `2a3534eda8bc95b3a4dc4178500c9a440e316904` |
| `pere/mvcc-trace-replay-harness` | #11779 | `2836c87e682b682666fecd257b4e22992ecf37a1` |

The first branch is the base. The recovery and checkpoint-stop branches are
merged into it. The checkpoint-stop branch contains the commits of the
trace replay branch. Three commits of #11794 change engine code in
`core/mvcc/database/` (`60d636b8b`, `2b723d0ed`, `3a95ac963`). They are not
in this repo. One of them also removes a `rootpage_gc_protected` call from
`mbt_tests/rows.rs`. This repo keeps that call, because the pinned turso still
has that function.

## Open items

- The test-only hooks in `harness/turso-hooks.patch` are not in turso. Until
  turso has them, the replay runs only through `run-in-turso.sh`.
- The pinned turso does not have the engine changes of #11794. The docs
  describe the code after #11794 in some places, for example the removal of
  `rootpage_gc_protected` (`docs/DESIGN-schema.md`, S14).
- The sequence spec has no replay driver. The schema driver replays only the
  bug traces of #11499 and #11502 (`docs/HARNESS.md`).
- Some docs cite local probe files and a local Rust fix (`633aeb51a`) that
  are not published. The docs say so where they cite them.
