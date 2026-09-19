import AppKit
import SwiftUI
import StorageSaverCore

/// Preview (dry run) → explicit confirmation → progress with Cancel → result.
public struct OptimizeView: View {
    @EnvironmentObject var model: AppModel
    @State private var limitGB: Double = 25
    @State private var clearThumbnails = false
    @State private var typedLimit = ""
    @State private var showingResult = false

    public init() {}

    private var raisedAboveDefault: Bool { bytes(fromGB: limitGB) > Policy.defaultMaxBytesPerRun }
    private var typedLimitMatches: Bool { !raisedAboveDefault || typedLimit.trimmingCharacters(in: .whitespaces) == "\(Int(limitGB))" }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ErrorBanner()
            switch model.activity {
            case .previewing:
                ProgressView("Checking what can be offloaded…")
                    .frame(maxWidth: .infinity, minHeight: 120)
            case .running(let p):
                running(p)
            default:
                if showingResult, let r = model.lastResult, !r.dryRun {
                    result(r)
                } else if showingResult {
                    ProgressView("Starting…").frame(maxWidth: .infinity, minHeight: 120)
                } else if let preview = model.preview, let token = model.confirmation {
                    previewContent(preview, token: token)
                } else {
                    Text("No preview yet.")
                    Button("Preview") { Task { await preview() } }
                }
            }
        }
        .padding(20)
        .windowFrame(width: 560, height: 480)
        .onAppear {
            limitGB = gigabytes(model.appBudgetBytes ?? model.policy.maxBytesPerRun)
            clearThumbnails = false
            showingResult = false
            Task { await preview() }
        }
    }

    private func preview() async {
        showingResult = false
        typedLimit = ""
        await model.prepareOptimize(limitBytes: bytes(fromGB: limitGB), clearThumbnails: clearThumbnails)
    }

    @ViewBuilder
    private func previewContent(_ p: OffloadResult, token: AppModel.RunConfirmation) -> some View {
        Text("Optimize now").font(.title2).bold()
        Text("\(model.ruleLine), synced to iCloud: \(Format.count(p.attachmentFiles)) files (\(Format.bytes(p.attachmentBytes))) in \(p.byChat.count) conversations would have their local copies removed. iCloud copies are never touched; Messages re-downloads on demand.")
            .fixedSize(horizontal: false, vertical: true)

        if !p.prerequisiteBlockers.isEmpty {
            ForEach(p.prerequisiteBlockers, id: \.self) { b in
                Label(b, systemImage: "xmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        notes(p)

        if !p.byChat.isEmpty {
            List(p.byChat.prefix(50), id: \.chatIdentifier) { b in
                HStack {
                    Text(b.displayName.isEmpty ? b.chatIdentifier : b.displayName).lineLimit(1)
                    Spacer()
                    Text("\(Format.count(b.files)) files · \(Format.bytes(b.bytes))").foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(minHeight: 120)
        }

        GroupBox {
            HStack {
                Text("Limit this run to")
                TextField("GB", value: $limitGB, format: .number.precision(.fractionLength(0...1)))
                    .frame(width: 70)
                    .disabled(model.appBudgetBytes != nil)
                Text("GB")
                Spacer()
                Toggle("Also clear thumbnail cache (regenerable)", isOn: $clearThumbnails)
            }
            if model.appBudgetBytes != nil {
                Text("The first run through this app is capped at \(Format.bytes(model.appBudgetBytes!)). Check the result, then later runs may go up to \(Format.bytes(model.policy.maxBytesPerRun)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if raisedAboveDefault {
                HStack {
                    Text("Above the 25 GB default. Type \(Int(limitGB)) to confirm:")
                    TextField("", text: $typedLimit).frame(width: 60)
                }.font(.caption)
            }
            HStack {
                Button("Update preview") { Task { await preview() } }
                if bytes(fromGB: limitGB) != token.limitBytes || clearThumbnails != token.clearThumbnails {
                    Text("Options changed: update the preview before removing.").font(.caption).foregroundStyle(.orange)
                }
            }
        }

        HStack {
            Button("Cancel") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction)
            Spacer()
            Button(role: .destructive) {
                Task {
                    // Switch to the result view up front so the post-run health
                    // refresh never shows an empty "No preview yet" state.
                    showingResult = true
                    if await !model.confirmOptimize(token) { showingResult = false }
                }
            } label: {
                Text("Remove \(Format.count(token.files)) files (\(Format.bytes(token.bytes))) from this Mac")
            }
            .disabled(model.confirmationBlocker(token) != nil || !typedLimitMatches
                      || bytes(fromGB: limitGB) != token.limitBytes || clearThumbnails != token.clearThumbnails)
        }
    }

    @ViewBuilder
    private func notes(_ p: OffloadResult) -> some View {
        if p.keptPreviouslyRemoved > 0 {
            Label("\(Format.count(p.keptPreviouslyRemoved)) files (\(Format.bytes(p.keptPreviouslyRemovedBytes))) were optimized before and are back on this Mac; they stay.", systemImage: "pin")
                .font(.caption).foregroundStyle(.secondary)
        }
        if model.messagesApp.isRunning {
            Label("Messages is open. That is fine; it shows stale previews until relaunched, and the menu will offer a relaunch afterwards.", systemImage: "message").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        if !p.externalDeletions.isEmpty {
            Label(p.externalDeletions.joined(separator: "; "), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func running(_ p: OffloadProgress) -> some View {
        Text("Optimizing…").font(.title2).bold()
        ProgressView(value: p.fraction) {
            Text("\(p.phase.rawValue): \(Format.count(p.filesDone)) of \(Format.count(p.filesTotal)) files · \(Format.bytes(p.bytesDone)) of \(Format.bytes(p.bytesTotal))")
        }
        if let c = p.currentPath { Text((c as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
        if p.archived > 0 { Text("Archived copies: \(p.archived)").font(.caption) }
        if p.errors > 0 { Text("Errors: \(p.errors)").font(.caption).foregroundStyle(.orange) }
        Spacer()
        HStack {
            Spacer()
            Button("Cancel after the current file") { model.cancelRun() }.keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func result(_ r: OffloadResult) -> some View {
        switch r.outcome {
        case .ok: Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
        case .cancelled: Label("Cancelled", systemImage: "stop.circle").font(.title2)
        case .stopped: Label("Stopped as a precaution", systemImage: "pause.circle").foregroundStyle(.orange).font(.title2)
        case .problem: Label("Problem", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.title2)
        case .incomplete: Label("Did not finish", systemImage: "questionmark.circle").font(.title2)
        }
        ScrollView { Text(r.render()).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
        if model.needsMessagesRelaunch {
            Button("Relaunch Messages to show download buttons") { Task { await model.relaunchMessages() } }
        }
        if r.outcome == .problem {
            Text("Automatic runs are off. Open Health, read the details, and acknowledge the problem when you have checked your conversations on another device.")
                .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        }
        HStack { Spacer(); Button("Close") { NSApp.keyWindow?.close() }.keyboardShortcut(.defaultAction) }
    }
}
