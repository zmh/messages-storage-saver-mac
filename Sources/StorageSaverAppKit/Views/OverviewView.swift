import AppKit
import SwiftUI
import StorageSaverCore

/// What the app would do right now, and the button to do it.
struct OverviewView: View {
    @EnvironmentObject var model: AppModel

    private var fullDiskAccess: Bool { model.prerequisites?.fullDiskAccess ?? false }
    private var needsSetup: Bool { model.needsOnboarding || !fullDiskAccess }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ErrorBanner()
                Text("Messages Storage Saver").font(.title).bold()
                Text("Keeps recent iMessage attachments on this Mac and lets older ones live only in iCloud. Messages re-downloads an optimized attachment when you open it. Nothing is removed until you click Optimize Now and confirm a preview.")
                    .fixedSize(horizontal: false, vertical: true)

                if case .unavailable(let why) = model.storeState {
                    Label(why, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }

                if needsSetup { setup } else { status }

                if fullDiskAccess {
                    GroupBox("Your rule") {
                        VStack(alignment: .leading, spacing: 8) {
                            RulePicker()
                            if model.needsOnboarding {
                                HStack {
                                    Spacer()
                                    Button("Save settings") { do { try model.update { _ in } } catch {} }.keyboardShortcut(.defaultAction)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        model.openOptimizeWindow()
                    } label: {
                        Label("Optimize Now…", systemImage: "internaldrive.badge.icloud").font(.title3).padding(.horizontal, 6).padding(.vertical, 2)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.activity.isIdle || model.store == nil || !fullDiskAccess)
                    if case .running(let p) = model.activity {
                        ProgressView(value: p.fraction).frame(width: 160)
                        Text("\(Format.count(p.filesDone)) of \(Format.count(p.filesTotal))").font(.caption)
                        Button("Cancel") { model.cancelRun() }
                    }
                    if model.needsMessagesRelaunch {
                        Button("Relaunch Messages to show download buttons") { Task { await model.relaunchMessages() } }
                    }
                }
                Text("First run through this app: at most \(Format.bytes(model.policy.firstRunMaxBytes)). Later runs: up to \(Format.bytes(model.policy.maxBytesPerRun)) each. See Help for what is and is not touched.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
        }
    }

    // First launch or missing permission: the two things that must happen first.
    private var setup: some View {
        GroupBox("Setup") {
            VStack(alignment: .leading, spacing: 8) {
                if fullDiskAccess {
                    Label("Full Disk Access granted: the Messages database is readable.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Text("Reading ~/Library/Messages requires Full Disk Access. Add Messages Storage Saver in System Settings › Privacy & Security › Full Disk Access, then relaunch the app.")
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Open Full Disk Access settings") { SystemSettings.open(SystemSettings.fullDiskAccess) }
                        Button("Check again") { Task { await model.refresh(includeAnalysis: true) } }
                        Button("Relaunch app") { SystemSettings.relaunchApp() }
                    }
                }
                if fullDiskAccess, model.needsOnboarding {
                    Text("Choose your rule below and click Save settings. Automatic runs and start-at-login are off unless you turn them on in Settings.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                cloudChecks
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var status: some View {
        GroupBox("Right now") {
            VStack(alignment: .leading, spacing: 6) {
                Label(model.localSizeLine, systemImage: "internaldrive")
                if let e = model.currentEstimate {
                    Label("\(model.ruleLine): \(Format.count(e.files)) attachments, \(Format.bytes(e.bytes)) would be freed.", systemImage: "arrow.down.circle")
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(model.lastRunLine, systemImage: "clock")
                Label(model.healthLine, systemImage: model.health?.isHealthy == false || model.problem != nil ? "exclamationmark.triangle.fill" : "checkmark.shield")
                    .foregroundStyle(model.problem != nil ? .red : .primary)
                cloudChecks
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var cloudChecks: some View {
        if let pr = model.prerequisites, fullDiskAccess {
            let failing = pr.checks.filter { $0.ok == false || $0.name == "Keep Messages setting" }
            ForEach(Array(failing.enumerated()), id: \.offset) { CheckRow(check: $0.element) }
            if model.syncLooksBehind || model.syncRequestStatus != nil { SyncNowButton() }
            if !pr.readyForOffload {
                Text("Optimizing waits until every check above passes (details in Health).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
