import SwiftUI

/// The main window: a sidebar of panes. Opened on every user launch.
public struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(AppModel.Pane.allCases, selection: Binding(get: { Optional(model.selectedPane) }, set: { if let p = $0 { model.selectedPane = p } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch model.selectedPane {
                case .overview: OverviewView()
                case .settings: SettingsView()
                case .health: HealthView()
                case .help: HelpView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 600)
    }
}
