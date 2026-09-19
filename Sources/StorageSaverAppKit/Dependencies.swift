import Foundation

/// Messages.app as the model sees it. Offloading while Messages runs is safe
/// (sync safety comes from the database checks); Messages just shows stale
/// thumbnails until relaunched, so the model tracks whether a relaunch is due.
public protocol MessagesAppObserving: AnyObject {
    var isRunning: Bool { get }
    var launchDate: Date? { get }
    /// Graceful quit followed by reopen. Only ever called on a user's click.
    func relaunch() async
}

public protocol Notifying: AnyObject {
    func notify(title: String, body: String, isProblem: Bool)
}

public enum LoginItemStatus: Equatable {
    case enabled
    case disabled
    /// Registered, but the user must approve it in System Settings › Login Items.
    case requiresApproval
    /// Not running from an app bundle (bare `swift run`), so no login item.
    case unavailable
}

public protocol LoginItemManaging: AnyObject {
    var status: LoginItemStatus { get }
    func set(enabled: Bool) throws
    func openSystemSettings()
}

/// Periodic wake-ups. The model decides on each tick whether anything runs.
public protocol Scheduling: AnyObject {
    func schedule(_ tick: @escaping @MainActor () async -> Void)
    func invalidate()
}
