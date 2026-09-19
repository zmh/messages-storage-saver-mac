import AppKit
import SwiftUI
import StorageSaverAppKit

/// One model for the whole process, created on first use on the main actor.
@MainActor let appModel: AppModel = {
    let m = AppModel.live()
    return m
}()

@main
struct StorageSaverApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model: AppModel

    init() {
        let m = appModel
        model = m
        delegate.model = m
    }

    var body: some Scene {
        // First scene: opened automatically on every user launch.
        Window("Messages Storage Saver", id: AppModel.mainWindowID) {
            MainWindow().environmentObject(model)
        }
        .defaultSize(width: 920, height: 640)
        .commands {
            CommandGroup(replacing: .help) {
                Button("Messages Storage Saver Help") { model.openMainWindow(.help) }
            }
        }

        Window("Optimize", id: AppModel.optimizeWindowID) {
            OptimizeView().environmentObject(model)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuView().environmentObject(model)
        } label: {
            MenuLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.menu)
    }
}
