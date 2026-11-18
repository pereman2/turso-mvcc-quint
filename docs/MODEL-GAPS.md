# What the model covers, and what the code does around it

This file lists each MVCC mechanism in the code, the checkpoint modes where it
runs, and whether a spec in this folder models it. It also sorts each
mechanism into design (a guarantee needs it), optimization (the same result
with less work or memory), or dead (it runs in a mode where nothing needs it).
It comes from a read of the code. No test ran for it, so every bug lead in the
mechanism table is not verified until a test shows it. The first specs did not
model a checkpoint on the connection of an open reader or a checkpoint that
stops partway. Rust runs later showed bugs there (#11831 and #11835), so those
specs missed them. The checkpoint-stop section below gives the later model
results for both paths, with the Rust probe results. `FINDINGS.md` lists the
verdicts, and the section "Scope and limits" in `specs/README.md` lists what the
specs leave out.

The mechanism table uses code at commit 719fcc411. The checkpoint-stop section
uses the requested base, 3a95ac963. The mode B rows and gaps 2, 14 and 24 use
turso main 2827d0cc1 (the B paths are the same at the pinned rev 0c9fe0dd9 of
the replay). Short names in this file:

- `mod.rs` is `core/mvcc/database/mod.rs`.
- `csm.rs` is `core/mvcc/database/checkpoint_state_machine.rs`.
- `cursor.rs` is `core/mvcc/cursor.rs`.
- Row spec is `MvccPassiveCheckpoint.qnt`. Schema spec is `MvccPassiveSchema.qnt`. Sequence spec is `MvccPassiveSequence.qnt`. Recovery spec is `MvccRecovery.qnt` (line numbers of commit 7c607534b, see `DESIGN-recovery.md`).

## The three modes

The code has two switches, not one. The first is the flag
`experimental_mvcc_passive_checkpoint` (`MvStore::uses_passive_checkpoint`, mod.rs:7952).
The second is the `CheckpointMode` of one checkpoint. Together they give three modes.

| Mode | Flag | Checkpoint mode | How it starts |
|---|---|---|---|
| B (blocking) | off | Truncate | Auto checkpoint (mod.rs:3706), explicit checkpoints (connection.rs:2615) |
| P (passive) | on | Passive | Auto checkpoint (mod.rs:3702), explicit PASSIVE |
| T (flag on, TRUNCATE) | on | Truncate | `PRAGMA wal_checkpoint(TRUNCATE)` (vdbe/execute.rs:593, connection.rs:2605), journal mode change (vdbe/execute.rs:18792) |

The code gates some paths on the flag and others on the checkpoint mode or on
"blocking lock held". Mode T gets a mix of both. The row and sequence specs
model P and T. The sequence spec also has a mode "blocking", which matches B
for locks but uses the P GC rules (`MvccPassiveSequence.qnt:80`). The T mode
uses `Mode = "truncateFlagOn"`. The checkpoint-stop section gives its results
and limits. The recovery spec covers B, P and T in part: the checkpoint file
steps, crash recovery, and the row GC rules of B and P, with no readers, schema
or indexes (`DESIGN-recovery.md`).

What the blocking lock gives in each mode:

- In B, every MVCC transaction holds `blocking_checkpoint_lock` in read mode for its whole life
  (`begin_tx` takes it at mod.rs:6729, `remove_tx` releases it at mod.rs:6862). The checkpoint
  takes it in write mode at `AcquireLock` (csm.rs:2516). `TursoRwLock::write` is a try lock
  (core/storage/wal.rs:350). So a B checkpoint does not wait for readers. It fails with `Busy`
  if any transaction is open. An auto checkpoint drops that error (mod.rs:3755-3759).
  Conclusion: while a B checkpoint runs, `txs` is empty and no commit is `Preparing`.
- In P and T, `begin_tx` never takes the lock (mod.rs:6423, mod.rs:6728-6729). So in T the
  write lock excludes other checkpoints and VACUUM, but not readers or writers. T takes the
  lock only at `CommitPagerTxn` (csm.rs:3246-3252), after collection and after
  `CompactSequences`.

## 1. Table of mechanisms

The kind column has three values. "Design" means a guarantee needs it. "Optimization" means
the same result with less work or memory. The row names the rule that it replaces. "Dead in B"
means that it runs in B but nothing in B needs it.

### Commit path

| Mechanism | Code | Modes (gate) | Modeled? | Kind |
|---|---|---|---|---|
| `Initial`: take end_ts and publish `Preparing` under the clock lock | mod.rs:3087-3310 | B, P, T (no gate) | Row spec `WritePrepare` | Design (R1 depends on it) |
| `Commit`: write-write validation | mod.rs:3312-3333, `check_rowid_for_conflicts` mod.rs:2071 | B, P, T (no gate) | Not modeled (DESIGN.md "leaves out write-write conflicts") | Design |
| `WaitForDependencies`, commit dependencies, `abort_now` | mod.rs:3335, `register_commit_dependency` mod.rs:11129, rollback sets `abort_now` mod.rs:7172 | B, P, T (no gate) | Row spec `WriteAbort` with `Aborts`, `GuardReadersAbortOnDependency` | Design |
| `BuildLogRecord` and `canonical_log_id` | mod.rs:2458-2470 | B, P, T (no gate) | Schema spec (ids, `FixPersistIds`) | Design today. SIMPLIFY step 3 removes it |
| `MarkDirtyKeys` | mod.rs:2728, `step_mark_dirty_keys` mod.rs:2737, `mark_tx_write_set_dirty` mod.rs:7905, `mark_checkpoint_dirty_key` mod.rs:7861 | B, P, T (no gate) | Row spec `WriteMarkDirty`, `WriteLateMark` (`DirtyKeys = TRUE`) | Optimization (replaces a walk of the whole version store). Dead in B, see section 2 |
| Logical log append and fsync | mod.rs:3408-3586 | B, P, T | Row spec `WriteLogAppend` (one atomic step) | Design |
| Group commit (`AwaitGroupCommit`, `SyncGroupPrefix`, `GroupPrefixSynced`) | mod.rs:1449, mod.rs:3448, mod.rs:3558, mod.rs:3572, `group_commit.rs` | B, P, T (`group_commit_enabled`) | `MvccGroupCommit.qnt` (no checkpoint, no readers) | Optimization (replaces one fsync per commit) |
| `CommitEnd`, `publish_committed_tx` | mod.rs:3629, mod.rs:3677, mod.rs:7346 | B, P, T | Row spec `WriteFinish`. Schema spec `DdlFinish` for the header | Design |
| TxID to timestamp rewrite | `rewrite_live_versions_for_committed_tx` mod.rs:7383 | B, P, T | Modeled in `WriteFinish`, which is `CommitEnd` plus the rewrite. The what-if `RemoveTxBeforeRewrite` splits them (`WriteRewrite`) | Optimization (replaces a lookup of the tx state on each read) |
| `finalized_tx_states` insert at `remove_tx` | mod.rs:6829-6835, mod.rs:6871 | B, P, T | Row spec `WriteRemoveTx`, behind `ModelFinalizedPrune`. The insert and the removal from `txs` are one step | Design (TxID resolution after the tx leaves `txs`) |
| `gc_incremental` on commit | call mod.rs:3730-3732, body mod.rs:8203. Trigger `should_gc` mod.rs:8123 | B, P, T. In B it takes the lock in read mode (mod.rs:8207-8219) and unlinks empty slots (mod.rs:8296). P and T leave empty slots | Row spec `Gc`, `GcSample`, `GcApply`, `GcEnd` (GC at any moment) | Optimization (replaces "GC only at checkpoint end") |
| `gc_in_progress`, `gc_last_lwm` short cut, `gc_table_cursor` budget | mod.rs:8226-8240, mod.rs:8019, mod.rs:8263-8310 | B, P, T | Not modeled | Optimization (scheduling only) |
| Auto checkpoint trigger | mod.rs:3700-3720 | B, P, T (`should_checkpoint`) | Not modeled | Design (bounds the log) |
| Rollback | `rollback_tx_inner` mod.rs:7144, `rollback_version_chain` mod.rs:7264 | B, P, T | Row spec `WriteAbort` (Preparing only) | Design |
| Rollback resets `materialized_at` | `set_end(None)` mod.rs:7273, mod.rs:10997 | B, P, T | Row spec `AbortKeepsMaterialized` | Leak (DESIGN-rows finding 1) |
| Rollback unmarks dirty keys | mod.rs:7209, `unmark_checkpoint_dirty_key_if_stamp` mod.rs:7883 | B, P, T (no gate) | Row spec `WriteAbort` with `DirtyKeys` | Optimization bookkeeping. Dead in B |
| `cleanup_dropped_commit` (abort after log append counts as commit) | mod.rs:7292 | B, P, T | `MvccGroupCommit.qnt` `Drop` and `DropFinish` (group path only, no readers) | Design |
| Exclusive tx and commit lock | mod.rs:7400, mod.rs:7673, mod.rs:7713 | B, P, T | Not modeled (only its cookie effect, schema S8) | Design |

### Begin and read path

| Mechanism | Code | Modes (gate) | Modeled? | Kind |
|---|---|---|---|---|
| Lifetime read guard on the blocking lock | mod.rs:6410-6420, mod.rs:6729, release mod.rs:6862 | B only (gate: flag off) | Sequence spec `TxBegin` waits while a blocking checkpoint runs (MvccPassiveSequence.qnt:246) | Design for B |
| Read mark taken before the clock lock | mod.rs:6757 | B, P, T | Row spec `ReaderPin`, `ReaderBegin`. Schema spec S21 | Design |
| `schema_generation` check at begin | mod.rs:6768. Bump at csm.rs:2147 | B, P, T (no gate on the check or the bump) | Schema spec S10 (`noGenerationGate`: not needed) | Not needed in the model |
| `schema_still_valid_for_tx` | mod.rs:7978 | P, T (gate: flag) | Schema spec S10 | Not needed in the model |
| `Busy` while a DDL commit has not published its cookie | mod.rs:6779, mod.rs:7685 | B, P, T | Schema spec S8 (`noBusy` fails) | Design |
| Root page to table id at begin_ts | cursor.rs:613-623 | P, T use `try_get_` and return `SchemaUpdated`. B uses `get_` (gate: flag) | Schema spec S7 (`noOpenFallback`: not needed) | Not needed in the model |
| `is_btree_readable_at` (binding covers begin_ts, `materialized_at <= read_mark`) | mod.rs:10695, cursor.rs:833-860 | B, P, T | Schema spec S1, S2, S3, S15, S16 | S1 design. S2, S3 not needed in the model |
| Dual cursor looks at the chain twice | cursor.rs:977, cursor.rs:1064, cursor.rs:1233 | B, P, T | Row spec `ReadLooksAtChainTwice`, `ReaderReadStart`, `ReaderReadEnd` | Design today. SIMPLIFY step 6 |
| B-tree covers the chain (skip the chain, read the B-tree) | `btree_covers_chain_for_snapshot` mod.rs:6070-6087, `chain_is_write_buffer_for` mod.rs:6024, cursor.rs:1203. On main 2827d0cc1: mod.rs:6093-6111, mod.rs:6047-6076, call sites cursor.rs:1201-1204, mod.rs:5912, mod.rs:6195, mod.rs:6240 | B only (with the flag on, it returns false at the first line, mod.rs:6093-6111) | Modeled: row spec `FallThrough` with `Mode = "blocking"` and the guards `GuardFallThroughCkptMax`, `GuardFallThroughMark`. In `blockingMainNoFallThrough` (563,686 states, 48 s) no look uses it, because a pass that succeeds with no failed pass before it empties the store. It runs only after a pass that stops after its stamp (`reachBlockingFallThrough`, 1,855 states, 42 s). Whether the engine stops there is not verified | Optimization (replaces "read the chain, else the B-tree"). Not shown needed in `blockingMain` |
| `checkpoint_in_progress` test inside it | mod.rs:6079. On main 2827d0cc1: mod.rs:6093-6111 | Reached only in B, but only the P/T path sets the flag (csm.rs:2486-2496, ck.rs:2408-2418 on main) | Not modeled | Dead in B (always false) |
| Index lockstep merge | `index_chain_invalidates_btree` mod.rs:6099, cursor.rs:524, debug compare cursor.rs:667-672 | B, P, T | Index spec `ReaderReadStart`, `ReaderReadEnd` model the per-key rule with two looks. The trace replay scans with the lockstep cursor (`DESIGN-indexes.md`) | Optimization (replaces `query_btree_version_is_valid` per key, mod.rs:6126) |
| Row map epochs | cursor.rs:479-484, cursor.rs:907-948, mod.rs:8829, mod.rs:8841 | B, P, T | Not modeled | Optimization (replaces a fresh skip list seek per step) |
| Sequence allocation registry | mod.rs:6881, mod.rs:6920, mod.rs:6954 | B, P, T | Not modeled (DESIGN-sequences "Not modeled") | Optimization for forward-only scans |

### Checkpoint states

| Mechanism | Code | Modes (gate) | Modeled? | Kind |
|---|---|---|---|---|
| `PrepareCheckpoint`: `checkpoint_in_progress` CAS | csm.rs:2479-2499 | P, T (gate: flag) | Row spec `ck.pc` (one checkpoint at a time) | Design for P |
| `AcquireLock` | csm.rs:2511-2534 | B only (P and T skip it, csm.rs:2501-2509) | Sequence spec `CheckpointStart` with `Mode == "blocking"` | Design for B |
| Snapshot below every `Preparing` commit | `checkpoint_snapshot_ts` mod.rs:7843 | B, P, T (no gate) | Row spec `SnapshotTs`, R1 `GuardSnapshotBelowPreparing` | Design for P and T. Dead in B (no `Preparing` tx exists while B holds the lock) |
| Full-scan generation | read csm.rs:2503, csm.rs:2528. `require_checkpoint_full_scan` mod.rs:7925. `clear_checkpoint_full_scan` mod.rs:7932, called csm.rs:3523 | B, P, T (no gate) | Row spec `RequireFullScan`, `Remark`, `CheckpointClearFullScan` | Design for the dirty-key optimization. Dead in B with no dirty keys |
| `BuildLocalSchemaView` | csm.rs:2535 | P, T (gate: flag) | Schema spec S18 | Design for P |
| `index_id_to_index` from the shared schema | csm.rs:909-923, refresh csm.rs:851, csm.rs:2531 | B (gate: flag off) | Not modeled | Design for B |
| `CollectTableRows`, `CollectIndexRows` (dirty walk or full walk) | csm.rs:1271-1300, csm.rs:1313, csm.rs:1329, csm.rs:1568-1591, csm.rs:1651 | B, P, T. A set `full_scan_generation` selects the full walk | Row spec `CheckpointCollect`. Index spec `CheckpointCollectIndex` (P only) | Design (collect). The dirty walk is the optimization |
| Clamp of a future drop to "live" | `maybe_get_checkpointable_versions` csm.rs:1078-1130 | B, P, T | Row spec `CheckpointCollect`, schema spec `CheckpointObj` | Design for P and T. In B no future commit exists |
| Prune candidates | `record_prune_candidate` csm.rs:1734, `record_dirty_stamps` csm.rs:1530 | B, P, T (no gate) | Row spec `CheckpointPrune` | Optimization bookkeeping. Dead in B |
| Debug check that every changed key is dirty | csm.rs:1763, csm.rs:1787 | B, P, T (debug) | `CollectsEveryChange` | Check |
| `persistent_tx_ts_max` row in the same frame | `maybe_stage_mvcc_metadata_write` csm.rs:2423, staged at csm.rs:2632-2633 | B, P, T | Row spec `CheckpointCommit`, `RecoveryCorrect` | Design |
| Write rows, `written_table_rowids` | csm.rs:2400-2411 | B, P, T | Not modeled (DESIGN-rows: schema cases) | Design |
| `CompactSequences` | csm.rs:3208-3239, driver csm.rs:705-725, `pending_sequence_compactions` csm.rs:792 (skips CYCLE at csm.rs:817) | P records deletes. B and T delete inline and purge the chain (`purge_row_versions_during_checkpoint` mod.rs:8988). Gate: `CheckpointMode::Passive` (csm.rs:3224), not the flag | Sequence spec `CheckpointCompact`, including mode T (see checkpoint-stop section) | Design (bounds the backing table) |
| `CommitPagerTxn`, header stage | csm.rs:3241-3295 | B, P, T. T takes the lock here (csm.rs:3246-3252) | Row spec `CheckpointCommit`, schema spec issue11499 | Design |
| Publish window | `apply_checkpoint_publish_window` csm.rs:2154-2205 | P: under the clock lock (`apply_passive_publish_window_ordered` csm.rs:2208). B and T: under the blocking lock (csm.rs:3313-3320), no clock lock | Row spec `CheckpointPublish`, schema spec `CheckpointPublish` | Design |
| Publish drain bit | `checkpoint_publish_in_progress`, mod.rs:7957-7968, csm.rs:3298-3309 | P (gate: mode) | Not modeled. The recovery spec `CkPublish` models the publish as its own step, but not this retry | Dead (not verified). Only checkpoints CAS it, and `checkpoint_in_progress` already allows one checkpoint. No `begin_tx` reads it (rg finds only mod.rs:4442, mod.rs:4655, mod.rs:7959, mod.rs:7966), so the comment at csm.rs:2211-2212 is wrong. The busy retry at csm.rs:3300-3309 cannot fire |
| Sequence deletes at a fresh clock ts | csm.rs:2163-2167, `seqcompact_commit_delete` mod.rs:8998, `seqcompact_stamp_delete` mod.rs:9007 | P only (only csm.rs:2217 passes `Some(ts)`) | Sequence spec `CheckpointPublish`, S3 | Design |
| Root bindings: retire, alloc, visible | csm.rs:2169-2185, mod.rs:4809, mod.rs:4848, mod.rs:4859 | B, P, T | Schema spec S4, S6 | Design for P |
| Patch `sqlite_schema` roots, `dropped_root_pages`, generation bump | `publish_checkpointed_schema_roots` csm.rs:2021-2148 | B, P, T | Schema spec S11, S12, S13 | Design |
| `durable_txid_max` store | csm.rs:2186-2188 and again csm.rs:3481-3483 | B, P, T | Row spec `CheckpointPublish` | Design. The second store writes the same value |
| `CheckpointWal` | csm.rs:3373-3397 | B, P, T. `Busy` goes on only in P (gate: mode) | Row spec `CheckpointBackfill` | Design |
| `SyncDbFile`, publish `nBackfill` | csm.rs:3399-3438, csm.rs:1960 (a mode that restarts the log skips it) | B, P, T | Row spec `CheckpointBackfill` | Design |
| `TruncateLogicalLog` | csm.rs:1919-1944, `LogicalLog::truncate` core/mvcc/persistent_storage/logical_log.rs:1083-1095 | B: whole log, asserted (csm.rs:3326-3338). P and T: if one record is above the boundary, keep all. Gate: `clears_whole_logical_log` csm.rs:1942, true for Truncate mode with the flag off | Row spec `CheckpointTruncateDecide` and `CheckpointTruncateApply` (see checkpoint-stop section) | Design |
| `TruncateWal` (WAL restart) | csm.rs:3440-3470. The restart itself runs in `CheckpointWal` (wal.rs:5249-5258 on main 2827d0cc1), and `TruncateWal` only truncates the file (ck.rs:3366-3390) | B, T (gate `should_restart_log`) | B: modeled inside the atomic step `CheckpointBlocking`, in counted frames (the stamp `(seq + 1, 0)` counts to frame `F`). T: not modeled | Design for B |
| Set `backfill_floor` | csm.rs:3484-3489 | B, P, T (no gate) | Row spec `CheckpointBackfill`, `GcFloor` | Design for P (R5). Dead in B |
| `gc_rootpage_entries(lwm)` | csm.rs:3490-3491, mod.rs:4870 | B, P, T | Schema spec S5 | Design for P |
| `GcTableRows`, `GcIndexRows`: stamp, then GC | csm.rs:3492-3516, csm.rs:2252-2329, csm.rs:2331-2398. Table rows on main 2827d0cc1: ck.rs:2172-2179 | B, P, T (no gate) | Row spec `CheckpointStamp`, then `Gc`. In B: inside `CheckpointBlocking`. Index spec `CheckpointStampTable`, `CheckpointStampIndex`, then `GcTable`, `GcIndex` (P only) | Stamp: design for P, dead in B. GC here: optimization (replaces the later sweep) |
| `materialized_at` stamp | `stamp_chain_materialized` mod.rs:8651, frame from `wal_pos()` at csm.rs:2257 | B, P, T | Row spec `CheckpointStamp`. In B: the stamp of `CheckpointBlocking`. The B stamp is the restart position `(seq + 1, 0)`, never `ORIGIN` (gap 14) | Design for P (R2). Dead in B |
| `PruneDirtyKeys` | csm.rs:3518-3527, csm.rs:1741 | B, P, T (no gate) | Row spec `CheckpointPrune`, `CheckpointPruneDone` | Optimization bookkeeping. Dead in B |
| `Finalize` sweep, B and T | `drop_unused_row_versions_and_slots` csm.rs:3531-3535, mod.rs:8188. On main 2827d0cc1: ck.rs:3452-3456, mod.rs:8232 | B and T (gate: `blocking_checkpoint_lock_held`) | B: modeled as the GC step with `lwm = Inf` inside `CheckpointBlocking`. T: not modeled. Sequence spec "blocking" uses the P rules | B: replaceable by "remove every entry". `BlockingStoreEmpty` holds in `blockingMain` |
| `Finalize` sweep, P | `drop_unused_row_versions_unlink_empty_at` csm.rs:3536-3543, mod.rs:8195 | P | Row spec `Gc` | Optimization (memory) |
| Release locks | csm.rs:1022-1034 | B, P, T | Not modeled | Design |

### GC rules and floors

| Mechanism | Code | Modes (gate) | Modeled? | Kind |
|---|---|---|---|---|
| Rule 1 (aborted garbage) | mod.rs:8591-8592 | B, P, T | Row spec `Gc` | Design (memory) |
| Rule 2, P form (`materialized_at <= floor`) | mod.rs:8604-8609 | P, T (gate: flag) | Row spec `Gc`, R2 | Design |
| Rule 2, B form (`e > ckpt_max` and `in_btree or no current`) | mod.rs:8610-8619. On main 2827d0cc1: mod.rs:8648-8665 | B (gate: flag off) | Modeled: row spec `Rule2B` with `GuardB2KeepUncheckpointed`, `GuardB2InBtree`, `GuardB2Tombstone`. `blockingNoB2Keep` and `blockingNoB2InBtree` fail `ReadsCorrect` (13,683 and 87,133 states). `blockingNoB2Tombstone` finds no error (662,548 states). The rule has no stamp test, and `blockingPagerPin` shows the wrong read that follows (gap 24) | Design for B. The `not(has_current)` term is not shown needed at these bounds |
| Rule 3 (last current, idle only) | mod.rs:8623-8640. B also needs `b <= ckpt_max` (mod.rs:8633). On main 2827d0cc1: mod.rs:8673-8683 | B, P, T. Gates: `lwm == MAX`, `materialized_for_readers` | Row spec `GuardDropCurrentOnlyWhenIdle`, R3. In B: `Rule3B` with `GuardB3InCkptMax`. `blockingNoB3CkptMax` finds no error (563,686 states, 46 s), but that result is vacuous: the guarded path never decides a step in `blockingMain`, and a pass stamps only versions at or below its new `durable`, so the term is implied by the stamp | Design (memory). The model does not test the `b <= ckpt_max` term |
| `gc_chain_now` checks `lwm == MAX` again | mod.rs:8154-8170 | B, P, T | Row spec `GuardGcRechecksIdleLwm` | Design |
| `compute_min_reader_mark` in the floor | mod.rs:10718, used mod.rs:8251, mod.rs:8376-8378, mod.rs:8454-8457, mod.rs:8494-8497 | B, P, T | Row spec `GcFloorRule` | Optimization at most. The owner model can lower the floor after its pager pin disappears (`MvccPassiveCheckpoint.qnt:1078`). A wrong read without this term is not verified |
| Pinned pager read marks in the floor | `gc_floor_reader_mark` csm.rs:2237-2250 | Checkpoint GC in B, P, T. Not in `gc_incremental` | Row spec `floorPinned` | Design option |
| `prune_finalized_tx_states` | mod.rs:8542, only from `drop_unused_row_versions_inner` mod.rs:8434 and the checkpoint `Finalize` sweep csm.rs:3535 and csm.rs:3543 | B, P, T (only in a full sweep) | Row spec `FinPruneCollect` and `FinPruneApply`, behind `ModelFinalizedPrune`. Results in gap 6 | Design (memory). The referenced filter is redundant for safety, by the source order of the rewrite and `remove_tx` (gap 6) |
| Empty slot unlink, writer retry | mod.rs:8296, mod.rs:8380, mod.rs:8478, mod.rs:8517. Retry in `insert_version` mod.rs:8727-8752 | B, P, T (P keeps slots until `Finalize`) | Not modeled | Optimization (memory) |
| Chain shrink | `shrink_version_chain_allocation` mod.rs:8691 | B, P, T | Not modeled | Optimization (memory) |

### Recovery and other paths

| Mechanism | Code | Modes (gate) | Modeled? | Kind |
|---|---|---|---|---|
| Recovery: replay log records above `persistent_tx_ts_max` | `maybe_recover_logical_log` mod.rs:9609, boundary mod.rs:9663-9681 | B, P, T | Row, schema, sequence specs `RecoveryCorrect` | Design |
| Recovery WAL backfill (TRUNCATE) | mod.rs:9275-9290 | B, P, T | Recovery spec `Open` | Design |
| Startup case table: refuse or reconcile | `maybe_complete_interrupted_checkpoint_nonblock` mod.rs:9179. Read-only refusal mod.rs:9222. `NoLog` refusal mod.rs:9237 (flag off only). `Invalid` refusal mod.rs:9247 | B, P, T. The `NoLog` refusal has the gate "flag off" | Recovery spec `Open`, `OpenSucceeds` (`issue7480`, `issue9749`, `leadA`, `leadB`) | Design. The `NoLog` refusal is a bug (#7480, #9749, PR #9770) |
| Log header written with the first frame after a truncate | logical_log.rs:717, header read logical_log.rs:1832-1860 | B, P, T | Recovery spec `CommitWrite`, `Crash` with `torn` | Design. A torn header with WAL frames refuses every open (`leadB`) |
| Checkpoint error cleanup | `cleanup_after_external_io_error` csm.rs:1039-1075 | B, P, T | Partly. Recovery spec `CkFail` stops a checkpoint at each modeled step from the pager commit to the WAL truncate. It models the effects of a failure before the publish, of a log truncate error, and of an async truncate failure. A failure inside the backfill or between the WAL truncate and its fsync is not modeled (`DESIGN-recovery.md`) | Design. A failure after the publish leaves versions unstamped (`idea2`, `idea2Passive`) |
| Log truncate error | `truncate_to_zero` logical_log.rs:1058-1078, Unix truncate core/io/unix.rs:500-512 | B, P, T | Recovery spec `LogTruncateErrors` (`logTruncError`) | Bug lead. The salt and running CRC change before the truncate call, and an error keeps the offset. The next frame does not chain, so a crash loses an acknowledged commit. A `LogicalLog` unit test shows the unreadable frame |
| Replay keeps one timestamp per frame | mod.rs:9936, `insert_version_raw` mod.rs:8880 | B, P, T | Recovery spec `RecoveryOneTs` (`idea1`) | Design. One timestamp for all frames brings back deleted rows |
| Bootstrap ids from root pages | `bootstrap` mod.rs:5121 | B, P, T | Schema spec `Boot` | Design today |
| VACUUM reset with `SkipMap::clear` | mod.rs:4958-4983, gate mod.rs:4891 | B, P, T | Not modeled | Design |
| Rowid allocator cache | `table_id_to_last_rowid` mod.rs:4484, dropped in `gc_rootpage_entries` mod.rs:4880 | B, P, T | Not modeled | Optimization (cache) |
| Busy retries | B begin mod.rs:6729-6731. DDL cookie mod.rs:6800. B checkpoint csm.rs:2516-2519. P publish csm.rs:3299-3309. P backfill csm.rs:3381-3395. Auto checkpoint swallows errors mod.rs:3755-3759 | See each | Schema spec `Busy` (S8). Row spec backfill of zero frames | Mixed |

## 2. What blocking mode (B) runs that only the passive design needs

Facts that hold during a B checkpoint, all verified in code:

- `txs` is empty. The checkpoint holds `blocking_checkpoint_lock` in write mode
  (csm.rs:2516). Every transaction holds it in read mode for its life (mod.rs:6729,
  mod.rs:6862). VACUUM already relies on this and asserts `txs.is_empty()` under the same
  lock (mod.rs:4891-4898).
- The checkpoint does not wait for readers. It returns `Busy` (csm.rs:2517-2519). An auto
  checkpoint drops the error (mod.rs:3755-3759). So under steady load, B checkpoints can be
  skipped again and again (not verified how often).
- No commit is `Preparing`. The snapshot is `last_committed_tx_ts`.
- The checkpoint writes every committed change and then truncates the whole logical log
  (csm.rs:1921-1931, asserts at csm.rs:3326-3338).
- New readers cannot start until the checkpoint releases the lock (mod.rs:6729).

So at the end of a B checkpoint, the B-tree holds the full committed state, the log is
empty, and no transaction exists. The version store holds nothing that the B-tree does not
have. Each item below exists only to protect a concurrent reader or a concurrent commit.

| # | What B runs | Code | What B can do instead | What must stay true |
|---|---|---|---|---|
| 1 | Mark dirty keys on every commit | mod.rs:2728, mod.rs:2737, mod.rs:7905 | With the flag off, skip the mark. Collect with a walk of the whole store (`collect_table_rows_from_store` csm.rs:1313, `collect_index_rows_from_store` csm.rs:1595). With item 6, the store holds only keys that changed after the last B checkpoint. So the full walk visits the same keys as the dirty walk | The store must be empty after every B checkpoint. If a checkpoint fails or is skipped, the full walk still finds every change, because nothing removes a changed key before it is written |
| 2 | Unmark dirty keys on rollback | mod.rs:7209 | Nothing | Follows from item 1 |
| 3 | Prune candidates, `PruneDirtyKeys`, full-scan generation and its CAS | csm.rs:1734, csm.rs:1741, csm.rs:3518-3527, mod.rs:7921-7950 | Nothing. If the dirty maps stay, B can clear them after the checkpoint. B can also set the generation to 0. Every lost stamp is at or below the snapshot | No `Preparing` commit during the checkpoint (true in B) |
| 4 | Snapshot clamp below `Preparing` commits | mod.rs:7843-7858 | Use `last_committed_tx_ts`. Keep an assert that no tx is `Preparing` | `txs` empty |
| 5 | `materialized_at` stamp in `GcTableRows`, `GcIndexRows` | csm.rs:2286-2293, csm.rs:2380-2386, mod.rs:8651 | Nothing. In B the stamp is the WAL position after `TruncateWal` (csm.rs:2257 runs after csm.rs:3440-3470), so it does not name the frame of the write. The position is `(seq + 1, 0)` and never `ORIGIN` (wal.rs:6106-6119 on main 2827d0cc1, the probe prints the WAL position after each pass, `(3, 0)`, `(4, 0)`, `(5, 0)`, and `rows_versions = 0`. The stamp is that position by code reading, ck.rs:2179). It equals `ORIGIN` only after 2^32 restarts of this WAL file (the sequence is read from the WAL header at open, core/storage/sqlite3_ondisk.rs:1812). Gap 14 is closed | None |
| 6 | GC rules at the end: `GcTableRows`, `GcIndexRows`, then `drop_unused_row_versions_and_slots` | csm.rs:3492-3516, csm.rs:3531-3535, mod.rs:8188, mod.rs:8408 | Remove every entry of `rows` and of each `index_rows` inner map, one by one. Do not call `SkipMap::clear` (core/skiplist/base.rs:1515): it only marks towers in batches of 100 and leaves the unlink to later searches. Then empty `finalized_tx_states`, because no tx exists and no version is left that names a TxID | `txs` empty. Every committed version is in the B-tree. No pager-level reader without an MVCC tx. This is false. An MVCC reader takes the gate before its read mark (mod.rs:6410-6420), but the schema reparse paths (core/connection.rs:1413, core/connection.rs:1469) pin a read mark with no gate and keep it while their `SELECT` begins an MVCC transaction. The raw WAL API does not open the window: `wal_insert_begin` (core/connection.rs:2529) also takes the WAL write lock, so the pass fails before its publish, and `wal_get_frame` (core/connection.rs:2500) pins only inside its call and runs no SQL. A reparse pin makes the B pass fail with `Busy` after its publish, and Rule 2 B form then drops a delete (gap 24, `FINDINGS.md` row 24). Attached databases: not verified |
| 7 | `backfill_floor`, `compute_min_reader_mark`, `gc_floor_reader_mark` in GC | csm.rs:3484-3489, mod.rs:10718, csm.rs:2237 | Nothing in the checkpoint GC. `gc_incremental` between checkpoints only needs Rule 2 B form, which uses `ckpt_max`, not the floor. That is the cause of the wrong read of gap 24: the rule has no stamp test and no floor (mod.rs:8657-8661 on main 2827d0cc1). Rule 3 in B also reads the floor (mod.rs:8631), but item 6 already drops those versions | Same as item 6 |
| 8 | Rule 3 tests `lwm == MAX` | mod.rs:8635 | Always true in a B checkpoint | `txs` empty |
| 9 | Versioned root bindings: retire with `end_ts`, `gc_rootpage_entries(lwm)`, `materialized_at` on bindings, `STAGED` | csm.rs:2169-2185, mod.rs:4859, mod.rs:4870, mod.rs:10695 | Replace the binding at publish and delete retired bindings at once. No reader can see the old binding | Not verified: statements prepared before the checkpoint must get `SchemaUpdated` or must map their root again. The cookie check and the generation check (mod.rs:6768) give this today |
| 10 | `schema_generation` bump | csm.rs:2147 | Not verified that B needs it. The bump makes every statement prepared before it fail with `SchemaUpdated` at the next begin (mod.rs:6768). In B the cursor maps roots with `get_table_id_from_root_page_at` (cursor.rs:621-622) | Prepared statements must not use a stale root |
| 11 | `checkpoint_in_progress` test in `btree_covers_chain_for_snapshot` | mod.rs:6079 | Delete it. It is always false in B | None |
| 12 | Sequence chain purge (S5) | mod.rs:8988, csm.rs:713-725 | Item 6 drops the chain anyway. Keep the B-tree delete | Same as item 6 |
| 13 | GC of sequence and row versions inside `GcTableRows` and again in `Finalize` | csm.rs:3492, csm.rs:3535 | One pass (item 6) | None |

B needs these items and must keep them:

- the blocking lock
- write-write validation and commit dependencies
- the `persistent_tx_ts_max` row in the same frame
- the truncate of the whole log, the WAL truncate, and recovery
- `gc_incremental` with Rule 2 B form between checkpoints
 Rule 2
B form frees superseded versions under load. It never frees a version that the next
checkpoint must write (mod.rs:8615-8618).

Warning about mode T. If `blocking_checkpoint_lock_held` is true, `Finalize` picks the B
sweep (csm.rs:3531). That is also true in T. The comment at csm.rs:3533 says "That lock waits
out open MVCC txs". In T it does not, because readers never take the lock (mod.rs:6423). So
the "drop everything" change must test the flag (or `txs.is_empty()` plus no pinned read
mark), not the lock.

## 3. Gaps in the model, ranked by risk

1. Mode T now appears in the row and sequence specs. The sequence model checks inline compaction and Busy before stamping. See the checkpoint-stop section for the result. The recovery spec covers T in part (kind `truncflag`: file steps, crash recovery and row GC, with no readers). The WAL restart and the blocking final GC sweep of mode T remain outside these models (`MvccPassiveSequence.qnt:48`). Their effects in T are not verified. The row spec models both for mode B (gap 2).
2. Modeled (row spec, `Mode = "blocking"`, turso main 2827d0cc1). The B checkpoint is two actions: `CheckpointBlocking` (a pass that succeeds, one atomic step, because no MVCC actor runs inside it) and `CheckpointBlockingFail` (a pass that stops after its publish). Three B paths change reads: Rule 2 B form (mod.rs:8648-8665), Rule 3 with `b <= ckpt_max` (mod.rs:8673-8683), and the B-tree fall-through read (mod.rs:6047-6111). Results (1 key, 2 readers, 5 timestamps, 2 checkpoints, 4 workers). `blockingMain` finds no error (563,686 states, 61 s). `blockingNoB2Keep` and `blockingNoB2InBtree` fail `ReadsCorrect`. `blockingNoB2Tombstone` finds no error: not shown needed at these bounds. `blockingNoB3CkptMax`, `blockingNoFallThroughMark` and `blockingNoFallThroughCkptMax` find no error too, but they are vacuous: the guarded path never decides a step in `blockingMain` (563,686 states each, the same as `blockingMain`), and the two `ckpt_max` terms are implied by the stamp in this model. `GuardFallThroughMark` is needed: `blockingNoFallThroughMarkPinned` fails `ReadsCorrect`. `blockingPagerPin` fails `ReadsCorrect` (gap 24). The fall-through read never runs in `blockingMain` (`blockingMainNoFallThrough`, no error). `DESIGN-rows.md`, section "Mode B", has the full table. The model leaves out index rows in B, root bindings, the real reparse window, the yields of `GcTableRows` and a crash inside a B pass. The sequence spec still uses the P GC rules in all three modes (`MvccPassiveSequence.qnt:51`).
3. Modeled in part. The schema spec has `Mode` (`"passive"`, `"truncateFlagOn"`; `MvccPassiveSchema.qnt:103`). In mode T the publish runs in four steps with no clock lock: `CheckpointPublishRoots` (csm.rs:2169-2190), `CheckpointPublishHeader` (csm.rs:2194-2199), `CheckpointPublishSchema` (csm.rs:2021-2136) and `CheckpointPublishGen` (csm.rs:2137-2147), called at csm.rs:3321-3324 (`MvccPassiveSchema.qnt:1077-1146`; the passive publish is `CheckpointPublish`, `MvccPassiveSchema.qnt:1050`). A reader can prepare, begin, open and read between them. The witness `reachBeginMidPublish` shows only the begin. `truncateFlagOn` checks the main invariants and finds no error in 28,866,833 distinct states. `truncateNoRefreshRoot` (`GuardRefreshRoot` off) fails `OpenCorrect`, so the guard carries that result. At these bounds the missing clock wrapper costs only a spurious `SchemaUpdated`. The TRUNCATE backfill needs every read lock free, else the pass fails with Busy at `published`. In `truncateFlagOn` every pass is a T pass, so passive auto passes mixed with T passes are not checked. No configuration combines mode T with the owner path or with catalog reads. These parts are still open: WAL restart; the final blocking GC sweep of mode T (csm.rs:3532-3535); interleavings inside the root map ops; the sqlite_schema payload patch apart from `Database::schema` with ALTER (`Alters` stays off in mode T); the cleanup publish in mode T; a prepare inside the passive publish window. The trace replay refuses the mode T steps.
4. Mode T `Finalize` uses `reader_mark_floor = STAGED` (mod.rs:8188). So it ignores readers that pinned a read mark but are not in `txs` yet (rule R5). If the R5 argument holds after a WAL restart, `backfill_floor` still protects them. Not verified.
5. Modeled in mode P: `MvccPassiveIndex.qnt` (`DESIGN-indexes.md`). It models the index chains of one row, the index dirty map and its prune, `CollectIndexRows` with `unwritten_index_rows`, the `GcIndexRows` stamp, the separate index GC loop (mod.rs:8348) and the two looks of the dual cursor. TLC finds no violation of `IndexReadsCorrect`, `BtreeIndexMatchesTable`, `RecoveryCorrect` and `IndexChainsStamped` in 52,815,276 states. The trace replay runs the lockstep cursor (cursor.rs:524) and conforms on 160 traces. Still open: index rows in modes B and T, index DDL, unique indexes, more than one row, aborts, and failed passes.
6. Modeled for reads in the row spec (`ModelFinalizedPrune`, `DESIGN-rows.md`, "Finalized TxID states"). The code is safe by construction, and the referenced filter of the prune is not what makes it safe. Every path that removes a writer from `txs` first rewrites its TxID markers to timestamps. So no version names a finalized TxID when it enters the cache. In engine order the model assumes the rewrite comes before `remove_tx`, so `TxIdsResolve` and the filter-off pass hold by construction. The redundancy verdict rests on the source order at rev 0c9fe0dd9 (the normal commit mod.rs:3652 and 3660 before mod.rs:3698, the dropped COMMIT mod.rs:7320 before mod.rs:7330, the abandoned group waiter mod.rs:1951 before mod.rs:1956, and the fast paths mod.rs:3303 and 3377 with an empty write set, mod.rs:6831-6832) plus the what-if controls. `finalizedNoReferenced` shows only that the new steps keep the other invariants. With one key, one reader and `MaxTs = 4`, TLC finds no error with the filter on (`finalizedMain`, 3,071,602 states) and with the filter off (`finalizedNoReferenced`, 1,709,056 states). `finalizedNoReferenced` also passes at `MaxTs = 5` (15,360,546 states). The run with two readers and `MaxTs = 5` did not finish in 44 minutes. The what-if `RemoveTxBeforeRewrite` breaks `TxIdsResolve` with the filter off (`finalizedRemoveBeforeRewriteNoReferenced`) and `ReadsCorrect` with it on (`finalizedRemoveBeforeRewrite`). A broken order breaks reads even with the filter on. So the filter does not replace the order rewrite then `remove_tx`. The filter does fire in the engine order: a writer that is Preparing at the collect can leave `txs` before the apply, and the filter keeps its TxID for one more round (`reachFinalizedGuardFires`). That only delays a prune. The trace replay conforms on 100 `mbtFinalized` traces and 100 `mbt` traces. A retiring writer keeps its WAL read mark until its statement ends (`fin.pins`, connection.rs:4894-4897), and the backfill stops at it. Left out: write-write conflict checks (a lost TxID gives "no conflict", mod.rs:2215-2217. Gap 7 models conflicts with timestamps, not lost TxIDs. The same order argument covers conflicts, but nothing models a lost TxID in a conflict check), the checkpoint `committed_ts` lookup of a lost TxID (csm.rs:1827-1838), `still_retiring` (the model removes the writer from `txs` in the same step), the prune only at `Finalize` and VACUUM (the model prunes at any time), root page GC protection (`rootpage_gc_protected` skips the collect), and writers of more than one row, index rows and mode B.
7. Modeled (row spec, `Updates`), turso rev 0c9fe0dd9. A registered reader can update one key (`ReaderUpdate`, one step: statement check, commit check and chain edit). The step decides a write-write conflict with the code rules (`is_write_write_conflict`, `check_version_conflicts`, mod.rs:2163 and mod.rs:10884). `NoLostUpdate` says that no write of the key lands between the begin and the commit of an update. Results at 1 key: `updates` (2 readers, 5 timestamps, 1 pass) finds no error in 8,466,039 distinct states (206 s). `main` still gives 17,344,980 states. At size S (1 reader, 4 timestamps, 1 pass) the guards that GC uses are not needed for `NoLostUpdate`: `updatesNoGcWait` (351,787 states) and `updatesNoRule2Lwm` (73,230) find no error. This is "not shown needed at these bounds": the lwm alone or the floor with the idle Rule 3 guard keeps what an update needs. With both off (`updatesNoRule2LwmNoGcWait`, 2,303 states) `NoLostUpdate` fails: GC drops a delete while the updater is open and the update commits over it. `updatesNoIdleRule3NoGcWait` (599 states) fails too: Rule 3 drops the only current version. These two are the negative controls. `updatesGcSampleNoRecheck` (2 passes, 1,481,376 states) finds no error, and its control `updatesGcSampleNoRecheckNoGcWait` (2,211 states) fails. Mode B: `blockingUpdates` (18,458 states) and `blockingUpdatesNoRule2Lwm` (21,378) find no error. The five `reach*` checks fail as they must, so each state is reachable. All predictions of the design held. The model leaves out: the updater stays in `txs` as Preparing in the engine, and the model removes it from the lwm after the step; deletes by a reader; more than one key; 2 passes in `updates` (not run); indexes. The trace replay (`ReaderUpdate` step in `rows.rs`) agrees with the engine on all 5 witnesses (`ww-reachConflictAfterGc` runs `Gc` before the updater begins, so the replay does not show evidence kept across a GC; only the TLC negative controls show that), and the regression replay gives 100 of 100 for `mbt` and `mbtBlocking`. The commit-dependency path is not modeled: a Preparing insert or update of the key with a timestamp below the begin of the updater gives no conflict in the engine (mod.rs:11234-11248, 10884), so `ReaderUpdate` is not enabled there. This is safe for `NoLostUpdate` because writes of the key are serialized: while an in-flight write below the begin exists, no write of the key lies between the begin and the clock. A Preparing delete below the begin is a lead, not verified: the commit check gives a conflict that has no cause (mod.rs:11324-11331, 2232-2245, 2299-2308). It cannot lose an update. A write above the begin stays a conflict, raised by the commit check. See `DESIGN-rows.md`, section "Write-write conflicts and GC". `FINDINGS.md` row 25.
8. Modeled. `MvccGroupCommit.qnt` models group commit and the order of log fsync and `CommitEnd` (mod.rs:3448-3586), with `DESIGN-group-commit.md`. A FULL commit that returns success is on disk (`AckDurable`), and the main configuration passes with 3 transactions and 4 tickets. Two promises fail in the code today. A dropped COMMIT becomes `Committed` before any fsync (`dropCommitsUnsynced`). A rolled-back transaction comes back after a crash (`dropResurrects`, `FINDINGS.md` row 20). The trace replay (`harness/mbt_tests/group.rs`) follows both on the engine. The spec leaves out readers and commit dependencies, I/O errors, the checkpoint, the non-group path and liveness. `finish_abandoned_group_waiter` removes a transaction without `notify_committed_dependents` (mod.rs:1949). Not verified.
9. WAL restart (core/storage/wal.rs:5367) and the value of `backfill_floor` across it are not verified (DESIGN-rows "WAL restart").
10. `cleanup_dropped_commit` (mod.rs:7292) treats an abort after the log append as a commit. `MvccGroupCommit.qnt` models it on the group path (`Drop`, `DropFinish`), with no readers. A dropped COMMIT becomes `Committed` before any fsync (`dropCommitsUnsynced`). The non-group path and the agreement of readers with recovery are not modeled.
11. Modeled. The schema spec has catalog scans through the dual cursor and GC of `sqlite_schema` versions, with the feature constant `CatalogReads` (`MvccPassiveSchema.qnt`, `ReaderReadCatalog` and `GcCatalog`). `issue8093` and `issue8094` show the symptoms of both issues with `GuardFrozenMark` off. The trace replay runs five `reach*` traces of the design on the engine and checks each catalog scan and each catalog GC both ways (DESIGN-schema "Catalog reads and catalog GC", HARNESS "Catalog traces"). Left out: a scan that runs while GC changes the chain (the scan is one atomic step), GC per version of an altered row, catalog reads with `ALTER`, the write-set rule of the stamp (the model stamps every row whose newest event is in the window), and a `DROP` and a `CREATE` of one name in one transaction.
12. Modeled. The schema spec has the object map of a row commit and the stable table id, with the feature constant `SyncObjectMap` and the fix constant `FixPermanentLogId` (`MvccPassiveSchema.qnt`, `WriteRow`, `LogId`, `MapNames`). The sync modules turn `CatalogReads` on, because the last lookup of the map reads the `sqlite_schema` versions that catalog GC drops. The invariants are `ObjectMapCorrect` (the object map of a row commit names the table of the row) and `StableIdsDistinct` (no two live tables have the same `abs(rootpage)`). The design passes both, and `NeverMapsFromBinding` (`sync`, 256,855 states, `docs/logs/gap12/r3-sync-tlc.log`). Two known issues break the push. `issue11501Sync`: the map of the commit of `INSERT INTO t6` names `t7` (`FINDINGS.md` row 26). `issue8004Sync`: a DDL commit installs its old copy of the schema, catalog GC drops the `sqlite_schema` versions of the table, and the next `INSERT` fails with `Corrupt` on every connection (`FINDINGS.md` row 27). A Rust test on turso main at ae2cb7388 shows each one (3 of 3 runs, `docs/logs/gap12/r3-repro-*.log`). A permanent id alone does not keep the client map apart (`permanentIdOnly`). The stable id changes at the first checkpoint (`reachStableIdChanges`). The `sqlite_schema` fallback of the map gives a name with the DDL commit of the code (`reachMapsFromCatalog`). The trace replay conforms on `reachMapsPageId` and `reachStableIdChanges`, and after each step it checks the live `sqlite_schema.rootpage` against `RootCol` and `StableIdsDistinct`. On `reachMapsInPass` the object map conforms, and the recovery check then fails with #11502. On `issue8004Sync` the engine fails the `INSERT` at the step where the spec has `omap = "-"` (DESIGN-schema "Sync object map", HARNESS "Sync traces"). Left out: the connection schema as a separate copy, a restart, more than one row of a table (`ObjectMapCorrect` covers the first row of each table), a row commit while another connection has an open DDL (not tested on the engine), rows and schema rows in one commit, ALTER, indexes, the server and the pull protocol, and a publish between `canonical_log_id` and the map build. Lead, not verified: a commit on another thread that reads a binding page before the publish window patches `rootpage` fails with `Corrupt`.
13. Modeled. The schema spec has the rowid allocator cache (`table_id_to_last_rowid`, mod.rs:4506) with the feature constant `RowidCache` (`MvccPassiveSchema.qnt`, `RowAlloc`, `RowCommit`, `RowAbort`, `rcache`). The cache drops its key with a `remove` op in the publish (mod.rs:4814) and with each retired binding that `gc_rootpage_entries` drops (mod.rs:4892). A cache that is not initialized starts from the largest committed rowid. This simplifies the engine, which starts from the largest rowid that the snapshot of the transaction sees (`op_new_rowid`, execute.rs:12669-12744, cursor.rs:612). The invariant is `NoRowidReuse`: no writer holds a rowid that a committed row or another writer has. The design passes it (`rowidCache`, 10,773 states, TLC), because the cache key is the table id, which a checkpoint keeps and the process never gives again. A cache keyed by the page of the binding reuses a rowid (`rowidKeyByRoot`, 586 states): a writer holds rowid 1, a checkpoint publishes the page, and the next writer finds no cache under the page and gets rowid 1 again. The reachability checks `reachRowidAcrossPublish`, `reachRowidCacheGc` and `reachRowidPendingPair` pass (`docs/logs/gap13/tlc.log`). The trace replay `rowid_cache_traces_conform` conforms on turso 0c9fe0dd9: the engine rowid equals the spec rowid at each `RowAlloc` (`docs/logs/gap13/replay.log`, HARNESS). Left out: deletes, VACUUM (mod.rs:5006), restart and recovery bumps, rollback restores, the random rowid fallback, and indexes. The `WriteRow` row action is off when the cache is on. A DROP waits for the writers of its table (not verified on the engine). Council findings, not blocking: writers have no snapshot and no `begin_ts`, so they do not hold `Lwm` down, and binding GC can run earlier than in the code (mod.rs:8036). An open writer cannot run during any DDL, and the DROP guard replaces the `SchemaConflict` of the code (mod.rs:3180). The model has no explicit-rowid bump (mod.rs:5512) and no separate `initialized` flag (mod.rs:10658). `rowidCache` has one table, so the stale retire of `record_rootpage_alloc` (mod.rs:4848-4861) and a page that a second table reuses are not reached. A two-table run with `Pages = Set(2)` is the next step. The replayed traces have no `RowCommit` or `RowAbort`. Lead, not verified: a writer with an old snapshot and a newer physical schema resolves a reused page to the retired binding of the dropped table (cursor.rs:613-621, mod.rs:4737-4753), so its row and rowid go to the dropped table id. Line numbers are from turso main 9cf2de2d8. The replay ran on 0c9fe0dd9.
14. Closed. The B stamp is never `ORIGIN`. The WAL restart runs in `CheckpointWal` (wal.rs:5249-5258), before the stamp, and the stamp is `pager.wal_pos()` (ck.rs:2179), which is `(seq + 1, 0)` (wal.rs:6106-6119, main 2827d0cc1). It equals `ORIGIN` only after 2^32 restarts of this WAL file (the sequence is read from the WAL header at open, core/storage/sqlite3_ondisk.rs:1812). Probe `probe_mode_b_stamp_after_restart` prints the WAL position after each of three passes, `(3, 0)`, `(4, 0)` and `(5, 0)`, and `rows_versions = 0` after each. The stamp is that position by code reading (ck.rs:2179), and the probe does not print the stamp. A reader after the restart read 3 rows (`harness/repro/mode-b-pager-pin.patch`). A reader that pins a mark after the restart has `(seq + 1, n)`, at or above the stamp. The variant `blockingStampOrigin` shows the harm of the what-if: `BlockingStoreEmpty` fails (77 states, 40 s) and `ReadsCorrect` holds (527,492 states).
15. A checkpoint that fails after its publish never stamps its rows. The retry collects from the new boundary (csm.rs:1138) and stamps only its own write set (csm.rs:2271), so GC keeps those versions until the key gets a new write. This is a missing stamp, not an `ORIGIN` stamp. Recovery spec `idea2` and `idea2Passive`, and a Rust test in each mode, show it.
16. A read-only open refuses a passive database that closed cleanly, because close does not checkpoint in MVCC and the WAL keeps frames (mod.rs:9222). Recovery spec `leadA`, and a Rust test shows it.
17. The log truncate decides, submits the truncate and resets the writer under the log lock (persistent_storage/mod.rs:230). On an async backend such as io_uring (core/io/io_uring.rs:848), a newer append can run before the truncate completes, and the truncate then erases it (recovery spec `logTruncSplit`). This is a hypothesis: the Unix truncate completes in the submit call, and no Rust test shows the order.
18. A log truncate error makes the next acknowledged commit unreadable after a crash (recovery spec `logTruncError`, section 1 row "Log truncate error").
19. The recovery spec has no readers, schema, indexes, I/O errors at open, SyncMode NORMAL or OFF, or explicit FULL and RESTART checkpoints (`DESIGN-recovery.md`).
20. The row and sequence specs store the checkpoint owner (`MvccPassiveCheckpoint.qnt:537`, `MvccPassiveSequence.qnt:434`). The schema spec now has the owner path too (`CheckpointOwnerReaders`, `FixRefuseCheckpointOwner`). An explicit checkpoint can start on an active reader's connection (`CheckpointStart`, `MvccPassiveSchema.qnt:753`). A nextval inner commit can start the auto-checkpoint there (`InnerCommitCheckpoint`, `MvccPassiveSchema.qnt:1465`, execute.rs:14384-14420, mod.rs:3698-3721). The pager commit ends the reader's WAL pin (pager.rs:3474-3475) and keeps its snapshot in `txs`. The main configuration turns the fix on, as rows and sequences do, so `main` keeps its 21,177,855 distinct states. `ownerCatalog` fails `CatalogReadsCorrect`: a scan of `sqlite_schema` returns a table created after the reader began (502,406 states). `reachAutoCheckpointOwner` reaches the inner-commit path. `ownerRows` finds no error in 2,621,152 distinct states with `MaxCheckpoints = 1`, because a schema frame is a full image and a reader at mark 0 never reads the B-tree. Open: the read mark of the owner's next statement, table reads at a mark above 0, and a Rust reproduction (the lead is the same as `rustFixOwner` of the row and sequence specs). The trace replay refuses a checkpoint on a reader's connection.
21. Modeled in part. With `GcSamplesFirst`, schema GC runs in steps: `GcSample` (mod.rs:8244-8266), `GcApply` and `GcApplyCatalog` (mod.rs:8277-8297, 8154-8173), `GcIndexPhase` (mod.rs:8348-8405) and `GcEnd` (`MvccPassiveSchema.qnt:1405-1448`; `Gc` at `MvccPassiveSchema.qnt:1315` is the one-step action). Rules 1 and 2 find nothing in a row chain of this spec, because a row is inserted once and never changed. Rule 2 applies to the sqlite_schema chain of a dropped table. The chain budget (mod.rs:8019) needs no state, because a model call can visit any subset of chains. `reachGcWithPinned` and `reachGcAfterBegin` reach the interleavings in the model. `GcApply` leaves out `rootpage_gc_protected`, so the model drops in more states than the engine, and the replay refuses `reachGcWithPinned` at `GcApply`. `gcSample`, `gcSampleNoRecheck` and `gcSampleCatalog` find no error (25,762,650, 25,782,306 and 33,540,732 distinct states with `MaxCheckpoints = 1`; with 2 passes `gcSample` and `gcSampleCatalog` ran over 40 minutes and were stopped), so `main` keeps `GcSamplesFirst` off. `gcSampleNoRecheck` passes because the row has one insert only, so it does not show that the recheck is unneeded. Open: the GC inside the checkpoint (`GcTableRows` with the lwm of `TruncateWal`, csm.rs:3493) is still part of `CheckpointFinish`. The name in the old text, `GcDrop`, was wrong: the action is `Gc`.
22. Lead, not verified, shared by table and index chains: `CommitEnd` marks a transaction committed before the chunked TxID rewrite runs, and the rewrite resets `materialized_at` (mod.rs:3645-3657, mod.rs:11009-11019, mod.rs:10988-11002). A checkpoint pass in that window can stamp a version and prune its dirty key, and the rewrite then clears the stamp. GC would then never drop that version. No spec models the rewrite. A Rust probe on turso main at ae2cb7388 did not show the leak: a COMMIT of 1100 rows stops after `CommitEnd` with the second rewrite chunk not done (`MVCC_COMMIT_BATCH_SIZE` is 1024), a passive checkpoint on another connection succeeds, the COMMIT finishes, and after three more checkpoints the store holds 0 row versions and every row reads back (3 of 3 runs). The probe does not show whether the checkpoint in the window collected the rows that were not rewritten yet.
23. Harness hole in the group commit replay. A leader drops after it issued the write of a parked waiter `a`, so `request_retry` puts the ticket of `a` on the retry list and wakes `a` (`group_commit.rs:248-260`). A third commit `b` then takes the lock, `take_work` returns `None` because a retry is pending (`group_commit.rs:165`), and `park` returns an immediate yield because the lock is free again (`group_commit.rs:109-113`). So `b` returns `Yield` until `a` runs. The spec puts `b` in `await`, and the driver steps only `b` and waits for a park, so it stopped with "COMMIT of b did not stop in 100000 steps". Fixed in the driver: 1000 `Yield` results in a row with no stop now count as a park, and `group_traces_from_folder` catches a panic per trace. With the fix, the 900 traces of the batch that found it replay with 899 done and 1 refused. Trace: `harness/mbt_tests/traces/group-retry-spin.itf.json`, 13 steps. Lead, not verified: a caller that steps `b` to completion on one thread before it steps `a` spins forever. The spec has no liveness check.
24. Lead, shown on turso main 2827d0cc1 by a Rust probe with a direct pager pin. A trigger through a public API is not shown. A B pass that fails with `Busy` at `CheckpointWal` has already published `durable_txid_max` (ck.rs:3238-3243). Rule 2 B form then drops a delete, because `e <= ckpt_max` and the rule has no stamp test (mod.rs:8657-8661). A reader that pinned its WAL read mark before, with no gate, adopts that old mark at its next begin (exec.rs:4350), finds an empty chain and reads the B-tree row that the delete removed. Variant `blockingPagerPin` fails `ReadsCorrect` (48,470 states, 40 s). The first idea for a fix (Rule 2 B needs a stamp, `FixB2NeedsStamp`) was rejected: a version has a stamp only inside a pass, so it stops all Rule 2 B drops. Variant `blockingPagerPinFixed` has `FixB2WaitsForPinned` (Rule 2 B drops nothing while a pinned read mark is below the WAL max frame) and finds no error (2,009,967 states, 100 s). GC still drops versions with it (`reachFixedGcDrops`, 400 states, 41 s). The cost: while a stale pin exists, Rule 2 drops nothing. The fix is in the model only, not in the engine and not tried in Rust. An engine form of the fix must count every pager reader, also a reader on read slot 0. `min_pinned_read_frame()` reads only slots 1 to 4 (wal.rs:916-927 on main 2827d0cc1). A reader that pins on a fully backfilled WAL takes slot 0 (wal.rs:1059-1065), and the reader of the probe is that case. So a fix that uses only that function still drops the delete. This is by code reading. The Rust probe `probe_mode_b_pager_pin_after_failed_publish` fails in 3 of 3 runs, and a control without the GC reads no row. The trace replay of the bug trace fails at step 16 with `WrongRead`. The probe pins with `pager.begin_read_tx()`, as `maybe_reparse_schema` does (core/connection.rs:1413). A real failure needs a second thread to fail the checkpoint and a third to run the GC inside the reparse window. That is not tested. Likely symptom: a stale `sqlite_schema` row (not verified). `FINDINGS.md` row 24.

## 4. Optimizations the design does not need, and the rule each one stands in for

| Optimization | Code | Simpler rule for the spec | Refinement the code must keep |
|---|---|---|---|
| Dirty-key map with stamps, prune, full-scan generation | mod.rs:2737, mod.rs:7861-7950, csm.rs:1329, csm.rs:1734-1760 | Collect every key whose chain has an event in `(old boundary, snapshot_ts]`. The full walk of the version store is the reference | At the end of collection, the dirty set contains that key set (`CollectsEveryChange`) |
| `gc_incremental` on commit, budget, cursor, `gc_last_lwm`, `gc_in_progress` | mod.rs:8203-8340 | GC can apply `gc_version_chain` to any one chain at any time, with a sampled `lwm` and floor (row spec `Gc`, `GcSample`, `GcApply`) | Each call applies the same rules. Scheduling is free |
| GC inside `GcTableRows`, `GcIndexRows` | csm.rs:2295-2301, csm.rs:2387-2393 | Same rule as above. Only the stamp is part of the design | The stamp happens before the GC of the same chain |
| `Finalize` full sweep and empty slot unlink | mod.rs:8188, mod.rs:8195, mod.rs:8296 | An empty chain is the same as no chain | If GC unlinks the chain of a writer, the writer tries again (mod.rs:8727-8752) |
| Chain shrink | mod.rs:8691 | None (memory only) | None |
| B-tree fall-through read (B only) | mod.rs:6070-6087 | If the chain has a visible or ended version, a read uses the chain. Otherwise it reads the B-tree (DESIGN.md "How a reader reads a row") | The chain value must equal the B-tree value at the read mark |
| Index lockstep merge | mod.rs:6099, cursor.rs:524 | `query_btree_version_is_valid` per key (mod.rs:6126) | Same answer. The debug compare at cursor.rs:667-672 checks this |
| Row map epochs | cursor.rs:907-948 | Seek the skip list again on every step | After an insert, do not reuse a cached position |
| `compute_min_reader_mark` in the floor | mod.rs:10718 | Floor = the lowest pinned read mark (`floorPinned`). A floor of `backfill_floor` alone (`floorBackfill`) passes this spec, but a Rust run refuted it: a checkpoint on the connection of an open reader moves `backfill_floor` above that reader's mark (PR #11794) | A smaller floor is always safe. It keeps more versions |
| `rootpage_gc_protected` | mod.rs:10736 | Nothing, as far as the model shows. Per-version `materialized_at` covers it (schema S14, `StampsAtOrAfterBinding`). PR #11794 deletes it and adds a reachability check (`reachRootGuardFires`) and a Rust assertion. It did not run larger bounds | None |
| CYCLE skip in compaction | csm.rs:817 | Compact every sequence (sequence S4) | The skip only saves the scan |
| TxID to timestamp rewrite | mod.rs:7383 | A version's begin is the commit ts of its writer | Resolution through `txs`, then `finalized_tx_states`, gives the same ts |
| `finalized_tx_states` | mod.rs:6871, mod.rs:8542 | A finished tx keeps its state forever | Prune every TxID that is not in `txs`. This is safe when the rewrite comes before `remove_tx`. The referenced filter (`collect_referenced_txids` mod.rs:8530) is redundant for safety (gap 6, `finalizedNoReferenced`) |
| Group commit | mod.rs:3448-3586 | Each commit appends and fsyncs its own record before `CommitEnd` | A commit returns only after a fsync covers its record |
| All-or-nothing log truncate | logical_log.rs:1083-1095 | Drop the records at or below the boundary | Keeping more records is always safe for recovery |
| Sequence registry | mod.rs:6881-6960 | A scan reads the backing table at its snapshot | Same rows for forward-only scans |
| Dirty marks, stamps and floors in mode B | section 2 | B rule: after a B checkpoint the version store is empty | At the drop of the store, `txs` and the log are empty |

Suggested spec work that follows from this:

1. Done. Mode B is in the row spec (`Mode = "blocking"`, `blockingMain`). The B checkpoint is
   two actions, a pass that succeeds (one atomic step under "no tx open", ending with "store
   empty") and a pass that stops after its publish. The second action is needed to model the
   pager pin of gap 24. `ReadsCorrect` and `RecoveryCorrect` hold with Rule 2 B form, Rule 3
   with `b <= ckpt_max`, and the B-tree fall-through read, when no pager pin without a gate
   exists.
2. Reproduce the mode T sequence trace in Rust. The model allows an open
   reader at `CheckpointStart` (`MvccPassiveSequence.qnt:434`) and purges inline
   at `CheckpointCompact` (`MvccPassiveSequence.qnt:500`). A Rust failure is
   not verified. Section 5 gives the model result.

## 5. Checkpoint stops, owners, and mode T

The added model paths use Rust source at base `3a95ac963`.
The supplied probe report is a local file, `probes/RESULTS.md`. It is not in
this repo.
Probe 4 reports stranded versions at line 87 of that file.
Probe 5 reports leaked root pages at line 126 of that file.
No Rust probe was repeated for these model changes.
The recollect and resume repairs below are model proposals.
Their Rust implementations are not verified.

### Failure points and repairs

A pass can fail before commit, between commit and publish, or after publish.
Each model keeps durable writes and completed publications when it fails.
The schema failure drops staged root operations.
The cleanup in Rust starts at
`core/mvcc/database/checkpoint_state_machine.rs:1079`.
It clears staged roots at
`core/mvcc/database/checkpoint_state_machine.rs:1087`.
The pager commit completes at
`core/mvcc/database/checkpoint_state_machine.rs:3333`.
The next failure point is the publish yield at
`core/mvcc/database/checkpoint_state_machine.rs:3341`.
The boundary store is at
`core/mvcc/database/checkpoint_state_machine.rs:2232`.
These are separate model steps.

| Model action | Source step or proposed behavior |
|---|---|
| `MvccPassiveCheckpoint.qnt:788` | Cleanup releases an owner pin only for a pager transaction it owns, `core/mvcc/database/checkpoint_state_machine.rs:1079` |
| `MvccPassiveSchema.qnt:1283` | Cleanup drops staged roots, `core/mvcc/database/checkpoint_state_machine.rs:1087` |
| `MvccPassiveSequence.qnt:642` | Cleanup and TRUNCATE Busy, `core/mvcc/database/checkpoint_state_machine.rs:1079`, `core/mvcc/database/checkpoint_state_machine.rs:3421` |
| `MvccPassiveSchema.qnt:1210` | Failure phase before the stamp, `core/mvcc/database/checkpoint_state_machine.rs:3377`. Logical log contents are not modeled here |
| `MvccPassiveSchema.qnt:1300` | Proposed repair. Restore the committed root operations and publish before starting another pass. Rust fix not verified |
| `MvccPassiveCheckpoint.qnt:697` | Test the boundary before truncate, `core/mvcc/persistent_storage/logical_log.rs:1088` |
| `MvccPassiveCheckpoint.qnt:708` | Complete the submitted file truncate, `core/mvcc/persistent_storage/logical_log.rs:1074`. The destructive I/O ordering is not verified |
| `MvccPassiveCheckpoint.qnt:649` | Mode T boundary store, `core/mvcc/database/checkpoint_state_machine.rs:2232`, without the passive clock wrapper at `core/mvcc/database/checkpoint_state_machine.rs:2250` |
| `MvccPassiveSequence.qnt:260` | Keep the saved outer transaction while the inner transaction begins, `core/vdbe/execute.rs:14386`, `core/vdbe/execute.rs:14394` |
| `MvccPassiveSequence.qnt:275` | Remove the outer MVCC transaction, `core/mvcc/database/mod.rs:6817` |
| `MvccPassiveSequence.qnt:374` | The inner commit can start an auto-checkpoint, `core/vdbe/execute.rs:14502`, `core/mvcc/database/mod.rs:3700` |

`NoStrandedVersions` checks the row store after a successful completed pass
(`MvccPassiveCheckpoint.qnt:1011`). A failed pass can leave pending stamp work.
The fixed configuration must complete a later pass without leaving that work.
This is a safety check after completion. Eventual completion is not verified.
`NoLeakedPages` checks every committed schema image without a pending-publish
exception (`MvccPassiveSchema.qnt:1722`).

The failure witnesses require a nonempty pager commit and the named failure.
The row witness also requires an unstamped version below the published boundary
(`MvccPassiveCheckpoint.qnt:1061`). The schema witness requires an allocation in that frame
(`MvccPassiveSchema.qnt:1751`).
The repair witnesses require the failure first, then an actual stamp or publish
(`MvccPassiveCheckpoint.qnt:1062` and `MvccPassiveSchema.qnt:1752`).
They do not count a no-op checkpoint as repair.

### Sequence mode T and checkpoint owners

Mode T has no `Registered == Set()` gate at checkpoint start and no checkpoint
gate at transaction begin (`MvccPassiveSequence.qnt:434` and `MvccPassiveSequence.qnt:246`).
The compactor deletes B-tree rows and purges their chains inline
(`MvccPassiveSequence.qnt:500`). The Rust driver pairs delete and purge at
`core/mvcc/database/checkpoint_state_machine.rs:736`.
A pinned reader makes the WAL checkpoint fail with Busy
(`MvccPassiveSequence.qnt:592` and `MvccPassiveSequence.qnt:642`).
The model stops before the final stamp and sweep.
The code's Busy error path is at
`core/mvcc/database/checkpoint_state_machine.rs:3449`.
Its final blocking sweep is at
`core/mvcc/database/checkpoint_state_machine.rs:3576`.

`reachTruncateBusy` requires a nonempty pager commit, a pinned reader, and
failure at `published` (`MvccPassiveSequence.qnt:814`).
`reachPurgeBeforeBusy` also requires that the same pass purged a chain
(`MvccPassiveSequence.qnt:815`).
A model read failure in mode T is a lead. A Rust reproduction is not verified.
The supplied sequence probe did not reproduce a wrong read
(`probes/RESULTS.md:55`).

`CheckpointOwnerReaders` enables outer snapshots in the sequence spec.
`TxCommit` picks `ckNow`. A successful inner commit can then start a checkpoint
on that connection while the outer snapshot stays registered (`MvccPassiveSequence.qnt:374`).
The pager commit releases the owner's pager pin (`MvccPassiveSequence.qnt:527`).
`FixRefuseCheckpointOwner` refuses this checkpoint and keeps the outer pin.
Both the row and sequence main configurations enable this proposed fix
(`MvccPassiveCheckpoint.qnt:537` and `MvccPassiveSequence.qnt:434`).
`reachAutoCheckpointOwner` requires a nonempty pager commit from the auto path
while the outer reader remains registered (`MvccPassiveSequence.qnt:812`).

The sequence main bounds use two values, two connections, `MaxTs = 6`,
and two passes. The owner-off variants keep their earlier bounds.
The mode T variants use two values, two connections, `MaxTs = 6`, and two passes.
The owner variants use two values, one connection, `MaxTs = 5`, and two passes.
`MaxTs` bounds transaction begins and commits (`MvccPassiveSequence.qnt:69`).
Each passive publish advances the clock (`MvccPassiveSequence.qnt:578`).
`TypeOK` permits the extra publish ticks (`MvccPassiveSequence.qnt:789`).
The new leak bounds appear in `DESIGN-rows.md` and `DESIGN-schema.md`.
The sequence model still reads each chain once and omits WAL restart.
It does not verify the unlocked schema publish race.

### The Rust fix uses early stamps and cleanup publication

The Rust fix is in a local worktree that is not published.
Its checked head is `633aeb51a`. The following source references use that head.
The diff against `origin/main` adds two rules.
The pager commit calls `stamp_committed_versions` before the publish yield
(`core/mvcc/database/checkpoint_state_machine.rs:3301`).
Cleanup publishes a committed pass with a pending header
(`core/mvcc/database/checkpoint_state_machine.rs:1040`).
Passive cleanup uses `apply_passive_publish_window_ordered` at
`core/mvcc/database/checkpoint_state_machine.rs:1045`.
Blocking cleanup uses `apply_checkpoint_publish_window` at
`core/mvcc/database/checkpoint_state_machine.rs:1048`.

Each model has `FixStampAtPagerCommit` and `FixCleanupPublishes` constants.
They stay off in the earlier controls. The `rustFix*` variants turn both on.
They do not enable the earlier recollect-or-resume repairs.

| Model step | Model action | Rust source |
|---|---|---|
| Stamp after pager commit | `MvccPassiveCheckpoint.qnt:619`, `MvccPassiveSchema.qnt:956`, `MvccPassiveSequence.qnt:527` | `core/mvcc/database/checkpoint_state_machine.rs:3301`, `core/mvcc/database/checkpoint_state_machine.rs:3568` |
| Publish in normal or failure path | `MvccPassiveCheckpoint.qnt:654`, `MvccPassiveSchema.qnt:1147`, `MvccPassiveSequence.qnt:571` | `core/mvcc/database/checkpoint_state_machine.rs:1040`, `core/mvcc/database/checkpoint_state_machine.rs:2162` |
| Failure calls cleanup publish | `MvccPassiveCheckpoint.qnt:788`, `MvccPassiveSchema.qnt:1283`, `MvccPassiveSequence.qnt:642` | `core/mvcc/database/checkpoint_state_machine.rs:1043` |
| Record GC of an early stamp with an open reader | `MvccPassiveCheckpoint.qnt:908`, `MvccPassiveCheckpoint.qnt:914` | `core/mvcc/database/mod.rs:8651` stamps the terminal event. The model then applies its existing GC rules |

The row and sequence `rustFixOwner` configurations allow a checkpoint on the
connection of an open outer snapshot. Their `Safety` values include all main
invariants (`MvccPassiveCheckpoint.qnt:1052`, `MvccPassiveSequence.qnt:806`).
Both saved owner traces contain a wrong snapshot read.
Both regenerated traces include the new pager phase and a real frame commit.
The row trace expects 0 and returns 2. The sequence trace expects 0 and returns 1.
The reader's MVCC snapshot remains registered after its pager pin disappears.
The fix does not address that path in these models.
Rust reproductions of these saved traces are not verified.

The sequence `rustFixTruncate` configuration also checks `Safety`.
Its saved trace reads 0 where the snapshot expects 1 after inline compaction
purges the older chain (`MvccPassiveSequence.qnt:500`).
This trace fails before the second pass commits its pager transaction.
Early stamping and cleanup publication cannot repair that earlier purge.
The sequence model still omits the final blocking GC sweep.
A Rust reproduction is not verified.

The sequence model does not represent the backing table root or its initial row
(`MvccPassiveSequence.qnt:48`). Its compaction treats that table as available.
Rust resolves an unpublished negative root through `current_root_page`
(`core/mvcc/database/checkpoint_state_machine.rs:805` at base `3a95ac963`).
It skips a sequence if that root cannot resolve
(`core/mvcc/database/checkpoint_state_machine.rs:827` at that base).
A Rust replay must satisfy this root requirement before it creates the modeled values.
Whether the saved trace meets all Rust root and initial-row conditions is not verified.

`reachCleanupPublish` in each model requires a nonempty committed frame and
an actual publish from failure cleanup (`MvccPassiveCheckpoint.qnt:1057`,
`MvccPassiveSchema.qnt:1749`, `MvccPassiveSequence.qnt:810`).
The schema witness also requires an allocated root in that frame.
`reachEarlyStampGc` uses the lowest pinned mark as a control.
It records an actual GC removal with a registered reader open
(`MvccPassiveCheckpoint.qnt:914`).
`reachEarlyStampGcAfterFailure` uses the code GC floor.
It adds a failed published pass and completion
of a later empty pass (`MvccPassiveCheckpoint.qnt:920`).
Each passive publish and each cleanup publish is one model step.
Errors inside that step and contention on the cleanup window are not verified.

The simulator did not capture `reachEarlyStampGcAfterFailure` in 200,000
walks of 40 steps. TLC reached it after 144,369 states.
An ITF trace for that witness is not verified.

The saved ITF traces were in `traces/bugs/` of the author's worktree. They
are not in this repo. `make bug-traces` writes them again.
`MvccPassiveCheckpoint-rustFixOwner.itf.json`,
`MvccPassiveSequence-rustFixOwner.itf.json`, and
`MvccPassiveSequence-rustFixTruncate.itf.json` contain the wrong reads.
`MvccPassiveCheckpoint-reachEarlyStampGc.itf.json` contains the GC witness.

The pager commit changes the connection transaction state at
`core/storage/pager.rs:3429` at base `3a95ac963`.
`set_tx_state` only writes that field (`core/connection.rs:4845` at that base).
The MVCC transaction id has a separate setter (`core/connection.rs:4886`).
The model therefore keeps the registered snapshot when it releases the pager pin.

The owner model keeps the MVCC snapshot after it releases the pager pin
(`MvccPassiveCheckpoint.qnt:238`, `MvccPassiveCheckpoint.qnt:239`).
`GcKeepsVersionsAboveReaders` checks both sets (`MvccPassiveCheckpoint.qnt:1030`).
The code floor still counts the retained registered mark (`MvccPassiveCheckpoint.qnt:824`).
`ownCheckpointGc` therefore expects no GC violation.
Its earlier expected failure assumed a different relation between those sets.
The pinned-only control, `ownCheckpointGcPinnedFloor`, now expects the GC check to fail.
It ignores that registered mark after the pin disappears.
The new simulator trace uses a registered owner and a nonempty pager commit.
At step 25, owner `r1` has begin timestamp 5 and mark 0, then commits frame 1.
The first empty pass keeps every reader pin. No `committed` state has frame 0.
The GC check sees an ended version stamped at frame 1 above the retained mark 0.
A wrong read from this GC step is not verified.
`reachReaderMarkBelowFloor` checks both sets too (`MvccPassiveCheckpoint.qnt:1078`).
TLC reaches that retained-mark state after 38,049 states.

| Owner control | Result | Distinct states |
|---|---|---:|
| `ownCheckpoint` | `ReadsCorrect` fails as expected | 148,132 |
| `ownCheckpointBackfillFloor` | `ReadsCorrect` fails as expected | 146,017 |
| `ownCheckpointKeepsMark` | `ReadsCorrect` fails as expected | 149,126 |
| `ownCheckpointKeepsMarkBackfillFloor` | `ReadsCorrect` fails as expected | 150,509 |
| `ownCheckpointGc` | No GC-floor violation | 32,893,504 |
| `ownCheckpointGcBackfillFloor` | `GcKeepsVersionsAboveReaders` fails as expected | 128,575 |
| `ownCheckpointGcPinnedFloor` | `GcKeepsVersionsAboveReaders` fails as expected | 135,575 |
| `reachStampedAboveReader` | `NeverStampedAboveReader` fails as expected | 17,532 |
| `reachReaderMarkBelowFloor` | `NeverReaderMarkBelowBackfillFloor` fails as expected | 38,049 |

### Review corrections: empty passes, owners, and purge witnesses

The empty-pass rule uses `5dd5ae137:core/mvcc/database/checkpoint_state_machine.rs:2650`.
A pass with neither data work nor a new metadata boundary skips the pager transaction.
The models enter `published` directly as the entry phase of the WAL checkpoint.
They do not call `CheckpointCommit` or `CheckpointPublish` on that path.
A higher boundary counts as metadata work, as the base metadata helper does
(`3a95ac963:core/mvcc/database/checkpoint_state_machine.rs:2467`).

`CheckpointBeginPager` chooses this path in the row model
(`MvccPassiveCheckpoint.qnt:602`). The sequence collection does the same before
compaction (`MvccPassiveSequence.qnt:465`). A nonempty pass acquires its pager
transaction in `MvccPassiveSequence.qnt:478`.
`pagerOwned` is true only during that transaction.
Pager commit clears it. Failure cleanup clears an owner pin only while it is true
(`MvccPassiveCheckpoint.qnt:788`, `MvccPassiveSequence.qnt:642`).
This matches the cleanup lock-state checks
(`5dd5ae137:core/mvcc/database/checkpoint_state_machine.rs:1058`).
Both `TypeOK` checks reject a `committed` state with frame 0
(`MvccPassiveCheckpoint.qnt:1034`, `MvccPassiveSequence.qnt:789`).

Explicit owners must be between statements. Rows select only `active` readers
(`MvccPassiveCheckpoint.qnt:537`). Sequences select only saved outer transactions with no inner statement
(`MvccPassiveSequence.qnt:434`). The explicit checkpoint also blocks
new operations on its owner until it stops.
These gates represent the active-statement refusal at
`3a95ac963:core/connection.rs:2590` and `3a95ac963:core/connection.rs:4833`.
The nextval auto-checkpoint starts separately in `TxCommit`
(`MvccPassiveSequence.qnt:374`). It can retain an outer transaction.

Before a pager write, a pinned owner's mark must equal the current WAL length
(`MvccPassiveCheckpoint.qnt:602`, `MvccPassiveSequence.qnt:478`).
A stale snapshot stops the pass before it owns a pager transaction.
It keeps the owner's pin. This represents `BusySnapshot`
(`3a95ac963:core/storage/wal.rs:3598`).

`purged` records each version that inline compaction actually removes
(`MvccPassiveSequence.qnt:514`). Empty chains contribute no record.
`RemovedRowNeeded` requires an open snapshot that needs that version's row as
its current sequence value (`MvccPassiveSequence.qnt:663`).
The reader must have an active read or a saved outer snapshot.
The reader's saved B-tree image must lack that row.
Its current read path must also lack that row.
`NeverPurgesBeforeBusy` requires that state, a nonempty pager commit, and Busy
at `published`. The weaker `NeverTruncateBusy` records compaction reaching Busy.

The regenerated `rustFixTruncate` trace skips its first empty pager transaction.
Its second pass removes row 1 before pager commit, then fails at `compacted`.
The outer reader at timestamp 4 and mark 0 expects 1 and receives 0.
The trace has no `committed` state with frame 0.
The sequence purge failure remains in the model after the empty-pass correction.
The backing-root and initial-row requirements above remain not verified in Rust.

### Verification results

Every command uses `WORKERS=8`. Shards execute one after another in `specs/`.
The commands set the following values on the make command line:

```sh
QUINT=<path to quint 0.33.1>
JAVA_HOME=<path to Temurin 21>
JAVA_TOOL_OPTIONS=-Djava.io.tmpdir=<a scratch directory>
```

The command-line value for `JAVA_TOOL_OPTIONS` overrides the Makefile default.
No command uses `/tmp` or the TLC `-cleanup` flag.
Counterexample counts depend on the order of the eight workers.
They count the states found before the first error. Passing counts cover all
reachable states within the stated bounds.

| Spec | Configuration | Result | Invariant | Distinct states |
|---|---|---|---|---:|
| Rows | `main` | Pass | All listed invariants | 17,344,980 |
| Schema | `main` | Pass | All listed invariants | 21,177,855 |
| Sequence | `main` | Pass | All listed invariants | 1,407,267 |

| Spec | Configuration | Result | Invariant | Distinct states |
|---|---|---|---|---:|
| Rows | `failedPublish` | Fail (expected) | `NoStrandedVersions` | 2,790 |
| Rows | `failedPublishFixed` | Pass | All listed invariants | 10,167 |
| Rows | `reachFailedPublish` | Fail (expected) | `NeverFailsAfterPublish` | 731 |
| Rows | `reachRepairedVersions` | Fail (expected) | `NeverRepairsVersions` | 4,685 |
| Rows | `logTruncateRace` | Fail (expected) | `RecoveryCorrect` | 205 |
| Rows | `reachTruncateAppend` | Fail (expected) | `NeverLosesAppendAtTruncate` | 503 |
| Rows | `logTruncateAtomic` | Pass | All listed invariants | 615 |
| Rows | `truncateFlagOn` | Fail (expected) | `NoStrandedVersions` | 34,195 |
| Rows | `truncateFlagOnFixed` | Pass | All listed invariants | 300,115 |
| Rows | `reachTruncateRepair` | Fail (expected) | `NeverRepairsVersions` | 73,059 |
| Rows | `refuseCheckpointOwner` | Pass | All listed invariants | 210,694 |
| Rows | `rustFix` | Pass | All listed invariants | 502,396 |
| Rows | `rustFixOwner` | Fail (expected) | `Safety` | 23,598 |
| Rows | `rustFixTruncate` | Pass | All listed invariants | 457,428 |
| Rows | `reachCleanupPublish` | Fail (expected) | `NeverCleanupPublishes` | 1,086 |
| Rows | `rustFixPinnedFloor` | Pass | All listed invariants | 1,037,362 |
| Rows | `reachEarlyStampGc` | Fail (expected) | `NeverGcEarlyStampWithReader` | 7,970 |
| Rows | `reachEarlyStampGcAfterFailure` | Fail (expected) | `NeverGcEarlyStampAfterFailure` | 144,369 |
| Schema | `failedCommit` | Fail (expected) | `NoLeakedPages` | 772 |
| Schema | `failedCommitFixed` | Pass | All listed invariants | 4,206 |
| Schema | `reachFailedCommit` | Fail (expected) | `NeverFailsBeforePublish` | 230 |
| Schema | `reachRepairedRoots` | Fail (expected) | `NeverRepairsRoots` | 552 |
| Schema | `rustFix` | Pass | All listed invariants | 125,104 |
| Schema | `reachCleanupPublish` | Fail (expected) | `NeverCleanupPublishes` | 454 |
| Schema | `truncateFlagOn` | Pass | All listed invariants | 28,866,833 |
| Schema | `reachBeginMidPublish` | Fail (expected) | `NeverBeginsMidPublish` | 9,569 |
| Schema | `truncateNoRefreshRoot` | Fail (expected) | `OpenCorrect` | 31,630 |
| Schema | `ownerCatalog` | Fail (expected) | `CatalogReadsCorrect` | 502,406 |
| Schema | `ownerRows` (`MaxCheckpoints = 1`) | Pass | All listed invariants | 2,621,152 |
| Schema | `reachAutoCheckpointOwner` | Fail (expected) | `NeverAutoCheckpointOnReader` | 4,463 |
| Schema | `gcSample` (`MaxCheckpoints = 1`) | Pass | All listed invariants | 25,762,650 |
| Schema | `gcSampleNoRecheck` (`MaxCheckpoints = 1`) | Pass | All listed invariants | 25,782,306 |
| Schema | `gcSampleCatalog` (`MaxCheckpoints = 1`) | Pass | All listed invariants | 33,540,732 |
| Schema | `gcSampleNoCatalogFloor` | Fail (expected) | `CatalogReadsCorrect` | 234,424 |
| Schema | `reachGcWithPinned` | Fail (expected) | `NeverGcWithPinned` | 757,073 |
| Schema | `reachGcAfterBegin` | Fail (expected) | `NeverGcAfterBegin` | 1,303,879 |
| Sequence | `truncateFlagOn` | Fail (expected) | `ReadsCorrect` | 18,618 |
| Sequence | `truncateFlagOnStranded` | Fail (expected) | `NoStrandedVersions` | 7,587 |
| Sequence | `reachTruncateBusy` | Fail (expected) | `NeverTruncateBusy` | 8,122 |
| Sequence | `reachPurgeBeforeBusy` | Fail (expected) | `NeverPurgesBeforeBusy` | 32,112 |
| Sequence | `ownCheckpoint` | Fail (expected) | `ReadsCorrect` | 2,874 |
| Sequence | `refuseCheckpointOwner` | Pass | All listed invariants | 9,184 |
| Sequence | `reachAutoCheckpointOwner` | Fail (expected) | `NeverAutoCheckpointOnReader` | 855 |
| Sequence | `rustFix` | Pass | All listed invariants | 15,971 |
| Sequence | `rustFixOwner` | Fail (expected) | `Safety` | 4,544 |
| Sequence | `rustFixTruncate` | Fail (expected) | `Safety` | 261,184 |
| Sequence | `reachCleanupPublish` | Fail (expected) | `NeverCleanupPublishes` | 1,350 |

Schema checks after the mode T, owner and GC steps patch: `main` gives 21,177,855 distinct states as before. `catalog` (35,436,959), `rustFix` (125,104) and `failedCommitFixed` (4,206) give the same counts as before. `indexes` (10,375,595), `issue8537` and `noCatalogGcFloor` finished as their comments say. `alter` was not run after the patch.

`make typecheck` passes for all three specs.
`make check` passes for all three main configurations after the review fixes.
The sequential variant shards check every row and sequence configuration.
They also rerun schema `rustFix`. The schema source did not change in this review.
Its other table entries retain the earlier results.

68 of 69 scheduled configurations finished and matched their comments.
The `MvccPassiveCheckpoint-gcSample` search did not finish within the review time box.
Its result is not verified.

The unchanged schema `alter` and `indexes` variants remain not verified from round 1.
The full set of 109 configurations is therefore not verified.

The review log, the full result table and the type-check log are local files
of the author. They are not in this repo.
The sequence mode-T checks repeat after the final purge-predicate restriction.
Both `truncateFlagOn` and `rustFixTruncate` still fail as their comments require.
The purge bug therefore remains reachable in the corrected model.
A Rust reproduction remains not verified.

The trace guide is a local file of the author. It is not in this repo.
It records the new nonempty owner commit and the corrected sequence purge trace.
The archived guide and traces retain the round 1 evidence.
The simulator found traces for both leak failures and their repair witnesses in round 1.
The after-failure GC witness has a TLC result but no ITF trace.
All completed TLC checks match their current comments.
