import Foundation
import SQLite3
import XCTest
@testable import StorageSaverCore

/// The invariants added for unattended (app) use. Fresh fixture per test.
final class HardeningTests: XCTestCase {
    var store: MessagesStore!
    var support: URL!
    var archiveRoot: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-hardening-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Fixture.packageRoot.appendingPathComponent("scripts/make-fixture.py").path, dir.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        store = MessagesStore(root: dir)
        support = dir.appendingPathComponent("support")
        archiveRoot = dir.deletingLastPathComponent().appendingPathComponent("mss-archive-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        Offloader.testHookBeforeUnlink = nil
        if FileManager.default.fileExists(atPath: archiveRoot.path) { chmod(archiveRoot.path, 0o755) }
    }

    func journal() -> Journal { Journal(url: support.appendingPathComponent("journal.jsonl")) }
    func lockURL() -> URL { support.appendingPathComponent("run.lock") }
    func policy() -> Policy { var p = Policy(); p.firstRunMaxBytes = 1_000_000_000; return p }
    func fileCount() -> Int { Analyzer.walkFiles(store.attachmentsDir).files.count }

    func rawExec(_ sql: String) {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK, sql)
        sqlite3_close(raw)
    }

    func makeQuiescent() { rawExec("UPDATE attachment SET transfer_state = -1 WHERE guid = 'att-transfer_in_progress'") }

    func candidates() throws -> [Candidate] {
        try CandidateSelector.select(db: ReadOnlyDatabase(path: store.chatDB.path), store: store, policy: policy()).candidates
    }

    func realRun(_ request: OffloadRequest? = nil, progress: OffloadProgressHandler? = nil, isCancelled: CancellationCheck? = nil) throws -> OffloadResult {
        try Offloader.run(store: store, request: request ?? OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false),
                          journal: journal(), lockURL: lockURL(), progress: progress, isCancelled: isCancelled)
    }

    func dryRun(_ request: OffloadRequest? = nil) throws -> OffloadResult {
        try Offloader.run(store: store, request: request ?? OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: true),
                          journal: journal(), lockURL: lockURL())
    }

    /// Puts a file back with the recorded size and an old mtime, like a re-download.
    func recreate(_ path: String, bytes: Int64) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(count: Int(bytes)).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-400 * 86_400)], ofItemAtPath: path)
    }

    // MARK: lock, cap, config

    func testLockIsHeldForTheWholeRun() throws {
        makeQuiescent()
        var sawBusy = false
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 2 {
                XCTAssertThrowsError(try RunLock(url: self.lockURL())) { sawBusy = "\($0)".contains("another run") }
            }
        }
        _ = try realRun()
        XCTAssertTrue(sawBusy)
        XCTAssertNoThrow(try RunLock(url: lockURL()), "released after the run")
    }

    func testPreviewsOnlyRunDoesNotLiftTheFirstRunCap() throws {
        makeQuiescent()
        var p = policy()
        p.firstRunMaxBytes = 5_000_000
        _ = try realRun(OffloadRequest(policy: p, tiers: [.previews], dryRun: false))
        XCTAssertTrue(journal().hasCompletedRealRun())
        XCTAssertFalse(journal().hasCompletedRealRun(tier: .attachments))
        XCTAssertEqual(try dryRun(OffloadRequest(policy: p, tiers: [.attachments], dryRun: true)).budgetBytes, 5_000_000)
        let real = try realRun(OffloadRequest(policy: p, tiers: [.attachments], dryRun: false))
        XCTAssertGreaterThan(real.attachmentFiles, 0)
        XCTAssertTrue(journal().hasCompletedRealRun(tier: .attachments))
        XCTAssertEqual(try dryRun(OffloadRequest(policy: p, tiers: [.attachments], dryRun: true)).budgetBytes, p.maxBytesPerRun)
    }

    func testPolicyDecodingIsTolerantOfMissingKeysAndStrictAboutTypes() throws {
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let url = support.appendingPathComponent("config.json")
        try #"{"keepDays": 45}"#.write(to: url, atomically: true, encoding: .utf8)
        let (p, o) = Policy.loadChecked(from: url)
        XCTAssertEqual(o, .loaded)
        XCTAssertEqual(p.keepDays, 45)
        XCTAssertEqual(p.maxBytesPerRun, Policy().maxBytesPerRun)
        XCTAssertEqual(p.pinnedChats, [])
        XCTAssertFalse(p.onlyWhileMessagesClosed)
        XCTAssertEqual(p.notifications, .runsAndProblems)

        try #"{"keepDays": "thirty"}"#.write(to: url, atomically: true, encoding: .utf8)
        let (p2, o2) = Policy.loadChecked(from: url)
        if case .unreadable = o2 {} else { XCTFail("wrong type must be unreadable, got \(o2)") }
        XCTAssertEqual(p2, Policy())

        XCTAssertEqual(Policy.loadChecked(from: support.appendingPathComponent("absent.json")).outcome, .noFile)

        var saved = Policy()
        saved.notifications = .never
        saved.onlyWhileMessagesClosed = true
        saved.pinnedChats = ["iMessage;-;+15550000002"]
        saved.archiveDirectory = "/Volumes/Backup/mss"
        try saved.save(to: url)
        XCTAssertEqual(Policy.loadChecked(from: url).policy, saved)
    }

    func testInvalidPolicyRefusesRealRunsButNotDryRuns() throws {
        makeQuiescent()
        var p = policy()
        p.keepDays = 3
        XCTAssertEqual(p.validationProblems().count, 1)
        let before = fileCount()
        XCTAssertNoThrow(try dryRun(OffloadRequest(policy: p, tiers: [.attachments], dryRun: true)))
        XCTAssertThrowsError(try realRun(OffloadRequest(policy: p, tiers: [.attachments], dryRun: false))) {
            XCTAssertTrue("\($0)".contains("keepDays"), "\($0)")
        }
        XCTAssertEqual(fileCount(), before)
        var future = policy()
        future.configVersion = Policy.currentConfigVersion + 1
        XCTAssertFalse(future.validationProblems().isEmpty)
        var raised = policy()
        raised.maxBytesPerRun = Policy.hardMaxBytesPerRun + 1
        XCTAssertFalse(raised.validationProblems().isEmpty)
        XCTAssertFalse(raised.nonDefaultSafetySettings.isEmpty)
        XCTAssertTrue(Policy().nonDefaultSafetySettings.isEmpty)
    }

    // MARK: archive

    func testArchiveInsideStoreIsRefused() throws {
        makeQuiescent()
        let inside = store.attachmentsDir.appendingPathComponent("archive")
        let before = fileCount()
        let dry = try dryRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: true, archiveDirectory: inside))
        XCTAssertTrue(dry.prerequisiteBlockers.contains { $0.contains("inside the Messages store") }, "\(dry.prerequisiteBlockers)")
        XCTAssertThrowsError(try realRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, archiveDirectory: inside)))
        XCTAssertEqual(fileCount(), before)
        let c = try candidates()[0]
        XCTAssertThrowsError(try Archive.copyVerified(from: c.path, to: URL(fileURLWithPath: c.path))) { XCTAssertTrue("\($0)".contains("itself")) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: c.path))
    }

    func testSameVolumeArchiveIsWarnedNotBlockedAndUnmountedIsBlocked() throws {
        let check = ArchiveLocation.check(archiveRoot, store: store)
        XCTAssertNil(check.blocker)
        XCTAssertTrue(check.reachable)
        XCTAssertEqual(check.sameVolumeAsStore, true)
        XCTAssertNotNil(check.warning)
        let unmounted = ArchiveLocation.check(URL(fileURLWithPath: "/Volumes/mss-no-such-volume-\(UUID().uuidString)/archive"), store: store)
        XCTAssertFalse(unmounted.reachable)
        XCTAssertTrue(unmounted.blocker?.contains("not mounted") == true, "\(unmounted)")
        let prereqs = Prerequisites.evaluate(store: store, db: try ReadOnlyDatabase(path: store.chatDB.path), archiveDirectory: archiveRoot)
        let archiveCheck = prereqs.checks.first { $0.name == "Archive folder" }
        XCTAssertNotNil(archiveCheck)
        XCTAssertNil(archiveCheck?.ok, "same volume is a warning, not a blocker")
        XCTAssertTrue(archiveCheck?.detail.hasPrefix("WARNING") == true)
    }

    func testArchiveFailureMidRunStopsInsteadOfSkipping() throws {
        makeQuiescent()
        let cands = try candidates()
        XCTAssertEqual(cands.count, 6)
        // A directory where the second copy must land makes that copy fail.
        let dst = Archive.destination(for: cands[1].path, store: store, archiveRoot: archiveRoot)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        let r = try realRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, archiveDirectory: archiveRoot))
        XCTAssertEqual(r.attachmentFiles, 1)
        XCTAssertEqual(r.outcome, .problem)
        XCTAssertTrue(r.aborted?.contains("archive failed") == true, "\(String(describing: r.aborted))")
        for c in cands.dropFirst() { XCTAssertTrue(FileManager.default.fileExists(atPath: c.path)) }
        XCTAssertEqual(journal().runSummaries().last?.outcome, .problem)
    }

    func testPrerequisiteRegressionAtCheckpointStopsTheRun() throws {
        makeQuiescent()
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        var req = OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, archiveDirectory: archiveRoot)
        req.checkpointEvery = 2
        Offloader.testHookBeforeUnlink = { _, i in if i == 1 { chmod(self.archiveRoot.path, 0o500) } }
        let r = try realRun(req)
        XCTAssertEqual(r.attachmentFiles, 2)
        XCTAssertEqual(r.outcome, .problem)
        XCTAssertTrue(r.aborted?.contains("prerequisites regressed") == true, "\(String(describing: r.aborted))")
        XCTAssertEqual(journal().runSummaries().last?.outcome, .problem)
    }

    // MARK: selection

    func testMultiChatAttachmentIsKeptWhenAnyChatIsPinnedAndSelectedOnceOtherwise() throws {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        let plain = try CandidateSelector.select(db: db, store: store, policy: policy())
        XCTAssertEqual(plain.candidates.filter { $0.guid == "att-boundary_31_days" }.count, 1)
        var p = policy()
        p.pinnedChats = ["Pinned Chat"]
        let pinned = try CandidateSelector.select(db: db, store: store, policy: p)
        XCTAssertFalse(pinned.candidates.contains { $0.guid == "att-boundary_31_days" })
        XCTAssertEqual(pinned.skippedPinned, 2)
    }

    func testMinimumBytesKeepsSmallFiles() throws {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        var p = policy()
        p.minimumBytes = 2_600_000
        let s = try CandidateSelector.select(db: db, store: store, policy: p)
        XCTAssertEqual(Set(s.candidates.map(\.guid)), ["att-eligible_old_video", "att-eligible_old_jpeg"])
        // Size is checked before the on-disk verification, so the two 900 KB rows
        // that would fail verification (missing, size mismatch) count as small too.
        XCTAssertEqual(s.skippedSmall, 6)
        XCTAssertEqual(s.skippedSmallBytes, 2_500_000 + 2_000_000 + 2_000_000 + 1_000_000 + 900_000 + 900_000)
        p.minimumBytes = -1
        XCTAssertFalse(p.validationProblems().isEmpty)
    }

    func testSavingsEstimatorMatchesSelection() throws {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        let table = try SavingsEstimator.compute(db: db, store: store, policy: policy())
        let plain = try CandidateSelector.select(db: db, store: store, policy: policy())
        let e30 = table.estimate(keepDays: 30, minimumBytes: 0)
        XCTAssertEqual(e30?.files, plain.candidates.count)
        XCTAssertEqual(e30?.bytes, plain.totalBytes)
        XCTAssertEqual(table.estimate(keepDays: 365, minimumBytes: 0)?.files, 5, "the 31-day file drops out")
        XCTAssertEqual(table.estimate(keepDays: 30, minimumBytes: 1_000_000)?.files, 6, "the 1 MB boundary file still counts")
        XCTAssertEqual(table.estimate(keepDays: 30, minimumBytes: 5_000_000)?.files, 1, "only the 40 MB video")
        XCTAssertEqual(table.estimate(keepDays: 730, minimumBytes: 5_000_000)?.files, 1, "only the 1200-day video")
        XCTAssertNil(table.estimate(keepDays: 30, minimumBytes: 2_600_000), "not a grid choice")
        XCTAssertEqual(table.eligibleFiles, 8, "verified on disk regardless of the window: 6 old + 2 recent")
        // Pinned chats and previously removed paths are excluded.
        var pinned = policy()
        pinned.pinnedChats = ["Pinned Chat"]
        XCTAssertEqual(try SavingsEstimator.compute(db: db, store: store, policy: pinned).estimate(keepDays: 30, minimumBytes: 0)?.files, 4)
        let excluded = Set([plain.candidates[0].path])
        XCTAssertEqual(try SavingsEstimator.compute(db: db, store: store, policy: policy(), excludingPaths: excluded).eligibleFiles, 7)
        XCTAssertEqual(SavingsEstimator.label(keepDays: 365), "1 year")
        XCTAssertEqual(SavingsEstimator.label(keepDays: 3650), "10 years")
        XCTAssertEqual(SavingsEstimator.label(minimumBytes: 5_000_000), "5 MB")
        XCTAssertEqual(SavingsEstimator.label(minimumBytes: 500_000_000), "500 MB")
        XCTAssertEqual(SavingsEstimator.label(minimumBytes: 0), "any size")
        XCTAssertEqual(SavingsEstimator.keepDaysChoices, [7, 30, 90, 180, 365, 730, 1095, 1825, 3650])
        XCTAssertEqual(SavingsEstimator.minimumBytesChoices, [0, 1_000_000, 5_000_000, 10_000_000, 100_000_000, 500_000_000])
        XCTAssertTrue(SavingsEstimator.keepDaysChoices.allSatisfy { $0 <= Policy.maximumKeepDays })
        XCTAssertEqual(table.estimate(keepDays: 3650, minimumBytes: 500_000_000)?.files, 0)
    }

    func testUnknownMessageDateIsNeverSelected() throws {
        let s = try CandidateSelector.select(db: ReadOnlyDatabase(path: store.chatDB.path), store: store, policy: policy())
        XCTAssertFalse(s.candidates.contains { $0.guid == "att-date_zero" })
        XCTAssertTrue(s.rejections.contains { $0.reason.contains("unknown") })
    }

    func testAFileRemovedOnceIsNeverRemovedAgain() throws {
        makeQuiescent()
        let r1 = try realRun()
        XCTAssertEqual(r1.attachmentFiles, 6)
        let e = journal().removedEntries()[0]
        try recreate(e.path!, bytes: e.bytes!)
        let r2 = try realRun()
        XCTAssertEqual(r2.attachmentFiles, 0)
        XCTAssertEqual(r2.keptPreviouslyRemoved, 1)
        XCTAssertEqual(r2.keptPreviouslyRemovedBytes, e.bytes)
        XCTAssertTrue(FileManager.default.fileExists(atPath: e.path!))
    }

    func testApprovedRowIDsRestrictARealRunToThePreview() throws {
        makeQuiescent()
        let dry = try dryRun()
        XCTAssertEqual(dry.selectedRowIDs.count, 6)
        XCTAssertEqual(dry.byChat.reduce(0) { $0 + $1.files }, 6)
        let approved = Set(dry.selectedRowIDs.prefix(2))
        let real = try realRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, approvedRowIDs: approved))
        XCTAssertEqual(real.attachmentFiles, 2)
        XCTAssertEqual(Set(journal().removedEntries().compactMap(\.rowID)), approved)
    }

    // MARK: canaries and outcomes

    func testExternalDeletionDuringRunStopsAsPrecaution() throws {
        makeQuiescent()
        var req = OffloadRequest(policy: policy(), tiers: [.attachments, .previews], dryRun: false)
        req.checkpointEvery = 2
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 1 { self.rawExec("INSERT INTO sync_deleted_messages (guid, recordID) VALUES ('external', 'r')") }
        }
        let r = try realRun(req)
        XCTAssertEqual(r.attachmentFiles, 2)
        XCTAssertEqual(r.outcome, .stopped, "\(r.render())")
        XCTAssertTrue(r.canaryViolations.isEmpty)
        XCTAssertFalse(r.externalDeletions.isEmpty)
        XCTAssertNil(r.tiers.first { $0.tier == "previews" }, "later tiers do not run after a stop")
        let h = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertTrue(h.problemRuns.isEmpty)
        XCTAssertNil(h.unacknowledgedProblem)
        XCTAssertTrue(h.notes.contains { $0.contains("precaution") }, "\(h.notes)")
        XCTAssertFalse(journal().hasCompletedRealRun(tier: .attachments))
    }

    func testTouchedRowTombstoneIsAHardProblemUntilAcknowledged() throws {
        makeQuiescent()
        var req = OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false)
        req.checkpointEvery = 2
        var firstRow: Int64?
        Offloader.testHookBeforeUnlink = { c, i in
            if i == 0 { firstRow = c.rowID }
            if i == 1 {
                self.rawExec("INSERT INTO sync_deleted_attachments (guid, recordID) VALUES ('ours', 'r'); UPDATE attachment SET ck_sync_state = 2 WHERE ROWID = \(firstRow!)")
            }
        }
        let r = try realRun(req)
        XCTAssertEqual(r.attachmentFiles, 2)
        XCTAssertEqual(r.outcome, .problem)
        XCTAssertFalse(r.canaryViolations.isEmpty)
        let h = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertNotNil(h.unacknowledgedProblem)
        XCTAssertFalse(h.isHealthy)
        try journal().appendAcknowledgement(runID: r.runID)
        let h2 = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertNil(h2.unacknowledgedProblem)
        XCTAssertFalse(h2.violations.isEmpty, "the row that left state 1 is still reported")
    }

    func testCancelStopsBetweenFilesAndStillWritesRunEnd() throws {
        makeQuiescent()
        var polls = 0
        let r = try realRun(OffloadRequest(policy: policy(), tiers: [.attachments, .previews], dryRun: false), isCancelled: { polls += 1; return polls > 2 })
        XCTAssertTrue(r.cancelled)
        XCTAssertEqual(r.outcome, .cancelled)
        XCTAssertEqual(r.attachmentFiles, 2)
        XCTAssertNil(r.tiers.first { $0.tier == "previews" })
        let entries = journal().readAll()
        XCTAssertTrue(entries.contains { $0.action == "cancel" })
        XCTAssertEqual(entries.last?.action, "run-end")
        XCTAssertTrue(entries.last?.note?.hasPrefix("cancelled") == true)
        XCTAssertFalse(journal().hasCompletedRealRun())
        let h = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertTrue(h.problemRuns.isEmpty)
        XCTAssertTrue(h.isHealthy)
    }

    func testCrashMidRunLeavesADanglingRunThatHealthFlags() throws {
        makeQuiescent()
        struct Boom: Error {}
        Offloader.testHookBeforeUnlink = { _, i in if i == 2 { throw Boom() } }
        XCTAssertThrowsError(try realRun())
        let h = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertFalse(h.runInProgress, "the lock is released when the run throws")
        XCTAssertNotNil(h.danglingRun)
        XCTAssertNotNil(h.unacknowledgedProblem)
        XCTAssertFalse(h.isHealthy)
        try journal().appendAcknowledgement(runID: h.danglingRun!.runID)
        XCTAssertNil(HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL()).unacknowledgedProblem)
    }

    func testRunInProgressIsNotADanglingRun() throws {
        makeQuiescent()
        var seenInProgress = false
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 1 {
                let h = HealthReport.compute(store: self.store, policy: self.policy(), journal: self.journal(), lockURL: self.lockURL())
                seenInProgress = h.runInProgress && h.danglingRun == nil
            }
        }
        _ = try realRun()
        XCTAssertTrue(seenInProgress)
    }

    // MARK: health and restore

    func testHealthReportCountsRemovedAndReappearedFiles() throws {
        makeQuiescent()
        _ = try realRun()
        let e = journal().removedEntries()[0]
        try recreate(e.path!, bytes: e.bytes!)
        let h = HealthReport.compute(store: store, policy: policy(), journal: journal(), lockURL: lockURL())
        XCTAssertEqual(h.filesRemoved, 6)
        XCTAssertEqual(h.filesReappeared, 1)
        XCTAssertTrue(h.isHealthy, "\(h.violations)")
        XCTAssertEqual(h.lastRealRun?.outcome, .ok)
        XCTAssertEqual(h.lastRealRun?.attachmentsRemoved, 6)
        XCTAssertEqual(h.realRuns, 1)
        XCTAssertFalse(h.render().isEmpty)
    }

    func testRestorerRoundTripIsByteIdenticalAndRestoredFilesStayLocal() throws {
        makeQuiescent()
        let r = try realRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, archiveDirectory: archiveRoot))
        XCTAssertEqual(r.archived, 6)
        let plan = Restorer.plan(store: store, journal: journal())
        XCTAssertEqual(plan.restorable.count, 6)
        XCTAssertEqual(plan.present, 0)
        XCTAssertEqual(plan.archiveMissing.count, 0)
        var ticks = 0
        let res = try Restorer.execute(plan: plan, store: store, journal: journal(), progress: { _, _ in ticks += 1 })
        XCTAssertEqual(res.restored, 6)
        XCTAssertEqual(ticks, 6)
        XCTAssertTrue(res.errors.isEmpty, "\(res.errors)")
        for e in plan.restorable { XCTAssertTrue(try Archive.filesAreIdentical(e.path!, e.archivePath!)) }
        XCTAssertEqual(journal().readAll().filter { $0.action == "restore" }.count, 6)
        let plan2 = Restorer.plan(store: store, journal: journal())
        XCTAssertEqual(plan2.restorable.count, 0)
        XCTAssertEqual(plan2.present, 6)
        let r2 = try realRun()
        XCTAssertEqual(r2.attachmentFiles, 0)
        XCTAssertEqual(r2.keptPreviouslyRemoved, 6)
    }

    // MARK: progress, origin, debug guard

    func testProgressReportsPhasesAndTotals() throws {
        var events: [OffloadProgress] = []
        _ = try Offloader.run(store: store, request: OffloadRequest(policy: policy(), tiers: [.attachments, .previews], dryRun: true),
                              journal: journal(), lockURL: lockURL(), progress: { events.append($0) })
        XCTAssertEqual(events.first?.phase, .preparing)
        XCTAssertEqual(events.first { $0.phase == .selecting }?.filesTotal, 6)
        XCTAssertTrue(events.contains { $0.phase == .previews })
        XCTAssertEqual(events.last?.phase, .done)
        XCTAssertEqual(events.last?.filesDone, events.last?.filesTotal)
    }

    func testOriginIsJournaledAndFilterable() throws {
        makeQuiescent()
        _ = try realRun(OffloadRequest(policy: policy(), tiers: [.attachments], dryRun: false, origin: "app-manual"))
        XCTAssertTrue(journal().hasCompletedRealRun(tier: .attachments, origin: "app-manual"))
        XCTAssertFalse(journal().hasCompletedRealRun(origin: "cli"))
        XCTAssertEqual(journal().runSummaries().last?.origin, "app-manual")
        XCTAssertEqual(journal().runSummaries().last?.tiers, ["attachments"])
    }

    func testCloudKitSyncStateIsReadOnlyAndNeverCrashes() throws {
        // Reads IMCore's view of the sync state; never requests a sync in tests.
        let s = CloudKitSync.state()
        XCTAssertTrue(s.available, "IMCore should load on macOS")
        XCTAssertNotNil(s.syncingEnabled)
        XCTAssertFalse(CloudKitSync.manualInstructions.isEmpty)
    }

    func testDebugBuildsRefuseTheLiveStoreWithoutOptIn() throws {
        XCTAssertThrowsError(try MessagesStore.liveChecked(environment: [:]))
        XCTAssertEqual(try MessagesStore.liveChecked(environment: ["MSS_ALLOW_REAL_STORE": "1"]).root, MessagesStore.live.root)
        XCTAssertEqual(store.configURL, store.supportDirectory.appendingPathComponent("config.json"))
        XCTAssertNotEqual(store.configURL, Policy.configURL)
    }
}
