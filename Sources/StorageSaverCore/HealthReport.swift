import Foundation

/// What this tool has removed, whether Messages re-downloaded any of it,
/// whether the canaries are quiet, and which runs still need a look. All
/// reads; the same logic backs `mss status` and the app's Health window.
public struct HealthReport: Codable {
    public struct Problem: Codable, Equatable {
        public var runID: String
        public var date: Date
        public var summary: String
    }

    public var generatedAt: Date
    public var runs: Int
    public var realRuns: Int
    public var filesRemoved: Int
    public var bytesRemoved: Int64
    public var previewCacheBytesCleared: Int64
    /// Removed files that are back on disk (Messages re-downloaded them, or a restore).
    public var filesReappeared: Int
    public var bytesReappeared: Int64
    public var baselineTombstones: [String: Int64]?
    public var currentTombstones: [String: Int64]?
    /// Offloaded rows whose file is still absent and that left ck_sync_state 1.
    public var rowsNoLongerSynced: Int
    /// Re-downloaded rows waiting for the daemon to re-mark them synced (normal).
    public var pendingResync: Int
    public var notes: [String]
    /// Canary findings that implicate this tool. Empty is healthy.
    public var violations: [String]
    /// Runs that ended `problem`, plus runs that never ended (crash, power loss).
    public var problemRuns: [Problem]
    /// The newest problem nobody has acknowledged; drives the kill switch.
    public var unacknowledgedProblem: Problem?
    public var danglingRun: RunSummary?
    /// Another process holds the run lock right now.
    public var runInProgress: Bool
    public var lastRun: RunSummary?
    public var lastRealRun: RunSummary?
    public var recentRuns: [RunSummary]
    /// Non-default values of settings the app never exposes.
    public var configWarnings: [String]
    /// chat.db could not be opened (typically: no Full Disk Access).
    public var databaseError: String?

    public var isHealthy: Bool { violations.isEmpty && unacknowledgedProblem == nil && databaseError == nil }

    public static func compute(store: MessagesStore, policy: Policy, journal: Journal? = nil, lockURL: URL? = nil, now: Date = Date()) -> HealthReport {
        let journal = journal ?? Journal(url: store.journalURL)
        let lockURL = lockURL ?? store.lockURL
        let entries = journal.readAll()
        let removed = journal.removedEntries()
        let summaries = journal.runSummaries()
        let acknowledged = journal.acknowledgedRunIDs()

        var reappeared = 0
        var reappearedBytes: Int64 = 0
        for e in removed {
            var st = stat()
            if lstat(e.path!, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                reappeared += 1
                reappearedBytes += e.bytes ?? 0
            }
        }

        // The lock tells a crashed run from one that is still going.
        var inProgress = false
        if let probe = try? RunLock(url: lockURL) { withExtendedLifetime(probe) {} } else { inProgress = true }

        var violations: [String] = []
        var notes: [String] = []
        var rowsLeft = 0
        var pendingResync = 0
        var current: [String: Int64]?
        var baseline: CanarySnapshot?
        var databaseError: String?
        do {
            let db = try ReadOnlyDatabase(path: store.chatDB.path)
            baseline = Canaries.loadBaselineMigrating(db: db, url: store.baselineURL)
            let ids = removed.compactMap(\.rowID)
            let snap = try Canaries.snapshot(db: db, rowIDs: ids, now: now)
            current = ["attachments": snap.tombstoneAttachments, "messages": snap.tombstoneMessages,
                       "attachmentsQueuedEver": snap.tombstoneAttachmentsSeq ?? -1, "messagesQueuedEver": snap.tombstoneMessagesSeq ?? -1]
            // A row that Messages re-downloaded is marked "needs sync" (0) until
            // the daemon's next pass reconciles it; that is normal. A row whose
            // file is still absent and that left state 1 is the real signal.
            let pathByRow = Dictionary(removed.compactMap { e in e.rowID.map { ($0, e.path!) } }, uniquingKeysWith: { a, _ in a })
            for (rowID, ck) in snap.rowSyncStates where ck != 1 {
                var st = stat()
                let fileBack = pathByRow[rowID].map { lstat($0, &st) == 0 } ?? false
                if fileBack && ck == 0 { pendingResync += 1 } else { rowsLeft += 1 }
            }
            if pendingResync > 0 { notes.append("\(pendingResync) re-downloaded row(s) waiting for the daemon to re-mark them synced (normal after a download)") }
            if rowsLeft > 0 { violations.append("\(rowsLeft) offloaded row(s) are no longer marked synced to iCloud") }
            // Deletions queued at any time other than during a run (Recently
            // Deleted expiry, deletions made in the Messages app) are reported, not blamed.
            let lastEnd = entries.last(where: { $0.action == "run-end" && $0.tombstoneMessagesSeq != nil })
            let refA = lastEnd?.tombstoneAttachmentsSeq ?? baseline?.tombstoneAttachmentsSeq
            let refM = lastEnd?.tombstoneMessagesSeq ?? baseline?.tombstoneMessagesSeq
            let since = lastEnd.map { "since the last run (\($0.runID))" } ?? "since the baseline"
            if let refA, let a = snap.tombstoneAttachmentsSeq, a > refA { notes.append("\(a - refA) attachment deletion(s) queued for iCloud \(since), outside any run") }
            if let refM, let m = snap.tombstoneMessagesSeq, m > refM { notes.append("\(m - refM) message deletion(s) queued for iCloud \(since), outside any run (Recently Deleted expiry or a deletion made in the Messages app)") }
        } catch {
            databaseError = "\(error)"
        }

        // Problem runs: ended with a canary/regression/archive/journal problem,
        // or never ended at all (unless a run is in progress right now).
        var problems: [Problem] = []
        var dangling: RunSummary?
        for s in summaries where !s.dryRun {
            if s.outcome == .problem {
                problems.append(Problem(runID: s.runID, date: s.ended ?? s.started, summary: "run \(s.runID) ended with a problem: \(s.note ?? "")"))
            } else if s.outcome == .incomplete && !(inProgress && s.runID == summaries.last?.runID) {
                dangling = s
                problems.append(Problem(runID: s.runID, date: s.started, summary: "run \(s.runID) started but never finished (crash, power loss, or force quit); check that its files are accounted for"))
            } else if s.outcome == .stopped {
                notes.append("run \(s.runID) stopped as a precaution: \(s.note ?? "")")
            }
        }
        for p in problems { violations.append(p.summary) }
        let unacknowledged = problems.last { !acknowledged.contains($0.runID) }

        return HealthReport(
            generatedAt: now,
            runs: summaries.count,
            realRuns: summaries.filter { !$0.dryRun && $0.outcome != .incomplete }.count,
            filesRemoved: removed.count,
            bytesRemoved: removed.reduce(0) { $0 + ($1.bytes ?? 0) },
            previewCacheBytesCleared: journal.previewCacheBytesCleared(),
            filesReappeared: reappeared,
            bytesReappeared: reappearedBytes,
            baselineTombstones: baseline.map { ["attachments": $0.tombstoneAttachments, "messages": $0.tombstoneMessages,
                                                "attachmentsQueuedEver": $0.tombstoneAttachmentsSeq ?? -1, "messagesQueuedEver": $0.tombstoneMessagesSeq ?? -1] },
            currentTombstones: current,
            rowsNoLongerSynced: rowsLeft,
            pendingResync: pendingResync,
            notes: notes,
            violations: violations,
            problemRuns: problems,
            unacknowledgedProblem: unacknowledged,
            danglingRun: dangling,
            runInProgress: inProgress,
            lastRun: summaries.last,
            lastRealRun: summaries.last { !$0.dryRun },
            recentRuns: Array(summaries.suffix(20)),
            configWarnings: policy.nonDefaultSafetySettings,
            databaseError: databaseError
        )
    }

    public func render() -> String {
        var out: [String] = []
        out.append("Runs: \(runs) (\(realRuns) real) · attachments removed: \(Format.count(filesRemoved)) files / \(Format.bytes(bytesRemoved)) · preview cache cleared: \(Format.bytes(previewCacheBytesCleared))")
        out.append("Attachments re-downloaded by Messages since: \(Format.count(filesReappeared)) files / \(Format.bytes(bytesReappeared))")
        if let b = baselineTombstones, let c = currentTombstones {
            out.append("Deletion queues (Apple drains these to iCloud) baseline → now: attachments \(b["attachments"]!) → \(c["attachments"]!), messages \(b["messages"]!) → \(c["messages"]!)")
            out.append("Deletions ever queued (must not grow because of this tool): attachments \(c["attachmentsQueuedEver"]!), messages \(c["messagesQueuedEver"]!)")
        }
        out.append("Offloaded rows no longer marked synced: \(rowsNoLongerSynced)")
        if let d = databaseError { out.append("Database: \(d)") }
        if runInProgress { out.append("A run is in progress.") }
        for n in notes { out.append("Note: \(n)") }
        for w in configWarnings { out.append("Config: \(w)") }
        if let p = unacknowledgedProblem { out.append("UNACKNOWLEDGED: \(p.summary)") }
        out.append(violations.isEmpty ? "Canaries: healthy" : "CANARY VIOLATIONS: " + violations.joined(separator: "; "))
        return out.joined(separator: "\n")
    }
}
