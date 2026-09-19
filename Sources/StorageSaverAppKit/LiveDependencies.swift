import AppKit
import Foundation
import ServiceManagement
import StorageSaverAutomation
import UserNotifications

/// Messages.app via NSRunningApplication. Bundle id verified on macOS 15.
public final class MessagesAppState: MessagesAppObserving {
    public static let bundleIdentifier = MessagesApp.bundleIdentifier
    public static let appURL = MessagesApp.appURL

    public init() {}

    private var app: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).first { !$0.isTerminated }
    }

    public var isRunning: Bool { app != nil }
    public var launchDate: Date? { app?.launchDate }

    public func relaunch() async {
        if let running = app {
            running.terminate() // graceful; never forceTerminate
            for _ in 0..<40 where !running.isTerminated {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard running.isTerminated else { return } // Messages refused to quit (unsent draft?); leave it
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: Self.appURL, configuration: config)
    }
}

/// Local notifications. Requires a real app bundle; a bare binary posts nothing.
public final class UserNotifier: Notifying {
    private var requested = false
    public init() {}

    static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public func notify(title: String, body: String, isProblem: Bool) {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if isProblem { content.sound = .defaultCritical; content.interruptionLevel = .timeSensitive } else { content.sound = .default }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if requested { post(); return }
        requested = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { post() } }
    }
}

/// Start at login through SMAppService (macOS 13+). Requires a bundle.
public final class LoginItem: LoginItemManaging {
    public init() {}

    public var status: LoginItemStatus {
        guard UserNotifier.canNotify else { return .unavailable }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        default: return .disabled
        }
    }

    public func set(enabled: Bool) throws {
        guard UserNotifier.canNotify else { return }
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    public func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

/// NSBackgroundActivityScheduler: every 6 h, an hour of tolerance, utility QoS.
public final class BackgroundScheduler: Scheduling {
    private var scheduler: NSBackgroundActivityScheduler?
    public let interval: TimeInterval
    public init(identifier: String = (Bundle.main.bundleIdentifier ?? "MessagesStorageSaver") + ".maintenance", interval: TimeInterval = 6 * 3600) {
        self.interval = interval
        scheduler = NSBackgroundActivityScheduler(identifier: identifier)
    }

    public func schedule(_ tick: @escaping @MainActor () async -> Void) {
        guard let scheduler else { return }
        scheduler.repeats = true
        scheduler.interval = interval
        scheduler.tolerance = min(3600, interval / 6)
        scheduler.qualityOfService = .utility
        scheduler.schedule { completion in
            Task { @MainActor in
                await tick()
                completion(.finished)
            }
        }
    }

    public func invalidate() { scheduler?.invalidate() }
}
