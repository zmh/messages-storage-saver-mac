import Foundation

/// One attachment file that passed both the database rule and on-disk checks.
public struct Candidate: Codable, Equatable {
    public let rowID: Int64
    public let guid: String
    public let dbFilename: String
    public let path: String
    public let bytes: Int64
    public let ckRecordID: String
    public let chatIdentifier: String
    public let chatDisplayName: String
    public let messageDate: Date
    public let uti: String
    public let mimeType: String
}

public struct Rejection: Codable, Equatable {
    public let rowID: Int64
    public let dbFilename: String
    public let reason: String
}

/// A row that satisfies Apple's purge-eligibility rule, before policy.
public struct EligibleRow {
    public let rowID: Int64
    public let guid: String
    public let dbFilename: String
    public let bytes: Int64
    public let ckRecordID: String
    public let chatIdentifier: String
    public let chatDisplayName: String
    public let messageDate: Date
    public let uti: String
    public let mimeType: String
}

public struct Selection {
    public var candidates: [Candidate] = []
    public var rejections: [Rejection] = []
    public var skippedRecent = 0
    public var skippedRecentBytes: Int64 = 0
    public var skippedPinned = 0
    public var skippedPinnedBytes: Int64 = 0
    /// Below the policy's minimum size.
    public var skippedSmall = 0
    public var skippedSmallBytes: Int64 = 0
    public var skippedBudget = 0
    public var skippedBudgetBytes: Int64 = 0
    public var totalBytes: Int64 { candidates.reduce(0) { $0 + $1.bytes } }
}

public enum CandidateSelector {
    /// Apple's rule, measured from +[IMFileTransfer canMarkPurgeable...]:
    /// synced to CloudKit (ck_sync_state = 1), transfer complete (5), and not
    /// an audio message, sticker, group photo or plugin payload. We add: a
    /// CloudKit record id must exist, the file must live inside Attachments,
    /// and hidden attachments are left alone.
    public static let eligibleSQL = """
    SELECT a.ROWID AS rowid, a.guid AS guid, a.filename AS filename, a.total_bytes AS total_bytes,
           a.ck_record_id AS ck_record_id, a.uti AS uti, a.mime_type AS mime_type,
           c.chat_identifier AS chat_identifier, COALESCE(c.display_name, '') AS display_name,
           CASE WHEN m.date < 1000000000000 THEN m.date * 1000000000 ELSE m.date END AS date_ns
    FROM attachment a
    JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID
    JOIN message m                    ON m.ROWID = maj.message_id
    JOIN chat_message_join cmj        ON cmj.message_id = m.ROWID
    JOIN chat c                       ON c.ROWID = cmj.chat_id
    WHERE a.ck_sync_state = 1 AND a.transfer_state = 5
      AND a.ck_record_id IS NOT NULL AND a.filename IS NOT NULL
      AND a.hide_attachment = 0 AND a.is_sticker = 0
      AND m.is_audio_message = 0
      AND COALESCE(a.mime_type, '') NOT LIKE 'audio/%'
      AND COALESCE(a.uti, '') NOT IN ('com.apple.coreaudio-format', 'public.mp3', 'public.mpeg-4-audio',
                                      'com.apple.sticker', 'dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy')
      AND a.filename NOT LIKE '%.pluginPayloadAttachment'
      AND (a.filename LIKE '~/Library/Messages/Attachments/%' OR a.filename LIKE '/Users/%/Library/Messages/Attachments/%')
      AND a.filename NOT LIKE '%GroupPhotoImage%' AND a.filename NOT LIKE '%BrandLogoImage%'
    ORDER BY date_ns ASC
    """

    public static func eligibleRows(db: ReadOnlyDatabase) throws -> [EligibleRow] {
        try db.query(eligibleSQL).compactMap { row in
            guard let rowID = row.int("rowid"), let guid = row.text("guid"), let filename = row.text("filename"),
                  let ck = row.text("ck_record_id"), let dateNS = row.int("date_ns") else { return nil }
            return EligibleRow(
                rowID: rowID, guid: guid, dbFilename: filename, bytes: row.int("total_bytes") ?? 0,
                ckRecordID: ck, chatIdentifier: row.text("chat_identifier") ?? "",
                chatDisplayName: row.text("display_name") ?? "", messageDate: AppleDate.date(fromDB: dateNS),
                uti: row.text("uti") ?? "", mimeType: row.text("mime_type") ?? ""
            )
        }
    }

    /// Message dates before this are treated as unknown (a `date` of 0 reads
    /// as 2001-01-01) and never offloaded. iMessage launched in 2011; 2007
    /// leaves room for imported SMS history.
    public static let earliestPlausibleMessageDate = Date(timeIntervalSince1970: 1_167_609_600) // 2007-01-01

    /// Applies the policy and verifies each file on disk. Never touches the
    /// database beyond the read-only query above.
    ///
    /// The query yields one row per (attachment, chat) join. An attachment
    /// shared with several chats appears once in the result, and is pinned if
    /// any of its chats is pinned.
    public static func select(db: ReadOnlyDatabase, store: MessagesStore, policy: Policy,
                              freeBytesNow: Int64? = nil, budgetBytes: Int64? = nil,
                              now: Date = Date(), filter: ((EligibleRow) -> Bool)? = nil) throws -> Selection {
        var selection = Selection()
        let rows = try eligibleRows(db: db)
        let cutoff = now.addingTimeInterval(-TimeInterval(policy.keepDays) * 86_400)
        let minMTime = now.addingTimeInterval(-TimeInterval(policy.minimumFileAgeHours) * 3_600)
        var accepted: Int64 = 0
        let target: Int64? = policy.mode == .freeSpaceTarget ? policy.targetFreeBytes : nil

        var pinnedRows = Set<Int64>()
        for row in rows where policy.isPinned(chatIdentifier: row.chatIdentifier, displayName: row.chatDisplayName) {
            pinnedRows.insert(row.rowID)
        }
        var seen = Set<Int64>()

        for row in rows {
            guard seen.insert(row.rowID).inserted else { continue }
            if let filter, !filter(row) { continue }
            if row.messageDate < Self.earliestPlausibleMessageDate {
                selection.rejections.append(Rejection(rowID: row.rowID, dbFilename: row.dbFilename, reason: "message date unknown (before 2007)"))
                continue
            }
            // The keep window is a floor in both modes: nothing newer is touched.
            if row.messageDate >= cutoff {
                selection.skippedRecent += 1; selection.skippedRecentBytes += row.bytes; continue
            }
            if pinnedRows.contains(row.rowID) {
                selection.skippedPinned += 1; selection.skippedPinnedBytes += row.bytes; continue
            }
            if row.bytes < policy.minimumBytes {
                selection.skippedSmall += 1; selection.skippedSmallBytes += row.bytes; continue
            }
            if let target, let free = freeBytesNow, free + accepted >= target {
                selection.skippedBudget += 1; selection.skippedBudgetBytes += row.bytes; continue
            }
            if let budgetBytes, accepted + row.bytes > budgetBytes {
                selection.skippedBudget += 1; selection.skippedBudgetBytes += row.bytes; continue
            }
            switch verify(row: row, store: store, minMTime: minMTime, requireExactSize: policy.requireExactSize) {
            case .success(let candidate):
                selection.candidates.append(candidate)
                accepted += candidate.bytes
            case .failure(let reason):
                selection.rejections.append(Rejection(rowID: row.rowID, dbFilename: row.dbFilename, reason: reason.description))
            }
        }
        return selection
    }

    /// On-disk verification of one eligible row. Regular file, inside the
    /// Attachments tree, exact size, not recently modified.
    static func verify(row: EligibleRow, store: MessagesStore, minMTime: Date, requireExactSize: Bool = true) -> Result<Candidate, VerifyFailure> {
        guard let url = store.resolve(dbFilename: row.dbFilename) else { return .failure("outside Attachments tree") }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .failure("missing on disk") }
        let mode = st.st_mode & S_IFMT
        guard mode == S_IFREG else { return .failure(mode == S_IFLNK ? "is a symlink" : "not a regular file") }
        guard store.containsInAttachments(url) else { return .failure("real path escapes Attachments tree") }
        guard st.st_size > 0 else { return .failure("empty file on disk") }
        if requireExactSize {
            guard Int64(st.st_size) == row.bytes else { return .failure("size on disk \(st.st_size) != total_bytes \(row.bytes)") }
        }
        let mtime = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
        guard mtime < minMTime else { return .failure("modified within the last \(Int(Date().timeIntervalSince(minMTime) / 3600)) h") }
        return .success(Candidate(
            rowID: row.rowID, guid: row.guid, dbFilename: row.dbFilename, path: url.path, bytes: row.bytes,
            ckRecordID: row.ckRecordID, chatIdentifier: row.chatIdentifier, chatDisplayName: row.chatDisplayName,
            messageDate: row.messageDate, uti: row.uti, mimeType: row.mimeType
        ))
    }
}

public struct VerifyFailure: Error, ExpressibleByStringInterpolation, CustomStringConvertible {
    public let description: String
    public init(stringLiteral value: String) { description = value }
}
