import Foundation
import CoreFoundation

/// Apple's own attachment offload lives inside the Messages daemon and is
/// switched off by user defaults in com.apple.madrid. These helpers read and
/// (only when the user explicitly asks) set those switches, restart the
/// daemon, and request a purge through the system CacheDelete service.
public enum AppleOffload {
    public static let domain = "com.apple.madrid"
    /// Callback model: the system asks imagent to purge; imagent validates
    /// each attachment against CloudKit, deletes the file, updates the row.
    public static let callbackKeys = ["EnableCacheDelete", "PurgeWithCacheDelete"]
    /// Centralized model: imagent marks eligible files APFS-purgeable and the
    /// OS reclaims them on demand.
    public static let centralizedKeys = ["EnableCentralizedCacheDelete", "EnableAttachmentsPurgeabilityMonitoring"]

    public static func status() -> [String: String] {
        var out: [String: String] = [:]
        for key in callbackKeys + centralizedKeys {
            if let n = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? NSNumber {
                out[key] = n.boolValue ? "true" : "false"
            } else {
                out[key] = "unset"
            }
        }
        return out
    }

    /// Sets the given keys to true. Returns the shell equivalent for the journal.
    @discardableResult
    public static func enable(keys: [String]) -> String {
        for key in keys { CFPreferencesSetAppValue(key as CFString, kCFBooleanTrue, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
        return keys.map { "defaults write \(domain) \($0) -bool YES" }.joined(separator: "; ")
    }

    @discardableResult
    public static func disable(keys: [String]) -> String {
        for key in keys { CFPreferencesSetAppValue(key as CFString, nil, domain as CFString) }
        CFPreferencesAppSynchronize(domain as CFString)
        return keys.map { "defaults delete \(domain) \($0)" }.joined(separator: "; ")
    }

    /// imagent reads the switches at launch ("Setting up cache delete callbacks").
    /// System Integrity Protection refuses `launchctl kickstart` for Apple's
    /// services, but a termination signal is allowed and launchd relaunches
    /// the daemon at once (the classic `killall imagent`).
    public static func restartDaemon() -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["imagent"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            return (p.terminationStatus, out + "\nIf the signal is refused, restart the Mac so imagent relaunches with the new switches.")
        }
        return (0, out.isEmpty ? "imagent signalled; launchd relaunches it" : out)
    }

    /// Recovered from the framework's code: the entry point takes the info
    /// dictionary and a completion block that receives one dictionary (the
    /// daemon's reply, or an error entry), and returns a request token.
    private typealias PurgeFn = @convention(c) (CFDictionary?, AnyObject?) -> Unmanaged<AnyObject>?
    private typealias PurgeCallback = @convention(block) (NSDictionary?) -> Void

    /// Asks CacheDelete to purge `bytes` from the Messages plugin at `urgency`
    /// and waits up to `timeout` seconds for the reply. The daemon, not this
    /// process, chooses and removes files. Returns the reply, or nil if the
    /// symbol is unavailable.
    public static func requestPurge(bytes: Int64, urgency: Int, volume: String = "/", timeout: TimeInterval = 180) -> [String: String]? {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/CacheDelete.framework/CacheDelete", RTLD_NOW),
              let sym = dlsym(handle, "CacheDeletePurgeSpaceWithInfoSync") else { return nil }
        let fn = unsafeBitCast(sym, to: PurgeFn.self)
        let info: [String: Any] = [
            "CACHE_DELETE_ID": CacheDeleteBridge.messagesPluginID,
            "CACHE_DELETE_AMOUNT": bytes,
            "CACHE_DELETE_URGENCY": urgency,
            "CACHE_DELETE_VOLUME": volume,
        ]
        let done = DispatchSemaphore(value: 0)
        var reply: [String: String] = [:]
        let callback: PurgeCallback = { result in
            if let result { for (k, v) in result { reply[String(describing: k)] = String(describing: v) } }
            else { reply["result"] = "nil reply" }
            done.signal()
        }
        let token = fn(info as CFDictionary, callback as AnyObject)
        reply["token"] = token.map { String(describing: $0.takeUnretainedValue()) } ?? "nil"
        if done.wait(timeout: .now() + timeout) == .timedOut { reply["result"] = "timed out after \(Int(timeout)) s waiting for the daemon's reply" }
        return reply
    }
}
