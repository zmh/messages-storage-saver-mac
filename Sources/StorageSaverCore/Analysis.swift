import Foundation

/// Read-only picture of a Messages store: what is there, what Apple's rule
/// considers eligible, what the policy would offload, and what is already
/// offloaded. Nothing here writes anything.
public struct AnalysisReport: Codable {
    public struct Bucket: Codable {
        public let label: String
        public var count: Int
        public var bytes: Int64
    }

    public var store: String
    public var generatedAt: Date
    public var chatDBBytes: Int64
    public var attachmentRows: Int
    public var attachmentRowBytes: Int64
    public var filesOnDisk: Int
    public var bytesOnDisk: Int64
    public var symlinksSkipped: Int
    public var previewCacheFiles: Int
    public var previewCacheBytes: Int64
    public var syncDirBytes: Int64
    public var eligibleRows: Int
    public var eligibleBytes: Int64
    public var eligibleByAge: [Bucket]
    public var eligibleVerifiedOnDisk: Int
    public var eligibleVerifiedBytes: Int64
    public var eligibleFlaggedPurgeable: Int
    public var purgedShapeRows: Int
    public var purgedShapeBytes: Int64
    public var unreferencedFiles: Int
    public var unreferencedBytes: Int64
    public var unreferencedLiveSidecars: Int
    public var unreferencedLiveSidecarBytes: Int64
    public var tombstoneAttachments: Int64
    public var tombstoneMessages: Int64
    public var policy: Policy
    public var candidateCount: Int
    public var candidateBytes: Int64
    public var skippedRecent: Int
    public var skippedRecentBytes: Int64
    public var skippedPinned: Int
    public var skippedPinnedBytes: Int64
    public var skippedSmall: Int = 0
    public var skippedSmallBytes: Int64 = 0
    public var skippedBudget: Int
    public var skippedBudgetBytes: Int64
    public var rejections: [Rejection]

    public func render() -> String {
        var out: [String] = []
        out.append("Messages store: \(store)")
        out.append("chat.db \(Format.bytes(chatDBBytes)) · Sync/ \(Format.bytes(syncDirBytes)) · preview cache \(Format.count(previewCacheFiles)) files / \(Format.bytes(previewCacheBytes))")
        out.append("Attachment rows: \(Format.count(attachmentRows)) / \(Format.bytes(attachmentRowBytes)) · files on disk: \(Format.count(filesOnDisk)) / \(Format.bytes(bytesOnDisk))" + (symlinksSkipped > 0 ? " · symlinks skipped: \(symlinksSkipped)" : ""))
        out.append("Already optimized by Apple (placeholder rows): \(Format.count(purgedShapeRows)) rows / \(Format.bytes(purgedShapeBytes))")
        out.append("Tombstones: \(tombstoneAttachments) attachments, \(tombstoneMessages) messages (must never grow because of this tool)")
        out.append("")
        out.append("Eligible by Apple's rule (synced, complete, not audio/sticker/group photo/plugin): \(Format.count(eligibleRows)) rows / \(Format.bytes(eligibleBytes))")
        out.append("  verified on disk: \(Format.count(eligibleVerifiedOnDisk)) / \(Format.bytes(eligibleVerifiedBytes)) · already flagged APFS-purgeable: \(Format.count(eligibleFlaggedPurgeable))")
        for b in eligibleByAge { out.append(String(format: "  %-12@ %10@ %12@", b.label, Format.count(b.count), Format.bytes(b.bytes))) }
        out.append("")
        out.append("Unreferenced files (no attachment row): \(Format.count(unreferencedFiles)) / \(Format.bytes(unreferencedBytes)), of which Live Photo .MOV sidecars: \(Format.count(unreferencedLiveSidecars)) / \(Format.bytes(unreferencedLiveSidecarBytes))")
        out.append("")
        let modeText = policy.mode == .keepDays ? "keep last \(policy.keepDays) days" : "free-space target \(Format.bytes(policy.targetFreeBytes)) (keep floor \(policy.keepDays) days)"
        let sizeText = policy.minimumBytes > 0 ? " · only files ≥ \(Format.bytes(policy.minimumBytes))" : ""
        out.append("Policy: \(modeText)\(sizeText)" + (policy.pinnedChats.isEmpty ? "" : " · pinned: \(policy.pinnedChats.joined(separator: ", "))"))
        out.append("  would offload: \(Format.count(candidateCount)) files / \(Format.bytes(candidateBytes))")
        out.append("  kept (recent): \(Format.count(skippedRecent)) / \(Format.bytes(skippedRecentBytes)) · kept (pinned): \(Format.count(skippedPinned)) / \(Format.bytes(skippedPinnedBytes)) · kept (small): \(Format.count(skippedSmall)) / \(Format.bytes(skippedSmallBytes)) · beyond budget/target: \(Format.count(skippedBudget)) / \(Format.bytes(skippedBudgetBytes))")
        if !rejections.isEmpty {
            var reasons: [String: Int] = [:]
            for r in rejections { reasons[r.reason.components(separatedBy: " ").prefix(3).joined(separator: " "), default: 0] += 1 }
            out.append("  rejected on disk: \(rejections.count) — " + reasons.sorted { $0.value > $1.value }.map { "\($0.key) ×\($0.value)" }.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }
}

public enum Analyzer {
    public static let ageBuckets: [(label: String, maxDays: Int)] = [
        ("≤30 days", 30), ("31–90 days", 90), ("91–365 days", 365), ("1–2 years", 730), ("2–5 years", 1825), (">5 years", Int.max),
    ]

    public static func run(store: MessagesStore, policy: Policy, now: Date = Date()) throws -> AnalysisReport {
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        try db.verifySchema()

        let totals = try db.query("SELECT COUNT(*) AS n, COALESCE(SUM(total_bytes), 0) AS b FROM attachment").first
        let purged = try db.query("SELECT COUNT(*) AS n, COALESCE(SUM(total_bytes), 0) AS b FROM attachment WHERE hide_attachment = 0 AND ck_sync_state IN (1, 4) AND transfer_state = 0").first
        let tombA = try db.scalarInt("SELECT COUNT(*) FROM sync_deleted_attachments")
        let tombM = try db.scalarInt("SELECT COUNT(*) FROM sync_deleted_messages")

        // Eligible rows, age buckets, on-disk verification and APFS flag.
        let eligible = try CandidateSelector.eligibleRows(db: db)
        var buckets = ageBuckets.map { AnalysisReport.Bucket(label: $0.label, count: 0, bytes: 0) }
        var verified = 0
        var verifiedBytes: Int64 = 0
        var flagged = 0
        for row in eligible {
            let days = Int(now.timeIntervalSince(row.messageDate) / 86_400)
            let idx = ageBuckets.firstIndex { days <= $0.maxDays } ?? buckets.count - 1
            buckets[idx].count += 1
            buckets[idx].bytes += row.bytes
            // No age restriction here: this counts what exists, not what may be offloaded.
            if case .success = CandidateSelector.verify(row: row, store: store, minMTime: .distantFuture) {
                verified += 1
                verifiedBytes += row.bytes
                if let url = store.resolve(dbFilename: row.dbFilename), APFSFlags.isPurgeable(path: url.path) == true { flagged += 1 }
            }
        }

        // Disk walk: totals, unreferenced files, Live Photo sidecars.
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
        let walk = walkFiles(store.attachmentsDir)
        var unreferenced = 0
        var unreferencedBytes: Int64 = 0
        var sidecars = 0
        var sidecarBytes: Int64 = 0
        for (path, size) in walk.files where !referenced.contains(path) {
            unreferenced += 1
            unreferencedBytes += size
            if path.lowercased().hasSuffix(".mov"), referencedDirs.contains((path as NSString).deletingLastPathComponent) {
                sidecars += 1
                sidecarBytes += size
            }
        }
        let previews = walkFiles(store.previewsDir)
        let sync = walkFiles(store.syncDir)
        let chatDBBytes = (try? FileManager.default.attributesOfItem(atPath: store.chatDB.path)[.size] as? Int64) ?? 0

        let (free, _) = Prerequisites.freeSpace(at: store.root)
        let selection = try CandidateSelector.select(db: db, store: store, policy: policy, freeBytesNow: free, now: now)

        return AnalysisReport(
            store: store.root.path, generatedAt: now, chatDBBytes: chatDBBytes,
            attachmentRows: Int(totals?.int("n") ?? 0), attachmentRowBytes: totals?.int("b") ?? 0,
            filesOnDisk: walk.files.count, bytesOnDisk: walk.bytes, symlinksSkipped: walk.symlinks,
            previewCacheFiles: previews.files.count, previewCacheBytes: previews.bytes, syncDirBytes: sync.bytes,
            eligibleRows: eligible.count, eligibleBytes: eligible.reduce(0) { $0 + $1.bytes }, eligibleByAge: buckets,
            eligibleVerifiedOnDisk: verified, eligibleVerifiedBytes: verifiedBytes, eligibleFlaggedPurgeable: flagged,
            purgedShapeRows: Int(purged?.int("n") ?? 0), purgedShapeBytes: purged?.int("b") ?? 0,
            unreferencedFiles: unreferenced, unreferencedBytes: unreferencedBytes,
            unreferencedLiveSidecars: sidecars, unreferencedLiveSidecarBytes: sidecarBytes,
            tombstoneAttachments: tombA, tombstoneMessages: tombM, policy: policy,
            candidateCount: selection.candidates.count, candidateBytes: selection.totalBytes,
            skippedRecent: selection.skippedRecent, skippedRecentBytes: selection.skippedRecentBytes,
            skippedPinned: selection.skippedPinned, skippedPinnedBytes: selection.skippedPinnedBytes,
            skippedSmall: selection.skippedSmall, skippedSmallBytes: selection.skippedSmallBytes,
            skippedBudget: selection.skippedBudget, skippedBudgetBytes: selection.skippedBudgetBytes,
            rejections: selection.rejections
        )
    }

    public struct Walk {
        public var files: [(String, Int64)] = []
        public var bytes: Int64 = 0
        public var symlinks = 0
    }

    /// Enumerates regular files under `dir`. Symlinks are counted and skipped,
    /// never followed.
    public static func walkFiles(_ dir: URL) -> Walk {
        var result = Walk()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys, options: []) else { return result }
        for case let url as URL in e {
            guard let rv = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if rv.isSymbolicLink == true { result.symlinks += 1; continue }
            guard rv.isRegularFile == true else { continue }
            let size = Int64(rv.fileSize ?? 0)
            result.files.append((url.standardizedFileURL.path, size))
            result.bytes += size
        }
        return result
    }
}
