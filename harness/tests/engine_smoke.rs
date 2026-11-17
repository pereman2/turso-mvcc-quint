//! Checks that the pinned turso_core opens an MVCC database with the passive
//! checkpoint flag, checkpoints it, and reads the rows back after a reopen.
//! The trace replay drives the same mode from inside turso_core.
#![cfg(feature = "engine")]

use std::sync::Arc;

use turso_core::{ConnectOpts, Connection, Database, DatabaseOpts, OpenFlags, PlatformIO, Value};
use turso_sqlite::SqliteDialect;

fn open(path: &str) -> Arc<Connection> {
    let io = Arc::new(PlatformIO::new().unwrap());
    let db = Database::open_file_with_flags(
        io,
        path,
        OpenFlags::default(),
        DatabaseOpts::new().with_experimental_mvcc_passive_checkpoint(true),
        None,
        Arc::new(SqliteDialect),
    )
    .unwrap();
    db.connect(ConnectOpts::new()).unwrap()
}

fn rows(conn: &Arc<Connection>, sql: &str) -> Vec<Vec<Value>> {
    let mut stmt = conn.prepare(sql).unwrap();
    let mut rows = Vec::new();
    stmt.run_with_row_callback(|row| {
        rows.push(row.get_values().cloned().collect());
        Ok(())
    })
    .unwrap();
    rows
}

#[test]
fn passive_checkpoint_keeps_rows_across_reopen() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("smoke.db");
    let path = path.to_str().unwrap();
    {
        let conn = open(path);
        conn.pragma_update("journal_mode", "'mvcc'").unwrap();
        conn.execute("CREATE TABLE t(id INTEGER PRIMARY KEY, v TEXT)")
            .unwrap();
        conn.execute("INSERT INTO t VALUES (1, 'a'), (2, 'b')")
            .unwrap();
        conn.execute("PRAGMA wal_checkpoint(PASSIVE)").unwrap();
        conn.execute("INSERT INTO t VALUES (3, 'c')").unwrap();
        conn.close().unwrap();
    }
    let conn = open(path);
    assert_eq!(
        rows(&conn, "SELECT id, v FROM t ORDER BY id"),
        vec![
            vec![Value::from_i64(1), Value::build_text("a")],
            vec![Value::from_i64(2), Value::build_text("b")],
            vec![Value::from_i64(3), Value::build_text("c")],
        ]
    );
}
