import AppKit
import SwiftUI
import StorageSaverAutomation
import StorageSaverCore

public enum MenuIconState: Equatable { case normal, running, warning, problem }

public enum MenuIcon {
    @MainActor
    public static func state(for model: AppModel) -> MenuIconState {
        if model.problem != nil || model.configIsUnreadable || model.store == nil { return .problem }
        if model.activity.isRunning { return .running }
        if model.keepMessagesIsSet || (model.health?.isHealthy == false) { return .warning }
        return .normal
    }

    public static func image(for state: MenuIconState) -> NSImage {
        let name: String
        let color: NSColor?
        switch state {
        case .normal: name = "internaldrive"; color = nil
        case .running: name = "arrow.triangle.2.circlepath"; color = nil
        case .warning: name = "exclamationmark.triangle"; color = .systemOrange
        case .problem: name = "exclamationmark.triangle.fill"; color = .systemRed
        }
        let base = NSImage(systemSymbolName: name, accessibilityDescription: "Messages Storage Saver") ?? NSImage()
        var config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        if let color { config = config.applying(.init(paletteColors: [color])) }
        let image = base.withSymbolConfiguration(config) ?? base
        image.isTemplate = color == nil
        return image
    }
}

/// "Sync now": the same request Messages' Settings button makes, plus the
/// daemon's reply. Shown next to the sync prerequisites.
struct SyncNowButton: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(model.syncRequestInProgress ? "Syncing…" : "Sync now") { Task { await model.requestCloudSync() } }
                    .disabled(model.syncRequestInProgress || model.store?.isLive != true)
                Text("Presses Sync Now in Messages › Settings › iMessage for you (needs the Accessibility permission once).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let s = model.syncRequestStatus {
                Text(s).font(.caption).foregroundStyle(model.syncLooksBehind ? .orange : .green).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if !MessagesSyncAutomation.isTrusted {
                    Button("Open Accessibility settings") { MessagesSyncAutomation.openAccessibilitySettings() }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}

struct CheckRow: View {
    let check: Prerequisites.Check
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(check.ok == nil ? "·" : (check.ok! ? "✓" : "✗"))
                .foregroundStyle(check.ok == nil ? Color.secondary : (check.ok! ? Color.green : Color.red))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.name).fontWeight(.medium)
                Text(check.detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let t = model.testStoreBanner {
            Label(t, systemImage: "testtube.2")
                .font(.callout).fontWeight(.semibold)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
        }
        if let e = model.lastError {
            HStack(alignment: .top) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                Text(e).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { model.clearError() }.buttonStyle(.link)
            }
            .padding(8)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

extension View {
    func windowFrame(width: CGFloat, height: CGFloat) -> some View {
        self.frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
    }
}

enum SystemSettings {
    static let fullDiskAccess = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    static func open(_ url: URL) { NSWorkspace.shared.open(url) }

    /// Quit and reopen this app (Full Disk Access takes effect on relaunch).
    static func relaunchApp() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { NSApp.terminate(nil); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"\(url.path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }
}

func gigabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }
func bytes(fromGB gb: Double) -> Int64 { Int64((gb * 1_000_000_000).rounded()) }
