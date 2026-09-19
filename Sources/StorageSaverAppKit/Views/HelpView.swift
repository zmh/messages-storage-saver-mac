import SwiftUI
import StorageSaverCore

/// What the app does, what it never does, and how to get things back.
struct HelpView: View {
    @EnvironmentObject var model: AppModel

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return b.isEmpty ? v : "\(v) (\(b))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Help").font(.title).bold()

                GroupBox("What it does") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Removes only the local copy of attachments that Messages marks as fully synced to iCloud, matching the rule you choose (size and age). The iCloud copy stays; Messages re-downloads on demand.", systemImage: "checkmark")
                        Label("Every file is journaled first and re-verified against the Messages database immediately before removal.", systemImage: "checkmark")
                        Label("Watches Messages' iCloud deletion queues before, during and after every run and stops at the first sign of trouble. Any problem turns automatic runs off until you acknowledge it in Health.", systemImage: "checkmark")
                        Label("Caps the first run at \(Format.bytes(Policy().firstRunMaxBytes)) and later runs at \(Format.bytes(Policy().maxBytesPerRun)).", systemImage: "checkmark")
                    }.font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("What it never does") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Never writes to the Messages database, never deletes messages, never touches iCloud or your other devices.", systemImage: "xmark")
                        Label("Never touches audio messages, stickers, group photos, pinned conversations, or anything newer than your window.", systemImage: "xmark")
                        Label("Never removes a file it removed before and that came back (re-downloaded files stay for good).", systemImage: "xmark")
                        Label("Never sends anything anywhere. No network, no analytics. Never changes a Messages setting.", systemImage: "xmark")
                    }.font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Getting an attachment back") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Quit and reopen Messages, open the conversation, and click the download button on the attachment; it comes back from iCloud, byte for byte. Conversation Details › Download does not list these attachments, so it is one at a time. Once re-downloaded, the app never touches that file again.")
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Relaunch Messages") { Task { await model.relaunchMessages() } }
                            if let h = model.health {
                                Text("Optimized so far: \(Format.count(h.filesRemoved)) attachments (\(Format.bytes(h.bytesRemoved))); \(Format.count(h.filesReappeared)) re-downloaded since.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Never do these in Messages or iCloud settings") {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Messages › Settings › General › Keep messages: 30 Days or One Year", systemImage: "exclamationmark.triangle")
                        Label("iCloud settings › Messages › Disable & Delete", systemImage: "exclamationmark.triangle")
                        Label("Deleting messages in the Messages app while Messages in iCloud is on", systemImage: "exclamationmark.triangle")
                        Text("Each of these deletes from iCloud and every device, which this app can neither cause nor undo. The app warns and pauses automatic runs if Keep messages is not set to Forever.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Sync now") {
                    Text("Optimizing waits until Messages has uploaded everything to iCloud. If it lags, the Sync now button presses Messages › Settings › iMessage › Sync Now for you, which needs the Accessibility permission once. It changes no setting.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Under the hood: everything this app calls") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("There is no Messages API for offloading and the app calls none. It removes a file with unlink(2) and relies on Messages' own behaviour: a row whose file is missing but which still has an iCloud record (ck_sync_state = 1, ck_record_id set) is shown by Messages as downloadable, and Messages fetches it from CloudKit when you click. Apple's own attachment purge (IMDCKCacheDeleteManager, the CacheDelete framework, \"mark purgeable\") is not linked into this app at all; the build refuses to package it if it were.")
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Reads").font(.headline)
                        bullet("~/Library/Messages/chat.db, opened read-only (SQLite mode=ro, PRAGMA query_only, an authorizer that denies everything but SELECT). Tables and columns: attachment (ROWID, guid, filename, uti, mime_type, transfer_state, total_bytes, is_sticker, hide_attachment, ck_sync_state, ck_record_id), message (ROWID, date, is_audio_message, ck_sync_state), chat (chat_identifier, display_name), message_attachment_join, chat_message_join, and the row counts and sqlite_sequence counters of sync_deleted_attachments and sync_deleted_messages. Never message text or attributedBody.")
                        bullet("Apple's eligibility rule, as one query: ck_sync_state = 1 AND transfer_state = 5 AND ck_record_id IS NOT NULL AND hide_attachment = 0 AND is_sticker = 0 AND message.is_audio_message = 0 AND not an audio UTI/MIME, not a .pluginPayloadAttachment, not a GroupPhotoImage/BrandLogoImage, filename under ~/Library/Messages/Attachments.")
                        bullet("lstat(2) on each candidate file (regular file, real path inside Attachments, size equal to total_bytes, not modified in the last 24 h) and, for the estimates, a walk of Attachments and Caches/Previews.")
                        bullet("Preferences, read only, via CFPreferencesCopyAppValue: com.apple.madrid CloudKitSyncingEnabled, CloudKitSyncDate, CloudKitLastDownloadProgress, CloudKitHasAvailableRecordsToDownload, IMCloudKitAccountStatusKey; com.apple.iChat KeepMessageForDays (to warn); the cached iMessage server bag key ck-cache-delete-version.")
                        bullet("Free space through the volume's available-capacity resource values.")

                        Text("Writes").font(.headline)
                        bullet("unlink(2) on files this run selected, under ~/Library/Messages/Attachments (and, only when you tick it, the regenerable thumbnails under ~/Library/Messages/Caches/Previews). Nothing else under ~/Library/Messages, ever: no database write, no Sync/ folder, no preference.")
                        bullet("Its own files in ~/Library/Application Support/MessagesStorageSaver: config.json, journal.jsonl (one line per removed file, before it is removed), baseline.json (canary counters), run.lock.")

                        Text("Talks to, only on your click").font(.headline)
                        bullet("Relaunch Messages: NSRunningApplication.terminate() (a normal Quit, never force) then NSWorkspace open of Messages.app.")
                        bullet("Sync now: the Accessibility API (AXUIElement) to open Messages › Settings, select the iMessage tab and press its Sync Now button, exactly as you would. Needs the Accessibility permission. A direct daemon request was tried and is refused by imagent for anything but Messages itself, so this is the only route.")
                        bullet("Start at login: SMAppService.mainApp register/unregister. Notifications: UNUserNotificationCenter, local only. Automatic runs: NSBackgroundActivityScheduler every 6 h, only while switched on.")

                        Text("Never").font(.headline)
                        bullet("No network, no CloudKit calls, no writes to any Apple preference domain, no daemon restarts, no chflags/xattr/APFS purgeable flags, no message or conversation deletion. The tombstone counters that would reveal an iCloud deletion are checked before, during and after every run.")
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Using it") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Launch it when the disk is getting full, check the rule in Settings, click Optimize Now, confirm the preview, then relaunch Messages. Closing the window quits the app. If you would rather it keep up on its own, turn on Optimize automatically in Settings › Automation & Notifications; the app then stays in the menu bar and can start at login.")
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Settings, journal and health records live in ~/Library/Application Support/MessagesStorageSaver. Delete that folder to forget everything.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Text("Version \(version)").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
    }
}
