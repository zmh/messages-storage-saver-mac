import AppKit
import ApplicationServices
import Foundation

/// Messages.app identity, shared by the app and the command line.
public enum MessagesApp {
    public static let bundleIdentifier = "com.apple.MobileSMS"
    public static let appURL = URL(fileURLWithPath: "/System/Applications/Messages.app")
}

/// Presses Messages' own "Sync Now" button (Messages › Settings › iMessage)
/// through the Accessibility API. The daemon accepts sync requests only from
/// Messages itself, so this is the one way another app can ask for an upload
/// pass. Needs the Accessibility permission; changes no setting.
public enum MessagesSyncAutomation {
    public enum Outcome: Equatable {
        case pressed
        case needsAccessibility
        case messagesNotRunning
        case notFound(String)
        public var message: String {
            switch self {
            case .pressed: return "Pressed Sync Now in Messages. Uploads usually catch up within a minute."
            case .needsAccessibility: return "Allow Messages Storage Saver under System Settings › Privacy & Security › Accessibility, then try again. This lets it press the Sync Now button in Messages for you."
            case .messagesNotRunning: return "Messages could not be launched."
            case .notFound(let what): return "Could not find \(what) in Messages. Use Messages › Settings › iMessage › Sync Now."
            }
        }
    }

    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that offers to open Accessibility settings.
    public static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    public static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: - AX helpers

    static func attribute(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success ? value : nil
    }
    static func children(_ el: AXUIElement) -> [AXUIElement] { (attribute(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
    static func title(_ el: AXUIElement) -> String { (attribute(el, kAXTitleAttribute) as? String) ?? "" }
    static func role(_ el: AXUIElement) -> String { (attribute(el, kAXRoleAttribute) as? String) ?? "" }
    static func press(_ el: AXUIElement) -> Bool { AXUIElementPerformAction(el, kAXPressAction as CFString) == .success }

    /// Depth-first search with a node budget, so a huge transcript never hangs the caller.
    static func find(in root: AXUIElement, maxDepth: Int = 14, budget: Int = 4000, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        var visited = 0
        func walk(_ el: AXUIElement, _ depth: Int) -> AXUIElement? {
            visited += 1
            if visited > budget || depth > maxDepth { return nil }
            if predicate(el) { return el }
            for c in children(el) { if let hit = walk(c, depth + 1) { return hit } }
            return nil
        }
        return walk(root, 0)
    }

    static func button(titled wanted: [String], in root: AXUIElement) -> AXUIElement? {
        find(in: root) { el in
            let r = role(el)
            guard r == kAXButtonRole || r == kAXRadioButtonRole || r == kAXMenuItemRole else { return false }
            let t = title(el)
            return wanted.contains { t == $0 || t.hasPrefix($0) }
        }
    }

    // MARK: - Flow

    @MainActor
    public static func pressSyncNow() async -> Outcome {
        guard isTrusted else { promptForAccessibility(); return .needsAccessibility }
        guard let messages = await runningMessages() else { return .messagesNotRunning }
        let app = AXUIElementCreateApplication(messages.processIdentifier)

        // Already open?
        if let sync = button(titled: ["Sync Now"], in: app) {
            return press(sync) ? .pressed : .notFound("the Sync Now button (press failed)")
        }

        // Messages menu › Settings…
        messages.activate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let rawMenuBar = attribute(app, kAXMenuBarAttribute), CFGetTypeID(rawMenuBar) == AXUIElementGetTypeID() else { return .notFound("the menu bar") }
        let menuBar = rawMenuBar as! AXUIElement
        guard let appMenu = children(menuBar).first(where: { title($0) == "Messages" }) ?? children(menuBar).dropFirst().first else { return .notFound("the Messages menu") }
        guard let settingsItem = button(titled: ["Settings", "Preferences"], in: appMenu) ?? find(in: appMenu, where: { title($0).hasPrefix("Settings") || title($0).hasPrefix("Preferences") }) else {
            return .notFound("the Settings… menu item")
        }
        _ = press(settingsItem)

        // Wait for the settings window, then the iMessage tab, then the button.
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 250_000_000)
            if let sync = button(titled: ["Sync Now"], in: app) {
                return press(sync) ? .pressed : .notFound("the Sync Now button (press failed)")
            }
            if let tab = button(titled: ["iMessage"], in: app), role(tab) != kAXMenuItemRole {
                _ = press(tab)
            }
        }
        return .notFound("the Sync Now button")
    }

    @MainActor
    static func runningMessages() async -> NSRunningApplication? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: MessagesApp.bundleIdentifier).first(where: { !$0.isTerminated }) {
            return app
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        guard let app = try? await NSWorkspace.shared.openApplication(at: MessagesApp.appURL, configuration: config) else { return nil }
        for _ in 0..<40 where !app.isFinishedLaunching { try? await Task.sleep(nanoseconds: 250_000_000) }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        return app
    }
}
