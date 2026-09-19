import AppKit
import Foundation

/// Regular app with a Dock icon when you launch it; menu-bar-only when
/// launchd starts it as a login item. Single instance. Orderly shutdown: a
/// run in progress is cancelled (it finishes its current file and writes
/// run-end) before the app quits, sleeps, or the Mac powers off.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public var model: AppModel?
    private var observers: [NSObjectProtocol] = []

    public func applicationWillFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            if let other = others.first {
                other.activate()
                NSApp.terminate(nil)
            }
        }
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        if Self.launchedAsLoginItem() {
            // Automatic runs keep the app resident: no Dock icon, no window,
            // until the user opens it from the menu bar.
            model?.noteLaunchedAsLoginItem()
            NSApp.setActivationPolicy(.accessory)
            for window in NSApp.windows where Self.isMainWindow(window) { window.close() }
        }
        model?.start()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model?.cancelRun() }
            })
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.model?.updateRelaunchFlag() }
            })
        }
    }

    /// Dock icon click or a second Spotlight launch while running.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model?.openMainWindow() }
        return true
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        model?.shouldQuitWhenLastWindowCloses ?? true
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.activity.isRunning else { return .terminateNow }
        model.cancelRun()
        Task { @MainActor in
            for _ in 0..<600 where model.activity.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    public func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    static func launchedAsLoginItem() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent, event.eventID == kAEOpenApplication else { return false }
        return event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        (window.identifier?.rawValue.hasPrefix("main") ?? false) || window.title == "Messages Storage Saver"
    }
}
