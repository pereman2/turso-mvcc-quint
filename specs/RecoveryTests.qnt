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
    MaxCheckpoints = 2,
    MaxCrashes = 1,
    MaxFails = 0,
    InitFlag = true,
    OpenFlags = Set(false, true),
    OpenReadOnly = Set(false, true),
    CheckpointKinds = Set("passive"),
    CrashOnlyWhenIdle = false,
    TornHeaderGarbage = true,
    Fix9770 = false,
    FixBlockingStoreEmpty = false,
    RecoveryOneTs = false,
    FixStampBelowBoundary = false,
    AsyncLogTruncate = false,
    LogTruncateErrors = false,
    SyncMode = "normal",
    PassiveBackfillSkips = true,
    FixCkCommitSyncsWal = false
  ).* from "./MvccRecovery"

  action commitRow =
    CommitWrite("a", false)
      .then(CommitAppendDone)
      .then(CommitFsync)
      .then(CommitPublish)

  action commitCheckpoint =
    CkBegin("passive").then(CkCommit).then(CkPublish)

  action finishCheckpoint =
    CkTruncLog.then(CkTruncWal).then(CkGc)

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
      .then(OpenBackfill)
      .then(OpenSyncDb)
      .then(OpenHeader)
      .then(OpenFsyncLog)
      .then(OpenFinish)
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
}
