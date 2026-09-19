import Foundation
import StorageSaverCore

/// Forwards progress from the run thread to the main actor, throttled.
final class ProgressRelay {
    private var last = Date.distantPast
    private var lastPhase: OffloadProgress.Phase?
    private let minInterval: TimeInterval
    private let deliver: (OffloadProgress) -> Void

    init(minInterval: TimeInterval, deliver: @escaping (OffloadProgress) -> Void) {
        self.minInterval = minInterval
        self.deliver = deliver
    }

    func send(_ p: OffloadProgress) {
        let t = Date()
        if p.phase != lastPhase || p.phase == .done || t.timeIntervalSince(last) >= minInterval {
            last = t
            lastPhase = p.phase
            deliver(p)
        }
    }
}

extension AppModel {
    // MARK: - Manual runs

    /// Dry run with the same request a real run would use. Produces the
    /// preview and a confirmation token bound to exactly the rows shown.
    public func prepareOptimize(limitBytes: Int64? = nil, clearThumbnails: Bool = false) async {
        guard let store, let journal, activity.isIdle else { return }
        preview = nil
        confirmation = nil
        activity = .previewing
        var tiers: Set<Tier> = [.attachments]
        if clearThumbnails { tiers.insert(.previews) }
        // A per-run limit can lower the cap, and raise it (up to the hard
        // maximum) only once this app has completed a real run.
        let ceiling = appBudgetBytes ?? Policy.hardMaxBytesPerRun
        let budget = min(limitBytes ?? appBudgetBytes ?? policy.maxBytesPerRun, ceiling)
        let request = makeRequest(tiers: tiers, dryRun: true, budgetBytes: budget, origin: Self.manualOrigin)
        let result = await Task.detached(priority: .userInitiated) { () -> Result<OffloadResult, Error> in
            Result { try Offloader.run(store: store, request: request, journal: journal) }
        }.value
        switch result {
        case .success(let r):
            preview = r
            confirmation = RunConfirmation(previewRunID: r.runID, rowIDs: Set(r.selectedRowIDs), files: r.attachmentFiles, bytes: r.attachmentBytes,
                                           clearThumbnails: clearThumbnails, limitBytes: r.budgetBytes, createdAt: now())
        case .failure(let e):
            lastError = "\(e)"
        }
        activity = .idle
    }

    /// Why a confirmation cannot start a real run right now; nil means it can.
    public func confirmationBlocker(_ token: RunConfirmation) -> String? {
        guard store != nil else { return "the Messages store is not available" }
        if configIsUnreadable { return "the settings file is unreadable; fix it in Settings first" }
        let problems = policyProblems
        if !problems.isEmpty { return "settings are out of range: " + problems.joined(separator: "; ") }
        guard let confirmation, confirmation == token else { return "this preview is no longer current; run the preview again" }
        if now().timeIntervalSince(token.createdAt) > RunConfirmation.lifetime { return "the preview is older than 10 minutes; run it again" }
        guard activity.isIdle else { return "another run is in progress" }
        if let p = preview, !p.prerequisiteBlockers.isEmpty { return "prerequisites not met: " + p.prerequisiteBlockers.joined(separator: "; ") }
        if token.files == 0 && !token.clearThumbnails { return "nothing to optimize" }
        return nil
    }

    /// Real run restricted to the previewed rows and budget. Returns false
    /// (with `lastError` set) when the token is stale or a gate is closed.
    @discardableResult
    public func confirmOptimize(_ token: RunConfirmation) async -> Bool {
        if let why = confirmationBlocker(token) { lastError = why; return false }
        guard let store, let journal else { return false }
        var tiers: Set<Tier> = [.attachments]
        if token.clearThumbnails { tiers.insert(.previews) }
        let request = makeRequest(tiers: tiers, dryRun: false, budgetBytes: token.limitBytes, origin: Self.manualOrigin, approvedRowIDs: token.rowIDs)
        confirmation = nil
        await execute(request: request, store: store, journal: journal)
        return true
    }

    public func cancelRun() {
        runTask?.cancel()
    }

    // MARK: - Execution

    func execute(request: OffloadRequest, store: MessagesStore, journal: Journal) async {
        let messagesRunningAtStart = messagesApp.isRunning
        activity = .running(OffloadProgress(phase: .preparing))
        // No idle sleep, sudden or automatic termination while files are being removed.
        let activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled],
            reason: "Messages Storage Saver is optimizing attachments")
        defer { ProcessInfo.processInfo.endActivity(activityToken) }
        let relay = ProgressRelay(minInterval: 0.25) { [weak self] p in
            Task { @MainActor in
                guard let self, self.activity.isRunning else { return }
                self.activity = .running(p)
            }
        }
        let task = Task.detached(priority: .utility) { () throws -> OffloadResult in
            try Offloader.run(store: store, request: request, journal: journal,
                              progress: { relay.send($0) }, isCancelled: { Task.isCancelled })
        }
        runTask = task
        do {
            let result = try await task.value
            runTask = nil
            finish(result: result, messagesWasRunning: messagesRunningAtStart || messagesApp.isRunning)
            await refresh(includeAnalysis: true)
            let delay = followUpDelay
            if delay > 0 {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    await self?.refresh()
                }
            }
        } catch {
            runTask = nil
            activity = .idle
            // A thrown run (prerequisites, lock, crash) leaves no run-end; Health
            // shows it as dangling and the error stays in lastError.
            notifier.notify(title: "Messages Storage Saver could not run", body: "\(error)", isProblem: true)
            try? update { $0.automaticRuns = false }
            lastError = "\(error)"
            await refresh()
        }
    }

    func finish(result: OffloadResult, messagesWasRunning: Bool) {
        lastResult = result
        activity = .idle
        if !result.dryRun, result.attachmentFiles > 0, messagesWasRunning {
            relaunchNeededSince = result.finished ?? now()
        }
        switch result.outcome {
        case .problem:
            // Kill switch: automation off on disk, red icon, alert until acknowledged.
            try? update { $0.automaticRuns = false }
            if policy.notifications != .never {
                notifier.notify(title: "Messages Storage Saver stopped: problem",
                                body: (result.aborted ?? result.canaryViolations.first ?? "see Health") + " Automatic runs are off until you acknowledge this in Health.",
                                isProblem: true)
            }
        case .stopped:
            if policy.notifications != .never {
                notifier.notify(title: "Messages Storage Saver stopped as a precaution",
                                body: "Messages queued deletions for iCloud during the run (not this app). Nothing of yours was affected; the next run will continue.",
                                isProblem: false)
            }
        case .cancelled:
            break
        case .ok, .incomplete:
            if policy.notifications == .runsAndProblems, result.totalFiles > 0, !result.dryRun {
                let relaunch = relaunchNeededSince != nil ? " Relaunch Messages to see download buttons for optimized items." : ""
                notifier.notify(title: "Messages Storage Saver",
                                body: "Optimized \(Format.count(result.attachmentFiles)) attachments (\(Format.bytes(result.attachmentBytes)) freed). iCloud copies are untouched." + relaunch,
                                isProblem: false)
            }
        }
        updateRelaunchFlag()
    }
}
