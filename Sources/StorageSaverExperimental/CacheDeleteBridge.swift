import Foundation

/// Read-only bridge to the private CacheDelete framework, the system service
/// that asks registered daemons (including imagent) how much space they could
/// free at a given urgency. Only query functions are exposed here; requesting
/// an actual purge lives in `AppleOffload` and is never run automatically.
public enum CacheDeleteBridge {
    public static let messagesPluginID = "com.apple.imagent.cache-delete"

    public struct PurgeableReport: Codable {
        public let urgency: Int
        public let amount: Int64
        public let nonPurgeableAmount: Int64
        public let freeSpace: Int64
        public let volume: String
        public let cachedResult: Bool
        public let raw: [String: String]
    }

    private typealias CopyPurgeableFn = @convention(c) (CFDictionary?) -> Unmanaged<CFDictionary>?
    private typealias CopyHistoryFn = @convention(c) (CFDictionary?) -> Unmanaged<CFTypeRef>?

    private static let frameworkPath = "/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete"

    private static var handle: UnsafeMutableRawPointer? = {
        dlopen(frameworkPath, RTLD_NOW)
    }()

    public static var isAvailable: Bool { handle != nil && dlsym(handle, "CacheDeleteCopyPurgeableSpaceWithInfo") != nil }

    /// How much the Messages daemon reports as purgeable at `urgency` (0–4).
    public static func purgeableSpace(pluginID: String = messagesPluginID, urgency: Int, volume: String = "/") -> PurgeableReport? {
        guard let handle, let sym = dlsym(handle, "CacheDeleteCopyPurgeableSpaceWithInfo") else { return nil }
        let fn = unsafeBitCast(sym, to: CopyPurgeableFn.self)
        let info: [String: Any] = [
            "CACHE_DELETE_ID": pluginID,
            "CACHE_DELETE_URGENCY": urgency,
            "CACHE_DELETE_VOLUME": volume,
        ]
        guard let result = fn(info as CFDictionary)?.takeRetainedValue() as? [String: Any] else { return nil }
        func int(_ key: String) -> Int64 { (result[key] as? NSNumber)?.int64Value ?? 0 }
        var raw: [String: String] = [:]
        for (k, v) in result { raw[k] = String(describing: v) }
        return PurgeableReport(
            urgency: urgency,
            amount: int("CACHE_DELETE_AMOUNT"),
            nonPurgeableAmount: int("CACHE_DELETE_NONPURGEABLE_AMOUNT"),
            freeSpace: int("CACHE_DELETE_FREESPACE"),
            volume: (result["CACHE_DELETE_VOLUME"] as? String) ?? volume,
            cachedResult: int("CACHE_DELETE_CACHED_RESULT") != 0,
            raw: raw
        )
    }

    public static func purgeableSpaceAllUrgencies(pluginID: String = messagesPluginID) -> [PurgeableReport] {
        (0...4).compactMap { purgeableSpace(pluginID: pluginID, urgency: $0) }
    }

    /// Description of the daemon's purge history, if the framework exposes it.
    public static func purgeHistoryDescription() -> String? {
        guard let handle, let sym = dlsym(handle, "CacheDeleteCopyPurgeHistory") else { return nil }
        let fn = unsafeBitCast(sym, to: CopyHistoryFn.self)
        guard let result = fn(nil)?.takeRetainedValue() else { return nil }
        return String(describing: result)
    }
}
