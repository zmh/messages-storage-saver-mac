import ArgumentParser
import Foundation
import StorageSaverAutomation
import StorageSaverCore
import StorageSaverExperimental

@main
struct MSS: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mss",
        abstract: "Messages Storage Saver: keep recent iMessage attachments local, leave the rest in iCloud.",
        discussion: """
        Every command here is read-only unless explicitly told otherwise. The tool never \
        writes to chat.db, never deletes database rows, and never touches iCloud.
        """,
        subcommands: [Analyze.self, Estimate.self, Probe.self, ChatsCommand.self, Offload.self, Status.self, AcknowledgeCommand.self, JournalCommand.self, Restore.self, SyncNow.self, AppleOffloadCommand.self, Config.self]
    )
}

struct SyncNow: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sync-now",
        abstract: "Show Messages' iCloud sync state; with --yes, press Messages › Settings › iMessage › Sync Now for you.",
        discussion: """
        The Messages daemon accepts sync requests only from Messages itself (verified on macOS 15.8), \
        so --yes presses Messages' own Sync Now button through the Accessibility API. The terminal \
        needs the Accessibility permission (System Settings › Privacy & Security › Accessibility). \
        Changes no setting and restarts nothing.
        """
    )
    @OptionGroup var storeOptions: StoreOptions
    @Flag(name: .long, help: "Press Sync Now in Messages (otherwise only the state is shown).") var yes = false
    @Option(name: .long, help: "Seconds to wait for the upload backlog to clear.") var wait: Double = 60

    func run() throws {
        let store = try storeOptions.store()
        func unsynced() -> Int64 {
            (try? ReadOnlyDatabase(path: store.chatDB.path).scalarInt("SELECT COUNT(*) FROM message WHERE ck_sync_state = 0 AND date < (strftime('%s','now') - 3600 - 978307200) * 1000000000")) ?? -1
        }
        let s = CloudKitSync.state()
        print("Sync state: enabled=\(s.syncingEnabled.map(String.init) ?? "?") canStart=\(s.canStartSyncing.map(String.init) ?? "?") syncing=\(s.isSyncing.map(String.init) ?? "?") lastSync=\(Format.date(s.lastSyncDate))")
        let before = unsynced()
        print("Messages older than 1 h not yet uploaded: \(before)")
        guard yes else { print("Add --yes to press Sync Now in Messages."); return }
        guard MessagesSyncAutomation.isTrusted else {
            MessagesSyncAutomation.promptForAccessibility()
            print(MessagesSyncAutomation.Outcome.needsAccessibility.message.replacingOccurrences(of: "Messages Storage Saver", with: "your terminal"))
            throw ExitCode(2)
        }
        var outcome: MessagesSyncAutomation.Outcome?
        Task { @MainActor in outcome = await MessagesSyncAutomation.pressSyncNow() }
        while outcome == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        print(outcome!.message)
        guard outcome == .pressed else { throw ExitCode(2) }
        let deadline = Date().addingTimeInterval(wait)
        var now = before
        while Date() < deadline, now != 0 {
            RunLoop.main.run(until: Date().addingTimeInterval(5))
            now = unsynced()
            print("  not yet uploaded: \(now) · last sync \(Format.date(CloudKitSync.state().lastSyncDate))")
        }
        print(now == 0 ? "Uploads caught up." : "Still \(now) pending after \(Int(wait)) s; the daemon may still be working.")
    }
}

struct Estimate: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read-only: how much each keep window and size threshold would offload right now.")
    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var policyOptions: PolicyOptions

    func run() throws {
        let store = try storeOptions.store()
        let policy = try policyOptions.policy()
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        try db.verifySchema()
        let table = try SavingsEstimator.compute(db: db, store: store, policy: policy, excludingPaths: Journal(url: store.journalURL).removedPaths())
        if storeOptions.json { try emitJSON(table); return }
        func pad(_ s: String, _ width: Int, left: Bool = false) -> String {
            let fill = String(repeating: " ", count: max(0, width - s.count))
            return left ? s + fill : fill + s
        }
        print("Eligible and verified on disk: \(Format.count(table.eligibleFiles)) files / \(Format.bytes(table.eligibleBytes))")
        print(pad("older than", 12, left: true) + table.minimumBytesChoices.map { pad("≥ " + SavingsEstimator.label(minimumBytes: $0), 12) }.joined())
        for d in table.keepDaysChoices {
            let cells = table.minimumBytesChoices.map { s -> String in
                pad(table.estimate(keepDays: d, minimumBytes: s).map { Format.bytes($0.bytes) } ?? "?", 12)
            }
            print(pad(SavingsEstimator.label(keepDays: d), 12, left: true) + cells.joined() + (d == policy.keepDays ? "   ← current window" : ""))
        }
    }
}

struct StoreOptions: ParsableArguments {
    @Option(name: .long, help: "Path of a Messages store (default: ~/Library/Messages). Debug builds require this or MSS_ALLOW_REAL_STORE=1.")
    var messagesDir: String?

    @Flag(name: .long, help: "Emit JSON instead of text.")
    var json = false

    func store() throws -> MessagesStore {
        if let messagesDir {
            return MessagesStore(root: URL(fileURLWithPath: (messagesDir as NSString).expandingTildeInPath))
        }
        do {
            return try MessagesStore.liveChecked()
        } catch {
            throw ValidationError("Debug builds require --messages-dir <dir>, or MSS_ALLOW_REAL_STORE=1 to read the live store.")
        }
    }
}

struct PolicyOptions: ParsableArguments {
    @Option(name: .long, help: "Keep attachments newer than this many days local (default from config, initially 30).")
    var keepDays: Int?

    @Option(name: .long, help: "Policy mode: keep-days or free-space-target.")
    var mode: String?

    @Option(name: .long, help: "Free-space target in GB for free-space-target mode.")
    var targetFreeGb: Double?

    @Option(name: .long, parsing: .upToNextOption, help: "Chat identifier or display name to pin (never offloaded). Repeatable.")
    var pin: [String] = []

    @Option(name: .long, help: "Only offload attachments of at least this many MB (default from config, initially 0 = any size).")
    var minSizeMb: Double?

    /// The config with flags layered on top, plus whether the file was actually read.
    func checkedPolicy() throws -> (Policy, Policy.LoadOutcome) {
        let (loaded, outcome) = Policy.loadChecked()
        if case .unreadable(let why) = outcome {
            FileHandle.standardError.write("warning: \(Policy.configURL.path) is unreadable (\(why)); using defaults\n".data(using: .utf8)!)
        }
        var p = loaded
        if let keepDays { p.keepDays = keepDays }
        if let mode {
            switch mode {
            case "keep-days": p.mode = .keepDays
            case "free-space-target": p.mode = .freeSpaceTarget
            default: throw ValidationError("--mode must be keep-days or free-space-target")
            }
        }
        if let targetFreeGb { p.targetFreeBytes = Int64(targetFreeGb * 1_000_000_000) }
        if let minSizeMb { p.minimumBytes = Int64(minSizeMb * 1_000_000) }
        p.pinnedChats.append(contentsOf: pin)
        return (p, outcome)
    }

    func policy() throws -> Policy { try checkedPolicy().0 }
}

func emitJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct Analyze: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read-only report: what is local, what is eligible, what the policy would offload.")
    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var policyOptions: PolicyOptions

    func run() throws {
        let store = try storeOptions.store()
        let report = try Analyzer.run(store: store, policy: try policyOptions.policy())
        if storeOptions.json { try emitJSON(report) } else { print(report.render()) }
    }
}

struct Probe: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Prerequisites, Apple's cache-delete switches, and what the Messages daemon reports as purgeable.")
    @OptionGroup var storeOptions: StoreOptions

    struct Output: Codable {
        var prerequisites: Prerequisites
        var cacheDeleteAvailable: Bool
        var purgeable: [CacheDeleteBridge.PurgeableReport]
        var purgeHistory: String?
    }

    func run() throws {
        let store = try storeOptions.store()
        let db = try? ReadOnlyDatabase(path: store.chatDB.path)
        let prereqs = Prerequisites.evaluate(store: store, db: db)
        let purgeable = CacheDeleteBridge.isAvailable ? CacheDeleteBridge.purgeableSpaceAllUrgencies() : []
        let output = Output(prerequisites: prereqs, cacheDeleteAvailable: CacheDeleteBridge.isAvailable,
                            purgeable: purgeable, purgeHistory: CacheDeleteBridge.purgeHistoryDescription())
        if storeOptions.json { try emitJSON(output); return }

        print("Store: \(prereqs.store)")
        for c in prereqs.checks {
            let mark = c.ok == nil ? "·" : (c.ok! ? "✓" : "✗")
            print("  \(mark) \(c.name): \(c.detail)")
        }
        print(prereqs.readyForOffload ? "Ready for offload: yes" : "Ready for offload: NO (\(prereqs.blockers.count) blocker(s))")
        if let a = prereqs.tombstoneAttachments, let m = prereqs.tombstoneMessages { print("Tombstones: \(a) attachments, \(m) messages") }
        print("")
        print("Apple's cache-delete switches (com.apple.madrid): " + Prerequisites.appleDefaultKeys.map { "\($0)=\(prereqs.appleOffloadDefaults[$0] ?? "?")" }.joined(separator: ", "))
        print("Server bag ck-cache-delete-version: \(prereqs.serverBagCacheDeleteVersion.map(String.init) ?? "unknown")")
        print("Messages' internal CloudKit account code: \(prereqs.cloudKitAccountStatus.map(String.init) ?? "unknown") (observed as 4 on a working account; not a blocker)")
        print("")
        if purgeable.isEmpty {
            print("CacheDelete: framework not available or query failed")
        } else {
            print("Messages daemon purgeable space as reported to CacheDelete:")
            for r in purgeable { print("  urgency \(r.urgency): \(Format.bytes(r.amount)) purgeable · \(Format.bytes(r.freeSpace)) free" + (r.cachedResult ? " (cached)" : "")) }
            if purgeable.allSatisfy({ $0.amount == 0 }) {
                print("  → 0 at every urgency: Apple's built-in offload is inactive (switches unset, or not signed in / synced).")
            }
        }
        if let h = output.purgeHistory, !h.isEmpty {
            let entries = h.split(separator: "\n").filter { $0.contains("|") }
            let last = entries.last.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
            print("System purge history: \(entries.count) purges recorded (all services); latest: \(last)")
        }
    }
}

struct Config: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show the current policy (\(Policy.configURL.path)).")
    func run() throws {
        let (policy, outcome) = Policy.loadChecked()
        try emitJSON(policy)
        switch outcome {
        case .loaded: break
        case .noFile: FileHandle.standardError.write("(no config file; these are the defaults)\n".data(using: .utf8)!)
        case .unreadable(let why):
            FileHandle.standardError.write("error: \(Policy.configURL.path) is unreadable (\(why)); real runs will refuse until it is fixed or deleted\n".data(using: .utf8)!)
            throw ExitCode(1)
        }
        let problems = policy.validationProblems()
        if !problems.isEmpty {
            FileHandle.standardError.write(("invalid (real runs will refuse): " + problems.joined(separator: "; ") + "\n").data(using: .utf8)!)
        }
    }
}
