import Foundation

public enum Tier: String, Codable, CaseIterable {
    case previews, attachments, sidecars
}

/// Live progress of a run, delivered on the run's own thread; callers hop
/// to the main thread themselves and may throttle.
public struct OffloadProgress: Equatable, Sendable {
    public enum Phase: String, Sendable {
        case preparing, selecting, attachments, previews, sidecars, finalizing, done
    }
    public var phase: Phase
    public var filesDone = 0
    public var filesTotal = 0
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    public var archived = 0
    public var errors = 0
    public var currentPath: String?

    public init(phase: Phase, filesDone: Int = 0, filesTotal: Int = 0, bytesDone: Int64 = 0, bytesTotal: Int64 = 0,
                archived: Int = 0, errors: Int = 0, currentPath: String? = nil) {
        self.phase = phase; self.filesDone = filesDone; self.filesTotal = filesTotal; self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal; self.archived = archived; self.errors = errors; self.currentPath = currentPath
    }

    public var fraction: Double { filesTotal == 0 ? 0 : Double(filesDone) / Double(filesTotal) }
}

public typealias OffloadProgressHandler = (OffloadProgress) -> Void
public typealias CancellationCheck = () -> Bool

/// What a run would touch (or touched) per conversation.
public struct ChatBucket: Codable, Equatable {
    public var chatIdentifier: String
    public var displayName: String
    public var files: Int
    public var bytes: Int64
    public var oldest: Date
    public var newest: Date
}

public struct OffloadRequest {
    public var policy: Policy
    public var tiers: Set<Tier>
    public var dryRun: Bool
    public var archiveDirectory: URL?
    /// Explicit per-run byte cap; nil means the policy's first-run/normal cap.
    public var budgetBytes: Int64?
    public var chatFilter: String?
    public var beforeDate: Date?
    /// Who started the run ("cli", "app-manual", "app-auto"); journaled.
    public var origin: String?
    /// When set, only these attachment rows may be touched: the rows a
    /// preview showed. Anything that became eligible since is left alone.
    public var approvedRowIDs: Set<Int64>?
    /// Files between canary and prerequisite checkpoints. Tests lower it.
    public var checkpointEvery = 250

    public init(policy: Policy, tiers: Set<Tier>? = nil, dryRun: Bool = true, archiveDirectory: URL? = nil,
                budgetBytes: Int64? = nil, chatFilter: String? = nil, beforeDate: Date? = nil,
                origin: String? = nil, approvedRowIDs: Set<Int64>? = nil) {
        self.policy = policy
        var t = Set<Tier>()
        if policy.tiers.previewCache { t.insert(.previews) }
        if policy.tiers.attachments { t.insert(.attachments) }
        if policy.tiers.liveSidecars { t.insert(.sidecars) }
        self.tiers = tiers ?? t
        self.dryRun = dryRun
        self.archiveDirectory = archiveDirectory ?? policy.archiveDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        self.budgetBytes = budgetBytes
        self.chatFilter = chatFilter
        self.beforeDate = beforeDate
        self.origin = origin
        self.approvedRowIDs = approvedRowIDs
    }
}

public struct TierResult: Codable, Equatable {
    public var tier: String
    public var files = 0
    public var bytes: Int64 = 0
    public var skipped = 0
    public var errors: [String] = []
}

public struct OffloadResult: Codable {
    public var runID: String
    public var started: Date
    public var finished: Date?
    public var dryRun: Bool
    public var budgetBytes: Int64
    public var prerequisiteBlockers: [String]
    public var tiers: [TierResult]
    public var archived: Int = 0
    /// Hard canary findings (touched rows changed); trips the kill switch.
    public var canaryViolations: [String] = []
    /// Deletions Messages queued for iCloud during the run without touching
    /// any of this run's rows. A real run stops on these as a precaution.
    public var externalDeletions: [String] = []
    public var aborted: String?
    public var cancelled = false
    /// Files a previous run removed that are back on disk; never removed again.
    public var keptPreviouslyRemoved = 0
    public var keptPreviouslyRemovedBytes: Int64 = 0
    /// Attachment candidates grouped by conversation, largest first.
    public var byChat: [ChatBucket] = []
    /// Row ids the attachments tier selected (dry runs: what a real run may touch).
    public var selectedRowIDs: [Int64] = []

    public static let cancelledMarker = "cancelled by user"

    public var totalFiles: Int { tiers.reduce(0) { $0 + $1.files } }
    public var totalBytes: Int64 { tiers.reduce(0) { $0 + $1.bytes } }
    public var attachmentFiles: Int { tiers.first { $0.tier == Tier.attachments.rawValue }?.files ?? 0 }
    public var attachmentBytes: Int64 { tiers.first { $0.tier == Tier.attachments.rawValue }?.bytes ?? 0 }
    public var stoppedByExternalDeletion: Bool { aborted != nil && !cancelled && canaryViolations.isEmpty && !externalDeletions.isEmpty && (aborted ?? "").contains("precaution") }

    public var outcome: RunOutcome {
        if !canaryViolations.isEmpty { return .problem }
        if cancelled { return .cancelled }
        if stoppedByExternalDeletion { return .stopped }
        if aborted != nil { return .problem }
        return .ok
    }

    public func render() -> String {
        var out: [String] = []
        out.append(dryRun ? "DRY RUN (nothing was removed) — run \(runID)" : "Run \(runID)")
        if !prerequisiteBlockers.isEmpty { out.append("Blockers: " + prerequisiteBlockers.joined(separator: "; ")) }
        out.append("Budget for this run (attachments + sidecars; the preview cache is regenerable and not budgeted): \(Format.bytes(budgetBytes))")
        for t in tiers {
            out.append("  \(t.tier): \(Format.count(t.files)) files / \(Format.bytes(t.bytes))" + (t.skipped > 0 ? " · skipped \(t.skipped)" : "") + (t.errors.isEmpty ? "" : " · errors \(t.errors.count)"))
            for e in t.errors.prefix(5) { out.append("      ! \(e)") }
        }
        if archived > 0 { out.append("  archived copies: \(archived)") }
        if keptPreviouslyRemoved > 0 { out.append("  kept (removed before, back on disk): \(Format.count(keptPreviouslyRemoved)) / \(Format.bytes(keptPreviouslyRemovedBytes))") }
        out.append("Total: \(Format.count(totalFiles)) files / \(Format.bytes(totalBytes))")
        if !canaryViolations.isEmpty { out.append("CANARY VIOLATIONS: " + canaryViolations.joined(separator: "; ")) }
        if !externalDeletions.isEmpty { out.append("Note: Messages queued deletions for iCloud during the run, none involving this run's files: " + externalDeletions.joined(separator: "; ")) }
        if cancelled { out.append("CANCELLED by user after \(Format.count(totalFiles)) files") }
        else if let aborted { out.append("STOPPED: \(aborted)") }
        return out.joined(separator: "\n")
    }
}

public enum OffloadError: Error, CustomStringConvertible {
    case prerequisites([String])
    case invalidPolicy([String])
    case liveStoreNeedsArchiveOrConfirmation
    public var description: String {
        switch self {
        case .prerequisites(let b): return "prerequisites not met: " + b.joined(separator: "; ")
        case .invalidPolicy(let p): return "policy is invalid: " + p.joined(separator: "; ")
        case .liveStoreNeedsArchiveOrConfirmation: return "refusing to run"
        }
    }
}

/// Executes a policy against a store. Dry runs compute everything and remove
/// nothing. Real runs re-verify every row and file immediately before removal,
/// journal first, archive (optionally) with byte verification, remove through
/// `DeletionGuard`, and watch the canaries and prerequisites throughout.
public enum Offloader {
    /// Test hook: called right before each unlink in the attachments tier with
    /// the candidate and its index. Throwing simulates a crash mid-run.
    static var testHookBeforeUnlink: ((Candidate, Int) throws -> Void)?

    public static func run(store: MessagesStore, request: OffloadRequest, journal: Journal? = nil,
                           lockURL: URL? = nil, now: Date = Date(),
                           progress: OffloadProgressHandler? = nil,
                           isCancelled: CancellationCheck? = nil) throws -> OffloadResult {
        let journal = journal ?? Journal(url: store.journalURL)
        let lockURL = lockURL ?? store.lockURL
        let idFormatter = ISO8601DateFormatter()
        idFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let runID = idFormatter.string(from: now).replacingOccurrences(of: ":", with: "")
        if !request.dryRun {
            let problems = request.policy.validationProblems()
            if !problems.isEmpty { throw OffloadError.invalidPolicy(problems) }
        }
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        try db.verifySchema()
        let prereqs = Prerequisites.evaluate(store: store, db: db, archiveDirectory: request.archiveDirectory)
        let budget = request.budgetBytes ?? (journal.hasCompletedRealRun(tier: .attachments) ? request.policy.maxBytesPerRun : request.policy.firstRunMaxBytes)
        // The preview cache is regenerable local data; only tiers whose other
        // copy lives in iCloud need the iCloud checks.
        let needsCloud = !request.tiers.isDisjoint(with: [.attachments, .sidecars])
        let blockers = needsCloud ? prereqs.blockers : prereqs.localOnlyBlockers
        var result = OffloadResult(runID: runID, started: now, dryRun: request.dryRun, budgetBytes: budget,
                                   prerequisiteBlockers: blockers, tiers: [])
        if !request.dryRun && !blockers.isEmpty { throw OffloadError.prerequisites(blockers) }

        let lock = try RunLock(url: lockURL)
        defer { withExtendedLifetime(lock) {} }
        let tierList = request.tiers.map(\.rawValue).sorted().joined(separator: ",")
        try journal.append(JournalEntry(runID: runID, action: "run-start", dryRun: request.dryRun,
                                        note: "tiers=\(tierList) budget=\(budget)" + (request.origin.map { " origin=\($0)" } ?? "")))
        progress?(OffloadProgress(phase: .preparing))

        // Candidate selection (attachments tier) drives the canary watch list.
        let cutoff = now.addingTimeInterval(-TimeInterval(request.policy.keepDays) * 86_400)
        let (free, _) = Prerequisites.freeSpace(at: store.root)
        let previouslyRemoved = journal.removedPaths()
        var kept = 0
        var keptBytes: Int64 = 0
        var selection = Selection()
        if request.tiers.contains(.attachments) {
            selection = try CandidateSelector.select(db: db, store: store, policy: request.policy, freeBytesNow: free,
                                                     budgetBytes: budget, now: now, filter: { row in
                if let chat = request.chatFilter, row.chatIdentifier != chat, row.chatDisplayName != chat { return false }
                if let before = request.beforeDate, row.messageDate >= before { return false }
                if let ids = request.approvedRowIDs, !ids.contains(row.rowID) { return false }
                if let p = store.resolve(dbFilename: row.dbFilename)?.path, previouslyRemoved.contains(p) {
                    // Back on disk: the user wanted it, keep it. Still absent: nothing to do.
                    var st = stat()
                    if lstat(p, &st) == 0 { kept += 1; keptBytes += row.bytes }
                    return false
                }
                return true
            })
        }
        result.keptPreviouslyRemoved = kept
        result.keptPreviouslyRemovedBytes = keptBytes
        result.byChat = buckets(selection.candidates)
        result.selectedRowIDs = selection.candidates.map(\.rowID)
        let before = try Canaries.snapshot(db: db, rowIDs: selection.candidates.map(\.rowID), now: now)
        try Canaries.saveBaselineIfMissing(before, url: store.baselineURL)
        var startEntry = JournalEntry(runID: runID, action: "run-counters", dryRun: request.dryRun, note: "before")
        startEntry.tombstoneAttachmentsSeq = before.tombstoneAttachmentsSeq
        startEntry.tombstoneMessagesSeq = before.tombstoneMessagesSeq
        try journal.append(startEntry)
        progress?(OffloadProgress(phase: .selecting, filesTotal: selection.candidates.count, bytesTotal: selection.totalBytes))

        let guardian = DeletionGuard(store: store, approvedPaths: selection.candidates.map(\.path))
        var abort: String?
        var touched: [Int64] = []
        var prog = OffloadProgress(phase: .attachments, filesTotal: selection.candidates.count, bytesTotal: selection.totalBytes)

        /// Cancellation is checked between files; the current file is always
        /// finished (journaled and removed, or left alone) before stopping.
        func checkCancelled() -> Bool {
            if abort != nil { return true }
            guard isCancelled?() == true else { return false }
            abort = OffloadResult.cancelledMarker
            result.cancelled = true
            try? journal.append(JournalEntry(runID: runID, action: "cancel", dryRun: request.dryRun, note: "after \(prog.filesDone) files"))
            return true
        }

        func checkpoint(_ label: String) throws {
            let mid = try Canaries.snapshot(db: db, rowIDs: touched, now: Date())
            let a = Canaries.assess(before: before.restricted(to: touched), after: mid)
            if !a.hard.isEmpty {
                abort = "\(label): " + a.hard.joined(separator: "; ")
                try journal.append(JournalEntry(runID: runID, action: "canary", dryRun: request.dryRun, note: abort))
                return
            }
            if !a.external.isEmpty {
                result.externalDeletions = a.external
                if !request.dryRun {
                    abort = "\(label): stopped as a precaution, Messages queued deletions for iCloud that do not involve this run's files: " + a.external.joined(separator: "; ")
                    try journal.append(JournalEntry(runID: runID, action: "canary", dryRun: request.dryRun, note: abort))
                    return
                }
            }
            if !request.dryRun {
                let regressed = Prerequisites.regressions(store: store, archiveDirectory: request.archiveDirectory, needsCloud: needsCloud)
                if !regressed.isEmpty {
                    abort = "\(label): prerequisites regressed: " + regressed.joined(separator: "; ")
                    try journal.append(JournalEntry(runID: runID, action: "canary", dryRun: request.dryRun, note: abort))
                }
            }
        }

        // Tier: attachments
        if request.tiers.contains(.attachments) {
            var tr = TierResult(tier: Tier.attachments.rawValue)
            tr.skipped = selection.rejections.count
            for (i, c) in selection.candidates.enumerated() {
                if checkCancelled() { break }
                prog.currentPath = c.path
                if request.dryRun {
                    tr.files += 1; tr.bytes += c.bytes
                    prog.filesDone = tr.files; prog.bytesDone = tr.bytes
                    progress?(prog)
                    continue
                }
                // Re-verify the row right before touching the file.
                let rows: [Row]
                do {
                    rows = try db.query("SELECT ck_sync_state AS ck, transfer_state AS ts, ck_record_id AS rec FROM attachment WHERE ROWID = ?", [.int(c.rowID)])
                } catch {
                    abort = "database error before removal: \(error)"; tr.errors.append(abort!); break
                }
                guard let r = rows.first, r.int("ck") == 1, r.int("ts") == 5, r.text("rec") != nil else {
                    tr.skipped += 1; tr.errors.append("row \(c.rowID) changed state before removal; skipped"); continue
                }
                var archivePath: String?
                if let archiveRoot = request.archiveDirectory {
                    do {
                        archivePath = try Archive.copyVerified(from: c.path, to: Archive.destination(for: c.path, store: store, archiveRoot: archiveRoot))
                        result.archived += 1
                        prog.archived = result.archived
                    } catch {
                        // With an archive configured, no copy means no removal, and
                        // a failing archive (unplugged disk, full) stops the run.
                        abort = "archive failed: \(error)"; tr.errors.append(abort!); break
                    }
                }
                do {
                    try journal.append(JournalEntry(runID: runID, action: "offload", dryRun: false, tier: "attachments", path: c.path,
                                                    bytes: c.bytes, rowID: c.rowID, guid: c.guid, ckRecordID: c.ckRecordID,
                                                    chat: c.chatIdentifier, messageDate: c.messageDate, archivePath: archivePath))
                } catch {
                    abort = "journal write failed, nothing removed without a journal entry: \(error)"; tr.errors.append(abort!); break
                }
                touched.append(c.rowID)
                try testHookBeforeUnlink?(c, i)
                do {
                    let n = try guardian.unlink(c.path, root: .attachments, expectedSize: request.policy.requireExactSize ? c.bytes : nil)
                    tr.files += 1; tr.bytes += n
                } catch {
                    tr.errors.append("\(error)")
                }
                prog.filesDone = tr.files; prog.bytesDone = tr.bytes; prog.errors = tr.errors.count
                progress?(prog)
                if (i + 1) % max(1, request.checkpointEvery) == 0 { try checkpoint("mid-run") }
            }
            result.tiers.append(tr)
        }

        // Tier: preview cache (regenerable thumbnails)
        if request.tiers.contains(.previews), abort == nil {
            var tr = TierResult(tier: Tier.previews.rawValue)
            let walk = Analyzer.walkFiles(store.previewsDir)
            guardian.approve(walk.files.map(\.0))
            var p = OffloadProgress(phase: .previews, filesTotal: walk.files.count, bytesTotal: walk.bytes)
            progress?(p)
            for (i, (path, size)) in walk.files.enumerated() {
                if i % 100 == 0, checkCancelled() { break }
                if request.dryRun { tr.files += 1; tr.bytes += size; continue }
                do { tr.bytes += try guardian.unlink(path, root: .previews); tr.files += 1 } catch { tr.errors.append("\(error)") }
                if i % 100 == 99 { p.filesDone = tr.files; p.bytesDone = tr.bytes; progress?(p) }
            }
            if !request.dryRun {
                try journal.append(JournalEntry(runID: runID, action: "preview-cache", dryRun: false, tier: "previews",
                                                path: store.previewsDir.path, bytes: tr.bytes, note: "\(tr.files) files"))
            }
            result.tiers.append(tr)
        }

        // Tier: unreferenced Live Photo sidecars (older than the keep window).
        // Shares the run budget with the attachments tier; the preview cache
        // is regenerable and not counted.
        if request.tiers.contains(.sidecars), abort == nil {
            var tr = TierResult(tier: Tier.sidecars.rawValue)
            var remaining = budget - (result.tiers.first { $0.tier == Tier.attachments.rawValue }?.bytes ?? 0)
            let referencedRows = try db.query("SELECT filename FROM attachment WHERE filename IS NOT NULL")
            var referenced = Set<String>()
            var referencedDirs = Set<String>()
            for r in referencedRows {
                if let f = r.text("filename"), let url = store.resolve(dbFilename: f) {
                    let p = url.standardizedFileURL.path
                    referenced.insert(p)
                    referencedDirs.insert((p as NSString).deletingLastPathComponent)
                }
            }
            let walk = Analyzer.walkFiles(store.attachmentsDir)
            var targets: [(String, Int64)] = []
            for (path, size) in walk.files where !referenced.contains(path) && path.lowercased().hasSuffix(".mov")
                && referencedDirs.contains((path as NSString).deletingLastPathComponent) && !previouslyRemoved.contains(path) {
                var st = stat()
                guard lstat(path, &st) == 0 else { continue }
                let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                if mtime < cutoff { targets.append((path, size)) } else { tr.skipped += 1 }
            }
            guardian.approve(targets.map(\.0))
            var p = OffloadProgress(phase: .sidecars, filesTotal: targets.count, bytesTotal: targets.reduce(0) { $0 + $1.1 })
            progress?(p)
            for (path, size) in targets {
                if checkCancelled() { break }
                if size > remaining { tr.skipped += 1; continue }
                remaining -= size
                if request.dryRun { tr.files += 1; tr.bytes += size; continue }
                do {
                    try journal.append(JournalEntry(runID: runID, action: "sidecar", dryRun: false, tier: "sidecars", path: path, bytes: size))
                } catch {
                    abort = "journal write failed, nothing removed without a journal entry: \(error)"; tr.errors.append(abort!); break
                }
                do { tr.bytes += try guardian.unlink(path, root: .attachments); tr.files += 1 } catch { tr.errors.append("\(error)") }
                p.filesDone = tr.files; p.bytesDone = tr.bytes; progress?(p)
            }
            result.tiers.append(tr)
        }

        // Final canaries: tombstones and the sync state of every row we touched.
        progress?(OffloadProgress(phase: .finalizing, filesDone: result.totalFiles, filesTotal: result.totalFiles, bytesDone: result.totalBytes, bytesTotal: result.totalBytes))
        let after = try Canaries.snapshot(db: db, rowIDs: touched, now: Date())
        let assessment = Canaries.assess(before: before.restricted(to: touched), after: after)
        result.canaryViolations = assessment.hard
        for e in assessment.external where !result.externalDeletions.contains(e) { result.externalDeletions.append(e) }
        if let abort { result.aborted = abort }
        result.finished = Date()
        var endEntry = JournalEntry(runID: runID, action: "run-end", dryRun: request.dryRun, bytes: result.totalBytes,
                                    note: "\(result.outcome.rawValue) files=\(result.totalFiles)")
        endEntry.tombstoneAttachmentsSeq = after.tombstoneAttachmentsSeq
        endEntry.tombstoneMessagesSeq = after.tombstoneMessagesSeq
        try journal.append(endEntry)
        progress?(OffloadProgress(phase: .done, filesDone: result.totalFiles, filesTotal: result.totalFiles, bytesDone: result.totalBytes, bytesTotal: result.totalBytes))
        return result
    }

    static func buckets(_ candidates: [Candidate]) -> [ChatBucket] {
        var byChat: [String: ChatBucket] = [:]
        for c in candidates {
            var b = byChat[c.chatIdentifier] ?? ChatBucket(chatIdentifier: c.chatIdentifier, displayName: c.chatDisplayName, files: 0, bytes: 0, oldest: c.messageDate, newest: c.messageDate)
            b.files += 1
            b.bytes += c.bytes
            b.oldest = min(b.oldest, c.messageDate)
            b.newest = max(b.newest, c.messageDate)
            byChat[c.chatIdentifier] = b
        }
        return byChat.values.sorted { $0.bytes > $1.bytes }
    }
}
