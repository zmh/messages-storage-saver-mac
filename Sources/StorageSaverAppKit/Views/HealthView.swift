import SwiftUI
import StorageSaverCore

public struct HealthView: View {
    @EnvironmentObject var model: AppModel
    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ErrorBanner()
                HStack {
                    Text("Health").font(.title2).bold()
                    Spacer()
                    if let t = model.lastHealthCheckAt { Text("checked \(Format.date(t))").font(.caption).foregroundStyle(.secondary) }
                    Button("Check now") { Task { await model.refresh(includeAnalysis: true) } }.disabled(!model.activity.isIdle)
                }

                if let p = model.problem {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(p.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                            Text("Automatic runs are off. Before acknowledging: open the affected conversations on another device and confirm the attachments are still there. Acknowledging does not turn automatic runs back on.")
                                .font(.caption).fixedSize(horizontal: false, vertical: true)
                            Button("Acknowledge") { Task { await model.acknowledgeProblem() } }
                        }
                    }
                }

                if model.keepMessagesIsSet {
                    Label("Messages › Settings › General › Keep messages is not set to Forever. That Apple setting deletes messages and attachments from iCloud and every device. This app never changes it and will not run automatically while it is set.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }

                if let h = model.health {
                    GroupBox("Summary") {
                        Text(h.render()).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !h.configWarnings.isEmpty {
                        GroupBox("Non-default safety settings in config.json") {
                            ForEach(h.configWarnings, id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
                        }
                    }
                    if model.policy.archiveDirectory != nil {
                        Label("config.json sets archiveDirectory. The app relies on iCloud and does not archive; only the mss command line does.", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let pr = model.prerequisites {
                    GroupBox("Prerequisites") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(pr.checks.enumerated()), id: \.offset) { CheckRow(check: $0.element) }
                            if pr.fullDiskAccess { SyncNowButton() }
                            if !pr.fullDiskAccess {
                                HStack {
                                    Button("Open Full Disk Access settings") { SystemSettings.open(SystemSettings.fullDiskAccess) }
                                    Button("Relaunch app") { SystemSettings.relaunchApp() }
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if let runs = model.health?.recentRuns, !runs.isEmpty {
                    GroupBox("Recent runs") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(runs.reversed(), id: \.runID) { r in
                                HStack {
                                    Text(Format.date(r.started)).monospacedDigit()
                                    Text(r.dryRun ? "preview" : (r.origin ?? "cli")).foregroundStyle(.secondary)
                                    Text(r.tiers.joined(separator: "+")).foregroundStyle(.secondary)
                                    Spacer()
                                    Text("\(Format.count(r.files)) files · \(Format.bytes(r.bytes))").monospacedDigit()
                                    Text(r.outcome.rawValue).foregroundStyle(r.outcome == .problem ? .red : (r.outcome == .ok ? .green : .orange))
                                }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(24)
        }
    }
}
