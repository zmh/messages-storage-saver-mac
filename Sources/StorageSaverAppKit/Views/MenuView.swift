import AppKit
import SwiftUI
import StorageSaverCore

public struct MenuView: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        Button("Open Messages Storage Saver") { model.openMainWindow(.overview) }
        Divider()
        if let t = model.testStoreBanner { Text(t) }
        Text(model.localSizeLine)
        Text(model.ruleLine)
        Text(model.lastRunLine)
        Text(model.healthLine)
        Divider()
        if case .running(let p) = model.activity {
            Text("Optimizing… \(Int(p.fraction * 100))% · \(Format.count(p.filesDone)) of \(Format.count(p.filesTotal)) files · \(Format.bytes(p.bytesDone))")
            Button("Cancel after the current file") { model.cancelRun() }
        } else {
            Button("Optimize Now…") { model.openOptimizeWindow() }
                .disabled(!model.activity.isIdle || model.store == nil)
        }
        if model.needsMessagesRelaunch {
            Button("Relaunch Messages to show download buttons") { Task { await model.relaunchMessages() } }
        }
        Divider()
        Button("Settings…") { model.openMainWindow(.settings) }
        Button("Health…") { model.openMainWindow(.health) }
        Button("Help…") { model.openMainWindow(.help) }
        Divider()
        Button("Quit Messages Storage Saver") { NSApp.terminate(nil) }
    }
}

/// The status-bar icon. It exists from launch, so it is also where the model
/// learns how to open SwiftUI windows.
public struct MenuLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some View {
        Image(nsImage: MenuIcon.image(for: MenuIcon.state(for: model)))
            .onAppear {
                model.windowOpener = { id in openWindow(id: id) }
            }
    }
}
