# How sync depends on table ids

The schema spec models the object map of each commit and the stable table id (`DESIGN-schema.md`, "Sync object map"). It does not model the pull protocol or the server. Sync reads the logical log and
the `rootpage` column of `sqlite_schema`. It uses the same rule as recovery:
the id of a table is `-rootpage`. So any change to table ids, for example
step 3 of `SIMPLIFY.md`, must keep sync working. This file records what sync
expects. Line numbers are from commit 0c9fe0dd9.

## Where sync uses table ids

### The object map in each commit frame

When portable changes are on, each commit frame in the logical log has an
object map. The object map is a list of pairs: a table id and a table name.
Sync uses it to turn log records into row changes with a table name.

1. Core builds the object map in the commit path. It takes the `rootpage`
   of the `sqlite_schema` row and removes the sign. Then it calls
   `portable_table_id_from_rootpage` (`core/mvcc/database/mod.rs:634`,
   called at `mod.rs:2974`), which returns `-rootpage`.
2. The sync client reads the object map in `portable_object_names`
   (`sync/engine/src/database_sync_operations.rs:1141`).
3. `decode_recovery_ops_to_logical_txn` (`database_sync_operations.rs:1319`)
   reads the raw `i32` table id of each log record. It finds the name of the
   table through the object map of the same commit.

The record id and the object map id must use the same form, or the lookup
fails. Today both are `-rootpage`, because `canonical_log_id`
(`mod.rs:2458`) rewrites record ids after the table gets a page.

Core looks up the name of a record id `-page` in two places
(`mod.rs:2919-2999`). First it looks in the schemas by root page. Then it
looks in the `sqlite_schema` versions in the version store. Both can miss. A DDL commit can install an old copy of
the schema with the temporary root (#8004), and catalog GC drops the
versions. Then the commit fails with `Corrupt` on every connection
(`FINDINGS.md` row 27, `harness/repro/sync-object-map-8004.patch`).

The model leaves out a row commit while another connection has an open
DDL, a restart, and more than one row of a table. `DESIGN-schema.md`
("Sync object map", "Left out") gives the reasons.

### The stable table id in the pull protocol

A row change that the client pulls can name its table by `stable_table_id`,
not by name (`sync/engine/src/client_proto.rs:91`). The client keeps a map
from stable id to name in its sync metadata
(`logical_table_names_by_stable_id`, `sync/engine/src/types.rs:194`).
`resolve_row_table_name` (`database_sync_operations.rs:457`) reads it.

After a pull that copies pages, the client builds the map again
(`read_logical_replay_table_map`, `database_sync_operations.rs:2588`). It
reads `SELECT rootpage, name FROM sqlite_schema` and uses
`rootpage.unsigned_abs()` as the stable id (`:2612`). So the stable id in the protocol is the absolute value of the
root page.

## What a permanent table id changes

Example: table `t` gets id -5 at `CREATE`, and its first checkpoint gives it
page 6.

| Value | Today | With a permanent id |
|---|---|---|
| Table id in a log record | -5 before the publish, -6 after it | -5 always |
| Object map id (core) | `-abs(rootpage)`: -5, then -6 | -5. Core must emit the table id. |
| `stable_table_id` in the protocol | `abs(rootpage)`: 5, then 6 | 6, if the `rootpage` column in the B-tree holds the page |
| Map that the client builds again | `abs(rootpage)` from `sqlite_schema` | No change, with the same condition |

The rules for a permanent id:

- Core must write the table id into the object map, with no conversion from
  the root page. The sync decoder does not change.
- The `rootpage` column in the B-tree must hold the real page. The pull
  protocol and the client map depend on it. This is a second reason to
  decide carefully what the MVCC version of a `sqlite_schema` row holds.
- The map from table id to page lives in the database file. A pull that
  copies pages, or an external restore
  (`reset_logical_log_after_external_restore`,
  `sync/engine/src/database_sync_engine.rs:2399`), brings the map with the
  pages.

## Open questions

1. Id collision in the client map. Answer: the state exists, and it also
   breaks push. It is #11501. Before its first checkpoint, a table has
   `rootpage = -N`. `unsigned_abs()` turns it into N. A new table at -10
   and an old table at page 10 get the same stable id 10. A Rust test on
   turso main at ae2cb7388 shows the push symptom (3 of 3 runs,
   `harness/repro/sync-object-map-11501.patch`). `sqlite_schema` has
   `t6 | 10` and `t7 | -10`. An `INSERT INTO t6` writes the record id -10.
   The object map of that commit is `[{ mv_table_id: -10, name: "t7" }]`,
   because the lookup finds `rootpage == -10` before `rootpage == 10`
   (`table_name_for_rootpage_in_schema`, `core/mvcc/database/mod.rs:662-676`).
   The push sends the row of `t6` as a row of `t7`. Not verified: that
   `read_logical_replay_table_map` runs while a client database is in this
   state. Bootstrap bumps `next_table_id` below every root page
   (`mod.rs:4771-4781`), so a fresh replay cannot make the collision. It
   needs a pass that gives page N to another table while a local `CREATE`
   with id -N is open. Nobody traced whether the pull path can do that.
2. The stable id changes at the first checkpoint of a table, from the
   temporary id to the page. Answer: yes (`reachStableIdChanges` fails). The client changes its map only in two ways: pulled schema ops
   and the rebuild after a page pull. The schema ops are `Create`,
   `Refresh`, `Alter` and `Drop`
   (`sync/engine/src/database_sync_operations.rs:486-497`). A pulled row with an unknown id fails the pull with
   "unknown stable_table_id" (`:466-473`), so the failure is not silent.
   The server sets `stable_table_id`, and its code is not here. Not
   verified: whether it sends a `Refresh` at the change. A permanent id
   does not remove the change, because the `rootpage` column still goes
   from `-id` to the page.

## Next step

`DESIGN-schema.md`, section "Sync object map", has the model, the ten
configurations and their results.
