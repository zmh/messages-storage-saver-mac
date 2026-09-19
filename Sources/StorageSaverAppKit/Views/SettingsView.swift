import AppKit
import SwiftUI
import StorageSaverCore

public struct SettingsView: View {
    public enum Tab: String { case general, conversations, automation }
    @EnvironmentObject var model: AppModel
    @State private var tab: Tab = SettingsView.initialTab
    public init() {}

    /// `MSS_APP_SETTINGS_TAB=conversations` opens that tab (layout smoke tests).
    static var initialTab: Tab {
        Tab(rawValue: ProcessInfo.processInfo.environment["MSS_APP_SETTINGS_TAB"] ?? "") ?? .general
    }

    public var body: some View {
        VStack(spacing: 0) {
            ErrorBanner().padding([.horizontal, .top])
            TabView(selection: $tab) {
                GeneralTab().tabItem { Label("General", systemImage: "slider.horizontal.3") }.tag(Tab.general)
                ConversationsTab().tabItem { Label("Conversations", systemImage: "bubble.left.and.bubble.right") }.tag(Tab.conversations)
                AutomationTab().tabItem { Label("Automation & Notifications", systemImage: "clock.arrow.2.circlepath") }.tag(Tab.automation)
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(!model.activity.isIdle)
    }
}

@MainActor
func apply(_ model: AppModel, _ change: @escaping (inout Policy) -> Void) {
    do { try model.update(change) } catch { /* lastError is shown by the banner */ }
}

/// The rule pickers ("larger than X and older than Y") with live estimates.
/// Shared by Settings and the Overview.
struct RulePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Optimize attachments larger than")
                Picker("", selection: Binding(get: { model.policy.minimumBytes }, set: { v in apply(model) { $0.minimumBytes = v } })) {
                    ForEach(sizeChoices(), id: \.self) { Text(SavingsEstimator.label(minimumBytes: $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
                Text("and older than")
                Picker("", selection: Binding(get: { model.policy.keepDays }, set: { d in apply(model) { $0.keepDays = d } })) {
                    ForEach(dayChoices(), id: \.self) { Text(SavingsEstimator.label(keepDays: $0)).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
            estimateSummary
            estimateGrid
        }
        .task { await model.loadSavings() }
    }

    private func sizeChoices() -> [Int64] {
        var s = SavingsEstimator.minimumBytesChoices
        if !s.contains(model.policy.minimumBytes) { s.append(model.policy.minimumBytes); s.sort() }
        return s
    }

    private func dayChoices() -> [Int] {
        var d = SavingsEstimator.keepDaysChoices
        if !d.contains(model.policy.keepDays) { d.append(model.policy.keepDays); d.sort() }
        return d
    }

    @ViewBuilder
    private var estimateSummary: some View {
        if let e = model.currentEstimate {
            Label("Would free \(Format.bytes(e.bytes)) now (\(Format.count(e.files)) attachments), then keeps up as attachments age.", systemImage: "internaldrive")
                .foregroundStyle(.secondary)
        } else if model.savingsLoading || model.prerequisites?.fullDiskAccess == true {
            Label("Estimating…", systemImage: "hourglass").foregroundStyle(.secondary)
        } else {
            Label("Estimates appear once Full Disk Access is granted.", systemImage: "lock").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var estimateGrid: some View {
        if let table = model.savings {
            let sizes = table.minimumBytesChoices.filter { SavingsEstimator.minimumBytesChoices.contains($0) || $0 == model.policy.minimumBytes }
            let days = table.keepDaysChoices.filter { SavingsEstimator.keepDaysChoices.contains($0) || $0 == model.policy.keepDays }
            GroupBox("What each choice would free now") {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 3) {
                    GridRow {
                        Text("older than ↓ · larger than →").font(.caption).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                        ForEach(sizes, id: \.self) { s in
                            Text(SavingsEstimator.label(minimumBytes: s)).font(.caption).fontWeight(s == model.policy.minimumBytes ? .bold : .regular)
                        }
                    }
                    ForEach(days, id: \.self) { d in
                        GridRow {
                            Text(SavingsEstimator.label(keepDays: d)).font(.caption).fontWeight(d == model.policy.keepDays ? .bold : .regular).gridColumnAlignment(.leading)
                            ForEach(sizes, id: \.self) { s in
                                let e = table.estimate(keepDays: d, minimumBytes: s)
                                Text(e.map { Format.bytes($0.bytes) } ?? "–")
                                    .font(.caption).monospacedDigit()
                                    .fontWeight(d == model.policy.keepDays && s == model.policy.minimumBytes ? .bold : .regular)
                                    .foregroundStyle(d == model.policy.keepDays && s == model.policy.minimumBytes ? Color.accentColor : Color.primary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct GeneralTab: View {
    @EnvironmentObject var model: AppModel
    @State private var targetGB: Double = 50

    var body: some View {
        Form {
            Section("What to optimize") {
                RulePicker()
                Text("Only attachments that Messages marks as fully synced to iCloud are ever optimized: the iCloud copy stays and Messages re-downloads on demand. Audio messages, stickers, group photos and pinned conversations never are.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Free-space target (optional)") {
                Toggle("Stop once this much space is free, oldest attachments first", isOn: Binding(get: { model.policy.mode == .freeSpaceTarget }, set: { on in apply(model) { $0.mode = on ? .freeSpaceTarget : .keepDays } }))
                if model.policy.mode == .freeSpaceTarget {
                    HStack {
                        TextField("GB", value: $targetGB, format: .number.precision(.fractionLength(0))).frame(width: 80)
                        Text("GB free")
                        Button("Apply") { apply(model) { $0.targetFreeBytes = bytes(fromGB: targetGB) } }
                    }
                    Text("The window and size rule above still applies; the target only stops earlier.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { targetGB = gigabytes(model.policy.targetFreeBytes) }
    }
}

struct ConversationsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var manual = ""

    private var manualPins: [String] {
        model.policy.pinnedChats.filter { pin in !model.chats.contains { $0.chatIdentifier == pin } }
    }

    var body: some View {
        // One scrolling list: a bare List inside a stack sizes to its content
        // and pushes the window layout out of frame.
        List {
            Section {
                Text("Pinned conversations are never optimized. Pins are stored by conversation identifier, so renaming a group does not unpin it.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Section("Conversations with attachments (largest first)") {
                if model.chats.isEmpty {
                    ProgressView("Loading conversations…").frame(maxWidth: .infinity)
                } else {
                    ForEach(model.chats, id: \.chatIdentifier) { c in
                        Toggle(isOn: Binding(get: { model.policy.pinnedChats.contains(c.chatIdentifier) },
                                             set: { on in
                                                 apply(model) { p in
                                                     if on { if !p.pinnedChats.contains(c.chatIdentifier) { p.pinnedChats.append(c.chatIdentifier) } }
                                                     else { p.pinnedChats.removeAll { $0 == c.chatIdentifier || $0 == c.displayName } }
                                                 }
                                                 Task { await model.loadSavings() }
                                             })) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(c.displayName.isEmpty ? c.chatIdentifier : c.displayName).lineLimit(1)
                                    if !c.displayName.isEmpty { Text(c.chatIdentifier).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer()
                                Text("\(Format.count(c.files)) · \(Format.bytes(c.bytes))").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if !manualPins.isEmpty {
                Section("Pinned by name or identifier, not in the list") {
                    ForEach(manualPins, id: \.self) { pin in
                        HStack { Text(pin); Spacer(); Button("Remove") { apply(model) { $0.pinnedChats.removeAll { $0 == pin } } }.buttonStyle(.link) }
                    }
                }
            }
            Section("Pin by identifier") {
                HStack {
                    TextField("e.g. iMessage;-;+15551234567 or chat123456789", text: $manual)
                    Button("Pin") {
                        let v = manual.trimmingCharacters(in: .whitespaces)
                        guard !v.isEmpty else { return }
                        apply(model) { if !$0.pinnedChats.contains(v) { $0.pinnedChats.append(v) } }
                        manual = ""
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await model.loadChats() }
    }
}

/// Automatic runs, staying resident, and notifications, in one place.
struct AutomationTab: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmEnable = false

    var body: some View {
        Form {
            Section("Automatic runs") {
                Toggle("Optimize automatically", isOn: Binding(get: { model.policy.automaticRuns }, set: { on in
                    if on { confirmEnable = true } else { model.setAutomaticRuns(false) }
                }))
                .confirmationDialog("Turn on automatic runs?", isPresented: $confirmEnable) {
                    Button("Turn on") { model.setAutomaticRuns(true) }
                    if model.loginItemStatus == .disabled {
                        Button("Turn on and start at login") { if model.setAutomaticRuns(true) { model.setStartAtLogin(true) } }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Every 6 hours while the app is running, after a health check passes, \(model.ruleLine.lowercased()) that are synced to iCloud have their local copies removed, at most \(Format.bytes(model.policy.maxBytesPerRun)) per run. The app then stays in the menu bar instead of quitting when you close the window. Any problem stops automatic runs until you acknowledge it in Health.")
                }
                if !model.appHasCompletedRealRun {
                    Text("Available after one successful Optimize Now through this app.").font(.caption).foregroundStyle(.secondary)
                }
                if let s = model.lastSkipReason, model.policy.automaticRuns {
                    Text("Last automatic check: \(s.explanation).").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Only run automatically while Messages is closed", isOn: Binding(get: { model.policy.onlyWhileMessagesClosed }, set: { v in apply(model) { $0.onlyWhileMessagesClosed = v } }))
                Text("Running while Messages is open is safe. Messages shows stale thumbnails for optimized items until it is relaunched; the app offers a relaunch afterwards.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("Start at login") {
                switch model.loginItemStatus {
                case .unavailable:
                    Text("Available when the app runs from the Applications folder.").foregroundStyle(.secondary)
                case .requiresApproval:
                    HStack {
                        Text("Needs your approval in System Settings › Login Items.")
                        Button("Open Login Items") { model.openLoginItems() }
                    }
                default:
                    Toggle("Start Messages Storage Saver at login (hidden, in the menu bar)", isOn: Binding(get: { model.loginItemStatus == .enabled }, set: { model.setStartAtLogin($0) }))
                }
                Text("Off by default: launch the app yourself when the disk fills up. Useful only together with automatic runs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Picker("Notify me", selection: Binding(get: { model.policy.notifications }, set: { v in apply(model) { $0.notifications = v } })) {
                    Text("after runs that free space, and on problems").tag(NotificationMode.runsAndProblems)
                    Text("only on problems").tag(NotificationMode.problemsOnly)
                    Text("never").tag(NotificationMode.never)
                }
                .pickerStyle(.radioGroup)
            }
            Section("Limits") {
                LabeledContent("Per run", value: Format.bytes(model.policy.maxBytesPerRun))
                LabeledContent("First run through this app", value: Format.bytes(model.policy.firstRunMaxBytes))
                Text("A single Optimize Now can be limited further, or raised for that run only with a typed confirmation.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
