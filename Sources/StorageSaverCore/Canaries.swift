import Foundation

/// Signals that would mean something went wrong at the iCloud level. The
/// tombstone tables only grow when a deletion is queued for CloudKit, and an
/// offloaded row should stay `ck_sync_state = 1` forever.
public struct CanarySnapshot: Codable, Equatable {
    public var takenAt: Date
    /// Current queue lengths (informational: Apple's sync engine drains them).
    public var tombstoneAttachments: Int64
    public var tombstoneMessages: Int64
    /// Auto-increment counters of the tombstone tables. These only ever grow,
    /// so an increase means a deletion was queued for iCloud at some point,
    /// even if the queue has since been flushed. Optional for old baselines.
    public var tombstoneAttachmentsSeq: Int64?
    public var tombstoneMessagesSeq: Int64?
    /// rowID -> ck_sync_state for watched rows.
    public var rowSyncStates: [Int64: Int64]

    public static var baselineURL: URL { Policy.supportDirectory.appendingPathComponent("baseline.json") }

    /// The same snapshot watching only `rowIDs` (the rows a run has touched
    /// so far); the counters are kept.
    public func restricted(to rowIDs: [Int64]) -> CanarySnapshot {
        var copy = self
        let keep = Set(rowIDs)
        copy.rowSyncStates = rowSyncStates.filter { keep.contains($0.key) }
        return copy
    }
}

/// Two kinds of finding. `hard` means a row this tool touched changed in a
/// way that suggests an iCloud-level deletion; it trips the kill switch.
/// `external` means Messages queued deletions for iCloud while none of the
/// touched rows changed (Recently Deleted expiry, a deletion made on another
/// device): a run stops as a precaution but it is not this tool's doing.
public struct CanaryAssessment: Equatable {
    public var hard: [String] = []
    public var external: [String] = []
    public var all: [String] { hard + external }
    public var isClean: Bool { hard.isEmpty && external.isEmpty }
}

public enum Canaries {
    static func sequence(db: ReadOnlyDatabase, table: String) throws -> Int64 {
        // sqlite_sequence is absent until the first AUTOINCREMENT insert.
        let rows = try db.query("SELECT seq FROM sqlite_sequence WHERE name = ?", [.text(table)])
        return rows.first?.int("seq") ?? 0
    }

    public static func snapshot(db: ReadOnlyDatabase, rowIDs: [Int64], now: Date = Date()) throws -> CanarySnapshot {
        let a = try db.scalarInt("SELECT COUNT(*) FROM sync_deleted_attachments")
        let m = try db.scalarInt("SELECT COUNT(*) FROM sync_deleted_messages")
        let aSeq = try sequence(db: db, table: "sync_deleted_attachments")
        let mSeq = try sequence(db: db, table: "sync_deleted_messages")
        var states: [Int64: Int64] = [:]
        for chunk in stride(from: 0, to: rowIDs.count, by: 500).map({ Array(rowIDs[$0..<min($0 + 500, rowIDs.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("SELECT ROWID AS rowid, ck_sync_state AS ck FROM attachment WHERE ROWID IN (\(placeholders))", chunk.map { .int($0) })
            for r in rows { if let id = r.int("rowid") { states[id] = r.int("ck") ?? -1 } }
            for id in chunk where states[id] == nil { states[id] = -2 } // row vanished
        }
        return CanarySnapshot(takenAt: now, tombstoneAttachments: a, tombstoneMessages: m,
                              tombstoneAttachmentsSeq: aSeq, tombstoneMessagesSeq: mSeq, rowSyncStates: states)
    }

    /// Classifies what changed between two snapshots. Queue lengths shrinking
    /// is normal (Apple flushes them to iCloud); the auto-increment counters
    /// growing is what signals a new queued deletion.
    public static func assess(before: CanarySnapshot, after: CanarySnapshot) -> CanaryAssessment {
        var tombstones: [String] = []
        if let b = before.tombstoneAttachmentsSeq, let a = after.tombstoneAttachmentsSeq {
            if a > b { tombstones.append("\(a - b) attachment deletion(s) were queued for iCloud since the baseline (sync_deleted_attachments counter \(b) → \(a))") }
        } else if after.tombstoneAttachments > before.tombstoneAttachments {
            tombstones.append("sync_deleted_attachments grew \(before.tombstoneAttachments) → \(after.tombstoneAttachments): an attachment deletion was queued for iCloud")
        }
        if let b = before.tombstoneMessagesSeq, let a = after.tombstoneMessagesSeq {
            if a > b { tombstones.append("\(a - b) message deletion(s) were queued for iCloud since the baseline (sync_deleted_messages counter \(b) → \(a))") }
        } else if after.tombstoneMessages > before.tombstoneMessages {
            tombstones.append("sync_deleted_messages grew \(before.tombstoneMessages) → \(after.tombstoneMessages): a message deletion was queued for iCloud")
        }
        var left = 0
        var vanished = 0
        for (id, ck) in before.rowSyncStates where ck == 1 {
            switch after.rowSyncStates[id] {
            case .some(1), .none: continue
            case .some(-2): vanished += 1
            default: left += 1
            }
        }
        var rowProblems: [String] = []
        if left > 0 { rowProblems.append("\(left) offloaded row(s) left ck_sync_state = 1 (no longer marked as synced to iCloud)") }
        if vanished > 0 { rowProblems.append("\(vanished) offloaded row(s) disappeared from the attachment table") }

        // Touched rows intact: the queued deletions concern other rows.
        if rowProblems.isEmpty { return CanaryAssessment(hard: [], external: tombstones) }
        return CanaryAssessment(hard: tombstones + rowProblems, external: [])
    }

    /// Every finding, hard and external, as text. Empty means healthy.
    public static func violations(before: CanarySnapshot, after: CanarySnapshot) -> [String] {
        assess(before: before, after: after).all
    }

    public static func saveBaselineIfMissing(_ s: CanarySnapshot, url: URL = CanarySnapshot.baselineURL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(s).write(to: url, options: .atomic)
    }

    public static func loadBaseline(url: URL = CanarySnapshot.baselineURL) -> CanarySnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try? d.decode(CanarySnapshot.self, from: data)
    }

    /// Baselines written before the counters existed get them filled in from
    /// the current database (the counters are monotonic, so this can only
    /// make the check stricter going forward).
    public static func loadBaselineMigrating(db: ReadOnlyDatabase, url: URL) -> CanarySnapshot? {
        guard var b = loadBaseline(url: url) else { return nil }
        if b.tombstoneAttachmentsSeq == nil || b.tombstoneMessagesSeq == nil {
            b.tombstoneAttachmentsSeq = try? sequence(db: db, table: "sync_deleted_attachments")
            b.tombstoneMessagesSeq = try? sequence(db: db, table: "sync_deleted_messages")
            let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? e.encode(b) { try? data.write(to: url, options: .atomic) }
        }
        return b
    }
}
