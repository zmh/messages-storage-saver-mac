# Privacy

The app and the command-line tool run entirely on your Mac and send nothing anywhere. There is
no network code, no analytics, no crash reporting.

They read, from `chat.db`: attachment metadata (row id, GUID, file name, type, size, transfer
and sync state, CloudKit record id), message dates and the audio-message flag, conversation
identifiers and display names, and the sizes and counters of the deletion tombstone tables.
They never read message text, `attributedBody`, handles' contact details, or attachment
contents (an archive copy, if you enable one, is a plain file copy).

They read these preferences: `com.apple.madrid` (Messages in iCloud sync state and Apple's
offload switches), `com.apple.iChat` (`KeepMessageForDays`, to warn you), and the cached
iMessage server bag (`ck-cache-delete-version`). The app also asks macOS whether Messages.app
is running and when it was launched, to offer a relaunch after a run. When you click
"Sync now" (or run `mss sync-now --yes`), they press Messages' own Sync Now button
(Messages › Settings › iMessage) through the Accessibility API, because the Messages daemon
accepts sync requests only from Messages itself. This needs the Accessibility permission, is
only ever done on your click, and changes no setting.

They write only to `~/Library/Application Support/MessagesStorageSaver/` (config, journal,
baseline, lock). The journal records the path, size, row id, GUID, CloudKit record id,
conversation identifier and message date of every removed file so removals can be audited,
reconciled and restored. Delete the folder to forget everything. The app registers itself as a
login item only if you turn that on (off by default) through the standard macOS API, and posts
local notifications (on by default for runs that free space and for problems; adjustable).

Only the command-line tool, with your explicit `--yes`, can write Apple's four
`com.apple.madrid` switches (`mss apple-offload enable`) and restart the Messages daemon;
`disable` removes them. That code is not part of the app.
