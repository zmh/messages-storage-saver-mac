import ArgumentParser
import Foundation
import StorageSaverCore
import StorageSaverExperimental

struct Offload: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Offload eligible attachments. DRY RUN unless --yes is given.",
        discussion: """
        Removes only local copies of attachments that chat.db marks as fully synced to iCloud \
        (Apple's own eligibility rule), older than the keep window, verified on disk immediately \
        before removal. Never writes to chat.db. Journals every file first. Stops if the iCloud \
        deletion tombstone tables change.
        """
    )
    @OptionGroup var storeOptions: StoreOptions
    @OptionGroup var policyOptions: PolicyOptions

    @Option(name: .long, parsing: .upToNextOption, help: "Tiers to run: previews, attachments, sidecars (default from config).")
    var tier: [String] = []

    @Option(name: .long, help: "Copy each file here (byte-verified) before removing it.")
    var archiveTo: String?

    @Option(name: .long, help: "Only this chat identifier or display name.")
    var chat: String?

    @Option(name: .long, help: "Only messages before this date (YYYY-MM-DD).")
    var before: String?

    @Option(name: .long, help: "Per-run cap in GB (overrides the first-run 1 GB / normal 25 GB caps).")
    var limitGb: Double?

    @Flag(name: .long, help: "Actually remove files. Without it, nothing is removed.")
    var yes = false

    @Flag(name: .long, help: "Print progress to stderr.")
    var progress = false

    func run() throws {
        let store = try storeOptions.store()
        let (policy, outcome) = try policyOptions.checkedPolicy()
        if yes, case .unreadable(let why) = outcome {
            throw ValidationError("refusing a real run: \(Policy.configURL.path) is unreadable (\(why)). Fix or delete it first; the defaults are more aggressive than your settings may be.")
        }
        var tiers: Set<Tier>? = nil
        if !tier.isEmpty {
            tiers = Set(try tier.map { t in
                guard let v = Tier(rawValue: t) else { throw ValidationError("unknown tier \(t); use previews, attachments, sidecars") }
                return v
            })
        }
        var beforeDate: Date?
        if let before {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            guard let d = f.date(from: before) else { throw ValidationError("--before must be YYYY-MM-DD") }
            beforeDate = d
        }
        let request = OffloadRequest(
            policy: policy, tiers: tiers, dryRun: !yes,
            archiveDirectory: archiveTo.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            budgetBytes: limitGb.map { Int64($0 * 1_000_000_000) }, chatFilter: chat, beforeDate: beforeDate,
            origin: "cli"
        )
        if yes && store.isLive {
            FileHandle.standardError.write("Removing local copies from the live Messages store (iCloud copies are untouched)...\n".data(using: .utf8)!)
        }
        let showProgress = progress && isatty(STDERR_FILENO) != 0
        let result = try Offloader.run(store: store, request: request, progress: showProgress ? { p in
            let line = "\r\(p.phase.rawValue): \(Format.count(p.filesDone))/\(Format.count(p.filesTotal)) files · \(Format.bytes(p.bytesDone))   "
            FileHandle.standardError.write(line.data(using: .utf8)!)
        } : nil)
        if showProgress { FileHandle.standardError.write("\n".data(using: .utf8)!) }
        if storeOptions.json { try emitJSON(result) } else { print(result.render()) }
        if result.outcome == .problem { throw ExitCode(3) }
    }
}

struct ChatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "chats", abstract: "Conversations ranked by eligible attachment bytes older than N days (to pick a test slice or chats to pin).")
    @OptionGroup var storeOptions: StoreOptions
    @Option(name: .long) var olderThanDays: Int = 365
    @Option(name: .long) var top: Int = 25
    @Option(name: .long, help: "Only conversations whose newest eligible attachment is before this date (YYYY-MM-DD): dormant chats are quick to scroll to the top.")
    var newestBefore: String?
    @Option(name: .long, help: "Only conversations with at least this many MB of eligible attachments.")
    var minMb: Double = 0
    @Option(name: .long, help: "Only conversations with at most this many eligible attachments (small threads are easy to inspect).")
    var maxFiles: Int?
    @Option(name: .long, help: "Only conversations with at least this many eligible attachments.")
    var minFiles: Int = 1

    func run() throws {
        let store = try storeOptions.store()
        let db = try ReadOnlyDatabase(path: store.chatDB.path)
        var chats = try Chats.summarize(db: db, policy: Policy.load(), olderThanDays: olderThanDays)
        if let newestBefore {
            let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
            guard let cutoff = df.date(from: newestBefore) else { throw ValidationError("--newest-before must be YYYY-MM-DD") }
            chats = chats.filter { $0.newest < cutoff }
        }
        chats = chats.filter { Double($0.bytes) >= minMb * 1_000_000 && $0.files >= minFiles && (maxFiles == nil || $0.files <= maxFiles!) }
        if storeOptions.json { try emitJSON(Array(chats.prefix(top))); return }
        let f = DateFormatter(); f.dateFormat = "yyyy-MM"
        print(String(format: "%10@  %6@  %-7@  %-7@  %@", "bytes", "files", "oldest", "newest", "chat (display name · identifier)"))
        for c in chats.prefix(top) {
            print(String(format: "%10@  %6@  %-7@  %-7@  %@%@", Format.bytes(c.bytes), Format.count(c.files), f.string(from: c.oldest), f.string(from: c.newest),
                         c.displayName.isEmpty ? "" : c.displayName + " · ", c.chatIdentifier) + (c.pinned ? "  [pinned]" : ""))
        }
    }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "What this tool has removed, whether Messages re-downloaded any of it, and canary health.")
    @OptionGroup var storeOptions: StoreOptions

    struct Output: Codable {
        var policy: Policy
        var health: HealthReport
    }

    func run() throws {
        let store = try storeOptions.store()
        let (policy, outcome) = Policy.loadChecked()
        let health = HealthReport.compute(store: store, policy: policy)
        if storeOptions.json { try emitJSON(Output(policy: policy, health: health)); return }
        if case .unreadable(let why) = outcome { print("WARNING: config is unreadable (\(why)); showing defaults") }
        print(health.render())
    }
}

struct AcknowledgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "acknowledge", abstract: "Mark a problem run as seen (does not re-enable automatic runs).")
    @OptionGroup var storeOptions: StoreOptions
    @Argument(help: "The run id shown by `mss status`.") var runID: String

    func run() throws {
        let store = try storeOptions.store()
        try Journal(url: store.journalURL).appendAcknowledgement(runID: runID, note: "mss acknowledge")
        print("Acknowledged run \(runID).")
    }
}

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "journal", abstract: "Print the last N journal entries.")
    @OptionGroup var storeOptions: StoreOptions
    @Option(name: .long) var last: Int = 20
    func run() throws {
        let store = try storeOptions.store()
        let entries = Journal(url: store.journalURL).readAll().suffix(last)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for entry in entries { print(String(decoding: try e.encode(entry), as: UTF8.self)) }
    }
}

struct AppleOffloadCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "apple-offload",
        abstract: "Inspect or switch on Apple's own (dormant) Messages attachment offload.",
        subcommands: [AppleStatus.self, AppleEnable.self, AppleDisable.self, AppleRequestPurge.self]
    )

    struct AppleStatus: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "status", abstract: "Show the com.apple.madrid switches and what the daemon reports as purgeable.")
        func run() throws {
            for (k, v) in AppleOffload.status().sorted(by: { $0.key < $1.key }) { print("\(k) = \(v)") }
            for r in CacheDeleteBridge.purgeableSpaceAllUrgencies() { print("urgency \(r.urgency): \(Format.bytes(r.amount)) purgeable") }
        }
    }

    static let macOSCaveat = """
    Verified 2026-09-17 on macOS 15.8: the daemon's -[IMDCKUtilities cacheDeleteEnabled] is compiled to \
    return NO, so these switches do not enable attachment purging on this macOS (a purge request \
    freed other caches and changed no attachment row). Kept for future macOS versions; use \
    `mss offload` for actual space saving.
    """

    struct AppleEnable: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "enable", abstract: "Set the switches Apple's daemon checks (EnableCacheDelete + PurgeWithCacheDelete; --centralized adds the APFS-purgeable model) and restart imagent.", discussion: AppleOffloadCommand.macOSCaveat)
        @Flag(name: .long, help: "Also enable the centralized (APFS purgeable flag) model.") var centralized = false
        @Flag(name: .long, help: "Required. Writes preferences and restarts the Messages daemon.") var yes = false
        func run() throws {
            guard yes else { throw ValidationError("add --yes to write the switches and restart imagent") }
            print("Note: " + AppleOffloadCommand.macOSCaveat)
            var keys = AppleOffload.callbackKeys
            if centralized { keys += AppleOffload.centralizedKeys }
            let cmd = AppleOffload.enable(keys: keys)
            try Journal().append(JournalEntry(runID: "apple", action: "apple-defaults", dryRun: false, note: cmd))
            let r = AppleOffload.restartDaemon()
            print("Set: \(cmd)\nRestarted imagent (launchctl status \(r.status)) \(r.output)")
            print("Revert with: mss apple-offload disable --yes")
        }
    }

    struct AppleDisable: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "disable", abstract: "Remove all four switches and restart imagent.")
        @Flag(name: .long) var yes = false
        func run() throws {
            guard yes else { throw ValidationError("add --yes to remove the switches and restart imagent") }
            let cmd = AppleOffload.disable(keys: AppleOffload.callbackKeys + AppleOffload.centralizedKeys)
            try Journal().append(JournalEntry(runID: "apple", action: "apple-defaults", dryRun: false, note: cmd))
            let r = AppleOffload.restartDaemon()
            print("Removed: \(cmd)\nRestarted imagent (launchctl status \(r.status)) \(r.output)")
        }
    }

    struct AppleRequestPurge: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "request-purge", abstract: "EXPERIMENT: ask CacheDelete to have the Messages daemon purge N GB at an urgency (0-4). The daemon, not this tool, chooses and removes files.")
        @Option(name: .long) var gb: Double = 0.3
        @Option(name: .long) var urgency: Int = 1
        @Flag(name: .long) var yes = false
        func run() throws {
            guard yes else { throw ValidationError("add --yes to send the purge request") }
            let bytes = Int64(gb * 1_000_000_000)
            let store = try MessagesStore.liveChecked()
            let db = try? ReadOnlyDatabase(path: store.chatDB.path)
            let purgedBefore = (try? db?.scalarInt("SELECT COUNT(*) FROM attachment WHERE transfer_state = 0")) ?? -1
            let filesBefore = Analyzer.walkFiles(store.attachmentsDir).files.count
            try Journal().append(JournalEntry(runID: "apple", action: "apple-purge-request", dryRun: false, bytes: bytes, note: "urgency \(urgency)"))
            guard let r = AppleOffload.requestPurge(bytes: bytes, urgency: urgency) else { print("CacheDeletePurgeSpaceWithInfoSync unavailable"); return }
            for (k, v) in r.sorted(by: { $0.key < $1.key }) { print("\(k) = \(v)") }
            let purgedAfter = (try? db?.scalarInt("SELECT COUNT(*) FROM attachment WHERE transfer_state = 0")) ?? -1
            let filesAfter = Analyzer.walkFiles(store.attachmentsDir).files.count
            print("Attachment rows in purged state: \(purgedBefore) → \(purgedAfter) · files under Attachments: \(filesBefore) → \(filesAfter)")
            if purgedAfter == purgedBefore && filesAfter == filesBefore {
                print("No attachment was purged: whatever the daemon freed was not attachment data. " + AppleOffloadCommand.macOSCaveat)
            }
        }
    }
}

struct Restore: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "How to get offloaded attachments back, and copy them back from an archive if one was used.")
    @OptionGroup var storeOptions: StoreOptions
    @Option(name: .long, help: "Only this chat identifier.") var chat: String?
    @Flag(name: .long, help: "Copy archived files back into the store (only files that are missing).") var fromArchive = false
    @Flag(name: .long) var yes = false

    func run() throws {
        let store = try storeOptions.store()
        print(Restorer.messagesInstructions)
        let plan = Restorer.plan(store: store, chat: chat)
        guard !plan.onRecord.isEmpty else { print("No archived copies recorded in the journal."); return }
        print("Archived copies on record: \(plan.onRecord.count); present in the store: \(plan.present); restorable from the archive: \(plan.restorable.count) (\(Format.bytes(plan.totalBytes))); archive copy unreachable: \(plan.archiveMissing.count)")
        guard fromArchive else { print("Add --from-archive --yes to copy the missing ones back."); return }
        guard yes else { throw ValidationError("add --yes to copy files back into the store") }
        let result = try Restorer.execute(plan: plan, store: store)
        print("Restored \(result.restored) file(s) / \(Format.bytes(result.bytes)) from the archive" + (result.errors.isEmpty ? "." : "; \(result.errors.count) error(s):"))
        for e in result.errors.prefix(10) { print("  ! \(e)") }
    }
}
