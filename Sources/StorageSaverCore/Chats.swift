import Foundation

/// Per-conversation view of eligible attachments, to choose test slices and
/// pinned chats.
public struct ChatSummary: Codable {
    public let chatIdentifier: String
    public let displayName: String
    public var files = 0
    public var bytes: Int64 = 0
    public var oldest: Date
    public var newest: Date
    public var pinned = false
}

public enum Chats {
    public static func summarize(db: ReadOnlyDatabase, policy: Policy, olderThanDays: Int, now: Date = Date()) throws -> [ChatSummary] {
        let cutoff = now.addingTimeInterval(-TimeInterval(olderThanDays) * 86_400)
        var byChat: [String: ChatSummary] = [:]
        for row in try CandidateSelector.eligibleRows(db: db) where row.messageDate < cutoff {
            var s = byChat[row.chatIdentifier] ?? ChatSummary(chatIdentifier: row.chatIdentifier, displayName: row.chatDisplayName,
                                                              oldest: row.messageDate, newest: row.messageDate,
                                                              pinned: policy.isPinned(chatIdentifier: row.chatIdentifier, displayName: row.chatDisplayName))
            s.files += 1
            s.bytes += row.bytes
            s.oldest = min(s.oldest, row.messageDate)
            s.newest = max(s.newest, row.messageDate)
            byChat[row.chatIdentifier] = s
        }
        return byChat.values.sorted { $0.bytes > $1.bytes }
    }
}
