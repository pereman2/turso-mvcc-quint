# MVCC Passive Checkpoint Specification

Quint specifications of the passive checkpoint in MVCC mode. The documents
are in [`docs/`](../docs). `DESIGN.md` describes the design in prose and maps
it to the Rust code. [`FINDINGS.md`](../docs/FINDINGS.md) lists each claim about a bug or a simplification, with a verdict and its
evidence. Read [Scope and limits](#scope-and-limits) below before you trust a
result.

| Spec | Configurations | Design document |
|------|----------------|-----------------|
| `MvccPassiveCheckpoint.qnt` | `MvccPassiveCheckpointConfigs.qnt` | `DESIGN.md`, `DESIGN-rows.md` |
| `MvccPassiveSequence.qnt` | `MvccPassiveSequenceConfigs.qnt` | `DESIGN-sequences.md` |
| `MvccPassiveSchema.qnt` | `MvccPassiveSchemaConfigs.qnt` | `DESIGN-schema.md` |
| `MvccRecovery.qnt` | `MvccRecoveryConfigs.qnt` | `DESIGN-recovery.md` |
| `MvccGroupCommit.qnt` | `MvccGroupCommitConfigs.qnt` | `DESIGN-group-commit.md` |

A configurations file has one module for each configuration. The module sets
the constants of the spec. The module named `main` is the main configuration
of the spec. Each other module is a variant. A variant switches off one rule
of the design or tries a simpler rule. The comment above each module gives the
result to expect and the invariants to check. The Makefile reads this comment.

To add a spec, add `Spec.qnt` and `SpecConfigs.qnt` with a module `main`.
The Makefile finds every `Mvcc*.qnt` file that has a configurations file.

`SIMPLIFY.md` is a plan to make the passive checkpoint simpler, based on the
model results. The plan keeps the invariants that the specs check. `MODEL-GAPS.md` lists what the
specs cover and what the code does around them. `SYNC.md` describes how sync depends
on table ids. The specs do not model sync.

## Scope and limits

These results are evidence within these bounds and this model, not proof.

### What is modeled

There are five specs in this folder.

- Rows (`MvccPassiveCheckpoint.qnt`): version chains, the logical log, WAL
  frames, the database file, writers, the checkpoint and GC. The main
  configuration checks the invariants `ReadsCorrect`, `RecoveryCorrect`,
  `BackfillBelowReaders` and `BackfillFloorBelowReaders`. The dirty-key
  variants also check `CollectsEveryChange`. The main configuration has 1 key,
  2 readers, 5 timestamps and 2 checkpoints. TLC explores 16,786,385 states in
  10 minutes on 3 workers.
- Schema (`MvccPassiveSchema.qnt`): table ids, root bindings,
  `sqlite_schema`, the schema cookie, page allocation, DDL, publish and
  recovery. The main configuration has 2 tables, pages 2 and 3, 1 reader, 4
  timestamps and 2 checkpoints. It has no index and no ALTER. TLC explores
  15,985,399 states in 17 minutes.
- Sequences (`MvccPassiveSequence.qnt`): sequence rows, `nextval`,
  compaction and publish. The main configuration has values 1 to 3, 2
  connections, a clock bound of 8 and 2 passes. The sequence is ascending,
  and `setval` is off. TLC explores 4,008,777 states in 3.5 minutes on 3
  workers.

- Recovery (`MvccRecovery.qnt`): the checkpoint file steps, crash recovery
  and open, with the row GC rules of modes B and P. It has no readers, schema
  or indexes. `DESIGN-recovery.md` gives its configurations and results.
- Group commit (`MvccGroupCommit.qnt`): the commit queue, the leader batch,
  the retry path, the log fsync and dropped COMMIT statements. The main
  configuration has 3 transactions (2 FULL, 1 NORMAL) and 4 tickets. TLC
  explores 157,611 states in about 10 seconds on a Mac. It has no readers and no
  checkpoint. `DESIGN-group-commit.md` gives its configurations and results.

The row and sequence specs also model a checkpoint on the connection of an
open reader, checkpoint passes that stop before they complete, and mode T.
`MODEL-GAPS.md` section 5 gives these results.

### What is not modeled

- Mode B, the default (flag off), with readers. This covers Rule 2 B form, Rule 3 with
  `b <= ckpt_max` and the B-tree fall-through read. The "blocking" mode of
  the sequence spec uses the passive GC rules. `MODEL-GAPS.md` says that this
  is false for the flag off.
- Mode T (flag on plus `PRAGMA wal_checkpoint(TRUNCATE)`) is only partly
  modeled. WAL restart and the blocking final GC sweep are not in the specs.
- Index rows. They have their own GC loop, their own dirty map, the lockstep
  cursor and `rootpage_gc_protected` for indexes.
- Write-write validation against a GC that drops versions.
- `finalized_tx_states` pruning.
- Group commit in the row, schema and sequence specs, where the log append
  is one atomic step. `MvccGroupCommit.qnt` models it alone, with no
  checkpoint and no readers.
- Real cursor scans. The model reads one key in one step.
- WAL restart and TRUNCATE, and `backfill_floor` across them.
- `cleanup_dropped_commit` on the non-group path. `MvccGroupCommit.qnt`
  models it on the group path.
- Reads of `sqlite_schema` through the dual cursor, and the GC of
  `sqlite_schema`.
- The statement retry loop.
- A checkpoint on its own connection, and checkpoints that stop partway, in
  the schema spec. The first specs left both out and missed #11831 and
  #11835. The row and sequence specs added these paths after the bugs.
- The sync object map and stable table ids.

### Bounds

The bounds are small on purpose. For example, the row spec has 1 key, 2
readers and 5 timestamps. A bug that needs 2 keys and a third reader is
invisible to it. Larger-bound runs for the deletion of `rootpage_gc_protected`
(PR #11794) were not done.

### Parity with the code

There is no `PARITY.md` yet. Parity today is the set of manual `file:line`
tables in `DESIGN*.md` and `MODEL-GAPS.md`, made at commit 719fcc411. The
replay harness in `harness/` runs only with a patch to turso
(`docs/HARNESS.md`). A replay shows that the code can
follow the paths of the model. It never tests paths that the code has and the
model lacks.

These results are evidence within these bounds and this model, not proof.

## Install the tools

You need Node.js, Java and Quint. Quint downloads Apalache itself.

1. Install Quint 0.33.1 from npm:

   ```bash
   npm install -g @informalsystems/quint@0.33.1
   ```

   If you install it into another directory, give its path to make, for
   example `make check QUINT=~/.local/share/quint/node_modules/.bin/quint`.

2. Install Java 17 or later, for example Temurin 21. Quint runs Apalache and
   TLC with the `java` command on `PATH`. To use another Java, give its home
   directory to make, for example `make check JAVA_HOME=/opt/jdk-21`.

3. Run `quint verify` once with network access. Quint then downloads Apalache
   0.62.4 to `~/.quint`. The TLC backend also needs this download, because
   Quint uses Apalache to prepare the spec for TLC and runs the TLC that
   comes with Apalache. Any target that model checks does this step for you.

## Run the targets

```bash
# Check the main configuration of each spec with TLC
make check

# Check every variant and compare the result with the comment above it
make variants

# Run the Quint simulator on each main configuration
make simulate

# Write random traces of each spec to traces/
make traces

# Write one failing trace for each variant that must fail to traces/bugs/
make bug-traces

# Check only the crash recovery spec: main, variants and reachability checks
make recovery
```

These make variables change the runs:

| Variable | Default | Meaning |
|----------|---------|---------|
| `QUINT` | `quint` | The Quint command |
| `JAVA_HOME` | empty | The Java to use. Empty means the `java` on `PATH` |
| `WORKERS` | 4 | TLC workers, and simulator threads |
| `ONLY` | empty | Module names to check, separated by spaces. Empty means all |
| `SERVER` | `localhost:8822` | The port of the Apalache server that Quint starts |
| `STATES` | `states` | The directory for TLC states and temporary files |
| `SPECS` | every `Mvcc*.qnt` with a configurations file | The specs to run |
| `SAMPLES` | 10000 | Simulator runs for `simulate` |
| `STEPS` | 40 | Steps in each simulator run and trace |
| `TRACES` | 10 | Traces for each spec for `traces` |
| `BUG_SAMPLES` | 200000 | Simulator runs for each variant for `bug-traces` |

For example, this command checks two variants with 6 workers:

```bash
make variants ONLY="noGcWait noSnapshotClamp" WORKERS=6
```

Two runs at the same time in this directory need their own `SERVER` and
`STATES`, for example:

```bash
make variants SPECS=MvccPassiveSequence SERVER=localhost:8826 STATES=$PWD/states2
```

`check` and `variants` use the TLC backend (`quint verify --backend tlc`).
TLC visits every reachable state, and it visits each order of the keys,
readers and connections. If Apalache or TLC fails, Quint can still exit with 0. For
this reason, the Makefile reads the output text to find the result.

The Java tools write their temporary files and TLC states to `states/`. The
Makefile deletes them after each run. To do it by hand, run `make clean`.

## How long the runs take

These times are for 3 TLC workers.

| Run | Distinct states | Time |
|-----|-----------------|------|
| `make check`, row spec (`MvccPassiveCheckpoint`) | 16,786,385 | 10 minutes |
| `make check`, sequence spec (`MvccPassiveSequence`) | 4,008,777 | 3.5 minutes |
| Largest row variant that ran in full (`dirtyKeys`) | 45,359,101 | 26 minutes |
| Other row and sequence variants | up to 20,771,050 | up to 13 minutes |

`make variants` for the row spec takes about two hours. `gcSample` alone
needs more than 40 minutes. To leave out the largest
variants, give the others with `ONLY`.

## Traces

`make traces` runs the simulator with `--mbt`. Each state in a trace file has
two more fields:

- `mbt::actionTaken`: the action of the step, for example `WritePrepare`.
- `mbt::nondetPicks`: the values that the action picked, under the names of
  the action parameters, for example `k` and `isDelete`.

The test in `harness/mbt_tests/` replays a trace against the Rust code with
these two fields. `docs/HARNESS.md` describes that test. For a
spec with a module named `mbt`, `make traces` uses that module, which takes
only the steps that the engine can take.

`make bug-traces` runs the simulator on each variant that must fail, until it
finds the violation, and writes that trace to `traces/bugs/<Spec>-<module>.itf.json`.
These are the traces of the known bugs, for example `issue11502`. If the
simulator finds no violation in `BUG_SAMPLES` runs, the target prints `miss`.
The TLC backend finds every one of these violations, but it does not write
them as ITF.
