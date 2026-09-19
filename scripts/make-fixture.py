#!/usr/bin/env python3
"""Build a synthetic Messages store for tests.

Creates <out>/chat.db from Tests/Fixtures/schema.sql (the real macOS 15.8
schema, extracted read-only), plus a synthetic Attachments tree and a
preview cache, covering every eligibility edge case the offload logic must
handle. Never touches ~/Library/Messages and refuses to write there.

Usage: python3 scripts/make-fixture.py Tests/Fixtures/store
"""
import os
import random
import re
import sqlite3
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "..", "Tests", "Fixtures", "schema.sql")
APPLE_EPOCH = 978307200  # 2001-01-01 in Unix seconds
DAY = 86400

# The fixture DB uses the same "~/Library/Messages/Attachments/..." filename
# convention as the real store; the tool maps that prefix onto --messages-dir.
STORE_PREFIX = "~/Library/Messages/Attachments/"


def apple_ns(days_ago):
    return int((time.time() - days_ago * DAY - APPLE_EPOCH) * 1_000_000_000)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = os.path.realpath(os.path.expanduser(sys.argv[1]))
    forbidden = os.path.realpath(os.path.expanduser("~/Library/Messages"))
    if out == forbidden or out.startswith(forbidden + os.sep):
        sys.exit("refusing to write a fixture inside the live Messages store")
    os.makedirs(out, exist_ok=True)
    db_path = os.path.join(out, "chat.db")
    if os.path.exists(db_path):
        os.remove(db_path)
    for suffix in ("-wal", "-shm"):
        if os.path.exists(db_path + suffix):
            os.remove(db_path + suffix)

    conn = sqlite3.connect(db_path)
    with open(SCHEMA) as f:
        lines = f.read().splitlines()
    # Internal tables (sqlite_sequence, sqlite_stat1, ...) are auto-managed;
    # the real schema dump includes them but they cannot be created directly.
    schema = "\n".join(l for l in lines if not re.match(r"\s*CREATE TABLE sqlite_", l))
    conn.executescript(schema)

    cur = conn.cursor()
    cur.execute("INSERT INTO handle (ROWID, id, service) VALUES (1, '+15550000001', 'iMessage')")
    cur.execute("INSERT INTO handle (ROWID, id, service) VALUES (2, '+15550000002', 'iMessage')")
    chats = [
        (1, "chat-old-friend", "iMessage;-;+15550000001", "Old Friend"),
        (2, "chat-pinned", "iMessage;-;+15550000002", "Pinned Chat"),
        (3, "chat-group", "iMessage;+;chat123456", "Group"),
    ]
    for rowid, guid, ident, name in chats:
        cur.execute(
            "INSERT INTO chat (ROWID, guid, chat_identifier, service_name, display_name, style, state, account_id, ck_sync_state) "
            "VALUES (?, ?, ?, 'iMessage', ?, 45, 3, 'acct', 1)",
            (rowid, guid, ident, name),
        )

    random.seed(7)
    rows = []  # (label, chat_id, days_ago, attachment dict or None, message flags)

    def att(name, size, ck=1, ts=5, uti="public.jpeg", mime="image/jpeg", hidden=0, sticker=0,
            on_disk=True, disk_size=None, ck_record="rec", path=None, extra_sidecar=None):
        return dict(name=name, size=size, ck=ck, ts=ts, uti=uti, mime=mime, hidden=hidden, sticker=sticker,
                    on_disk=on_disk, disk_size=size if disk_size is None else disk_size,
                    ck_record=ck_record, path=path, extra_sidecar=extra_sidecar)

    cases = [
        ("eligible_old_jpeg", 1, 400, att("IMG_0001.jpeg", 3_000_000), {}),
        ("eligible_old_heic_with_live_sidecar", 1, 800, att("IMG_0002.HEIC", 2_500_000, uti="public.heic", mime="image/heic", extra_sidecar="IMG_0002.MOV"), {}),
        ("eligible_old_video", 1, 1200, att("IMG_0003.MOV", 40_000_000, uti="com.apple.quicktime-movie", mime="video/quicktime"), {}),
        ("recent_within_keep_window", 1, 5, att("IMG_0004.jpeg", 1_000_000), {}),
        ("boundary_29_days", 1, 29, att("IMG_0005.jpeg", 1_000_000), {}),
        # Also joined to the pinned chat: pinned if ANY of its chats is pinned, selected once otherwise.
        ("boundary_31_days", 1, 31, att("IMG_0006.jpeg", 1_000_000), {"extra_chats": [2]}),
        ("audio_message", 1, 500, att("Audio Message.caf", 200_000, uti="com.apple.coreaudio-format", mime="audio/x-caf"), {"is_audio_message": 1}),
        ("sticker", 1, 500, att("sticker.png", 50_000, uti="public.png", mime="image/png", sticker=1), {}),
        ("plugin_payload", 1, 500, att("payload.pluginPayloadAttachment", 30_000, uti="dyn.age81a5dzq7y066dbtf0g82peqf4hk2pdrb00n5xy", mime=""), {}),
        ("hidden_attachment", 1, 500, att("hidden.jpeg", 70_000, hidden=1), {}),
        ("not_synced_ck0", 1, 500, att("IMG_0010.jpeg", 900_000, ck=0, ck_record=None), {}),
        ("sync_failed_ck2", 1, 500, att("IMG_0011.jpeg", 900_000, ck=2), {}),
        ("ck4_not_eligible", 1, 500, att("IMG_0012.jpeg", 900_000, ck=4), {}),
        ("already_purged_placeholder", 1, 500, att("IMG_0013.jpeg", 900_000, ts=0, on_disk=False, path="NULL"), {}),
        ("transfer_in_progress", 1, 500, att("IMG_0014.jpeg", 900_000, ts=3), {}),
        ("missing_on_disk", 1, 500, att("IMG_0015.jpeg", 900_000, on_disk=False), {}),
        ("size_mismatch", 1, 500, att("IMG_0016.jpeg", 900_000, disk_size=123), {}),
        ("outside_store_var_folders", 1, 500, att("IMG_0017.jpeg", 900_000, path="/var/folders/xx/yy/T/IMG_0017.jpeg", on_disk=False), {}),
        ("pinned_chat_old", 2, 700, att("IMG_0018.jpeg", 2_000_000), {}),
        ("group_chat_old", 3, 700, att("IMG_0019.jpeg", 2_000_000), {}),
        ("rich_link_old", 1, 700, att("link.pluginPayloadAttachment", 20_000, uti="com.apple.messages.richlink", mime=""), {}),
        # message.date = 0 reads as 2001-01-01: unknown age, never offloaded.
        ("date_zero", 1, 900, att("IMG_0021.jpeg", 800_000), {"date": 0}),
    ]

    msg_rowid = 0
    att_rowid = 0
    for label, chat_id, days_ago, a, flags in cases:
        msg_rowid += 1
        att_rowid += 1
        date = flags["date"] if "date" in flags else apple_ns(days_ago)
        cur.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, is_audio_message, service, cache_has_attachments, ck_sync_state) "
            "VALUES (?, ?, ?, 1, ?, 0, ?, 'iMessage', 1, 1)",
            (msg_rowid, f"msg-{label}", label, date, flags.get("is_audio_message", 0)),
        )
        cur.execute("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)", (chat_id, msg_rowid, date))
        for extra in flags.get("extra_chats", []):
            cur.execute("INSERT INTO chat_message_join (chat_id, message_id, message_date) VALUES (?, ?, ?)", (extra, msg_rowid, date))
        guid = f"att-{label}"
        hexes = f"{random.randrange(256):02x}/{random.randrange(256):02x}"
        if a["path"] == "NULL":
            filename = None
        elif a["path"]:
            filename = a["path"]
        else:
            filename = f"{STORE_PREFIX}{hexes}/{guid}/{a['name']}"
        cur.execute(
            "INSERT INTO attachment (ROWID, guid, original_guid, created_date, filename, uti, mime_type, transfer_state, is_outgoing, "
            "transfer_name, total_bytes, is_sticker, hide_attachment, ck_sync_state, ck_record_id) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, ?, ?)",
            (att_rowid, guid, guid, date // 1_000_000_000, filename, a["uti"], a["mime"], a["ts"], a["name"], a["size"],
             a["sticker"], a["hidden"], a["ck"], (f"{a['ck_record']}-{guid}" if a["ck_record"] else None)),
        )
        cur.execute("INSERT INTO message_attachment_join (message_id, attachment_id) VALUES (?, ?)", (msg_rowid, att_rowid))
        if filename and filename.startswith(STORE_PREFIX) and a["on_disk"]:
            rel = filename[len(STORE_PREFIX):]
            full = os.path.join(out, "Attachments", rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            with open(full, "wb") as f:
                f.write(os.urandom(min(a["disk_size"], 4096)))
                if a["disk_size"] > 4096:
                    f.truncate(a["disk_size"])
            # Files carry the mtime of their message, like real downloads.
            mtime = time.time() - days_ago * DAY
            os.utime(full, (mtime, mtime))
            if a["extra_sidecar"]:
                sidecar = os.path.join(os.path.dirname(full), a["extra_sidecar"])
                with open(sidecar, "wb") as f:
                    f.truncate(1_500_000)
                os.utime(sidecar, (mtime, mtime))
            # Preview thumbnails mirror the layout under Caches/Previews.
            prev = os.path.join(out, "Caches", "Previews", "Attachments", rel + ".preview.jpg")
            os.makedirs(os.path.dirname(prev), exist_ok=True)
            with open(prev, "wb") as f:
                f.truncate(20_000)

    # Orphan attachment row with no message join (like group photos).
    att_rowid += 1
    cur.execute(
        "INSERT INTO attachment (ROWID, guid, original_guid, filename, uti, mime_type, transfer_state, total_bytes, ck_sync_state, ck_record_id) "
        "VALUES (?, 'att-orphan', 'att-orphan', ?, 'public.jpeg', 'image/jpeg', 5, 500000, 1, 'rec-orphan')",
        (att_rowid, f"{STORE_PREFIX}aa/bb/iMessage;+;chat123456/GroupPhotoImage"),
    )
    gp = os.path.join(out, "Attachments", "aa", "bb", "iMessage;+;chat123456", "GroupPhotoImage")
    os.makedirs(os.path.dirname(gp), exist_ok=True)
    with open(gp, "wb") as f:
        f.truncate(500_000)

    # A symlink inside the store pointing outside: must never be followed/deleted.
    link_dir = os.path.join(out, "Attachments", "cc", "dd", "att-symlink")
    os.makedirs(link_dir, exist_ok=True)
    target = os.path.join(out, "outside-target.bin")
    with open(target, "wb") as f:
        f.truncate(10_000)
    link = os.path.join(link_dir, "escape.jpeg")
    if not os.path.lexists(link):
        os.symlink(target, link)

    # Tombstone baselines.
    cur.execute("INSERT INTO sync_deleted_attachments (guid, recordID) VALUES ('gone-1', 'rec-gone-1')")
    cur.execute("INSERT INTO sync_deleted_messages (guid, recordID) VALUES ('gone-m1', 'rec-gone-m1')")
    conn.commit()
    conn.close()
    print(f"fixture written to {out}: {len(cases)} cases + orphan + symlink")


if __name__ == "__main__":
    main()
