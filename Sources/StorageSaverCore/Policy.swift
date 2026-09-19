import Foundation

/// How the app tells you about runs.
public enum NotificationMode: String, Codable, CaseIterable {
    /// After every run that removed files, and on any problem.
    case runsAndProblems
    case problemsOnly
    case never
}

/// What to keep local and what may be offloaded. Persisted as JSON in
/// `~/Library/Application Support/MessagesStorageSaver/config.json`.
///
/// Decoding is tolerant of missing keys (each falls back to its default) but
/// strict about wrong types, so a hand-edited or corrupt file is reported as
/// unreadable instead of silently becoming the defaults.
public struct Policy: Codable, Equatable {
    public enum Mode: String, Codable {
        /// Offload every eligible attachment older than `keepDays`.
        case keepDays
        /// Offload oldest-first only until `targetFreeBytes` is available.
        case freeSpaceTarget
    }

    public struct Tiers: Codable, Equatable {
        /// Regenerable thumbnails under Caches/Previews.
        public var previewCache = true
        /// Synced attachments older than the window (the main lever).
        public var attachments = true
        /// Live Photo .MOV sidecars not referenced by any database row.
        public var liveSidecars = false
        public init() {}

        enum CodingKeys: String, CodingKey { case previewCache, attachments, liveSidecars }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Tiers()
            previewCache = try c.decodeIfPresent(Bool.self, forKey: .previewCache) ?? d.previewCache
            attachments = try c.decodeIfPresent(Bool.self, forKey: .attachments) ?? d.attachments
            liveSidecars = try c.decodeIfPresent(Bool.self, forKey: .liveSidecars) ?? d.liveSidecars
        }
    }

    public var mode: Mode = .keepDays
    public var keepDays: Int = 30
    /// Attachments smaller than this are never offloaded (0 = any size).
    public var minimumBytes: Int64 = 0
    public var targetFreeBytes: Int64 = 50_000_000_000
    /// chat_identifier or display_name values whose attachments are never touched.
    public var pinnedChats: [String] = []
    public var tiers = Tiers()
    public var archiveDirectory: String?
    /// Blast-radius limits. The first attachments run ever is capped harder.
    public var maxBytesPerRun: Int64 = 25_000_000_000
    public var firstRunMaxBytes: Int64 = 1_000_000_000
    public var automaticRuns = false
    /// Files modified more recently than this are never offloaded.
    public var minimumFileAgeHours: Int = 24
    /// Require the on-disk size to equal `attachment.total_bytes`. About 10% of
    /// eligible rows on a real store fail this (images stored locally in an
    /// optimized form, smaller than the original in iCloud); keep it strict
    /// until the restore path has been validated for those.
    public var requireExactSize = true
    /// Automatic runs wait for Messages.app to quit. Off by default: offloading
    /// while Messages is open is safe, Messages just shows stale thumbnails
    /// until it is relaunched.
    public var onlyWhileMessagesClosed = false
    public var notifications: NotificationMode = .runsAndProblems
    /// Bumped when the on-disk format changes incompatibly. A file written by
    /// a newer version is loaded but fails validation, so real runs refuse.
    public var configVersion = Policy.currentConfigVersion

    public static let currentConfigVersion = 1
    public static let minimumKeepDays = 7
    public static let maximumKeepDays = 3650
    /// Raising a run above this needs a typed confirmation in the app.
    public static let defaultMaxBytesPerRun: Int64 = 25_000_000_000
    public static let hardMaxBytesPerRun: Int64 = 100_000_000_000

    public init() {}

    enum CodingKeys: String, CodingKey {
        case mode, keepDays, minimumBytes, targetFreeBytes, pinnedChats, tiers, archiveDirectory, maxBytesPerRun, firstRunMaxBytes,
             automaticRuns, minimumFileAgeHours, requireExactSize, onlyWhileMessagesClosed, notifications, configVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Policy()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        keepDays = try c.decodeIfPresent(Int.self, forKey: .keepDays) ?? d.keepDays
        minimumBytes = try c.decodeIfPresent(Int64.self, forKey: .minimumBytes) ?? d.minimumBytes
        targetFreeBytes = try c.decodeIfPresent(Int64.self, forKey: .targetFreeBytes) ?? d.targetFreeBytes
        pinnedChats = try c.decodeIfPresent([String].self, forKey: .pinnedChats) ?? d.pinnedChats
        tiers = try c.decodeIfPresent(Tiers.self, forKey: .tiers) ?? d.tiers
        archiveDirectory = try c.decodeIfPresent(String.self, forKey: .archiveDirectory) ?? d.archiveDirectory
        maxBytesPerRun = try c.decodeIfPresent(Int64.self, forKey: .maxBytesPerRun) ?? d.maxBytesPerRun
        firstRunMaxBytes = try c.decodeIfPresent(Int64.self, forKey: .firstRunMaxBytes) ?? d.firstRunMaxBytes
        automaticRuns = try c.decodeIfPresent(Bool.self, forKey: .automaticRuns) ?? d.automaticRuns
        minimumFileAgeHours = try c.decodeIfPresent(Int.self, forKey: .minimumFileAgeHours) ?? d.minimumFileAgeHours
        requireExactSize = try c.decodeIfPresent(Bool.self, forKey: .requireExactSize) ?? d.requireExactSize
        onlyWhileMessagesClosed = try c.decodeIfPresent(Bool.self, forKey: .onlyWhileMessagesClosed) ?? d.onlyWhileMessagesClosed
        notifications = try c.decodeIfPresent(NotificationMode.self, forKey: .notifications) ?? d.notifications
        configVersion = try c.decodeIfPresent(Int.self, forKey: .configVersion) ?? d.configVersion
    }

    public static let supportDirectory: URL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MessagesStorageSaver")

    public static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }

    public enum LoadOutcome: Equatable {
        case loaded
        case noFile
        case unreadable(String)
    }

    /// Loads the config and says whether it was actually read. Callers that
    /// remove files must refuse to run on `.unreadable`: the defaults are more
    /// aggressive than most people's settings (30 days, no pinned chats).
    public static func loadChecked(from url: URL = configURL) -> (policy: Policy, outcome: LoadOutcome) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (Policy(), .noFile) }
        do {
            let data = try Data(contentsOf: url)
            return (try JSONDecoder().decode(Policy.self, from: data), .loaded)
        } catch {
            return (Policy(), .unreadable("\(error)"))
        }
    }

    public static func load(from url: URL = configURL) -> Policy {
        loadChecked(from: url).policy
    }

    public func save(to url: URL = configURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    /// Range checks shared by the app and the CLI. Empty means valid. Real runs
    /// refuse an invalid policy; dry runs and analysis accept anything.
    public func validationProblems(volumeCapacityBytes: Int64? = nil) -> [String] {
        var out: [String] = []
        if configVersion > Self.currentConfigVersion {
            out.append("config was written by a newer version (configVersion \(configVersion) > \(Self.currentConfigVersion))")
        }
        if keepDays < Self.minimumKeepDays || keepDays > Self.maximumKeepDays {
            out.append("keepDays must be between \(Self.minimumKeepDays) and \(Self.maximumKeepDays) (is \(keepDays))")
        }
        if minimumBytes < 0 || minimumBytes > 10_000_000_000 { out.append("minimumBytes must be between 0 and 10 GB") }
        if mode == .freeSpaceTarget {
            if targetFreeBytes < 1_000_000_000 { out.append("targetFreeBytes must be at least 1 GB") }
            if let cap = volumeCapacityBytes, targetFreeBytes > cap { out.append("targetFreeBytes exceeds the disk size") }
        }
        if maxBytesPerRun < 100_000_000 { out.append("maxBytesPerRun must be at least 100 MB") }
        if maxBytesPerRun > Self.hardMaxBytesPerRun { out.append("maxBytesPerRun must not exceed \(Format.bytes(Self.hardMaxBytesPerRun))") }
        if firstRunMaxBytes < 1_000_000 { out.append("firstRunMaxBytes must be at least 1 MB") }
        if minimumFileAgeHours < 0 { out.append("minimumFileAgeHours must not be negative") }
        if let a = archiveDirectory, a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("archiveDirectory is empty; remove the key or set a folder")
        }
        return out
    }

    /// Knobs the app never exposes. Non-default values are shown in Health so
    /// a hand-edited config cannot quietly weaken the safety checks.
    public var nonDefaultSafetySettings: [String] {
        var out: [String] = []
        if !requireExactSize { out.append("requireExactSize is off") }
        if minimumFileAgeHours < 24 { out.append("minimumFileAgeHours is \(minimumFileAgeHours) (default 24)") }
        if tiers.liveSidecars { out.append("the sidecar tier is enabled (not validated)") }
        if firstRunMaxBytes > 1_000_000_000 { out.append("firstRunMaxBytes is \(Format.bytes(firstRunMaxBytes)) (default 1.0 GB)") }
        if maxBytesPerRun > Self.defaultMaxBytesPerRun { out.append("maxBytesPerRun is \(Format.bytes(maxBytesPerRun)) (default 25.0 GB)") }
        return out
    }

    public func isPinned(chatIdentifier: String?, displayName: String?) -> Bool {
        let set = Set(pinnedChats)
        if let c = chatIdentifier, set.contains(c) { return true }
        if let d = displayName, !d.isEmpty, set.contains(d) { return true }
        return false
    }
}
