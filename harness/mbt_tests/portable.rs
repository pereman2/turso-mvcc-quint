//! Reads the row records and the object map of the newest commit of the
//! MVCC logical log. The wire format is the one of `PortableLogicalBuilder`
//! (core/mvcc/portable_logical.rs): field 12 is a string, field 13 is an
//! object map entry with the table id in field 1 (zigzag) and the index of
//! its name in field 2. The decoder follows the test helpers in
//! core/mvcc/database/tests.rs:18368-18518.

use std::sync::Arc;

use crate::mvcc::database::SQLITE_SCHEMA_MVCC_TABLE_ID;
use crate::mvcc::persistent_storage::logical_log::{ParsedOp, StreamingLogicalLogReader};
use crate::util::IOExt;
use crate::Connection;

/// The newest commit of the logical log, as sync reads it.
#[derive(Debug)]
pub(super) struct LastCommit {
    /// Commit timestamp of the newest frame with ops.
    pub(super) record_ts: Option<u64>,
    /// Table ids of the table row records of that frame (no sqlite_schema).
    pub(super) record_ids: Vec<i64>,
    /// Commit timestamp of the newest frame with portable changes.
    pub(super) map_ts: Option<u64>,
    /// The (table id, name) pairs of the object map of that frame.
    pub(super) objects: Vec<(i64, String)>,
}

/// Reads the newest frame twice: once for its row records
/// (`StreamingLogicalLogReader::next_frame`) and once for its portable
/// changes (`next_portable_changes`). The caller checks that the two
/// timestamps are equal, so both come from the same commit.
pub(super) fn last_commit(conn: &Arc<Connection>) -> LastCommit {
    let mv_store = conn.mv_store().as_ref().unwrap().clone();
    let io = conn.get_pager().io.clone();
    let mut reader = StreamingLogicalLogReader::new(mv_store.get_logical_log_file(), None);
    reader.read_header(&io).unwrap();
    let mut ops = Vec::new();
    while let Some(frame) = io.block(|| reader.next_frame()).unwrap() {
        ops = frame;
    }
    let mut record_ts = None;
    let mut record_ids = Vec::new();
    for op in &ops {
        if let ParsedOp::UpsertTable {
            table_id,
            commit_ts,
            ..
        } = op
        {
            if *table_id != SQLITE_SCHEMA_MVCC_TABLE_ID {
                record_ids.push(i64::from(*table_id));
                record_ts = Some(*commit_ts);
            }
        }
    }
    let mut reader = StreamingLogicalLogReader::new(mv_store.get_logical_log_file(), None);
    reader.read_header(&io).unwrap();
    let mut map_ts = None;
    let mut payload = Vec::new();
    while let Some(frame) = io.block(|| reader.next_portable_changes()).unwrap() {
        map_ts = Some(frame.commit_ts);
        payload = frame.payload;
    }
    let mut objects = Vec::new();
    let mut offset = 0;
    while offset < payload.len() {
        let len = varint(&payload, &mut offset) as usize;
        objects.extend(txn_object_map(&payload[offset..offset + len]));
        offset += len;
    }
    LastCommit {
        record_ts,
        record_ids,
        map_ts,
        objects,
    }
}

fn txn_object_map(txn: &[u8]) -> Vec<(i64, String)> {
    let mut strings = Vec::new();
    let mut entries = Vec::new();
    let mut offset = 0;
    while offset < txn.len() {
        let key = varint(txn, &mut offset);
        match (key >> 3, key & 7) {
            (12, 2) | (13, 2) => {
                let len = varint(txn, &mut offset) as usize;
                let bytes = &txn[offset..offset + len];
                offset += len;
                if key >> 3 == 12 {
                    strings.push(String::from_utf8(bytes.to_vec()).unwrap());
                } else {
                    entries.push(entry(bytes));
                }
            }
            (_, wire) => skip(txn, &mut offset, wire),
        }
    }
    entries
        .into_iter()
        .map(|(id, name)| (id, strings[name].clone()))
        .collect()
}

/// One object map entry: the table id and the index of its name.
fn entry(bytes: &[u8]) -> (i64, usize) {
    let (mut id, mut name, mut offset) = (0, 0, 0);
    while offset < bytes.len() {
        let key = varint(bytes, &mut offset);
        match (key >> 3, key & 7) {
            (1, 0) => {
                let v = varint(bytes, &mut offset);
                id = ((v >> 1) as i64) ^ (-((v & 1) as i64));
            }
            (2, 0) => name = varint(bytes, &mut offset) as usize,
            (_, wire) => skip(bytes, &mut offset, wire),
        }
    }
    (id, name)
}

fn varint(bytes: &[u8], offset: &mut usize) -> u64 {
    let (mut value, mut shift) = (0u64, 0);
    loop {
        let byte = bytes[*offset];
        *offset += 1;
        value |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return value;
        }
        shift += 7;
    }
}

fn skip(bytes: &[u8], offset: &mut usize, wire: u64) {
    match wire {
        0 => {
            varint(bytes, offset);
        }
        2 => {
            let len = varint(bytes, offset) as usize;
            *offset += len;
        }
        other => panic!("unsupported protobuf wire type {other}"),
    }
}
