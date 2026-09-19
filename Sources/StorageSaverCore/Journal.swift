import Foundation

/// One line per action, appended before the action happens, fsync'd.
public struct JournalEntry: Codable, Equatable {
    public var timestamp: Date
    public var runID: String
    /// run-start, run-counters, run-end, offload, archive, preview-cache, sidecar,
    /// canary, cancel, acknowledge, restore, apple-defaults, apple-purge-request
    public var action: String
    public var tier: String?
    public var path: String?
    public var bytes: Int64?
    public var rowID: Int64?
    public var guid: String?
    public var ckRecordID: String?
    public var chat: String?
    public var messageDate: Date?
    public var archivePath: String?
    public var dryRun: Bool
    public var note: String?
    /// Deletion-queue counters at run boundaries, so later checks can tell a
    /// deletion queued during a run from one queued at any other time.
    public var tombstoneAttachmentsSeq: Int64?
    public var tombstoneMessagesSeq: Int64?

    public init(runID: String, action: String, dryRun: Bool, tier: String? = nil, path: String? = nil, bytes: Int64? = nil,
                rowID: Int64? = nil, guid: String? = nil, ckRecordID: String? = nil, chat: String? = nil,
                messageDate: Date? = nil, archivePath: String? = nil, note: String? = nil, timestamp: Date = Date()) {
        self.timestamp = timestamp; self.runID = runID; self.action = action; self.dryRun = dryRun; self.tier = tier
        self.path = path; self.bytes = bytes; self.rowID = rowID; self.guid = guid; self.ckRecordID = ckRecordID
        self.chat = chat; self.messageDate = messageDate; self.archivePath = archivePath; self.note = note
    }
}

/// How a run ended, as recorded by the prefix of its run-end note.
public enum RunOutcome: String, Codable {
    /// Finished normally.
    case ok
    /// Stopped by the user; nothing wrong happened.
    case cancelled
    /// Stopped as a precaution because Messages queued deletions for iCloud
    /// during the run that did not involve any file this tool touched.
    case stopped
    /// A canary fired, a prerequisite regressed, or an archive/journal write
    /// failed. Automatic runs stay off until acknowledged.
    case problem
    /// run-start without run-end: crash, power loss, or still running.
    case incomplete

    static func parse(_ note: String?) -> RunOutcome {
        for o in [RunOutcome.ok, .cancelled, .stopped, .problem] where (note ?? "").hasPrefix(o.rawValue) { return o }
        return .incomplete
    }
}

/// One run reconstructed from its run-start / run-end entries.
public struct RunSummary: Codable, Equatable {
    public var runID: String
    public var started: Date
    public var ended: Date?
    public var dryRun: Bool
    public var origin: String?
    public var tiers: [String]
    public var budgetBytes: Int64?
    /// Files removed across all tiers (from the run-end note).
    public var files: Int
    public var bytes: Int64
    /// Attachment files this run actually removed (offload entries).
    public var attachmentsRemoved: Int
    public var outcome: RunOutcome
    public var note: String?
}

public final class Journal {
    public let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public static var defaultURL: URL { Policy.supportDirectory.appendingPathComponent("journal.jsonl") }

    public init(url: URL = Journal.defaultURL) {
        self.url = url
    }

    public func append(_ entry: JournalEntry) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        var line = try encoder.encode(entry)
        line.append(0x0A)
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    public func readAll() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(JournalEntry.self, from: $0) }
    }

    /// Marks a problem run as seen. Acknowledging never re-enables automatic
    /// runs by itself.
    public func appendAcknowledgement(runID: String, note: String? = nil) throws {
        try append(JournalEntry(runID: runID, action: "acknowledge", dryRun: false, note: note))
    }

    public func acknowledgedRunIDs() -> Set<String> {
        Set(readAll().filter { $0.action == "acknowledge" }.map(\.runID))
    }

    /// Parses `key=value` pairs from a run-start / run-end note.
    static func fields(_ note: String?) -> [String: String] {
        var out: [String: String] = [:]
        for token in (note ?? "").split(separator: " ") {
            if let eq = token.firstIndex(of: "=") {
                out[String(token[..<eq])] = String(token[token.index(after: eq)...])
            }
        }
        return out
    }

    /// Every run, oldest first, reconstructed from run-start/run-end pairs.
    public func runSummaries() -> [RunSummary] {
        let entries = readAll()
        var order: [String] = []
        var summaries: [String: RunSummary] = [:]
        var removedByRun: [String: Int] = [:]
        for e in entries {
            switch e.action {
            case "run-start":
                let f = Self.fields(e.note)
                order.append(e.runID)
                summaries[e.runID] = RunSummary(
                    runID: e.runID, started: e.timestamp, ended: nil, dryRun: e.dryRun, origin: f["origin"],
                    tiers: (f["tiers"] ?? "").split(separator: ",").map(String.init), budgetBytes: f["budget"].flatMap { Int64($0) },
                    files: 0, bytes: 0, attachmentsRemoved: 0, outcome: .incomplete, note: e.note
                )
            case "run-end":
                guard var s = summaries[e.runID] else { continue }
                s.ended = e.timestamp
                s.outcome = RunOutcome.parse(e.note)
                s.files = Int(Self.fields(e.note)["files"] ?? "") ?? 0
                s.bytes = e.bytes ?? 0
                s.note = e.note
                summaries[e.runID] = s
            case "offload":
                if !e.dryRun { removedByRun[e.runID, default: 0] += 1 }
            default:
                continue
            }
        }
        return order.compactMap { id in
            guard var s = summaries[id] else { return nil }
            s.attachmentsRemoved = removedByRun[id] ?? 0
            return s
        }
    }

    /// True once a non-dry run of the given tier finished with outcome `ok`
    /// (for attachments: and removed at least one file). The first attachments
    /// run is budget-capped harder than later ones. With no tier, any real run
    /// that ended `ok` counts.
    public func hasCompletedRealRun(tier: Tier? = nil, origin: String? = nil) -> Bool {
        runSummaries().contains { s in
            guard !s.dryRun, s.outcome == .ok else { return false }
            if let origin, s.origin != origin { return false }
            guard let tier else { return true }
            guard s.tiers.contains(tier.rawValue) else { return false }
            return tier == .attachments ? s.attachmentsRemoved >= 1 : true
        }
    }

    /// Individual files this tool removed (real runs only). The preview cache
    /// is journaled as one aggregate entry per run and is not included here.
    public func removedEntries() -> [JournalEntry] {
        readAll().filter { !$0.dryRun && ["offload", "sidecar"].contains($0.action) && $0.path != nil }
    }

    /// Paths this tool has removed at least once. A file that came back (the
    /// user re-downloaded or restored it) is never removed a second time.
    public func removedPaths() -> Set<String> {
        Set(removedEntries().compactMap(\.path))
    }

    /// Bytes of regenerable preview cache cleared by real runs.
    public func previewCacheBytesCleared() -> Int64 {
        readAll().filter { !$0.dryRun && $0.action == "preview-cache" }.reduce(0) { $0 + ($1.bytes ?? 0) }
    }
}
