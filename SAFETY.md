# Safety model

The only thing this tool removes is a local file whose bytes also exist in iCloud. Every layer
below exists to make the other outcomes impossible, including by accident, including when the
app runs unattended, and including by an AI assistant working in this repository.

## Why file removal cannot delete from iCloud

Messages in iCloud propagates deletions through tombstone tables in `chat.db`
(`sync_deleted_attachments`, `sync_deleted_messages`, `sync_deleted_chats`) that are written
only by database triggers when a row is deleted. Removing a file writes nothing to the
database. The tool cannot delete rows: its database connection is opened read-only, forced into
`query_only`, and guarded by an SQLite authorizer that denies everything except reading. The
public API has no execute method. Apple's own delete triggers additionally call SQL functions
that exist only inside the Messages daemon. The code that writes Apple's preference domain and
restarts the daemon (research only) lives in a separate module the app never links; the build
script refuses to package an app binary that references it.

## What gets removed

A file is removed only if all of the following hold, checked immediately before removal:

1. Its row satisfies Apple's own offload-eligibility rule: `ck_sync_state = 1` (synced to CloudKit),
   `transfer_state = 5` (complete), a CloudKit record id exists, not hidden, not a sticker,
   not an audio message, not a group photo, not an app payload.
2. The message is older than the keep window (30 days by default, never below 7) and dated
   after 2007 (a date of 0 reads as 2001 and is treated as unknown). The file is at least the
   configured minimum size (any size by default). None of its conversations is pinned; an
   attachment shared by several conversations is kept if any of them is pinned.
3. The path is a regular file (not a symlink, not a directory) whose real path is inside
   `~/Library/Messages/Attachments`, its size matches the database (`requireExactSize`), and it
   was not modified in the last 24 hours.
4. This tool has never removed that path before. A file that came back (re-downloaded or
   restored) stays for good.
5. Removal goes through `DeletionGuard`, the only code path that calls `unlink(2)`. It refuses
   paths the current run did not select, anything that looks like a database, and anything
   outside the allowed tree. It cannot remove directories.
6. The file was journaled first (`~/Library/Application Support/MessagesStorageSaver/journal.jsonl`).
   The command line can additionally copy each file to an archive folder (`--archive-to`,
   byte-compared; the first archive failure stops the run). The app relies on iCloud as the
   other copy and never archives.

## Budgets and prerequisites

- Dry run by default. Real runs need `--yes` (CLI) or the confirm button (app).
- First attachments run: 1 GB. Later runs: 25 GB. Overridable only per run (`--limit-gb`, or
  the run limit in the app, above 25 GB only with a typed confirmation, never above 100 GB).
  The app caps its own first run at 1 GB even if the CLI ran before.
- Real runs refuse to start unless Messages in iCloud is on, the last sync is within 48 hours,
  the initial download is complete, every message older than an hour has been uploaded to
  CloudKit, no transfer is in progress, at least 2 GB is free, and the archive folder (if
  any) is reachable, writable, and not inside the Messages store or `~/Library`. The
  preview-cache tier only needs Full Disk Access and free space.
- Real runs refuse an unreadable or out-of-range `config.json` (a corrupt file would
  otherwise silently mean the defaults: 30 days, no pinned conversations).
- One run at a time (a file lock held for the whole run, shared by the app and the CLI).
- Every 250 files the run re-checks Full Disk Access, Messages in iCloud, and the archive
  folder; any regression stops the run.

## Canaries

Before, during (every 250 files) and after a run the tool records the tombstone counters and
the `ck_sync_state` of every row it touched. A touched row leaving state 1 or vanishing is a
**hard** violation: the run stops, `mss offload` exits with code 3, the app turns automatic
runs off, shows a red icon, and reports it until you acknowledge it in Health (acknowledging
never turns automatic runs back on). Tombstone growth while every touched row is intact means
Messages queued a deletion that did not involve this tool (Recently Deleted expiry, a deletion
on another device): the run **stops as a precaution**, is reported as a note, and automatic
runs continue after the next passing health check. If a hard violation ever happens: stop,
open Health, and check the conversation on another device before doing anything else.

## The app's own gates

- A real run starts only from the Optimize window after a dry-run preview, through a
  destructive-styled button that states the file count and size. The run touches only the
  previewed rows and never more than the previewed budget; the preview expires after
  10 minutes.
- The default mode is on demand: you launch the app, run it, and closing the window quits it.
  Automatic runs and start at login are off by default; automatic runs can only be turned on
  after a successful manual run through the app, and only that mode keeps the app resident. Each 6-hour tick first runs a read-only health check, then a fixed, ordered
  gate: store readable, settings readable and valid, automation on, nothing running, no
  unacknowledged problem, no run that never finished, a prior app run, Apple's "Keep messages"
  not set, prerequisites met, Messages closed (only if you asked for that), at least 10 minutes
  since launch and 15 since a settings change, at least 5 hours since the last automatic run.
- A run that never wrote its end record (crash, power loss) is reported as a problem and blocks
  automatic runs until acknowledged. Quit, sleep and power-off cancel a running run first; the
  current file is always finished (journaled and removed, or left alone).
- Cancel stops between files; final canaries and the run's end record are still written.
- Debug builds refuse the live store unless `MSS_ALLOW_REAL_STORE=1`; development and tests
  use fixture stores.
- The app writes only to its own support directory. It never writes any preference domain,
  never quits Messages on its own (a relaunch is offered after a run, on your click), and has
  no network code.

## Restore paths

1. Messages.app: quit and reopen Messages, open the conversation, click the download button on
   the attachment. Conversation Details › Download does not list these attachments.
2. `mss restore --chat ID --from-archive --yes` copies files back from an archive folder made
   by the command line, byte-verified. Restored files are never offloaded again.
3. Your backup (Time Machine, or the `.backup` copy and manifest this project makes).

## Guardrails for development with an AI assistant

`.claude/settings.json` denies file edits under `~/Library/Messages` and the Messages
preference domains, and `.claude/hooks/protect-messages.py` blocks any shell command that
mentions the live store together with a mutating or scripting token, any `sqlite3` on a
Messages database without `-readonly`, any `defaults write` to Messages domains, any control
of the Messages daemons or of Messages.app, any invocation of this tool with `--yes`, any use
of `MSS_ALLOW_REAL_STORE`, and any launch of the app that is not pointed at a fixture store.
Deletion commands are confined to the project and temp directories. The hook fails closed and
has its own tests. Real offload steps are typed or clicked by a human.
