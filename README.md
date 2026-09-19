# Messages Storage Saver for Mac

**Free up the space iMessage attachments take on your Mac, without deleting anything from iCloud, your iPhone, or your conversations.**

[![Download for macOS](https://img.shields.io/github/v/release/zmh/messages-storage-saver-mac?label=Download%20for%20macOS&style=for-the-badge)](https://github.com/zmh/messages-storage-saver-mac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%20%7C%2015%20Sequoia-blue)](#requirements)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

<p align="center">
  <img src="docs/images/system-settings-storage-messages-190gb.png" width="480" alt="macOS System Settings › General › Storage showing Messages using 190 GB, next to Apple's Store in iCloud and Optimize Storage recommendations that do nothing for Messages">
  <br>
  <em>Sound familiar? System Settings › Storage on the Mac this was built on: Messages, 190 GB. Apple's recommendations on that screen don't touch it.</em>
</p>

Is **Messages taking up 50, 100, 200 GB of storage on your Mac**? System Settings › Storage shows "Messages" as one of the biggest items, but there is no "Optimize Mac Storage" switch for Messages the way there is for Photos. Every photo and video anyone ever sent you is stored twice: once in iCloud (Messages in iCloud) and once under `~/Library/Messages/Attachments`, forever.

Messages Storage Saver is the missing switch. It removes **only the local copy** of attachments that Messages has already uploaded to iCloud, matching a rule you choose ("larger than 100 MB and older than 2 years"), and shows you exactly how much each rule would free before you click. Messages keeps working: an optimized attachment shows a download button and comes back from iCloud when you open it. Nothing is ever deleted from iCloud, from your other devices, or from a conversation.

- Native macOS app (SwiftUI), open source, no network access, no analytics.
- Works with **Messages in iCloud** on macOS 14 Sonoma and macOS 15 Sequoia, Apple silicon and Intel.
- Live estimate table: what "older than 1 month / 1 year / 5 years" × "any size / 5 MB / 100 MB / 500 MB" would free right now.
- Every run is a dry-run preview first; the first real run is capped at 1 GB.
- Validated on a 190 GB Messages library: 157 GB eligible, 15 GB freed in the first two runs, re-download byte-identical.

## Download

1. **[Download the latest release](https://github.com/zmh/messages-storage-saver-mac/releases/latest)** (`MessagesStorageSaver-x.y.z.dmg`), open it and drag **Messages Storage Saver** to Applications.
2. Launch it from Spotlight. Releases are signed with a Developer ID and notarized by Apple, so it opens like any other app.
3. Grant **Full Disk Access** when the window asks (System Settings › Privacy & Security › Full Disk Access › add Messages Storage Saver), then click **Relaunch app**. This is required to read the Messages database; it is the same permission Terminal needs to see `~/Library/Messages`.
4. Pick a rule, click **Optimize Now…**, read the preview, confirm. Then quit and reopen Messages so it shows download buttons instead of stale thumbnails.

Or build from source (below).

## Requirements

- macOS 14 or newer, Apple silicon or Intel.
- **Messages in iCloud turned on and synced** (Messages › Settings › iMessage › Enable Messages in iCloud). The app refuses to run until Messages reports the upload backlog is empty. A **Sync now** button in the app presses Messages' own Sync Now for you if it lags (needs the Accessibility permission, once).
- Full Disk Access for the app.

## How it works

### The problem

With Messages in iCloud, Apple keeps the master copy of every attachment in CloudKit. Your Mac downloads each one and never lets go, even for a video someone sent you in 2017. iOS quietly offloads old attachments when the phone is full; the Messages daemon on macOS contains the same offload code, but on macOS 15 it is compiled out (verified by disassembly in this project), so the local copy grows forever. Messages' own remedies, **"Keep messages: 30 days / 1 year"** and **"Disable & Delete"**, are worse than the problem: they delete conversations from iCloud and every device.

### What the app does instead

1. **Reads the Messages database read-only** and finds attachments that Messages itself marks as fully uploaded to iCloud, using Apple's own eligibility rule (the same conditions the daemon's dormant offload code checks): `ck_sync_state = 1` (synced to CloudKit), `transfer_state = 5` (transfer complete), a CloudKit record id present, not hidden, not a sticker, not an audio message, not a group photo, not an app payload.
2. **Applies your rule**: older than N (1 week to 10 years) and larger than N (any size to 500 MB), never pinned conversations, never anything modified in the last 24 hours, only files whose size on disk matches what the database expects.
3. **Shows a preview** of exactly which files in which conversations would be affected, and how much space that frees.
4. **Removes only the local file** with `unlink(2)` after re-checking the row one more time and writing a journal entry first.
5. **Messages does the rest, natively.** When Messages sees a row whose file is missing but which still has an iCloud record, it shows the attachment as downloadable (the same placeholder iOS shows) and fetches it from CloudKit when you click. The app calls no Messages API for this; it does not exist for third parties, and none is needed.

### Every call it makes

There is no private "offload" or "mark purgeable" call in the app. This is the complete list, also shown in the app's Help pane:

| | What | How |
|---|---|---|
| Reads | `~/Library/Messages/chat.db` | SQLite opened read-only (`mode=ro`, `PRAGMA query_only`, an authorizer that denies everything except SELECT). Tables: `attachment`, `message` (dates and the audio flag only, never text), `chat`, the two join tables, and the row counts of the two deletion-tombstone tables. |
| Reads | candidate files | `lstat(2)`: regular file, real path inside `Attachments`, exact size, age. |
| Reads | Messages preferences | `CFPreferencesCopyAppValue` for `com.apple.madrid` (`CloudKitSyncingEnabled`, `CloudKitSyncDate`, `CloudKitLastDownloadProgress`) and `com.apple.iChat` (`KeepMessageForDays`, to warn you). |
| Writes | selected files | `unlink(2)` under `~/Library/Messages/Attachments`; thumbnails under `Caches/Previews` only if you tick that box. Nothing else under `~/Library/Messages`, ever. |
| Writes | its own state | `~/Library/Application Support/MessagesStorageSaver/`: `config.json`, `journal.jsonl`, `baseline.json`, `run.lock`. |
| On your click | Relaunch Messages | `NSRunningApplication.terminate()` (a normal Quit) and `NSWorkspace` open. |
| On your click | Sync now | The Accessibility API presses Messages › Settings › iMessage › **Sync Now**, exactly as you would. |
| Optional | Start at login, notifications | `SMAppService`, `UNUserNotificationCenter` (local). |
| Never | | Network, CloudKit, writing any Apple preference, restarting daemons, `chflags`/`xattr`/APFS purgeable flags, deleting a message or conversation. |

### Why it cannot delete from iCloud

Messages in iCloud propagates deletions through "tombstone" tables in `chat.db` that only Messages' own database triggers write when a row is deleted. Removing a file writes nothing to the database, and the app's database connection cannot write at all. The app records the tombstone counters before, during and after every run; if they ever grow during a run, it stops and turns automatic runs off until you look. Details in [SAFETY.md](SAFETY.md).

### Getting an attachment back

Quit and reopen Messages, open the conversation, click the download button on the attachment. It comes back from iCloud byte for byte (verified: identical size and content). Once re-downloaded, the app never touches that file again.

## Features and settings

- **Rule**: "Optimize attachments larger than [any size, 1 MB, 5 MB, 10 MB, 100 MB, 500 MB] and older than [1 week … 10 years]", with a live table of what every combination would free right now.
- **Pinned conversations** that are never touched.
- **Optimize Now…** with a preview, a per-run limit, and a confirm button that states the exact count and size.
- **Optimize automatically** (off by default): every 6 hours after a health check, at most 25 GB per run; only then does the app stay in the menu bar and optionally start at login.
- **Health**: prerequisites, what has been removed, what Messages re-downloaded, canary state, run history.
- **Help**: what it does and never does, and the call list above.
- Off by default: automatic runs, start at login. The app is meant to be launched a few times a year when the disk fills up; closing the window quits it.

## Frequently asked questions

**Does this delete my messages or attachments?** No. It removes local copies of attachments that are already in iCloud. Messages, conversations and iCloud are untouched, and the app has no code path that can delete a database row.

**Will attachments disappear from my iPhone or iPad?** No. Other devices sync from iCloud, which is not changed.

**How is this different from Messages › Settings › "Keep messages: 30 days"?** That setting deletes conversations, including attachments, from iCloud and every device. This app deletes nothing; it only frees local disk space.

**Why does it need Full Disk Access?** `~/Library/Messages` is protected; nothing can read the Messages database without it. The app reads it read-only.

**Why does "Sync now" ask for Accessibility?** The Messages daemon accepts sync requests only from Messages itself, so the button presses Messages' own Sync Now for you. It is optional; you can click that button in Messages yourself.

**I freed 15 GB but Finder shows less.** macOS reclaims space from APFS local snapshots over time; `tmutil listlocalsnapshots /` shows them.

**Is it safe to use on a huge library?** The first run is capped at 1 GB, later runs at 25 GB, every run is previewed, and re-download was validated on a 190 GB library. The one thing no tool can verify is that Apple's servers still hold every file; the app relies on Messages' own "uploaded" flag, the same flag Apple's daemon relies on.

## Build from source

```sh
git clone https://github.com/zmh/messages-storage-saver-mac.git
cd messages-storage-saver-mac
swift build -c release            # core library, `mss` CLI, app binary
swift test                        # 67 tests against a synthetic store, never your live one
scripts/build-app.sh --install    # dist/Messages Storage Saver.app, copied to /Applications
```

Signing: set `APP_SIGN_IDENTITY="Developer ID Application: …"` (or put it in `scripts/signing.local.sh`, which is git-ignored); without it the build is ad-hoc signed and Full Disk Access must be re-granted after each rebuild. `scripts/make-pkg.sh` notarizes and wraps the app in a `.dmg` (or a `.pkg` when a Developer ID Installer certificate is present).

Debug builds refuse the live Messages store; point them at a synthetic one:

```sh
python3 scripts/make-fixture.py /tmp/mss-fixture
scripts/build-app.sh --debug
open --env MSS_APP_STORE_DIR=/tmp/mss-fixture "dist/Messages Storage Saver.app"
```

## Command line

The same engine as `mss`, for scripting and inspection:

```sh
.build/release/mss analyze            # what is local, eligible, and would be optimized (read-only)
.build/release/mss estimate           # the savings table for every window × size (read-only)
.build/release/mss probe              # prerequisites (read-only)
.build/release/mss chats              # conversations ranked by old attachment bytes (read-only)
.build/release/mss offload            # DRY RUN: nothing is removed
.build/release/mss offload --yes      # removes local copies within the run budget
.build/release/mss status             # what was removed, what Messages re-downloaded, canaries
.build/release/mss sync-now --yes     # press Messages' Sync Now for you (needs Accessibility)
```

Options: `--keep-days`, `--min-size-mb`, `--pin "Name"`, `--limit-gb`, `--chat`, `--before`, `--archive-to DIR` (byte-verified copy before removal, command line only). Configuration is shared with the app in `~/Library/Application Support/MessagesStorageSaver/config.json`.

## Safety and privacy

- [SAFETY.md](SAFETY.md): the protection layers, canaries, budgets, and the gates the app adds for unattended runs.
- [PRIVACY.md](PRIVACY.md): exactly what is read and written. Nothing leaves your Mac.
- [experiments/EXPERIMENT.md](experiments/EXPERIMENT.md): the validation on a real account, including the finding that Apple's built-in offload is compiled out on macOS 15.

## Never do these (they delete from iCloud and every device)

- Messages › Settings › General › **Keep messages: 30 Days / One Year**
- iCloud settings › Messages › **Disable & Delete**
- Deleting messages inside the Messages app while Messages in iCloud is on
- Editing `chat.db` or touching `~/Library/Messages/Sync`

## License

MIT. Not affiliated with or endorsed by Apple. "Messages", "iMessage", "iCloud" and "macOS" are trademarks of Apple Inc.
