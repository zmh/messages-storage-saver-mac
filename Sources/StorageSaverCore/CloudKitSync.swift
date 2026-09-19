import Foundation
import ObjectiveC

/// Read-only view of Messages' iCloud sync state through IMCore getters
/// (`IMCloudKitEventNotificationManager.sharedInstance.syncState`). Used by
/// `mss sync-now` to print the state. Sending a sync request through IMCore
/// (`startPeriodicSync`) was tried and does not work from any process other
/// than Messages itself: imagent never completes the daemon connection
/// (verified on macOS 15.8), so "Sync now" presses Messages' own button via
/// Accessibility instead (StorageSaverAutomation). Everything is resolved at
/// runtime, so a macOS without these classes degrades to "unavailable".
public enum CloudKitSync {
    public struct State: Codable, Equatable {
        /// IMCore loaded and the manager class exists.
        public var available = false
        public var daemonConnected: Bool?
        public var syncingEnabled: Bool?
        public var syncingAvailable: Bool?
        public var canStartSyncing: Bool?
        public var isSyncing: Bool?
        public var lastSyncDate: Date?
        public var statusText: String?
        public var errorCount: Int?
    }

    public static let manualInstructions = "Messages › Settings › iMessage › Sync Now"

    private typealias ObjGetter = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>?
    private typealias BoolGetter = @convention(c) (AnyObject, Selector) -> Bool

    private static var loaded: Bool = {
        dlopen("/System/Library/PrivateFrameworks/IMCore.framework/IMCore", RTLD_NOW) != nil
    }()

    private static func call(_ obj: AnyObject, _ name: String) -> AnyObject? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel), let imp = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        return unsafeBitCast(imp, to: ObjGetter.self)(obj, sel)?.takeUnretainedValue()
    }

    private static func bool(_ obj: AnyObject, _ name: String) -> Bool? {
        let sel = NSSelectorFromString(name)
        guard obj.responds(to: sel), let imp = class_getMethodImplementation(type(of: obj), sel) else { return nil }
        return unsafeBitCast(imp, to: BoolGetter.self)(obj, sel)
    }

    private static func shared(_ className: String) -> AnyObject? {
        guard loaded, let cls = NSClassFromString(className) as? NSObject.Type else { return nil }
        return cls.perform(NSSelectorFromString("sharedInstance"))?.takeUnretainedValue()
    }

    private static func manager() -> AnyObject? { shared("IMCloudKitEventNotificationManager") }
    private static func daemon() -> AnyObject? { shared("IMDaemonController") }

    /// Read-only snapshot of what IMCore reports.
    public static func state() -> State {
        var s = State()
        guard let m = manager() else { return s }
        s.available = true
        s.daemonConnected = daemon().flatMap { bool($0, "isConnected") }
        guard let st = call(m, "syncState") else { return s }
        s.syncingEnabled = bool(st, "isSyncingEnabled")
        s.syncingAvailable = bool(st, "isSyncingAvailable")
        s.canStartSyncing = bool(st, "canStartSyncing")
        s.isSyncing = bool(st, "isSyncing")
        s.lastSyncDate = call(st, "lastSyncDate") as? Date
        s.statusText = call(st, "syncStatusText") as? String
        s.errorCount = (call(st, "errors") as? [Any])?.count
        return s
    }
}
