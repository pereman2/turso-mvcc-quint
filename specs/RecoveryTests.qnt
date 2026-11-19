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
