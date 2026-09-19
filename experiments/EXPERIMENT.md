# Validation experiment

## Results so far (2026-09-17/18, macOS 15.8)

- **Mechanism A (Apple's own purge) is unavailable on macOS 15.8.** `-[IMDCKUtilities cacheDeleteEnabled]`
  is compiled to return NO; the daemon logs "cache delete enabled NO" with both switches set. A purge
  request (correct call: `CacheDeletePurgeSpaceWithInfoSync(info, block)`) freed 176 MB of other
  caches and changed no attachment. Switches reverted.
- **Mechanism B (this tool) passed on three slices** (307 + 212 + 7 files, 846 MB, all archived):
  - iCloud untouched: attachment deletion counter unchanged; iPhone placeholders download fine.
  - No spontaneous re-download over 13+ hours and several sync passes.
  - Restore works: after **quitting and reopening Messages**, offloaded items show Apple's
    placeholder with a per-item download button; downloading returned a file byte-identical to
    the archive copy. The Conversation Details › Download button does **not** appear (rows are not
    in Apple's purged state), so restore is per item.
  - UX caveat: while Messages.app stays open it keeps showing cached thumbnails and "file can't be
    found" on open. Offload should run when Messages is closed, or prompt a relaunch.
  - A re-downloaded row goes to `ck_sync_state = 0` until the daemon's next pass; status reports
    this as pending, not as a violation.
  - Apple's 30-day Recently Deleted expiry queues message deletions on its own schedule; the
    counters are attributed per run, so this shows up as a note, not a violation.

Goal: prove, on a small slice, that offloading local attachment copies (a) leaves iCloud and
the iPhone untouched, (b) leaves Messages able to re-download on demand, and (c) does not make
the Mac re-download everything. Two mechanisms are tested: Apple's own dormant offload
(mechanism A) and this tool's file-level offload (mechanism B).

Everything below that removes or changes anything is typed **by you**, never by an assistant.
Commands assume a release build:

```sh
swift build -c release
alias mss="$PWD/.build/release/mss"
```

Baselines and checks are read-only and can be run at any time.

## Stage 0 — before signing in (signed out today)

1. Backups exist: `ls -la ~/Library/Application\ Support/MessagesStorageSaver/backups/`
   (a `.backup` copy of chat.db and a manifest of every attachment file, made 2026-09-17).
   A Time Machine backup to an external drive is strongly recommended before Stage 3.
2. Headroom for sync. The disk has ~14 GB free and Messages has pending placeholder
   downloads. Clear the regenerable preview cache (9.1 GB, Messages rebuilds thumbnails):
   ```sh
   mss offload --tier previews            # dry run
   mss offload --tier previews --yes      # removes ~/Library/Messages/Caches/Previews only
   ```
3. Record the signed-out baseline:
   ```sh
   mss probe
   mss analyze --json > ~/Desktop/mss-baseline-signed-out.json
   ```

## Stage 1 — sign in and let sync settle

1. Messages › Settings › iMessage: sign in. Make sure **Enable Messages in iCloud** is on.
   Click **Sync Now** if shown. Leave the Mac awake and on power.
2. Wait until `mss probe` shows every check ✓, in particular
   `Uploads caught up` and a sync date within 48 hours. Press Sync Now if it lags.
3. Baseline again:
   ```sh
   mss probe
   mss analyze --json > ~/Desktop/mss-baseline-signed-in.json
   mss status
   ```
   Note the tombstone counts (23 attachments / 4 messages today) and the purgeable amounts
   the daemon reports at urgency 0–4.

## Stage 2 — mechanism B: this tool, one old conversation (do this first)

1. Pick a conversation with a few hundred MB of attachments older than two years, ideally
   containing a Live Photo (HEIC + .MOV):
   ```sh
   mss chats --older-than-days 730 --top 15
   ```
2. Dry run, then real run with an archive copy (external drive preferred; a local folder is
   fine for a few hundred MB):
   ```sh
   mss offload --tier attachments --chat "<identifier>" --before 2023-01-01
   mss offload --tier attachments --chat "<identifier>" --before 2023-01-01 \
       --archive-to ~/mss-archive --yes
   mss journal --last 20
   ```
   The first real run is capped at 1 GB.
3. Work through the pass criteria below over 48 hours before moving on.

## Stage 3 — mechanism A: Apple's own offload (after Stage 2 passes)

Apple's daemon refuses to purge without two preferences it names in its own log strings.
`enable` writes them and restarts imagent (the equivalent of
`defaults write com.apple.madrid EnableCacheDelete -bool YES` and `PurgeWithCacheDelete`).

```sh
mss apple-offload status
mss apple-offload enable --yes
sleep 60; mss apple-offload status         # do the purgeable amounts change?
```

Ask the system to purge 300 MB from Messages at urgency 1 (the level the OS uses every
~30 minutes on this Mac):

```sh
mss apple-offload request-purge --gb 0.3 --urgency 1 --yes
mss analyze | head -8                       # "Already offloaded" rows / files on disk changed?
mss status
```

If the request is refused (entitlement) the OS's own cycle may still act within an hour;
re-run `mss analyze` after 60 minutes. Whatever happens, record it. Optional second round:
`mss apple-offload enable --centralized --yes`, then after an hour check whether eligible
files gain the APFS purgeable flag (`mss analyze` → "already flagged APFS-purgeable").

Revert at any time: `mss apple-offload disable --yes`.

### Pass criteria (both mechanisms)

| Check | How | Pass |
|---|---|---|
| (a) iPhone still has everything | open the conversation on the iPhone, scroll to those months | every photo/video opens |
| (b) no deletion reached iCloud | `mss status`: no run ended with a canary problem. Counter increases *outside* runs are reported as notes; they come from Apple's 30-day Recently Deleted expiry or deletions you make in the app | no problem runs |
| (c) rows stay synced | `mss status` ("rows no longer marked synced") at T+1 min, 1 h, 24 h | 0 |
| (d) Mac can restore | in Messages.app open the conversation, ⓘ, scroll down, **Download**; then `mss status` ("re-downloaded") and compare with the archive using `cmp` | files return byte-identical, including the `.MOV` |
| (e) no spontaneous re-download | `mss status` every few hours for 48 h; optionally `log stream --info --predicate 'process == "IMTransferAgent" OR process == "imagent"' \| grep -i -E "purg|download"` | removed files stay absent except the ones you restored in (d) |

Any failure of (a), (b) or (c) stops the experiment; revert with
`mss restore --chat "<identifier>" --from-archive --yes` and report.

## Stage 4 — scale up

```sh
mss offload --tier attachments --limit-gb 10 --archive-to ... --yes    # then 48 h of checks
mss offload --tier attachments --yes                                  # normal 25 GB cap per run
```

Run `mss status` after each; canary violations print in capitals and exit with code 3.
