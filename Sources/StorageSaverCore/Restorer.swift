import Foundation

/// Which offloaded files can be copied back from an archive.
public struct RestorePlan {
    /// Every removed file with an archive copy on record (filtered by chat).
    public var onRecord: [JournalEntry]
    /// Of those, currently present in the store (nothing to do).
    public var present: Int
    /// Missing from the store, archive copy exists, destination inside Attachments.
    public var restorable: [JournalEntry]
    /// Missing from the store and the archive copy is unreachable.
    public var archiveMissing: [JournalEntry]
    public var chat: String?
    public var totalBytes: Int64 { restorable.reduce(0) { $0 + ($1.bytes ?? 0) } }
}

public struct RestoreResult: Codable {
    public var restored = 0
    public var bytes: Int64 = 0
    public var skipped = 0
    public var errors: [String] = []
    public var cancelled = false
}

/// Copies archived files back into the store. The other restore path is
/// Messages.app itself, which re-downloads from iCloud per item.
public enum Restorer {
    public static let messagesInstructions = """
    Offloaded attachments still exist in iCloud. To get one back in Messages.app: quit and reopen Messages, \
    open the conversation, and click the download button on the attachment. Conversation Details › Download \
    does not list these attachments, so restore is per item. Never use "Disable & Delete" for Messages in \
    iCloud and never set "Keep messages" to 30 days or one year: both delete from iCloud and every device.
    """

    public static func plan(store: MessagesStore, journal: Journal? = nil, chat: String? = nil) -> RestorePlan {
        let journal = journal ?? Journal(url: store.journalURL)
        let onRecord = journal.removedEntries().filter { $0.archivePath != nil && (chat == nil || $0.chat == chat) }
        var present = 0
        var restorable: [JournalEntry] = []
        var archiveMissing: [JournalEntry] = []
        var seen = Set<String>()
        for e in onRecord {
            guard let dst = e.path, seen.insert(dst).inserted else { continue }
            if FileManager.default.fileExists(atPath: dst) { present += 1; continue }
            if let src = e.archivePath, FileManager.default.fileExists(atPath: src), store.containsInAttachments(URL(fileURLWithPath: dst)) {
                restorable.append(e)
            } else {
                archiveMissing.append(e)
            }
        }
        return RestorePlan(onRecord: onRecord, present: present, restorable: restorable, archiveMissing: archiveMissing, chat: chat)
    }

    /// Copies each restorable file back (byte-verified) and journals it.
    public static func execute(plan: RestorePlan, store: MessagesStore, journal: Journal? = nil,
                               progress: ((Int, Int) -> Void)? = nil, isCancelled: (() -> Bool)? = nil) throws -> RestoreResult {
        let journal = journal ?? Journal(url: store.journalURL)
        var result = RestoreResult()
        for (i, e) in plan.restorable.enumerated() {
            if isCancelled?() == true { result.cancelled = true; break }
            guard let src = e.archivePath, let dst = e.path, store.containsInAttachments(URL(fileURLWithPath: dst)) else { result.skipped += 1; continue }
            if FileManager.default.fileExists(atPath: dst) { result.skipped += 1; continue }
            do {
                _ = try Archive.copyVerified(from: src, to: URL(fileURLWithPath: dst))
                try journal.append(JournalEntry(runID: "restore", action: "restore", dryRun: false, path: dst, bytes: e.bytes, rowID: e.rowID, archivePath: src))
                result.restored += 1
                result.bytes += e.bytes ?? 0
            } catch {
                result.errors.append("\(dst): \(error)")
            }
            progress?(i + 1, plan.restorable.count)
        }
        return result
    }
}
