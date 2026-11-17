// Configurations of MvccPassiveIndex.qnt. Each module sets the constants of
// one configuration. The comment above a module gives the result to expect
// and the invariants to check. The Makefile reads these comments.

// Expect no error: the code today.
// Invariants: TypeOK IndexReadsCorrect BtreeIndexMatchesTable RecoveryCorrect IndexChainsStamped BackfillBelowReaders
module main {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect BtreeIndexMatchesTable to fail: the commit marks only the table key,
// so the checkpoint writes the row without its index entries.
// Invariants: BtreeIndexMatchesTable
module noIndexMark {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = false,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect IndexChainsStamped to fail: GcIndexRows does not stamp the written
// index slots, so GC never drops index versions that the B-tree already has.
// Invariants: IndexChainsStamped
module noIndexStamp {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = false,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect IndexReadsCorrect to fail: index GC drops versions without the
// materialized_at and floor test.
// Invariants: IndexReadsCorrect
module indexGcNoFloor {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = false,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect BtreeIndexMatchesTable to fail: PruneDirtyKeys removes an index key
// whose stamp rose after collection, so the next pass misses it.
// Invariants: BtreeIndexMatchesTable
module indexPruneDropsNewMark {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 6,
    MaxCheckpoints = 3,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = false,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect IndexChainsStamped to fail: GcIndexRows does not stamp the keys of
// unwritten_index_rows, so GC keeps an entry inserted and deleted after the
// old boundary.
// Invariants: IndexChainsStamped
module noUnwrittenStamp {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = false,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect IndexReadsCorrect to fail: index GC Rule 3 drops the current version
// while a reader is open, between the two looks of its read.
// Invariants: IndexReadsCorrect
module indexRule3WithReader {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = false,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverIndexMarker to fail: a commit ends an entry that only the B-tree
// has.
// Invariants: NeverIndexMarker
module reachIndexMarker {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverWritesMarkerDelete to fail: a pass writes the delete of an entry
// with a marker.
// Invariants: NeverWritesMarkerDelete
module reachWritesMarkerDelete {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverReadsFromBtree to fail: a reader finds an entry through the
// B-tree after GC emptied its chain.
// Invariants: NeverReadsFromBtree
module reachReadsFromBtree {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverRewritesSameKey to fail: UPDATE t SET v = v rewrites the entry.
// Invariants: NeverRewritesSameKey
module reachRewritesSameKey {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverUnwrittenIndexKey to fail: a pass collects an entry that was
// inserted and deleted after the old boundary.
// Invariants: NeverUnwrittenIndexKey
module reachUnwrittenIndexKey {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverMovesIndexEntry to fail: one frame moves an index entry.
// Invariants: NeverMovesIndexEntry
module reachMovesIndexEntry {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverEmptiesCurrentIndexChain to fail: GC drops the current index
// version, so readers use the B-tree entry.
// Invariants: NeverEmptiesCurrentIndexChain
module reachEmptiesIndexChain {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverReadsIndexFromOldMark to fail: a reader takes its result from
// the B-tree at an old read mark, and a later frame changed that entry.
// Invariants: NeverReadsIndexFromOldMark
module reachReadsOldMark {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 6,
    MaxCheckpoints = 3,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Expect NeverIndexStampRisesBeforePrune to fail: a commit marks an index key
// between collection and prune.
// Invariants: NeverIndexStampRisesBeforePrune
module reachStampRises {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1"),
    MaxTs = 5,
    MaxCheckpoints = 2,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = false,
    LogAppendOneAtATime = false,
    WriterBeginTicks = false,
    WritersPinMarks = false
  ).* from "./MvccPassiveIndex"
}

// Not model checked. make traces uses it.
// Invariants: TypeOK IndexReadsCorrect BtreeIndexMatchesTable RecoveryCorrect IndexChainsStamped BackfillBelowReaders
module mbt {
  import MvccPassiveIndex(
    Vals = Set(1, 2),
    Readers = Set("r1", "r2"),
    MaxTs = 8,
    MaxCheckpoints = 3,
    MarkIndexKeys = true,
    StampIndexRows = true,
    IndexGcWaitsForReaders = true,
    PruneKeepsNewerStamp = true,
    StampUnwrittenIndexRows = true,
    IndexRule3OnlyWhenIdle = true,
    BackfillToLimit = true,
    LogAppendOneAtATime = true,
    WriterBeginTicks = true,
    WritersPinMarks = true
  ).* from "./MvccPassiveIndex"
}
