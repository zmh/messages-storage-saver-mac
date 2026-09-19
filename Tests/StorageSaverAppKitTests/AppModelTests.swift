import Foundation
import SQLite3
import XCTest
@testable import StorageSaverCore
@testable import StorageSaverAppKit

// MARK: - Fakes

final class FakeMessagesApp: MessagesAppObserving {
    var isRunning: Bool
    var launchDate: Date?
    var relaunches = 0
    init(isRunning: Bool, launchDate: Date? = nil) { self.isRunning = isRunning; self.launchDate = launchDate }
    func relaunch() async { relaunches += 1; launchDate = Date(); isRunning = true }
}

final class FakeNotifier: Notifying {
    var posted: [(title: String, body: String, isProblem: Bool)] = []
    func notify(title: String, body: String, isProblem: Bool) { posted.append((title, body, isProblem)) }
}

final class FakeLoginItem: LoginItemManaging {
    var status: LoginItemStatus = .disabled
    func set(enabled: Bool) throws { status = enabled ? .enabled : .disabled }
    func openSystemSettings() {}
}

final class FakeScheduler: Scheduling {
    var tick: (@MainActor () async -> Void)?
    func schedule(_ tick: @escaping @MainActor () async -> Void) { self.tick = tick }
    func invalidate() { tick = nil }
}

final class Clock {
    var now: Date
    init(_ now: Date = Date()) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

// MARK: - Tests

@MainActor
final class AppModelTests: XCTestCase {
    static let packageRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { url = url.deletingLastPathComponent() }
        return url
    }()

    var store: MessagesStore!
    var messages: FakeMessagesApp!
    var notifier: FakeNotifier!
    var loginItem: FakeLoginItem!
    var scheduler: FakeScheduler!
    var clock: Clock!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mss-app-\(UUID().uuidString)")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [Self.packageRoot.appendingPathComponent("scripts/make-fixture.py").path, dir.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        store = MessagesStore(root: dir)
        messages = FakeMessagesApp(isRunning: false)
        notifier = FakeNotifier()
        loginItem = FakeLoginItem()
        scheduler = FakeScheduler()
        clock = Clock()
        makeQuiescent()
    }

    override func tearDownWithError() throws {
        Offloader.testHookBeforeUnlink = nil
    }

    func rawExec(_ sql: String) {
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(store.chatDB.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, sql, nil, nil, nil), SQLITE_OK, sql)
        sqlite3_close(raw)
    }

    func makeQuiescent() { rawExec("UPDATE attachment SET transfer_state = -1 WHERE guid = 'att-transfer_in_progress'") }

    func writeConfig(_ change: (inout Policy) -> Void = { _ in }) throws {
        var p = Policy()
        p.firstRunMaxBytes = 5_000_000
        change(&p)
        try p.save(to: store.configURL)
    }

    func makeModel(storeReady: Bool = true) -> AppModel {
        let m = AppModel(storeState: storeReady ? .ready(store) : .unavailable("test"), configURL: store.configURL, messagesApp: messages,
                         notifier: notifier, loginItem: loginItem, scheduler: scheduler, now: { self.clock.now })
        m.followUpDelay = 0
        m.checkpointEvery = 2
        return m
    }

    func fileCount() -> Int { Analyzer.walkFiles(store.attachmentsDir).files.count }

    /// Preview then confirm through the model, like a user clicking twice.
    @discardableResult
    func manualRun(_ m: AppModel, limitBytes: Int64? = nil) async -> OffloadResult? {
        await m.prepareOptimize(limitBytes: limitBytes)
        guard let token = m.confirmation else { XCTFail("no confirmation token: \(m.lastError ?? "")"); return nil }
        let started = await m.confirmOptimize(token)
        XCTAssertTrue(started, m.lastError ?? "")
        return m.lastResult
    }

    // MARK: gate table

    func testRunGateOrderAndReasons() {
        let launched = Date(timeIntervalSince1970: 1_000_000)
        var i = RunGateInputs(launchedAt: launched, now: launched.addingTimeInterval(3600))
        i.automaticRuns = true
        i.hasPriorAppRun = true
        XCTAssertEqual(RunGate.decide(i), .run)

        var t = i; t.storeReady = false; XCTAssertEqual(RunGate.decide(t), .skip(.storeUnavailable))
        t = i; t.configUnreadable = true; XCTAssertEqual(RunGate.decide(t), .skip(.configUnreadable))
        t = i; t.policyValid = false; XCTAssertEqual(RunGate.decide(t), .skip(.policyInvalid))
        t = i; t.automaticRuns = false; XCTAssertEqual(RunGate.decide(t), .skip(.automaticOff))
        t = i; t.busy = true; XCTAssertEqual(RunGate.decide(t), .skip(.busy))
        t = i; t.unacknowledgedProblem = true; XCTAssertEqual(RunGate.decide(t), .skip(.problemUnacknowledged))
        t = i; t.danglingRun = true; XCTAssertEqual(RunGate.decide(t), .skip(.danglingRun))
        t = i; t.hasPriorAppRun = false; XCTAssertEqual(RunGate.decide(t), .skip(.noPriorAppRun))
        t = i; t.keepMessagesSet = true; XCTAssertEqual(RunGate.decide(t), .skip(.keepMessagesSet))
        t = i; t.prerequisiteBlockers = ["x"]; XCTAssertEqual(RunGate.decide(t), .skip(.prerequisites))
        t = i; t.messagesRunning = true; XCTAssertEqual(RunGate.decide(t), .run, "Messages open is fine unless the preference says otherwise")
        t.onlyWhileMessagesClosed = true; XCTAssertEqual(RunGate.decide(t), .skip(.messagesRunning))
        t = i; t.now = launched.addingTimeInterval(60); XCTAssertEqual(RunGate.decide(t), .skip(.tooSoonAfterLaunch))
        t = i; t.lastSettingsChange = t.now.addingTimeInterval(-60); XCTAssertEqual(RunGate.decide(t), .skip(.tooSoonAfterSettingsChange))
        t = i; t.lastAutomaticRunEnded = t.now.addingTimeInterval(-3600); XCTAssertEqual(RunGate.decide(t), .skip(.ranRecently))
        t = i; t.lastAutomaticRunEnded = t.now.addingTimeInterval(-6 * 3600); XCTAssertEqual(RunGate.decide(t), .run)
        // A problem outranks everything the user could have set.
        t = i; t.unacknowledgedProblem = true; t.messagesRunning = true; t.onlyWhileMessagesClosed = true
        XCTAssertEqual(RunGate.decide(t), .skip(.problemUnacknowledged))
    }

    // MARK: onboarding, config, first run

    func testNoConfigMeansOnboardingAndDryPreviewStillWorks() async throws {
        let m = makeModel()
        XCTAssertTrue(m.needsOnboarding)
        XCTAssertEqual(m.configOutcome, .noFile)
        await m.prepareOptimize()
        XCTAssertEqual(m.preview?.attachmentFiles, 6)
        XCTAssertEqual(m.preview?.budgetBytes, Policy().firstRunMaxBytes, "first app run is capped")
        try m.update { $0.keepDays = 90 }
        XCTAssertFalse(m.needsOnboarding)
        XCTAssertEqual(Policy.loadChecked(from: store.configURL).policy.keepDays, 90)
    }

    func testFirstAppRunIsCappedEvenAfterACLIRun() async throws {
        try writeConfig()
        // A CLI run already proved the mechanism on this store.
        var p = Policy(); p.firstRunMaxBytes = 1_000_000_000
        _ = try Offloader.run(store: store, request: OffloadRequest(policy: p, tiers: [.attachments], dryRun: false, origin: "cli", approvedRowIDs: []), journal: Journal(url: store.journalURL))
        let m = makeModel()
        XCTAssertFalse(m.appHasCompletedRealRun)
        await m.prepareOptimize()
        XCTAssertEqual(m.preview?.budgetBytes, 5_000_000)
        let r = await manualRun(m)
        XCTAssertEqual(r?.outcome, .ok)
        XCTAssertGreaterThan(r?.attachmentFiles ?? 0, 0)
        XCTAssertLessThanOrEqual(r?.attachmentBytes ?? 0, 5_000_000)
        XCTAssertTrue(m.appHasCompletedRealRun)
        XCTAssertNil(m.appBudgetBytes, "later app runs use the policy cap")
    }

    func testUnreadableConfigBlocksRealRunsAndIsBackedUpOnSave() async throws {
        try FileManager.default.createDirectory(at: store.supportDirectory, withIntermediateDirectories: true)
        try #"{"keepDays": "thirty"}"#.write(to: store.configURL, atomically: true, encoding: .utf8)
        let m = makeModel()
        XCTAssertTrue(m.configIsUnreadable)
        await m.prepareOptimize()
        XCTAssertNotNil(m.confirmation, "previews are harmless")
        let before = fileCount()
        let started = await m.confirmOptimize(m.confirmation!)
        XCTAssertFalse(started)
        XCTAssertTrue(m.lastError?.contains("unreadable") == true, m.lastError ?? "")
        XCTAssertEqual(fileCount(), before)
        XCTAssertFalse(m.setAutomaticRuns(true))
        try m.update { $0.keepDays = 60 }
        XCTAssertEqual(m.configOutcome, .loaded)
        let backups = try FileManager.default.contentsOfDirectory(atPath: store.supportDirectory.path).filter { $0.contains("unreadable-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(Policy.loadChecked(from: store.configURL).policy.keepDays, 60)
    }

    func testUpdateRejectsOutOfRangeSettings() throws {
        try writeConfig()
        let m = makeModel()
        XCTAssertThrowsError(try m.update { $0.keepDays = 2 })
        XCTAssertEqual(m.policy.keepDays, 30)
        XCTAssertEqual(Policy.loadChecked(from: store.configURL).policy.keepDays, 30)
    }

    // MARK: confirm gate

    func testConfirmRequiresAFreshMatchingToken() async throws {
        try writeConfig()
        let m = makeModel()
        await m.prepareOptimize()
        let token = m.confirmation!
        let before = fileCount()
        // Stale.
        clock.advance(11 * 60)
        let staleStarted = await m.confirmOptimize(token)
        XCTAssertFalse(staleStarted)
        XCTAssertTrue(m.lastError?.contains("older than 10 minutes") == true)
        XCTAssertEqual(fileCount(), before)
        // Foreign token.
        await m.prepareOptimize()
        let fresh = m.confirmation!
        let foreign = AppModel.RunConfirmation(previewRunID: "x", rowIDs: fresh.rowIDs, files: fresh.files, bytes: fresh.bytes,
                                               clearThumbnails: false, limitBytes: fresh.limitBytes, createdAt: clock.now)
        let foreignStarted = await m.confirmOptimize(foreign)
        XCTAssertFalse(foreignStarted)
        XCTAssertEqual(fileCount(), before)
        // Real one.
        let freshStarted = await m.confirmOptimize(fresh)
        XCTAssertTrue(freshStarted)
        XCTAssertEqual(m.lastResult?.outcome, .ok)
        XCTAssertLessThan(fileCount(), before)
        XCTAssertNil(m.confirmation, "a token is single use")
        XCTAssertEqual(Set(Journal(url: store.journalURL).removedEntries().compactMap(\.rowID)).isSubset(of: fresh.rowIDs), true)
    }

    func testAppNeverRequestsSidecarsEvenIfConfigEnablesThem() async throws {
        try writeConfig { $0.tiers.liveSidecars = true }
        let m = makeModel()
        await m.prepareOptimize(clearThumbnails: true)
        XCTAssertEqual(Set(m.preview!.tiers.map(\.tier)), ["attachments", "previews"])
        await m.refresh()
        XCTAssertTrue(m.health!.configWarnings.contains { $0.contains("sidecar") })
    }

    // MARK: automatic runs

    func testAutomaticCannotBeEnabledBeforeAManualRun() async throws {
        try writeConfig()
        let m = makeModel()
        await m.refresh()
        XCTAssertFalse(m.setAutomaticRuns(true))
        XCTAssertFalse(m.policy.automaticRuns)
        XCTAssertFalse(Policy.loadChecked(from: store.configURL).policy.automaticRuns)
        await manualRun(m)
        XCTAssertTrue(m.setAutomaticRuns(true))
        XCTAssertTrue(Policy.loadChecked(from: store.configURL).policy.automaticRuns)
    }

    func testScheduledTickRespectsMessagesPreferenceAndTimers() async throws {
        try writeConfig()
        let m = makeModel()
        await manualRun(m, limitBytes: 5_000_000)
        XCTAssertTrue(m.setAutomaticRuns(true))
        let realRunsBefore = Journal(url: store.journalURL).runSummaries().filter { !$0.dryRun }.count

        await m.runScheduledTick()
        XCTAssertEqual(m.lastSkipReason, .tooSoonAfterLaunch)
        clock.advance(11 * 60)
        await m.runScheduledTick()
        XCTAssertEqual(m.lastSkipReason, .tooSoonAfterSettingsChange)
        clock.advance(16 * 60)

        try m.update { $0.onlyWhileMessagesClosed = true }
        clock.advance(16 * 60)
        messages.isRunning = true
        await m.runScheduledTick()
        XCTAssertEqual(m.lastSkipReason, .messagesRunning)
        XCTAssertEqual(Journal(url: store.journalURL).runSummaries().filter { !$0.dryRun }.count, realRunsBefore)

        messages.isRunning = false
        await m.runScheduledTick()
        XCTAssertNil(m.lastSkipReason)
        let runs = Journal(url: store.journalURL).runSummaries().filter { !$0.dryRun }
        XCTAssertEqual(runs.count, realRunsBefore + 1)
        XCTAssertEqual(runs.last?.origin, AppModel.automaticOrigin)
        XCTAssertEqual(runs.last?.outcome, .ok)

        await m.runScheduledTick()
        XCTAssertEqual(m.lastSkipReason, .ranRecently)
    }

    func testKillSwitchTurnsAutomationOffUntilAcknowledgedAndNeverBackOnByItself() async throws {
        try writeConfig()
        let m = makeModel()
        await manualRun(m, limitBytes: 3_000_000)
        XCTAssertTrue(m.setAutomaticRuns(true))
        // A touched row loses its synced state mid-run: hard canary.
        var firstRow: Int64?
        Offloader.testHookBeforeUnlink = { c, i in
            if i == 0 { firstRow = c.rowID }
            if i == 1 { self.rawExec("INSERT INTO sync_deleted_attachments (guid, recordID) VALUES ('ours', 'r'); UPDATE attachment SET ck_sync_state = 2 WHERE ROWID = \(firstRow!)") }
        }
        await m.prepareOptimize()
        let token = m.confirmation!
        let started = await m.confirmOptimize(token)
        XCTAssertTrue(started)
        Offloader.testHookBeforeUnlink = nil
        XCTAssertEqual(m.lastResult?.outcome, .problem)
        XCTAssertFalse(m.policy.automaticRuns)
        XCTAssertFalse(Policy.loadChecked(from: store.configURL).policy.automaticRuns)
        XCTAssertNotNil(m.problem)
        XCTAssertTrue(notifier.posted.contains { $0.isProblem })
        XCTAssertEqual(m.autoRunDecision(), .skip(.automaticOff))
        XCTAssertFalse(m.setAutomaticRuns(true), "blocked while unacknowledged")
        await m.acknowledgeProblem()
        XCTAssertNil(m.problem)
        XCTAssertFalse(m.policy.automaticRuns, "acknowledging never re-enables automation")
    }

    func testExternalDeletionStopIsNotAKillSwitch() async throws {
        try writeConfig()
        let m = makeModel()
        await manualRun(m, limitBytes: 3_000_000)
        XCTAssertTrue(m.setAutomaticRuns(true))
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 0 { self.rawExec("INSERT INTO sync_deleted_messages (guid, recordID) VALUES ('external', 'r')") }
        }
        clock.advance(30 * 60)
        await m.runScheduledTick()
        Offloader.testHookBeforeUnlink = nil
        XCTAssertEqual(m.lastResult?.outcome, .stopped)
        XCTAssertTrue(m.policy.automaticRuns, "a precautionary stop keeps automation on")
        XCTAssertNil(m.problem)
        XCTAssertTrue(notifier.posted.contains { $0.title.contains("precaution") })
    }

    func testThrownRunDisablesAutomationAndReportsError() async throws {
        try writeConfig()
        let m = makeModel()
        await manualRun(m, limitBytes: 3_000_000)
        XCTAssertTrue(m.setAutomaticRuns(true))
        struct Boom: Error {}
        Offloader.testHookBeforeUnlink = { _, i in if i == 1 { throw Boom() } }
        clock.advance(30 * 60)
        await m.runScheduledTick()
        Offloader.testHookBeforeUnlink = nil
        XCTAssertNotNil(m.lastError)
        XCTAssertFalse(m.policy.automaticRuns)
        XCTAssertNotNil(m.health?.danglingRun, "error=\(m.lastError ?? "") skip=\(String(describing: m.lastSkipReason)) runs=\(Journal(url: store.journalURL).runSummaries().map { "\($0.runID):\($0.outcome)" })")
        XCTAssertEqual(m.autoRunDecision(), .skip(.automaticOff))
    }

    // MARK: Messages relaunch, cancel, restore, login item

    func testRelaunchFlagFollowsMessagesLaunchDate() async throws {
        try writeConfig()
        messages.isRunning = true
        messages.launchDate = clock.now.addingTimeInterval(-3600)
        let m = makeModel()
        await manualRun(m, limitBytes: 3_000_000)
        XCTAssertTrue(m.needsMessagesRelaunch)
        XCTAssertTrue(notifier.posted.last?.body.contains("Relaunch Messages") == true)
        messages.launchDate = Date().addingTimeInterval(60)
        m.updateRelaunchFlag()
        XCTAssertFalse(m.needsMessagesRelaunch)
        // Not running at all: nothing to relaunch.
        messages.isRunning = false
        messages.launchDate = nil
        let m2 = makeModel()
        await manualRun(m2, limitBytes: 3_000_000)
        XCTAssertFalse(m2.needsMessagesRelaunch)
    }

    func testCancelFromTheModelEndsTheRunCleanly() async throws {
        try writeConfig { $0.firstRunMaxBytes = 1_000_000_000 }
        let m = makeModel()
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 1 { Task { @MainActor in m.cancelRun() }; Thread.sleep(forTimeInterval: 0.3) }
        }
        let r = await manualRun(m)
        XCTAssertEqual(r?.outcome, .cancelled)
        XCTAssertEqual(m.activity, .idle)
        XCTAssertEqual(Journal(url: store.journalURL).runSummaries().last?.outcome, .cancelled)
        XCTAssertTrue(m.health?.isHealthy == true)
    }

    func testAppIgnoresArchiveDirectoryInConfig() async throws {
        let archive = store.root.deletingLastPathComponent().appendingPathComponent("mss-app-archive-\(UUID().uuidString)")
        try writeConfig { $0.archiveDirectory = archive.path }
        let m = makeModel()
        let r = await manualRun(m)
        XCTAssertGreaterThan(r?.attachmentFiles ?? 0, 0)
        XCTAssertEqual(r?.archived, 0, "the app relies on iCloud and never archives")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertNil(Journal(url: store.journalURL).removedEntries().first?.archivePath)
    }

    func testSavingsEstimatesFollowTheRule() async throws {
        // A first-run cap above 40 MB so the video fits the preview budget.
        try writeConfig { $0.keepDays = 365; $0.minimumBytes = 5_000_000; $0.firstRunMaxBytes = 1_000_000_000 }
        let m = makeModel()
        await m.refresh(includeAnalysis: true)
        XCTAssertNotNil(m.savings)
        XCTAssertEqual(m.currentEstimate?.files, 1, "only the 1200-day 40 MB video")
        XCTAssertEqual(m.savings?.estimate(keepDays: 30, minimumBytes: 0)?.files, 6)
        XCTAssertTrue(m.ruleLine.contains("larger than 5 MB"))
        XCTAssertTrue(m.ruleLine.contains("older than 1 year"))
        // The preview honours the same rule.
        await m.prepareOptimize(limitBytes: 1_000_000_000)
        XCTAssertEqual(m.preview?.attachmentFiles, 1)
        // Changing pins re-estimates.
        try m.update { $0.pinnedChats = ["Old Friend"]; $0.keepDays = 30; $0.minimumBytes = 0 }
        await m.loadSavings(force: true)
        XCTAssertEqual(m.currentEstimate?.files, 2, "pinned chat 1 holds four of the six")
    }

    func testLoginItemAndNotificationsPreference() async throws {
        try writeConfig()
        let m = makeModel()
        m.setStartAtLogin(true)
        XCTAssertEqual(m.loginItemStatus, .enabled)
        try m.update { $0.notifications = .never }
        await manualRun(m)
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testOnDemandDefaultsAndQuitOnClose() async throws {
        try writeConfig()
        let m = makeModel()
        XCTAssertFalse(m.policy.automaticRuns, "off by default")
        XCTAssertEqual(m.loginItemStatus, .disabled, "start at login is opt-in")
        XCTAssertTrue(m.shouldQuitWhenLastWindowCloses, "closing the window quits an on-demand app")
        XCTAssertEqual(m.selectedPane, .overview)

        // While a run is going, the app must outlive its windows.
        var duringRun: Bool?
        Offloader.testHookBeforeUnlink = { _, i in
            if i == 0 { DispatchQueue.main.sync { MainActor.assumeIsolated { duringRun = m.shouldQuitWhenLastWindowCloses } } }
        }
        await manualRun(m, limitBytes: 3_000_000)
        Offloader.testHookBeforeUnlink = nil
        XCTAssertEqual(duringRun, false)
        XCTAssertTrue(m.shouldQuitWhenLastWindowCloses)

        // Automatic runs keep it resident, but never flip the login item by themselves.
        XCTAssertTrue(m.setAutomaticRuns(true))
        XCTAssertFalse(m.shouldQuitWhenLastWindowCloses)
        XCTAssertEqual(m.loginItemStatus, .disabled)
        XCTAssertTrue(m.setAutomaticRuns(false))
        XCTAssertTrue(m.shouldQuitWhenLastWindowCloses)
    }

    func testStoreUnavailableBlocksEverything() async {
        let m = makeModel(storeReady: false)
        await m.prepareOptimize()
        XCTAssertNil(m.confirmation)
        XCTAssertEqual(m.autoRunDecision(), .skip(.storeUnavailable))
        XCTAssertFalse(m.setAutomaticRuns(true))
        XCTAssertTrue(m.healthLine.contains("unavailable"))
    }
}
