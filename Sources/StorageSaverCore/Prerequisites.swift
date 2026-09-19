import Foundation
import CoreFoundation

/// Everything that must be true before any offload is allowed, plus the
/// state of Apple's own (dormant) cache-delete switches. All reads.
public struct Prerequisites: Codable {
    public struct Check: Codable, Equatable {
        public let name: String
        /// true = ok, false = blocker, nil = informational / not applicable
        public let ok: Bool?
        public let detail: String
        /// Only matters when removing files whose other copy is in iCloud.
        public var cloudRelated: Bool = false

        public init(name: String, ok: Bool?, detail: String, cloudRelated: Bool = false) {
            self.name = name; self.ok = ok; self.detail = detail; self.cloudRelated = cloudRelated
        }
    }

    public var store: String
    public var fullDiskAccess: Bool
    public var cloudKitSyncingEnabled: Bool?
    public var lastSyncDate: Date?
    public var lastDownloadProgress: Double?
    public var hasRecordsToDownload: Bool?
    public var cloudKitAccountStatus: Int?
    public var keepMessagesForDays: Int?
    public var serverBagCacheDeleteVersion: Int?
    /// EnableCacheDelete, PurgeWithCacheDelete, EnableCentralizedCacheDelete,
    /// EnableAttachmentsPurgeabilityMonitoring in com.apple.madrid.
    public var appleOffloadDefaults: [String: String]
    public var freeBytes: Int64
    public var freeBytesForImportantUsage: Int64
    public var transfersInProgress: Int64?
    public var tombstoneAttachments: Int64?
    public var tombstoneMessages: Int64?
    public var archive: ArchiveCheck?
    public var checks: [Check]
    public var blockers: [String] { checks.filter { $0.ok == false }.map { "\($0.name): \($0.detail)" } }
    public var readyForOffload: Bool { blockers.isEmpty }
    /// Blockers that apply when only regenerable local caches are removed.
    public var localOnlyBlockers: [String] { checks.filter { $0.ok == false && !$0.cloudRelated }.map { "\($0.name): \($0.detail)" } }
    /// Apple's Keep Messages setting deletes from iCloud and every device;
    /// the app blocks automatic runs while it is set.
    public var keepMessagesIsSet: Bool { keepMessagesForDays != nil }

    public static let appleDefaultKeys = [
        "EnableCacheDelete", "PurgeWithCacheDelete", "EnableCentralizedCacheDelete", "EnableAttachmentsPurgeabilityMonitoring",
    ]

    public static func evaluate(store: MessagesStore, db: ReadOnlyDatabase? = nil, archiveDirectory: URL? = nil) -> Prerequisites {
        var checks: [Check] = []
        let fda = hasFullDiskAccess(store: store)
        checks.append(Check(name: "Full Disk Access", ok: fda, detail: fda ? "chat.db is readable" : "cannot open \(store.chatDB.path) (grant Full Disk Access in System Settings › Privacy & Security)"))

        let madrid = "com.apple.madrid"
        let syncing = prefBool("CloudKitSyncingEnabled", madrid)
        let syncDate = prefDate("CloudKitSyncDate", madrid)
        let progress = prefDouble("CloudKitLastDownloadProgress", madrid)
        let hasRecords = prefBool("CloudKitHasAvailableRecordsToDownload", madrid)
        let accountStatus = prefInt("IMCloudKitAccountStatusKey", madrid)
        let keepDays = prefInt("KeepMessageForDays", "com.apple.iChat")
        let bagVersion = serverBagCacheDeleteVersion()
        var defaults: [String: String] = [:]
        for key in appleDefaultKeys {
            if let b = prefBool(key, madrid) { defaults[key] = b ? "true" : "false" } else { defaults[key] = "unset" }
        }

        if store.isLive {
            checks.append(Check(name: "Messages in iCloud", ok: syncing == true, detail: syncing == true ? "CloudKitSyncingEnabled = 1" : "CloudKitSyncingEnabled is \(syncing.map { String($0) } ?? "unset"); offloading requires the iCloud copy", cloudRelated: true))
            // Deletions made on other devices only reach this Mac through a
            // sync, so a stale sync could hide that an iCloud copy is gone.
            let recent = syncDate.map { Date().timeIntervalSince($0) < 48 * 3_600 } ?? false
            checks.append(Check(name: "Recent sync", ok: recent, detail: "last CloudKit sync \(Format.date(syncDate)) (must be within 48 h)", cloudRelated: true))
            checks.append(Check(name: "Initial download complete", ok: (progress ?? 0) >= 1.0, detail: "CloudKitLastDownloadProgress = \(progress.map { String($0) } ?? "unset")", cloudRelated: true))
            if let db {
                // Ground truth from the database: every message older than an
                // hour has been uploaded to CloudKit.
                let unsynced = (try? db.scalarInt("SELECT COUNT(*) FROM message WHERE ck_sync_state = 0 AND date < (strftime('%s','now') - 3600 - 978307200) * 1000000000")) ?? -1
                checks.append(Check(name: "Uploads caught up", ok: unsynced == 0, detail: unsynced == 0 ? "every message older than 1 h is in iCloud" : "\(unsynced) messages older than 1 h not yet uploaded (sync still running, or signed out)", cloudRelated: true))
            }
            // The daemon keeps this flag set between passes; informational only.
            checks.append(Check(name: "Records-available flag", ok: nil, detail: "CloudKitHasAvailableRecordsToDownload = \(hasRecords.map { $0 ? "1" : "0" } ?? "unset") (daemon hint, not a backlog measure)", cloudRelated: true))
        } else {
            checks.append(Check(name: "Messages in iCloud", ok: nil, detail: "not applicable to a fixture store"))
        }
        if let keepDays {
            checks.append(Check(name: "Keep Messages setting", ok: nil, detail: "WARNING: Messages › Settings › General › Keep messages is set to \(keepDays) days. That Apple setting deletes messages and attachments from iCloud and every device. This tool never changes it; consider setting it back to Forever."))
        }

        let (free, important) = freeSpace(at: store.root)
        checks.append(Check(name: "Free space", ok: free >= 2_000_000_000, detail: "\(Format.bytes(free)) free (\(Format.bytes(important)) counting purgeable)"))

        var inProgress: Int64?
        var tombA: Int64?
        var tombM: Int64?
        if let db {
            inProgress = try? db.scalarInt("SELECT COUNT(*) FROM attachment WHERE transfer_state NOT IN (-1, 0, 5, 7)")
            tombA = try? db.scalarInt("SELECT COUNT(*) FROM sync_deleted_attachments")
            tombM = try? db.scalarInt("SELECT COUNT(*) FROM sync_deleted_messages")
            checks.append(Check(name: "No transfers in progress", ok: (inProgress ?? 0) == 0, detail: "\(inProgress ?? -1) attachment rows in a transient transfer state"))
        }

        var archive: ArchiveCheck?
        if let archiveDirectory {
            let a = ArchiveLocation.check(archiveDirectory, store: store)
            archive = a
            // A same-disk archive is allowed but pointless for freeing space; flagged, not blocked.
            checks.append(Check(name: "Archive folder", ok: a.blocker == nil ? (a.sameVolumeAsStore == true ? nil : true) : false, detail: a.detail))
        }

        return Prerequisites(
            store: store.root.path, fullDiskAccess: fda, cloudKitSyncingEnabled: syncing, lastSyncDate: syncDate,
            lastDownloadProgress: progress, hasRecordsToDownload: hasRecords, cloudKitAccountStatus: accountStatus,
            keepMessagesForDays: keepDays, serverBagCacheDeleteVersion: bagVersion, appleOffloadDefaults: defaults,
            freeBytes: free, freeBytesForImportantUsage: important, transfersInProgress: inProgress,
            tombstoneAttachments: tombA, tombstoneMessages: tombM, archive: archive, checks: checks
        )
    }

    /// Cheap re-check used at run checkpoints and after wake: the conditions
    /// that can change underneath a running offload without the database
    /// showing it. Empty means nothing regressed.
    public static func regressions(store: MessagesStore, archiveDirectory: URL?, needsCloud: Bool) -> [String] {
        var out: [String] = []
        if !hasFullDiskAccess(store: store) { out.append("Full Disk Access: chat.db is no longer readable") }
        if needsCloud, store.isLive, prefBool("CloudKitSyncingEnabled", "com.apple.madrid") != true {
            out.append("Messages in iCloud: turned off during the run")
        }
        if let archiveDirectory, let b = ArchiveLocation.check(archiveDirectory, store: store).blocker {
            out.append("Archive folder: \(b)")
        }
        return out
    }

    // MARK: - Readers

    public static func hasFullDiskAccess(store: MessagesStore) -> Bool {
        let fd = open(store.chatDB.path, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES ? FileManager.default.fileExists(atPath: store.chatDB.path) : false
    }

    static func pref(_ key: String, _ domain: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, domain as CFString)
    }
    static func prefBool(_ key: String, _ domain: String) -> Bool? { (pref(key, domain) as? NSNumber)?.boolValue }
    static func prefInt(_ key: String, _ domain: String) -> Int? { (pref(key, domain) as? NSNumber)?.intValue }
    static func prefDouble(_ key: String, _ domain: String) -> Double? { (pref(key, domain) as? NSNumber)?.doubleValue }
    static func prefDate(_ key: String, _ domain: String) -> Date? { pref(key, domain) as? Date }

    /// `ck-cache-delete-version` from the cached iMessage server bag; non-zero
    /// means Apple's servers allow the cache-delete feature for this account.
    public static func serverBagCacheDeleteVersion() -> Int? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.apple.imessage.bag.plist")
        guard let data = try? Data(contentsOf: url),
              let outer = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let cached = outer["CachedBag"] as? Data,
              let bag = try? PropertyListSerialization.propertyList(from: cached, format: nil) as? [String: Any] else { return nil }
        return (bag["ck-cache-delete-version"] as? NSNumber)?.intValue
    }

    public static func freeSpace(at url: URL) -> (free: Int64, importantUsage: Int64) {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Int64(values?.volumeAvailableCapacity ?? 0), values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    public static func volumeCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map(Int64.init)
    }
}
