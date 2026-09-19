import AppKit
import Foundation
import StorageSaverAutomation
import StorageSaverCore

public enum ConfigError: Error, CustomStringConvertible {
    case invalid([String])
    case storeUnavailable
    public var description: String {
        switch self {
        case .invalid(let p): return p.joined(separator: "; ")
        case .storeUnavailable: return "the Messages store is not available"
        }
    }
}

/// Everything the menu, windows and scheduler read and call. Owns the store,
/// the policy, the run state, and the gates that keep unattended runs safe.
/// All blocking core calls run on background tasks; the model itself lives
/// on the main actor.
///
/// The app relies on iCloud as the other copy: it never archives (the CLI's
/// `--archive-to` remains for experiments) and ignores `archiveDirectory`.
@MainActor
public final class AppModel: ObservableObject {
    public enum StoreState: Equatable {
        case ready(MessagesStore)
        case unavailable(String)
        public var store: MessagesStore? { if case .ready(let s) = self { return s }; return nil }
    }

    public enum Activity: Equatable {
        case idle
        case refreshing
        case previewing
        case running(OffloadProgress)
        public var isIdle: Bool { self == .idle || self == .refreshing }
        public var isRunning: Bool { if case .running = self { return true }; return false }
    }

    /// Proof that the user saw a preview of exactly these rows moments ago.
    public struct RunConfirmation: Equatable {
        public let previewRunID: String
        public let rowIDs: Set<Int64>
        public let files: Int
        public let bytes: Int64
        public let clearThumbnails: Bool
        public let limitBytes: Int64
        public let createdAt: Date
        public static let lifetime: TimeInterval = 10 * 60
    }

    /// Sections of the main window.
    public enum Pane: String, CaseIterable, Identifiable {
        case overview, settings, health, help
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .overview: return "Overview"
            case .settings: return "Settings"
            case .health: return "Health"
            case .help: return "Help"
            }
        }
        public var symbol: String {
            switch self {
            case .overview: return "internaldrive"
            case .settings: return "slider.horizontal.3"
            case .health: return "heart.text.square"
            case .help: return "questionmark.circle"
            }
        }
    }

    public static let manualOrigin = "app-manual"
    public static let automaticOrigin = "app-auto"
    public static let analysisMaxAge: TimeInterval = 6 * 3600
    public static let mainWindowID = "main"
    public static let optimizeWindowID = "optimize"

    @Published public internal(set) var policy: Policy
    @Published public internal(set) var configOutcome: Policy.LoadOutcome
    @Published public internal(set) var storeState: StoreState
    @Published public internal(set) var activity: Activity = .idle
    @Published public internal(set) var prerequisites: Prerequisites?
    @Published public internal(set) var health: HealthReport?
    @Published public internal(set) var analysis: AnalysisReport?
    @Published public internal(set) var analysisAt: Date?
    /// What each keep window / size threshold would offload right now.
    @Published public internal(set) var savings: SavingsTable?
    @Published public internal(set) var savingsLoading = false
    /// Set when pins change; the next `loadSavings()` recomputes.
    var savingsStale = false
    @Published public internal(set) var preview: OffloadResult?
    @Published public internal(set) var confirmation: RunConfirmation?
    @Published public internal(set) var lastResult: OffloadResult?
    @Published public internal(set) var lastError: String?
    @Published public internal(set) var lastSkipReason: SkipReason?
    @Published public internal(set) var needsMessagesRelaunch = false
    @Published public internal(set) var chats: [ChatSummary] = []
    @Published public internal(set) var loginItemStatus: LoginItemStatus
    @Published public internal(set) var lastHealthCheckAt: Date?
    @Published public internal(set) var syncRequestInProgress = false
    @Published public internal(set) var syncRequestStatus: String?
    @Published public var selectedPane: Pane = .overview
    /// Set once by the menu-bar label view (it exists at launch) so the
    /// delegate and menu can open SwiftUI windows.
    public var windowOpener: ((String) -> Void)?
    public private(set) var launchedAsLoginItem = false

    public let configURL: URL
    let messagesApp: MessagesAppObserving
    let notifier: Notifying
    let loginItem: LoginItemManaging
    let scheduler: Scheduling
    let now: () -> Date
    public let launchedAt: Date
    /// Delay before the follow-up health check after a run (1 h; tests shorten it).
    public var followUpDelay: TimeInterval = 3600
    /// Files between mid-run canary/prerequisite checkpoints (tests lower it).
    public var checkpointEvery = 250
    var lastSettingsChange: Date?
    var runTask: Task<OffloadResult, Error>?
    /// Set when a run removed attachments while Messages was open; cleared once
    /// Messages has been relaunched since.
    var relaunchNeededSince: Date?

    public init(storeState: StoreState, configURL: URL, messagesApp: MessagesAppObserving, notifier: Notifying,
                loginItem: LoginItemManaging, scheduler: Scheduling, now: @escaping () -> Date = Date.init) {
        self.storeState = storeState
        self.configURL = configURL
        self.messagesApp = messagesApp
        self.notifier = notifier
        self.loginItem = loginItem
        self.scheduler = scheduler
        self.now = now
        self.launchedAt = now()
        let (p, outcome) = Policy.loadChecked(from: configURL)
        self.policy = p
        self.configOutcome = outcome
        self.loginItemStatus = loginItem.status
    }

    /// The real app: store from the environment, real Messages/notification/login-item/scheduler bridges.
    public static func live() -> AppModel {
        let storeState: StoreState
        var configURL = Policy.configURL
        do {
            let store = try StoreResolver.resolve()
            storeState = .ready(store)
            configURL = store.configURL
        } catch {
            storeState = .unavailable("\(error)")
        }
        let m = AppModel(storeState: storeState, configURL: configURL, messagesApp: MessagesAppState(), notifier: UserNotifier(),
                         loginItem: LoginItem(), scheduler: BackgroundScheduler())
        // `MSS_APP_PANE=settings` opens the window on that pane (layout smoke tests).
        if let pane = ProcessInfo.processInfo.environment["MSS_APP_PANE"].flatMap(Pane.init(rawValue:)) { m.selectedPane = pane }
        return m
    }

    // MARK: - Derived state

    public var store: MessagesStore? { storeState.store }
    /// Running against a fixture (MSS_APP_STORE_DIR), not ~/Library/Messages.
    public var isTestStore: Bool { store.map { !$0.isLive } ?? false }
    public var testStoreBanner: String? { isTestStore ? "TEST STORE: \(store!.root.path) (not your Messages)" : nil }
    public var needsOnboarding: Bool { configOutcome == .noFile }
    public var configIsUnreadable: Bool { if case .unreadable = configOutcome { return true }; return false }
    public var problem: HealthReport.Problem? { health?.unacknowledgedProblem }
    public var keepMessagesIsSet: Bool { prerequisites?.keepMessagesIsSet ?? false }
    public var policyProblems: [String] { policy.validationProblems(volumeCapacityBytes: store.flatMap { Prerequisites.volumeCapacity(at: $0.root) }) }
    var journal: Journal? { store.map { Journal(url: $0.journalURL) } }

    /// The estimate for the current window and size threshold.
    public var currentEstimate: SavingsEstimate? { savings?.estimate(keepDays: policy.keepDays, minimumBytes: policy.minimumBytes) }

    /// The app caps its own first attachments run at the first-run budget even
    /// if the CLI already ran (the CLI history proves the mechanism, not this UI).
    public var appHasCompletedRealRun: Bool {
        guard let journal else { return false }
        return journal.hasCompletedRealRun(tier: .attachments, origin: Self.manualOrigin) || journal.hasCompletedRealRun(tier: .attachments, origin: Self.automaticOrigin)
    }

    public var appBudgetBytes: Int64? {
        appHasCompletedRealRun ? nil : min(policy.firstRunMaxBytes, policy.maxBytesPerRun)
    }

    public var lastAutomaticRunEnded: Date? {
        health?.recentRuns.last { !$0.dryRun && $0.origin == Self.automaticOrigin && $0.ended != nil }?.ended
    }

    // MARK: - Windows and lifecycle

    /// Launched by launchd as a login item: stay in the menu bar, no Dock icon.
    public func noteLaunchedAsLoginItem() { launchedAsLoginItem = true }

    /// Brings the main window to the front at a pane, restoring the Dock icon
    /// if the app was launched hidden as a login item.
    public func openMainWindow(_ pane: Pane? = nil) {
        if let pane { selectedPane = pane }
        NSApp?.setActivationPolicy(.regular)
        windowOpener?(Self.mainWindowID)
        NSApp?.activate(ignoringOtherApps: true)
    }

    public func openOptimizeWindow() {
        NSApp?.setActivationPolicy(.regular)
        windowOpener?(Self.optimizeWindowID)
        NSApp?.activate(ignoringOtherApps: true)
    }

    /// On-demand use: closing the last window quits, unless the app is
    /// meant to stay resident (automatic runs) or a run is still going.
    public var shouldQuitWhenLastWindowCloses: Bool {
        !policy.automaticRuns && !activity.isRunning
    }

    public func start() {
        scheduler.schedule { [weak self] in await self?.runScheduledTick() }
        Task { await refresh(includeAnalysis: true) }
    }

    /// Prerequisites and health (cheap, read-only); analysis and savings
    /// estimates when stale or asked for.
    public func refresh(includeAnalysis: Bool = false) async {
        guard let store else { return }
        if activity == .idle { activity = .refreshing }
        let policy = self.policy
        let journalURL = store.journalURL
        let lockURL = store.lockURL
        let (prereqs, healthReport) = await Task.detached(priority: .utility) { () -> (Prerequisites, HealthReport) in
            let db = try? ReadOnlyDatabase(path: store.chatDB.path)
            let p = Prerequisites.evaluate(store: store, db: db, archiveDirectory: nil)
            let h = HealthReport.compute(store: store, policy: policy, journal: Journal(url: journalURL), lockURL: lockURL)
            return (p, h)
        }.value
        prerequisites = prereqs
        health = healthReport
        lastHealthCheckAt = now()
        let stale = analysisAt.map { now().timeIntervalSince($0) > Self.analysisMaxAge } ?? true
        if prereqs.fullDiskAccess, includeAnalysis || stale {
            let report = await Task.detached(priority: .utility) { try? Analyzer.run(store: store, policy: policy) }.value
            if let report { analysis = report; analysisAt = now() }
            await loadSavings(force: true)
        }
        loginItemStatus = loginItem.status
        updateRelaunchFlag()
        if activity == .refreshing { activity = .idle }
    }

    /// Savings estimates for the grid of windows and sizes (one pass, off-main).
    public func loadSavings(force: Bool = false) async {
        guard let store, !savingsLoading else { return }
        if !force, !savingsStale, let s = savings, now().timeIntervalSince(s.generatedAt) < Self.analysisMaxAge { return }
        savingsStale = false
        savingsLoading = true
        let policy = self.policy
        let journalURL = store.journalURL
        let table = await Task.detached(priority: .utility) { () -> SavingsTable? in
            guard let db = try? ReadOnlyDatabase(path: store.chatDB.path) else { return nil }
            return try? SavingsEstimator.compute(db: db, store: store, policy: policy, excludingPaths: Journal(url: journalURL).removedPaths())
        }.value
        if let table { savings = table }
        savingsLoading = false
    }

    public func loadChats() async {
        guard let store else { return }
        let policy = self.policy
        let list = await Task.detached(priority: .utility) { () -> [ChatSummary] in
            guard let db = try? ReadOnlyDatabase(path: store.chatDB.path) else { return [] }
            return (try? Chats.summarize(db: db, policy: policy, olderThanDays: 0)) ?? []
        }.value
        chats = list
    }

    // MARK: - Settings

    /// Validates, saves atomically, publishes. An unreadable file is backed up
    /// next to itself before being replaced.
    public func update(_ change: (inout Policy) -> Void) throws {
        var p = policy
        change(&p)
        let problems = p.validationProblems(volumeCapacityBytes: store.flatMap { Prerequisites.volumeCapacity(at: $0.root) })
        guard problems.isEmpty else { throw ConfigError.invalid(problems) }
        if case .unreadable = configOutcome, FileManager.default.fileExists(atPath: configURL.path) {
            let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "")
            try? FileManager.default.moveItem(at: configURL, to: configURL.appendingPathExtension("unreadable-\(stamp)"))
        }
        try p.save(to: configURL)
        if p.pinnedChats != policy.pinnedChats { savingsStale = true }
        policy = p
        configOutcome = .loaded
        lastSettingsChange = now()
        lastError = nil
    }

    /// Automatic runs can only be switched on after a real run through this
    /// app succeeded and nothing is waiting to be acknowledged.
    @discardableResult
    public func setAutomaticRuns(_ on: Bool) -> Bool {
        if on {
            guard store != nil else { lastError = "Automatic runs need a readable Messages store."; return false }
            guard !configIsUnreadable else { lastError = "Fix the unreadable settings file first."; return false }
            guard appHasCompletedRealRun else { lastError = "Run Optimize Now once and check the result before turning on automatic runs."; return false }
            guard problem == nil, health?.danglingRun == nil else { lastError = "Acknowledge the problem in Health first."; return false }
        }
        do { try update { $0.automaticRuns = on } } catch { lastError = "\(error)"; return false }
        return true
    }

    public func setStartAtLogin(_ on: Bool) {
        do { try loginItem.set(enabled: on) } catch { lastError = "\(error)" }
        loginItemStatus = loginItem.status
    }

    public func openLoginItems() { loginItem.openSystemSettings() }

    /// The "Uploads caught up" check is failing, or the last sync is stale.
    public var syncLooksBehind: Bool {
        guard let pr = prerequisites else { return false }
        return pr.checks.contains { ($0.name == "Uploads caught up" || $0.name == "Recent sync") && $0.ok == false }
    }

    /// Presses Messages' own Sync Now button for you (Accessibility), then
    /// re-checks the upload backlog. Only ever from a click. The daemon accepts
    /// sync requests only from Messages itself, so this is the working path.
    public func requestCloudSync() async {
        guard !syncRequestInProgress, store?.isLive == true else {
            if store?.isLive == false { syncRequestStatus = "Not available on a test store." }
            return
        }
        syncRequestInProgress = true
        syncRequestStatus = "Opening Messages › Settings › iMessage and pressing Sync Now…"
        let outcome = await MessagesSyncAutomation.pressSyncNow()
        syncRequestStatus = outcome.message
        if outcome == .pressed {
            let unsyncedBefore = pendingUploads()
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                let now = pendingUploads()
                syncRequestStatus = "Pressed Sync Now. Messages not yet uploaded: \(unsyncedBefore) → \(now)."
                if now == 0 { break }
            }
        }
        syncRequestInProgress = false
        await refresh()
    }

    /// Messages older than an hour that iCloud has not received yet (the
    /// "Uploads caught up" check).
    public func pendingUploads() -> Int64 {
        guard let store, let db = try? ReadOnlyDatabase(path: store.chatDB.path) else { return -1 }
        return (try? db.scalarInt("SELECT COUNT(*) FROM message WHERE ck_sync_state = 0 AND date < (strftime('%s','now') - 3600 - 978307200) * 1000000000")) ?? -1
    }

    public func acknowledgeProblem() async {
        guard let journal, let p = problem else { return }
        try? journal.appendAcknowledgement(runID: p.runID, note: "acknowledged in the app")
        await refresh()
    }

    public func clearError() { lastError = nil }

    // MARK: - Automatic runs

    public func gateInputs(now: Date? = nil) -> RunGateInputs {
        var i = RunGateInputs(launchedAt: launchedAt, now: now ?? self.now())
        i.storeReady = store != nil
        i.configUnreadable = configIsUnreadable
        i.policyValid = policyProblems.isEmpty
        i.automaticRuns = policy.automaticRuns
        i.busy = !activity.isIdle
        i.unacknowledgedProblem = problem != nil
        i.danglingRun = health?.danglingRun != nil
        i.hasPriorAppRun = appHasCompletedRealRun
        i.keepMessagesSet = keepMessagesIsSet
        i.prerequisiteBlockers = prerequisites?.blockers ?? ["not checked yet"]
        i.messagesRunning = messagesApp.isRunning
        i.onlyWhileMessagesClosed = policy.onlyWhileMessagesClosed
        i.lastSettingsChange = lastSettingsChange
        i.lastAutomaticRunEnded = lastAutomaticRunEnded
        return i
    }

    public func autoRunDecision(now: Date? = nil) -> AutoRunDecision {
        RunGate.decide(gateInputs(now: now))
    }

    /// One scheduler tick: always a read-only health check; a real run only
    /// when every gate is open.
    public func runScheduledTick() async {
        await refresh()
        switch autoRunDecision() {
        case .skip(let reason):
            lastSkipReason = reason
        case .run:
            lastSkipReason = nil
            guard let store, let journal else { return }
            let request = makeRequest(tiers: [.attachments], dryRun: false, budgetBytes: appBudgetBytes, origin: Self.automaticOrigin)
            await execute(request: request, store: store, journal: journal)
        }
    }

    /// Every request the app makes: never an archive, never sidecars.
    func makeRequest(tiers: Set<Tier>, dryRun: Bool, budgetBytes: Int64?, origin: String, approvedRowIDs: Set<Int64>? = nil) -> OffloadRequest {
        var request = OffloadRequest(policy: policy, tiers: tiers, dryRun: dryRun, budgetBytes: budgetBytes,
                                     origin: origin, approvedRowIDs: approvedRowIDs)
        request.archiveDirectory = nil
        request.checkpointEvery = checkpointEvery
        return request
    }

    // MARK: - Messages relaunch

    func updateRelaunchFlag() {
        guard let since = relaunchNeededSince else { needsMessagesRelaunch = false; return }
        if !messagesApp.isRunning || (messagesApp.launchDate ?? .distantPast) > since {
            relaunchNeededSince = nil
            needsMessagesRelaunch = false
        } else {
            needsMessagesRelaunch = true
        }
    }

    public func relaunchMessages() async {
        await messagesApp.relaunch()
        updateRelaunchFlag()
    }

    // MARK: - Display helpers

    public var ruleLine: String {
        let size = policy.minimumBytes > 0 ? "larger than \(SavingsEstimator.label(minimumBytes: policy.minimumBytes)) and " : ""
        return "Attachments \(size)older than \(SavingsEstimator.label(keepDays: policy.keepDays))"
    }

    public var localSizeLine: String {
        guard let a = analysis else { return store == nil ? "Messages store unavailable" : "Calculating…" }
        return "Local attachments \(Format.bytes(a.bytesOnDisk)) · can be optimized \(Format.bytes(currentEstimate?.bytes ?? a.candidateBytes))"
    }

    public var lastRunLine: String {
        guard let r = health?.lastRealRun else { return "Last run: never" }
        let when = Format.date(r.ended ?? r.started)
        switch r.outcome {
        case .ok: return "Last run: \(when) · \(Format.count(r.files)) files / \(Format.bytes(r.bytes))"
        case .cancelled: return "Last run: \(when) · cancelled after \(Format.count(r.files)) files"
        case .stopped: return "Last run: \(when) · stopped as a precaution"
        case .problem: return "Last run: \(when) · PROBLEM"
        case .incomplete: return "Last run: \(when) · did not finish"
        }
    }

    public var healthLine: String {
        if case .unavailable(let why) = storeState { return "Store unavailable: \(why)" }
        if configIsUnreadable { return "Settings file unreadable: real runs are blocked" }
        if let p = problem { return "Problem: \(p.summary)" }
        if keepMessagesIsSet { return "Warning: Messages › Keep messages is not Forever" }
        guard let h = health else { return "Health: not checked yet" }
        if !h.isHealthy { return "Health: \(h.violations.first ?? "see Health")" }
        if let s = lastSkipReason, policy.automaticRuns { return "Automatic: \(s.explanation)" }
        return "Health: OK" + (lastHealthCheckAt.map { " · checked \(Format.date($0))" } ?? "")
    }
}
