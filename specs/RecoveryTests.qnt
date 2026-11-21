module recoveryFullTests {
  import MvccRecovery(
    Keys = Set("a"),
    MaxTs = 1,
    MaxCheckpoints = 1,
    MaxCrashes = 1,
    MaxFails = 0,
    InitFlag = false,
    OpenFlags = Set(false, true),
    OpenReadOnly = Set(false, true),
    CheckpointKinds = Set("blocking"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = false,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = "full",
    PassiveBackfillSkips = false,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action checkpointRow =
    Init
      .then(CommitWrite("a", false))
      .then(CommitAppendDone)
      .then(CommitFsync)
      .then(CommitPublish)
      .then(CkBegin("blocking"))
      .then(CkCommit)
      .then(CkPublish)
      .then(CkBackfill)
      .then(CkSyncDb)
      .then(CkTruncLog)
      .then(CkTruncWal)
      .then(CkGc)
      .expect(lg.file.length() == 0 and lg.disk.length() == 1 and fs.metaDisk == 1)

  run discardedTruncateTest =
    checkpointRow
      .then(Crash("disk", false, false))
      .expect(lg.hdisk == "Valid" and lg.disk.length() == 1 and fs.wal.length() == 0)
      .then(OpenStart(false))
      .expect(reads.get("a") == 1 and replayTop == 0 and store.get("a") == Set())

  run persistedTruncateTest =
    checkpointRow
      .then(Crash("mem", false, false))
      .expect(lg.hdisk == "None" and lg.disk.length() == 0)
      .then(OpenStart(false))
      .expect(reads.get("a") == 1 and replayTop == 0)
}

module recoveryNormalTests {
  import MvccRecovery(
    Keys = Set("a"),
    MaxTs = 2,
    MaxCheckpoints = 3,
    MaxCrashes = 2,
    MaxFails = 1,
    InitFlag = true,
    OpenFlags = Set(false, true),
    OpenReadOnly = Set(false, true),
    CheckpointKinds = Set("passive"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = true,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = "normal",
    PassiveBackfillSkips = true,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action commit(del: bool): bool =
    CommitWrite("a", del)
      .then(CommitAppendDone)
      .then(CommitFsync)
      .then(CommitPublish)

  action commitRow = commit(false)

  action commitCheckpoint =
    CkBegin("passive").then(CkCommit).then(CkPublish)

  action finishCheckpoint =
    CkTruncLog.then(CkTruncWal).then(CkGc)

  action reconcileWal =
    OpenBackfill.then(OpenSyncDb).then(OpenHeader).then(OpenFsyncLog).then(OpenTruncWal)

  action finishOpen = reconcileWal.then(OpenSyncWal).then(OpenFinish)

  run skippedBackfillTest =
    Init
      .then(commitRow)
      .then(commitCheckpoint)
      .expect(floor == 0 and fs.walDisk == 0)
      .then(CkBackfill)
      .expect(floor == 1 and fs.walDisk == 1 and fs.metaDisk == 0)
      .then(CkSyncDb)
      .then(finishCheckpoint)
      .then(commitRow)
      .then(commitCheckpoint)
      .then(CkBackfillNone)
      .then(finishCheckpoint)
      .expect(floor == 1 and reads.get("a") == 2)
      .then(Crash("disk", false, false))
      .expect(floor == 1 and NormalPrefix and fs.wal.length() == 1
        and openOutcome(true, true).why == "readonly"
        and openOutcome(true, false).ok)
      .then(OpenStart(true))
      .then(finishOpen)
      .expect(reads.get("a") == 1 and fs.wal.length() == 0)

  run retainedLogTest =
    Init
      .then(commitRow)
      .then(commitCheckpoint)
      .then(commitRow)
      .then(CkBackfill)
      .expect(floor == 1 and reads.get("a") == 2)
      .then(CkSyncDb)
      .then(finishCheckpoint)
      .expect(lg.file.length() == 2 and lg.disk.length() == 0 and floor == 1)
      .then(Crash("disk", false, false))
      .expect(NormalPrefix and rebuildReads(openOutcome(true, false), Keys).get("a") == 1)

  action openBeforeWalSync =
    Init
      .then(commitRow)
      .then(commitCheckpoint)
      .then(commitRow)
      .then(Crash("mem", false, true))
      .expect(fs.metaDisk == 0 and fs.wal.length() == 1 and lg.disk.length() == 2)
      .then(OpenStart(false))
      .then(reconcileWal)
      .expect(fs.metaDisk == 1 and fs.dbDisk.get("a") == 1 and lg.disk.length() == 2
        and op.expected == { ts: 2, rows: Map("a" -> 2) })

  action reopenRetainedLog =
    (if (fs.wal.length() > 0) OpenStart(false).then(finishOpen) else OpenStart(false))
      .expect(mode == "run" and fs.wal.length() == 0 and durable == 1
        and replayTop == 2 and floor == 2 and reads.get("a") == 2
        and store.get("a") == Set(
          { b: 0, e: 2, v: 0, mat: 0, res: true },
          { b: 2, e: Inf, v: 2, mat: 0, res: false }))

  action partialBackfill =
    Init
      .then(commitRow)
      .then(commitCheckpoint)
      .then(CkFail)
      .then(commit(true))
      .then(commitCheckpoint)
      .expect(fs.wal.length() == 2 and fs.walDisk == 0 and durable == 2 and floor == 0)
      .then(CkBackfillPartial(1))
      .expect(fs.dbMem.get("a") == 1 and fs.metaMem == 1
        and fs.metaDisk == 0 and fs.nBackfill == 0 and fs.walDisk == 2 and floor == 2)

  action finishPartialBackfill =
    partialBackfill
      .then(CkSyncDb)
      .then(finishCheckpoint)
      .expect(fs.dbDisk.get("a") == 1 and fs.metaDisk == 1 and fs.nBackfill == 1
        and store.get("a") == Set({ b: 1, e: 2, v: 1, mat: walEnd, res: false })
        and DbFileReadsCorrect and reads.get("a") == 0)

  action reopenPartialBackfill =
    OpenStart(true)
      .then(finishOpen)
      .expect(clock == 2 and durable == 2 and floor == 2 and replayTop == 0
        and fs.metaDisk == 2 and fs.wal.length() == 0 and fs.nBackfill == 0
        and reads.get("a") == 0 and store.get("a") == Set())

  run partialBackfillBeforeDbSyncTest =
    partialBackfill
      .then(Crash("mem", false, false))
      .expect(fs.metaDisk == 0 and lg.disk.length() == 2 and NormalPrefix)
      .then(reopenPartialBackfill)

  run partialBackfillDropsUnsyncedLogTest =
    finishPartialBackfill
      .then(Crash("disk", false, false))
      .expect(fs.metaDisk == 1 and fs.wal.length() == 2 and lg.disk.length() == 0 and NormalPrefix)
      .then(reopenPartialBackfill)

  run fullBackfillReclaimsPartialBackfillDeleteTest =
    finishPartialBackfill
      .then(CkBegin("passive"))
      .then(CkCommit)
      .then(CkBackfill)
      .then(CkSyncDb)
      .then(finishCheckpoint)
      .expect(fs.nBackfill == 2 and fs.metaDisk == 2 and fs.dbDisk.get("a") == 0
        and store.get("a") == Set() and DbFileReadsCorrect)

  run powerLossDropsWalTruncateTest =
    openBeforeWalSync
      .then(Crash("disk", false, false))
      .expect(fs.wal.length() == 1 and op.expected.ts == 2 and NormalRecoveryStable)
      .then(reopenRetainedLog)

  run powerLossKeepsWalTruncateTest =
    openBeforeWalSync
      .then(Crash("disk", false, true))
      .expect(fs.wal.length() == 0 and op.expected.ts == 2 and NormalRecoveryStable)
      .then(reopenRetainedLog)

  run powerLossAfterWalSyncTest =
    openBeforeWalSync
      .then(OpenSyncWal)
      .then(Crash("disk", false, false))
      .expect(fs.wal.length() == 0 and op.expected.ts == 2 and NormalRecoveryStable)
      .then(reopenRetainedLog)

  run powerLossAfterReopenTest =
    Init
      .then(commitRow)
      .then(Crash("mem", false, false))
      .expect(floor == 0 and fs.wal.length() == 0)
      .then(OpenStart(true))
      .expect(floor == 1 and reads.get("a") == 1)
      .then(commitRow)
      .expect(floor == 1 and reads.get("a") == 2)
      .then(Crash("disk", false, false))
      .expect(NormalPrefix)
      .then(OpenStart(true))
      .expect(floor == 1 and reads.get("a") == 1)
}

module recoveryFullReaderTests {
  import MvccRecovery(
    Keys = Set("a"),
    MaxTs = 3,
    MaxCheckpoints = 3,
    MaxCrashes = 1,
    MaxFails = 1,
    InitFlag = true,
    OpenFlags = Set(false, true),
    OpenReadOnly = Set(false),
    CheckpointKinds = Set("passive", "blocking"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = true,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = "full",
    PassiveBackfillSkips = false,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action commit(del: bool): bool =
    CommitWrite("a", del).then(CommitAppendDone).then(CommitFsync).then(CommitPublish)

  action writeCheckpoint = CkBegin("passive").then(CkCommit).then(CkPublish)

  action finishCheckpoint = CkTruncLog.then(CkTruncWal).then(CkGc)

  action emptyCheckpoint = CkBegin("passive").then(CkCommit).then(CkBackfill)

  run walPinRetainsLogForReopenTest =
    Init
      .then(commit(false))
      .then(writeCheckpoint)
      .then(CkFail)
      .then(ReaderPin)
      .then(ReaderBegin)
      .expect(not(reader.dbFile) and reader.mark == 2
        and reader.snapshot == { ts: 1, rows: Map("a" -> 1) })
      .then(commit(true))
      .then(writeCheckpoint)
      .expect(clock == 2 and reads.get("a") == 0 and readerReads.get("a") == 1)
      .then(CkBackfill)
      .expect(fs.metaMem == 1 and fs.dbMem.get("a") == 1 and fs.metaDisk == 0
        and fs.nBackfill == 0 and ck.copiedThrough == 1 and fs.walDisk == 2)
      .then(CkSyncDb)
      .then(commit(false))
      .then(finishCheckpoint)
      .expect(fs.metaDisk == 1 and fs.dbDisk.get("a") == 1 and fs.nBackfill == 1
        and lg.file.foldl(List(), (times, r) => times.append(r.ts)) == List(1, 2, 3)
        and readerReads.get("a") == 1 and readerLwm == 1 and readerGcFloor == 2
        and reads.get("a") == 3 and store.get("a") == Set(
          { b: 1, e: 2, v: 1, mat: 3, res: false },
          { b: 3, e: Inf, v: 3, mat: 0, res: false }))
      .then(Crash("disk", false, false))
      .expect(reader == readerIdle and not(seen.contains("CleanClose"))
        and fs.metaDisk == 1 and fs.wal.length() == 2 and lg.disk == lg.file
        and lg.disk.length() == 3 and store.get("a") == Set())
      .then(OpenStart(true))
      .expect(reader == readerIdle and mode == "open")
      .then(OpenBackfill.then(OpenSyncDb).then(OpenHeader).then(OpenFsyncLog)
        .then(OpenTruncWal).then(OpenSyncWal).then(OpenFinish))
      .expect(reader == readerIdle and clock == 3 and durable == 2 and replayTop == 3
        and fs.dbDisk.get("a") == 0 and fs.wal.length() == 0 and reads.get("a") == 3
        and store.get("a") == Set({ b: 3, e: Inf, v: 3, mat: 0, res: false }))
      .then(ReaderPin)
      .then(ReaderBegin)
      .expect(reader.dbFile and reader.mark == 1 and readerBtree.get("a") == 0
        and reader.snapshot == { ts: 3, rows: Map("a" -> 3) } and readerReads.get("a") == 3)

  run dbFilePinPrecedesNewSnapshotTest =
    Init
      .then(commit(false))
      .then(writeCheckpoint)
      .then(CkBackfill.then(CkSyncDb).then(finishCheckpoint))
      .expect(fs.nBackfill == 1 and store.get("a") == Set())
      .then(ReaderPin)
      .expect(reader.phase == "pinned" and reader.dbFile and reader.mark == 2
        and reader.snapshot.ts == -1 and readerLwm == Inf and readerBtree.get("a") == 1)
      .then(commit(false))
      .then(writeCheckpoint)
      .then(CkBackfill)
      .expect(ck.pc == "trunclog" and walEnd == 3 and fs.nBackfill == 1
        and fs.metaMem == 1 and fs.metaDisk == 1 and fs.dbDisk.get("a") == 1)
      .then(finishCheckpoint)
      .expect(readerGcFloor == 2 and store.get("a") == Set(
        { b: 0, e: 2, v: 0, mat: 3, res: true },
        { b: 2, e: Inf, v: 2, mat: 3, res: false }))
      .then(ReaderBegin)
      .expect(reader.snapshot == { ts: 2, rows: Map("a" -> 2) } and reader.mark == 2
        and readerBtree.get("a") == 1 and readerReads.get("a") == 2)
      .then(ReaderEnd)
      .then(emptyCheckpoint.then(CkSyncDb).then(finishCheckpoint))
      .expect(reader == readerIdle and fs.nBackfill == 2 and fs.dbDisk.get("a") == 2
        and store.get("a") == Set())

  run registeredSnapshotKeepsLastCurrentVersionTest =
    Init
      .then(commit(false))
      .then(writeCheckpoint)
      .then(ReaderPin)
      .then(ReaderBegin)
      .then(CkBackfill.then(CkSyncDb).then(finishCheckpoint))
      .expect(not(reader.dbFile) and reader.mark == 2 and readerLwm == 1
        and readerGcFloor == 2 and fs.nBackfill == 1 and readerReads.get("a") == 1
        and store.get("a") == Set({ b: 1, e: Inf, v: 1, mat: 2, res: false }))
      .then(ReaderEnd)
      .then(ReaderPin)
      .then(emptyCheckpoint.then(finishCheckpoint))
      .expect(reader.phase == "pinned" and reader.dbFile and readerLwm == Inf
        and readerGcFloor == 2 and store.get("a") == Set())
      .then(ReaderBegin)
      .expect(reader.snapshot.ts == 1 and readerReads.get("a") == 1)

  run supersededVersionNeedsSnapshotAndBackfillTest =
    val chain = Set({ b: 1, e: 2, v: 1, mat: 3, res: false })
    Init.expect(gcChain(chain, 2, true, 3, 1) == chain
      and gcChain(chain, 2, true, 2, 2) == chain
      and gcChain(chain, 2, true, 3, 2) == Set())

  action pinInBlockingMode =
    Init
      .then(Crash("disk", false, false))
      .then(OpenStart(false))
      .then(ReaderPin)

  run blockingCheckpointWaitsForPinTest =
    pinInBlockingMode.then(CkBegin("blocking").fail())

  run blockingCheckpointWaitsForSnapshotTest =
    pinInBlockingMode.then(ReaderBegin).then(CkBegin("blocking").fail())

  action beginBlockingCheckpointAfterReader =
    pinInBlockingMode
      .then(ReaderBegin)
      .then(ReaderEnd)
      .then(CkBegin("blocking"))

  run readerWaitsForBlockingCheckpointTest =
    beginBlockingCheckpointAfterReader.then(ReaderPin.fail())

  run readerPinsAfterBlockingCheckpointTest =
    beginBlockingCheckpointAfterReader
      .then(CkCommit)
      .then(CkBackfill.then(finishCheckpoint))
      .then(ReaderPin)
      .expect(not(flag) and cnt.ck == 1 and ck.pc == "idle" and reader.phase == "pinned")
}

module recoveryNormalReaderTests {
  import MvccRecovery(
    Keys = Set("a"),
    MaxTs = 2,
    MaxCheckpoints = 2,
    MaxCrashes = 1,
    MaxFails = 1,
    InitFlag = true,
    OpenFlags = Set(true),
    OpenReadOnly = Set(false),
    CheckpointKinds = Set("passive"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = true,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = "normal",
    PassiveBackfillSkips = false,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action commit(del: bool): bool =
    CommitWrite("a", del).then(CommitAppendDone).then(CommitFsync).then(CommitPublish)

  action writeCheckpoint = CkBegin("passive").then(CkCommit).then(CkPublish)

  run walPinPartialCopyClearsLiveLogTest =
    Init
      .then(commit(false))
      .then(writeCheckpoint)
      .then(CkFail)
      .then(ReaderPin)
      .then(ReaderBegin)
      .expect(not(reader.dbFile) and reader.mark == 2
        and reader.snapshot == { ts: 1, rows: Map("a" -> 1) })
      .then(commit(true))
      .then(writeCheckpoint)
      .expect(fs.walDisk == 0 and clock == 2 and durable == 2 and floor == 0)
      .then(CkBackfill)
      .expect(fs.metaMem == 1 and fs.dbMem.get("a") == 1 and fs.metaDisk == 0
        and fs.nBackfill == 0 and ck.copiedThrough == 1 and fs.walDisk == 2 and floor == 2)
      .then(CkSyncDb.then(CkTruncLog).then(CkTruncWal).then(CkGc))
      .expect(fs.metaDisk == 1 and fs.dbDisk.get("a") == 1 and fs.nBackfill == 1
        and lg.hfile == "None" and lg.file == List() and lg.maxApp == 0
        and lg.disk == List() and reads.get("a") == 0 and readerReads.get("a") == 1
        and store.get("a") == Set({ b: 1, e: 2, v: 1, mat: 3, res: false }))
      .then(Crash("disk", false, false))
      .expect(reader == readerIdle and not(seen.contains("CleanClose"))
        and NormalPrefix and fs.wal.length() == 2 and fs.metaDisk == 1)
      .then(OpenStart(true))
      .expect(reader == readerIdle and op.expected == { ts: 2, rows: Map("a" -> 0) })
      .then(OpenBackfill.then(OpenSyncDb).then(OpenHeader).then(OpenFsyncLog)
        .then(OpenTruncWal).then(OpenSyncWal).then(OpenFinish))
      .expect(reader == readerIdle and clock == 2 and durable == 2 and floor == 2 and replayTop == 0
        and fs.metaDisk == 2 and fs.dbDisk.get("a") == 0 and fs.wal.length() == 0
        and reads.get("a") == 0 and store.get("a") == Set())
      .then(ReaderPin)
      .then(ReaderBegin)
      .expect(reader.dbFile and reader.mark == 1 and readerReads.get("a") == 0
        and reader.snapshot == { ts: 2, rows: Map("a" -> 0) })
}

module recoveryFailedTruncate {
  const Mode: str
  import MvccRecovery(
    Keys = Set("a"),
    MaxTs = 2,
    MaxCheckpoints = 3,
    MaxCrashes = 1,
    MaxFails = 2,
    InitFlag = false,
    OpenFlags = Set(false),
    OpenReadOnly = Set(false),
    CheckpointKinds = Set("blocking"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = true,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = Mode,
    PassiveBackfillSkips = false,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action commit = CommitWrite("a", false).then(CommitAppendDone).then(CommitFsync).then(CommitPublish)

  action writeCheckpoint = CkBegin("blocking").then(CkCommit).then(CkPublish)

  action finishOpen(expected: int): bool = OpenStart(false).then(OpenBackfill).then(OpenSyncDb).then(OpenHeader)
    .then(OpenFsyncLog).then(OpenTruncWal).then(OpenSyncWal).then(OpenFinish)
    .expect(reader == readerIdle and clock == expected and durable == expected and replayTop == 0
      and fs.metaDisk == expected and fs.dbDisk.get("a") == expected and fs.wal.length() == 0
      and reads.get("a") == expected)

  action slotZeroBusy =
    Init
      .then(PagerPin)
      .expect(reader.dbFile)
      .then(commit)
      .then(writeCheckpoint)
      .then(CkBackfill)
      .expect(ck.pc == "backfillbusy" and ck.copiedThrough == 0
        and fs.metaMem == 0 and fs.metaDisk == 0 and fs.nBackfill == 0
        and fs.walDisk == (if (normal) 0 else 1))
      .then(CkFail)
      .then(ReaderEnd)

  action partialCopy =
    slotZeroBusy
      .then(PagerPin)
      .expect(not(reader.dbFile) and reader.mark == 2)
      .then(commit)
      .then(writeCheckpoint)
      .then(CkBackfill)
      .expect(ck.pc == "backfillbusy" and ck.copiedThrough == 1
        and fs.dbMem.get("a") == 1 and fs.metaMem == 1
        and fs.dbDisk.get("a") == 0 and fs.metaDisk == 0 and fs.nBackfill == 0
        and fs.wal.length() == 2 and fs.walDisk == 2 and durable == 2
        and floor == (if (normal) 2 else 0))

  action partialBusy =
    partialCopy
      .then(CkFail)
      .expect(ck == ckIdle and cnt.fail == 2 and lg.file.length() == 2
        and lg.disk.length() == (if (normal) 0 else 2)
        and fs.metaMem == 1 and fs.metaDisk == 0 and fs.nBackfill == 0
        and store.get("a") == Set(
          { b: 1, e: 2, v: 1, mat: 0, res: false },
          { b: 2, e: Inf, v: 2, mat: 0, res: false })
        and reads.get("a") == 2)

  action reopenWithCopyLost =
    partialBusy
      .then(Crash("disk", false, false))
      .expect(fs.metaDisk == 0 and fs.wal.length() == 2)
      .then(finishOpen(2))

  action reopenWithCopyKept =
    partialBusy
      .then(Crash("disk", true, false))
      .expect(fs.metaDisk == 1 and fs.dbDisk.get("a") == 1 and fs.wal.length() == 2)
      .then(finishOpen(2))

  action retry =
    partialBusy
      .then(ReaderEnd)
      .then(CkBegin("blocking"))
      .expect(not(ck.nonempty))
      .then(CkCommit.then(CkBackfill).then(CkSyncDb).then(CkTruncLog).then(CkTruncWal).then(CkGc))
      .expect(ck == ckIdle and fs.metaDisk == 2 and fs.dbDisk.get("a") == 2
        and fs.wal.length() == 0 and fs.nBackfill == 0 and lg.file.length() == 0
        and reads.get("a") == 2)

  action tailPin =
    slotZeroBusy
      .then(PagerPin)
      .then(CkBegin("blocking").then(CkCommit))
      .expect(not(ck.nonempty))
      .then(CkBackfill)
      .expect(ck.pc == "backfillbusy" and ck.copiedThrough == fs.wal.length()
        and fs.wal.length() == 1 and fs.walDisk == 1
        and fs.dbMem.get("a") == 1 and fs.metaMem == 1
        and fs.dbDisk.get("a") == 0 and fs.metaDisk == 0)
      .then(CkFail)
      .expect(ck == ckIdle and fs.metaDisk == 0 and fs.nBackfill == 0 and lg.file.length() == 1)
      .then(Crash("disk", false, false))
      .expect(fs.metaDisk == 0 and fs.wal.length() == 1
        and lg.disk.length() == (if (normal) 0 else 1))
      .then(finishOpen(1))
}

module recoveryFullFailedTruncateTests {
  import recoveryFailedTruncate(Mode = "full").* from "./RecoveryTests"

  run reopenWithCopyLostTest = reopenWithCopyLost
  run reopenWithCopyKeptTest = reopenWithCopyKept
  run retryTest = retry
  run tailPinTest = tailPin
}

module recoveryNormalFailedTruncateTests {
  import recoveryFailedTruncate(Mode = "normal").* from "./RecoveryTests"

  run reopenWithCopyLostTest = reopenWithCopyLost
  run reopenWithCopyKeptTest = reopenWithCopyKept
  run retryTest = retry
  run tailPinTest = tailPin
}
