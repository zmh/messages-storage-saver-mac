import Foundation

/// What one (keep window, minimum size) choice would offload right now.
public struct SavingsEstimate: Codable, Equatable {
    public var keepDays: Int
    public var minimumBytes: Int64
    public var files: Int
    public var bytes: Int64
}

/// Estimates for a grid of choices, from one pass over the eligible rows.
/// These are "eventually" numbers: real runs are capped per run.
public struct SavingsTable: Codable, Equatable {
    public var generatedAt: Date
    public var keepDaysChoices: [Int]
    public var minimumBytesChoices: [Int64]
    public var estimates: [SavingsEstimate]
    /// Eligible attachments verified on disk, before any window or size rule.
    public var eligibleFiles: Int
    public var eligibleBytes: Int64

    public func estimate(keepDays: Int, minimumBytes: Int64) -> SavingsEstimate? {
        estimates.first { $0.keepDays == keepDays && $0.minimumBytes == minimumBytes }
    }
}

public enum SavingsEstimator {
    public static let keepDaysChoices = [7, 30, 90, 180, 365, 730, 1095, 1825, 3650]
    public static let minimumBytesChoices: [Int64] = [0, 1_000_000, 5_000_000, 10_000_000, 100_000_000, 500_000_000]

    /// Applies everything a real selection applies except the window, the
    /// size threshold and the run budget: Apple's rule, pinned chats, on-disk
    /// verification, the never-remove-twice list, and the date floor.
    public static func compute(db: ReadOnlyDatabase, store: MessagesStore, policy: Policy,
                               keepDaysChoices: [Int] = keepDaysChoices, minimumBytesChoices: [Int64] = minimumBytesChoices,
                               excludingPaths: Set<String> = [], now: Date = Date()) throws -> SavingsTable {
        let rows = try CandidateSelector.eligibleRows(db: db)
        var pinned = Set<Int64>()
        for r in rows where policy.isPinned(chatIdentifier: r.chatIdentifier, displayName: r.chatDisplayName) { pinned.insert(r.rowID) }
        let minMTime = now.addingTimeInterval(-TimeInterval(policy.minimumFileAgeHours) * 3_600)
        var seen = Set<Int64>()
        var items: [(date: Date, bytes: Int64)] = []
        for r in rows {
            guard seen.insert(r.rowID).inserted, !pinned.contains(r.rowID),
                  r.messageDate >= CandidateSelector.earliestPlausibleMessageDate else { continue }
            if let p = store.resolve(dbFilename: r.dbFilename)?.path, excludingPaths.contains(p) { continue }
            guard case .success(let c) = CandidateSelector.verify(row: r, store: store, minMTime: minMTime, requireExactSize: policy.requireExactSize) else { continue }
            items.append((c.messageDate, c.bytes))
        }
        var days = Set(keepDaysChoices); days.insert(policy.keepDays)
        var sizes = Set(minimumBytesChoices); sizes.insert(policy.minimumBytes)
        var out: [SavingsEstimate] = []
        for d in days.sorted() {
            let cutoff = now.addingTimeInterval(-TimeInterval(d) * 86_400)
            for s in sizes.sorted() {
                var files = 0
                var bytes: Int64 = 0
                for it in items where it.date < cutoff && it.bytes >= s { files += 1; bytes += it.bytes }
                out.append(SavingsEstimate(keepDays: d, minimumBytes: s, files: files, bytes: bytes))
            }
        }
        return SavingsTable(generatedAt: now, keepDaysChoices: days.sorted(), minimumBytesChoices: sizes.sorted(), estimates: out,
                            eligibleFiles: items.count, eligibleBytes: items.reduce(0) { $0 + $1.bytes })
    }

    /// "1 week", "1 month", "1 year", ...
    public static func label(keepDays d: Int) -> String {
        switch d {
        case 7: return "1 week"
        case 14: return "2 weeks"
        case 30: return "1 month"
        case 60: return "2 months"
        case 90: return "3 months"
        case 180: return "6 months"
        case 365: return "1 year"
        case 730: return "2 years"
        case 1095: return "3 years"
        case 1825: return "5 years"
        case 3650: return "10 years"
        default: return d % 365 == 0 ? "\(d / 365) years" : "\(d) days"
        }
    }

    public static func label(minimumBytes b: Int64) -> String {
        b == 0 ? "any size" : Format.bytes(b).replacingOccurrences(of: ".0 ", with: " ")
    }
}
