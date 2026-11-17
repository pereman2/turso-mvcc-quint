# Index rows in the passive checkpoint

This file describes `specs/MvccPassiveIndex.qnt`. The spec models the index
rows of the MVCC version store and how the passive checkpoint moves them into
the index B-tree. It closes item 5 of `MODEL-GAPS.md` section 3 within the
bounds below. Every code reference is a line at the pinned rev `0c9fe0dd9` of
the trace replay test, without `harness/turso-hooks.patch`. Short names:
`mod.rs` is `core/mvcc/database/mod.rs`, `csm.rs` is
`core/mvcc/database/checkpoint_state_machine.rs`, `cursor.rs` is
`core/mvcc/cursor.rs`, `execute.rs` is `core/vdbe/execute.rs`.

## What the spec models and why

A table with an index has two kinds of version chains. The table chain of a
row holds the row values. Each index key has its own chain in
`MvStore::index_rows` (mod.rs:4389). An index key is the record of the
indexed columns plus the rowid. An UPDATE that sets an indexed column ends a
version on the chain of the old index key. The same transaction adds a version
to the chain of the new index key.

The code keeps the index chains apart from the table chains in four places:

- A separate dirty map, `checkpoint_dirty_index_keys` (mod.rs:4452). One
  `MarkDirtyKeys` loop marks the table keys and the index keys of the write
  set with the same stamp.
- A separate collection phase, `CollectIndexRows`, after `CollectTableRows`,
  with the same snapshot and the same old boundary.
- A separate stamp and GC phase, `GcIndexRows`, after `GcTableRows`. It stamps
  each written index slot and each key in `unwritten_index_rows`.
- A separate incremental GC loop, `gc_index_incremental` (mod.rs:8348), with
  its own cursor. It calls the same `gc_chain_now` as the table loop.

A reader reads an index through the dual cursor. The MVCC side finds the
visible version of a chain. The B-tree side asks whether a chain hides the
B-tree entry. The two sides look at the chain at different moments.

The index matters for correctness in three ways. First, a covering index read
returns rows from the index alone. A lost or extra index entry then gives a
wrong query result, even with a correct table. Second, an UPDATE or DELETE
seeks the old index entry. A writer that does not find it fails with
`IdxDelete: no matching index entry` (execute.rs:12357, execute.rs:12378).
Third, recovery replays index rows from the logical log on top of the index
B-tree. Assume that a checkpoint writes the table row but not its index entry
and then cuts the log. After a crash, the index entry is lost.

## Facts from the code

This section answers the questions that the draft left open. Each answer
decides a part of the state or an action of the spec.

### Writes

An UPDATE that sets an indexed column first runs `IdxDelete` on the old key of
each index. Then it runs `IdxInsert` on the new key, then the table write
(`core/translate/emitter/update.rs:2301-2371`). The planner picks the indexes
by the columns that the SET clause names, not by a change of value
(`collect_indexes_to_update`, `core/translate/update.rs:581-672`). Take
`UPDATE t SET v = 5` on a row that already has `v = 5`. It ends the version of
key `(5, 1)`. In the same transaction, it adds a new version to that chain. A DELETE
runs `IdxDelete` for each index (`core/translate/emitter/delete.rs:800-805`).
An INSERT runs `IdxInsert` (`core/translate/insert.rs:1501-1507`).

`IdxDelete` reaches `MvccLazyCursor::delete` (cursor.rs:2018-2058) and then
`delete_from_table_or_index` with an index id (mod.rs:5661-5722). If the chain
has a version that the writer can see, the writer sets its end to its TxID
(mod.rs:5700). Assume that no version is visible and that the cursor
stands on a B-tree entry. Then the writer adds a version with begin `None`,
end TxID and `btree_resident = true` (mod.rs:5714, `insert_tombstone`
mod.rs:5794). The spec calls this version a marker. `IdxInsert` reaches `insert_to_table_or_index`
and adds a version with begin TxID (mod.rs:5443-5470). Each change adds the
chain to the write set once, in the order of the first write (mod.rs:930-937).
`set_end` and `set_begin` reset `materialized_at` to `ORIGIN`
(mod.rs:10988-11002).

### Commit marks and prune

`MarkDirtyKeys` walks the write set in steps of `MVCC_COMMIT_BATCH_SIZE = 1024`
keys (mod.rs:1541, mod.rs:2737-2779). `mark_tx_write_set_dirty` marks each key
in the map for its kind, table or index, with the commit timestamp
(mod.rs:7895-7918). So a transaction with at most 1024 changed chains marks
its table key and its index keys in one step. A larger transaction marks them
over several steps, all while it is `Preparing`.

The prune is the same code for both maps. Collection records a prune candidate
for each dirty key with a stamp at or below the snapshot (csm.rs:1734-1739,
index walk csm.rs:1668). `prune_dirty_keys` removes the key. When the stamp
of the key rose after collection, it puts the key back (csm.rs:1741-1758). `unmark_checkpoint_dirty_key` picks the
map by the key kind (mod.rs:7877-7881). The full walk records index candidates
in its `DirtyStamps` phase (csm.rs:1530-1566, csm.rs:1574-1586).

`MvStore::new` sets the full-scan generation to 1 (mod.rs:4658). So the first
pass after open walks the whole store (`collect_index_rows_from_store`
csm.rs:1595), not the dirty map. That pass clears the generation at its end
(csm.rs:3523-3526).

### Collection

`CollectIndexRows` runs after `CollectTableRows` with the same `snapshot_ts`
and the same `durable_txid_max_old` (csm.rs:2603-2648). Both phases select
versions with `maybe_get_checkpointable_versions` (csm.rs:1078-1210).
`collect_index_row_versions` adds at most one version per key to
`index_write_set` (csm.rs:1695-1732). If the key changed in (old, snap] but
needs no write, the key goes to `unwritten_index_rows` (csm.rs:1722-1730,
`deleted_since_last_checkpoint` csm.rs:1815-1824). An entry that was inserted
and deleted after the old boundary is such a key. Two rules are only for
indexes. Collection drops a delete in an index with no root binding at the
snapshot (`table_exists_for_snapshot`, csm.rs:1707). The keys of a destroyed
index go to `unwritten_index_rows` (csm.rs:1702, csm.rs:1722-1730). The draft said that the frame
writes every changed key. The code writes no delete for an entry that was
never in the B-tree.

The draft claimed that a split of index collection over several steps gives
the same collected set. The claim holds, for two reasons:

- A commit at or below the snapshot finished `MarkDirtyKeys` and all its chain
  writes before the snapshot. The snapshot is below every `Preparing`
  timestamp (mod.rs:7843-7859), and a commit leaves `Preparing` only at
  `CommitEnd` (mod.rs:3629-3657). A commit above the snapshot changes nothing:
  collection skips its begin (csm.rs:1098-1100) and treats its end as "live"
  (csm.rs:1104-1107).
- GC drops only stamped versions. Rule 2 and Rule 3 need
  `materialized_at != ORIGIN` (mod.rs:8600-8602). A pass stamps only versions
  whose last event is at or below its snapshot (mod.rs:8669-8677), after it
  publishes that boundary. So a version that GC can drop has its last event at
  or below the old boundary. An ended version of that kind leaves
  `exists_in_db_file` false (csm.rs:1124-1129) whether GC drops it or not.
  Rule 3 needs a chain with one version (mod.rs:8629-8638). So no later
  version depends on a current version that Rule 3 drops.

Two candidate counterexamples fail. Rule 3 cannot drop a current version that
no pass stamped, because it needs the same stamp test. `unwritten_index_rows`
depends only on the chain of one key, so a split cannot change it. The engine
also checks the dirty walk in debug builds: after collection, every index key
with a checkpointable version must be in the dirty map (csm.rs:1787-1812).

### Stamp and GC

`gc_checkpointed_index_versions` stamps only the slots of `index_write_set`
with a finished pager write (`written_index_slots`, csm.rs:2343-2357, set at
csm.rs:3174 and csm.rs:3198). It always stamps the keys of
`unwritten_index_rows` (csm.rs:2358-2361). So "every collected chain" is
wrong. `WriteIndexRow` skips three writes, and GC does not stamp them:

- a write to an index that is not in the snapshot schema (csm.rs:3087-3093)
- a delete in an index with no binding at the snapshot (csm.rs:3095-3101)
- a delete in a B-tree that this pass created (csm.rs:3125-3138)

All three need index DDL. The table side
gives the reason for this rule: a stamp on a skipped write lets GC drop a
version that the B-tree does not have (csm.rs:389-391).

Both checkpoint GC phases use the same floor, `gc_floor_reader_mark`
(csm.rs:2237-2250, csm.rs:2256, csm.rs:2334), and the same `lwm` from the
state (csm.rs:3500-3517). The floor includes pager-pinned read marks. The
incremental loop uses `compute_min_reader_mark` and `backfill_floor` only
(mod.rs:8356-8358), as the table loop does (mod.rs:8264-8266).
`gc_chain_now` has nothing index-specific (mod.rs:8154-8174). The incremental
loop and the `Finalize` sweep skip an index id that `rootpage_gc_protected`
protects (mod.rs:8371-8373, mod.rs:8506-8508, mod.rs:10736-10740). The table
loops have the same skip (mod.rs:8282, mod.rs:8466). In passive mode the incremental loop
keeps empty index slots (mod.rs:8393). Only `Finalize` unlinks an empty index
slot, and it bumps `index_rows_epoch` first (mod.rs:8521-8525).

### Reads

`btree_covers_chain_for_snapshot` returns false in passive mode
(mod.rs:6076-6078). So for a chain with a version, an index read always uses
the chain. An index seek looks at the chain three times:

1. The MVCC side: `seek_index` (cursor.rs:1811-1819) finds the first key with
   a visible version (`find_last_visible_index_version`, mod.rs:6228-6240).
2. The B-tree side: the seek checks the B-tree entry with
   `query_btree_version_is_valid` (cursor.rs:1301, mod.rs:6126-6156,
   `chain_leaves_btree_row_valid` mod.rs:6161-6178).
3. The record: `Column` reads the visible version again from the chain that
   step 1 found (cursor.rs:698-703, `read_visible_into_record`
   mod.rs:5921-5935). A table seek copies the payload under the chain lock in
   step 1 (`eq_seek_row`, cursor.rs:1781-1782). An index seek does not.

A forward scan from `Rewind` or `Next` uses the lockstep `IndexShadowScan` on
the B-tree side (cursor.rs:984-994, cursor.rs:1028, cursor.rs:472-535). It
calls `index_chain_invalidates_btree` (mod.rs:6099-6119), the same test as
`query_btree_version_is_valid`. A debug assertion compares the two on each row
(cursor.rs:661-673). A backward scan uses `query_btree_version_is_valid`
(cursor.rs:1082, cursor.rs:1116). If both sides have the same key, the MVCC
side wins (cursor.rs:253-268).

`SELECT v FROM t WHERE v = ?1` with `CREATE INDEX i ON t(v)` is a covering
index read. The index has `v`, and `k` is the rowid alias, so the index covers
both (`index_is_covering`, `core/translate/plan.rs:3663-3727`). This query
uses the seek path. `SELECT v FROM t INDEXED BY i` uses the scan path.
`INDEXED BY` is supported (`core/translate/optimizer/mod.rs:2372-2390`).

### Recovery

Recovery replays index rows from the logical log. It does not rebuild them
from table rows. The log has the ops `OP_UPSERT_INDEX` and `OP_DELETE_INDEX`
with the serialized index key (`core/mvcc/persistent_storage/logical_log.rs:113-114`,
`logical_log.rs:317-318`). Recovery skips records at or below
`persistent_tx_ts_max` (mod.rs:9817, mod.rs:10411, mod.rs:10437). An upsert
adds a version (mod.rs:10404-10428). A delete ends the latest replayed version
of the key. If no replayed version exists, it adds a marker with
`btree_resident = true` (mod.rs:10430-10474). The commit writes one log record
with the table ops and the index ops of the transaction (mod.rs:2494-2500,
mod.rs:2549-2600). Recovery does not mark dirty keys. The full-scan generation
of a new `MvStore` covers the replayed keys.

## State and actions

The spec has one row (rowid 1) in a table `t(k INTEGER PRIMARY KEY, v INTEGER)`
with an index on `v`. The row value comes from `Vals`. Index key `x` stands
for the record `(x, 1)`.

| Variable | Meaning |
|---|---|
| `tchain` | The version chain of the row |
| `ichain[x]` | The version chain of index key `x`. A version value of 1 means "present". Begin 0 is a marker for an entry that is only in the B-tree |
| `tdirty`, `idirty[x]` | The stamps in the two dirty maps. 0 means not dirty |
| `wal` | WAL frames. Each frame has the row write, the index writes and `persistent_tx_ts_max` |
| `dbRow`, `dbIdx` | The row and the index keys in the database file |
| `inflight`, `llog`, `durable`, `nBackfill`, `backfillFloor` | As in the row spec |
| `ck` | The checkpoint. `ck.iw` holds the index writes and `ck.iu` the unwritten index keys |
| `rd[r]` | Reader state: read mark, begin timestamp, and the first look at the current index key |

Actions:

- `WritePrepare(v)`: a commit that inserts, updates or deletes the row. It
  ends the current version of the old index key. For a chain with no current
  version, it adds a marker. It adds a version to the new index key. `v = 0` is a delete.
  `v = old` with `old != 0` is an UPDATE that sets `v` to its current value.
  It ends and adds a version on the same chain.
- `WriteMarkDirty`: marks the table key and both index keys in one step.
- `WriteLogAppend`, `WriteFinish`: as in the row spec. The log record has the
  table write and both index writes.
- `ReaderPin`, `ReaderBegin`, `ReaderReadStart(r, x)`, `ReaderReadEnd`,
  `ReaderEnd`: a reader looks up index key `x`. `ReaderReadStart` takes the
  first look. `ReaderReadEnd` takes the second look and the record look. The
  record look is a visible-version test at `ReaderReadEnd`. When the MVCC side
  wins from the first look, the read returns the entry only if the record
  look also finds a visible version.
- `CheckpointStart`, `CheckpointCollectTable`, `CheckpointCollectIndex`,
  `CheckpointCommit`, `CheckpointPublish`, `CheckpointBackfill`,
  `CheckpointTruncateLog`, `CheckpointStampTable`, `CheckpointStampIndex`.
  `CheckpointStampIndex` stamps the keys in `ck.iw` and `ck.iu` and then prunes
  both dirty maps.
- `GcTable`, `GcIndex(x)`: the two GC loops, at any moment. They use the floor
  of the incremental loop. The checkpoint floor is lower, so this floor allows
  every drop that the checkpoint GC makes.

`CheckpointCollectIndex` collects every index key in one step. The
"Collection" section above gives the reason. The reason also needs one
checkpoint at a time, which `checkpoint_in_progress` gives in passive mode. The step looks at each dirty
key `x` with a change in (old, snap]. Assume that the value of `x` at the
snapshot is 1, or that the B-tree at the old boundary has `x`. Then the step
puts `x` in `ck.iw` with its value at the snapshot. In the other case, the
step puts `x` in `ck.iu`. Only a checkpoint appends a frame. So the B-tree at
the old boundary is the image at the last WAL frame. The
frame of `CheckpointCommit` writes only `ck.iw`.

## Invariants

| Invariant | Promise |
|---|---|
| `IndexReadsCorrect` | If the row has value `x` at begin timestamp `b`, an index lookup at `b` finds key `x`. Otherwise it does not. This holds for both orders of the two looks, with the record look |
| `BtreeIndexMatchesTable` | The B-tree image at every readable WAL mark has the index entries of its row and no other entry |
| `RecoveryCorrect` | A crash now recovers the row and its index entries of the last logged commit, from the B-tree and the log records above `persistent_tx_ts_max` |
| `IndexChainsStamped` | After a completed pass, every index version whose last event is at or below `durable` has a stamp, so GC can drop it |
| `BackfillBelowReaders` | No pinned reader has a read mark below the backfilled frames |

## Variants

Each variant turns off one rule. Three rules are shared with table chains, so
those variants show that the index depends on the same rule. They do not
point at separate index code.

| Variant | Change | Code | Expected |
|---|---|---|---|
| `noIndexMark` | The commit does not mark index keys | `mark_tx_write_set_dirty` marks every write set key (mod.rs:7915-7917) | `BtreeIndexMatchesTable` fails |
| `noIndexStamp` | `GcIndexRows` does not stamp the written slots. `noUnwrittenStamp` covers the unwritten keys | csm.rs:2373-2379 | `IndexChainsStamped` fails (a leak) |
| `noUnwrittenStamp` | `GcIndexRows` stamps `ck.iw` only, not `ck.iu` | csm.rs:2358-2361 | `IndexChainsStamped` fails (a leak) |
| `indexGcNoFloor` | Index GC drops without the stamp and floor test | Shared `gc_version_chain` (mod.rs:8581) | `IndexReadsCorrect` fails |
| `indexPruneDropsNewMark` | The index dirty prune ignores a newer stamp | Shared `prune_dirty_keys` (csm.rs:1751-1754) | `BtreeIndexMatchesTable` fails |
| `indexRule3WithReader` | Index GC Rule 3 drops the current version while a reader is open | Shared Rule 3 idle test (mod.rs:8623-8628) | `IndexReadsCorrect` fails. The B-tree look of a read runs after GC emptied the chain |

The two stamp variants check a leak, not a read. Without the stamp, GC keeps
the index versions, so every read stays correct.

Nine reachability checks show that the paths run. Each one must fail.
`NeverRewritesSameKey` says that no commit ends and adds a version on the same
index chain. `NeverUnwrittenIndexKey` says that no pass puts a key in `ck.iu`.
`NeverIndexMarker`, `NeverWritesMarkerDelete` and `NeverReadsFromBtree` cover
the marker of an entry that only the B-tree has, the delete that a pass
writes for it, and a read that finds an entry through the B-tree.

## Results

| Configuration | Result |
|---|---|
| `main` | No error. 52,815,276 distinct states, depth 46, 9 minutes on 8 workers |
| `noIndexMark` | `BtreeIndexMatchesTable` fails (855 states) |
| `noIndexStamp` | `IndexChainsStamped` fails (11,292 states) |
| `indexGcNoFloor` | `IndexReadsCorrect` fails (1,479 states) |
| `indexPruneDropsNewMark` | `BtreeIndexMatchesTable` fails (556,220 states) |
| `noUnwrittenStamp` | `IndexChainsStamped` fails (83,811 states) |
| `indexRule3WithReader` | `IndexReadsCorrect` fails (150,876 states) |
| Nine `reach*` checks | Each one fails, so each path runs |

The other four reachability checks are `NeverMovesIndexEntry` (one frame
moves an entry), `NeverEmptiesCurrentIndexChain` (GC empties the chain of the
current entry), `NeverReadsIndexFromOldMark` (a read takes its result from the
B-tree at an old mark that the newest image contradicts) and
`NeverIndexStampRisesBeforePrune` (a commit marks a key between collection and
prune).

The trace replay ran 160 traces of the `mbt` module, 100 of them with index
GC. All 160 replay with no failure and no refusal. The replayed steps include
135 index GC steps, 268 index reads and 79 passes with an unwritten index
key. Four of these traces
are `harness/mbt_tests/traces/index-{27,112,150,154}.itf.json`, and the default test
replays them. The default test also replays `index-marker.itf.json`. It ends
with a pass that collects the delete of an entry with a marker, and the engine
collects the same delete. Random runs of `mbt` do not reach that path, so the
trace comes from a copy of the `mbt` module with `Readers = Set()`, named
`mbtMarker`, run with `quint run --mbt --invariant NeverWritesMarkerDelete`.

## Trace replay

`harness/mbt_tests/index.rs` replays traces of the `mbt` module on a table
with an index. It reuses the steps of the row driver (`docs/HARNESS.md`) for
writers, reader begins, the checkpoint start, the pager commit, the backfill
and the checks of `durable`, WAL frames, `nBackfill`, `backfillFloor` and the
logical log.

1. Before step 1, the driver creates `t` and `CREATE INDEX i ON t(v)` and runs
   `PRAGMA wal_checkpoint(TRUNCATE)`. The index then has a backfilled binding,
   so `rootpage_gc_protected` is false for it (mod.rs:10736-10740). The pass
   also clears the full-scan generation (mod.rs:4658, csm.rs:3523-3526), so
   the spec passes map to dirty-map walks.
2. A writer runs `INSERT INTO t VALUES (1, x)`, `UPDATE t SET v = x WHERE k = 1`
   or `DELETE FROM t WHERE k = 1` in `BEGIN CONCURRENT`. It stops at the same
   commit yield points as the row driver. `WriteMarkDirty` is a no-op step:
   the engine marks the keys inside the `COMMIT` stretch of `WriteLogAppend`,
   before `CommitEnd`.
3. At `ReaderReadEnd`, the reader runs one of two covering index reads. The
   driver uses them in turn. The seek is `SELECT v FROM t INDEXED BY i WHERE
   v = x`. The scan is `SELECT v FROM t INDEXED BY i`, which uses
   `IndexShadowScan`. The driver compares the whole result with the oracle.
   A seek must return `[x]` or nothing. A scan must return the row value at
   the begin timestamp, or nothing for no row. At setup, the
   driver requires `USING COVERING INDEX i` in `EXPLAIN QUERY PLAN` of both
   reads.
4. `GcTable` and `GcIndex(x)` call `gc_chain_now` on the chain of the row or
   of `(x, 1)`, with the floor of the incremental loop.
5. After `CheckpointCollectTable` and `CheckpointCollectIndex`, the driver
   compares the engine write sets with `ck.row`, `ck.iw` and `ck.iu`. Two test
   hooks in `harness/turso-hooks.patch` read `index_write_set` and
   `unwritten_index_rows`. The engine collects all index keys in one step,
   because its threshold is 1024 keys (csm.rs:1688).
6. `CheckpointStampTable` steps the machine to `GcIndexRows`.
   `CheckpointStampIndex` runs the pass to its end, with the prune and the
   `Finalize` sweep. The engine GC in these phases drops versions that the
   spec keeps until a `Gc` step. A later read still has to match the oracle.
7. After each writer and checkpoint step, a crash probe opens a copy of the
   files. It reads the row, scans the index and runs `PRAGMA
   integrity_check`. The row and the index must hold the value of the last
   logged commit, and the check must report `ok`.

Two checks of the spec have no engine check. `IndexChainsStamped` would need
a read of `materialized_at` on each index version, and
`BtreeIndexMatchesTable` would need a read of the B-tree without the version
store. The crash probe covers the B-tree image at the last frame in part,
because recovery starts from it.

The debug build adds two checks: the dirty-map assertion after collection
(csm.rs:1787-1812) and the shadow scan assertion on each scanned row
(cursor.rs:661-673).

The replay runs each read as one whole statement at `ReaderReadEnd`.
`ReaderReadStart` only saves the key, and the statement ends before the next
step. So the replay checks no step that runs inside one read. Three cursor
interleavings stay unverified by the replay: GC or a checkpoint between the
two looks of a read, a change between the seek and the record look at
`Column`, and the reseed of `IndexShadowScan` after `Finalize` unlinks a slot
during a scan. The spec checks the first two. The third is not modeled. To
check them on the engine, the driver needs to keep a statement open across
trace steps and stop it at a yield point. The crash probe also runs no checkpoint after
recovery, so it does not check that a recovered index survives the next
pass.

## Not modeled

The spec leaves out these parts. Each item gives the reason.

Out of scope:

- Index DDL. `destroyed_indexes` (csm.rs:1391, csm.rs:1400),
  `index_id_to_index` at the snapshot (csm.rs:2570-2591),
  `table_exists_for_snapshot` (csm.rs:1226-1237) and the three unstamped
  skip-writes in `WriteIndexRow` all need CREATE INDEX or DROP INDEX during a
  trace. The schema spec owns root bindings. The unstamped skip-writes are a
  leak lead, not a wrong read, and no test shows them.
- `rootpage_gc_protected` for index ids. With the setup checkpoint of the
  trace replay, the binding of `i` is backfilled before step 1, so the test is
  always false. The checkpoint GC phases do not call it for tables or indexes
  (csm.rs:2252-2398). The rows of a new B-tree get the same frame as their
  binding, so the version stamp gives the same protection. This last point is
  not verified.
- The reseed of `IndexShadowScan` on `index_rows_epoch` (cursor.rs:481-485).
  In passive mode only `Finalize` unlinks a slot, and only an empty one
  (mod.rs:8521-8525). A stale scan then sees an empty chain, which is the
  state of the chain at the unlink. A writer that adds a version to the new
  slot commits above the reader's begin. The spec reads one key in one step
  and cannot show a scan position. The trace replay does not check it either
  (see "Trace replay").
- Unique indexes. `NoConflict` and the unique check of `IdxInsert`
  (execute.rs:12409) read the index inside the writer. They need write-write
  conflicts, which no spec models.
- B-tree-resident index inserts (`insert_btree_resident_to_table_or_index`,
  mod.rs:5524-5547). They come from `INSERT OR REPLACE` and partial index
  paths, which need more than one write per commit.
- Non-covering index reads. They add a table seek by rowid at the same
  snapshot. The row spec covers the table read.
- More than one row, more than one index, and aborts. Rollback unmarks index
  keys with the shared `unmark_checkpoint_dirty_key_if_stamp`
  (mod.rs:7883-7894), as the row spec models for table keys. An aborted
  delete of an entry that is only in the B-tree differs: it leaves a marker
  version with begin `None`, so the key stays dirty. The next pass then visits
  a key with no change, which costs work but changes no result.
- Transactions with more than 1024 changed chains. They mark keys over
  several `MarkDirtyKeys` steps, all while `Preparing`.
- A checkpoint on a reader connection, failed passes, WAL restart, mode B and
  mode T.
- The full walk after open. The trace replay clears it in the setup pass.
- The writer part of the GC low-water mark. `compute_lwm` also counts active
  and preparing writers (mod.rs:7995-8007), so the engine Rule 3 needs no open
  writer (mod.rs:8162-8164, mod.rs:8635). The spec counts only readers. So the
  spec GC drops in more states than the engine GC, which can only add
  counterexamples.
