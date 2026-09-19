#!/usr/bin/env python3
"""Tests for protect-messages.py. Run: python3 .claude/hooks/test_protect_messages.py"""
import json
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HOOK = os.path.join(HERE, "protect-messages.py")
PROJECT = os.path.abspath(os.path.join(HERE, "..", ".."))
HOME = os.path.expanduser("~")


def run(tool, tool_input, cwd=PROJECT):
    env = dict(os.environ, CLAUDE_PROJECT_DIR=PROJECT)
    p = subprocess.run(
        [sys.executable, HOOK],
        input=json.dumps({"tool_name": tool, "tool_input": tool_input, "cwd": cwd}),
        capture_output=True, text=True, env=env,
    )
    return p.returncode, p.stderr


class Blocked(unittest.TestCase):
    def assertBlocked(self, cmd, tool="Bash", cwd=PROJECT):
        inp = {"command": cmd} if tool == "Bash" else {"file_path": cmd}
        code, err = run(tool, inp, cwd)
        self.assertEqual(code, 2, f"expected BLOCK for {cmd!r}, got {code}: {err}")

    def assertAllowed(self, cmd, tool="Bash", cwd=PROJECT):
        inp = {"command": cmd} if tool == "Bash" else {"file_path": cmd}
        code, err = run(tool, inp, cwd)
        self.assertEqual(code, 0, f"expected ALLOW for {cmd!r}, got {code}: {err}")

    # --- live store, mutating ---
    def test_rm_attachments(self):
        self.assertBlocked("rm -rf ~/Library/Messages/Attachments")

    def test_rm_after_cd(self):
        self.assertBlocked("cd ~/Library/Messages && rm -rf Attachments")

    def test_find_delete(self):
        self.assertBlocked("find ~/Library/Messages/Attachments -type f -mtime +30 -delete")

    def test_find_exec(self):
        self.assertBlocked(r"find ~/Library/Messages/Attachments -type f -exec rm {} \;")

    def test_mv_out(self):
        self.assertBlocked("mv ~/Library/Messages/chat.db /tmp/chat.db")

    def test_redirect_into_store(self):
        self.assertBlocked("echo x > ~/Library/Messages/chat.db")

    def test_truncate(self):
        self.assertBlocked("truncate -s 0 $HOME/Library/Messages/chat.db")

    def test_python_script_touching_store(self):
        self.assertBlocked("python3 -c \"import os; os.remove(os.path.expanduser('~/Library/Messages/Attachments/x'))\"")

    def test_python_readonly_script_still_blocked(self):
        # Scripts are opaque; anything mentioning the store is refused.
        self.assertBlocked("python3 probe.py --dir ~/Library/Messages")

    def test_xattr_delete(self):
        self.assertBlocked("xattr -d com.apple.quarantine ~/Library/Messages/Attachments/a/b/c/x.heic")

    def test_chflags(self):
        self.assertBlocked("chflags uchg ~/Library/Messages/chat.db")

    # --- sqlite ---
    def test_sqlite_without_readonly(self):
        self.assertBlocked("sqlite3 ~/Library/Messages/chat.db 'SELECT 1'")

    def test_sqlite_readonly_with_delete(self):
        self.assertBlocked("sqlite3 -readonly ~/Library/Messages/chat.db 'DELETE FROM attachment'")

    def test_sqlite_restore(self):
        self.assertBlocked("sqlite3 -readonly ~/Library/Messages/chat.db '.restore /tmp/x.db'")

    def test_sqlite_replace_into(self):
        self.assertBlocked("sqlite3 -readonly ~/Library/Messages/chat.db 'REPLACE INTO kvtable VALUES (1)'")

    def test_sqlite_replace_function_is_readonly(self):
        self.assertAllowed("sqlite3 -readonly ~/Library/Messages/chat.db \"SELECT replace(filename,'~','/x') FROM attachment LIMIT 1\"")

    # --- prefs & daemons ---
    def test_defaults_keep_messages(self):
        self.assertBlocked("defaults write com.apple.iChat KeepMessageForDays -int 30")

    def test_defaults_madrid(self):
        self.assertBlocked("defaults write com.apple.madrid EnableCacheDelete -bool YES")

    def test_defaults_delete(self):
        self.assertBlocked("defaults delete com.apple.madrid EnableCacheDelete")

    def test_launchctl_imagent(self):
        self.assertBlocked("launchctl kickstart -k gui/501/com.apple.imagent")

    def test_killall_messages(self):
        self.assertBlocked("killall Messages")

    # --- the tool itself ---
    def test_tool_execute(self):
        self.assertBlocked("swift run mss offload --keep-days 30 --yes")

    def test_tool_build_binary_execute(self):
        self.assertBlocked(".build/release/mss offload --execute")

    def test_sync_now_is_the_one_allowed_yes(self):
        # A sync request deletes nothing; the user asked for it to be runnable.
        self.assertAllowed(".build/release/mss sync-now --yes")
        self.assertAllowed(".build/release/mss sync-now")
        self.assertBlocked(".build/release/mss offload --yes")
        self.assertBlocked(".build/release/mss sync-now; .build/release/mss offload --yes")

    def test_allow_real_store_env_blocked(self):
        self.assertBlocked("MSS_ALLOW_REAL_STORE=1 .build/debug/mss analyze")
        self.assertBlocked("export MSS_ALLOW_REAL_STORE=1")

    def test_app_launch_on_live_store_blocked(self):
        self.assertBlocked('open "dist/Messages Storage Saver.app"')
        self.assertBlocked("open dist/MessagesStorageSaver.app")
        self.assertBlocked("swift run MessagesStorageSaver")
        self.assertBlocked(".build/debug/MessagesStorageSaver")
        self.assertBlocked('"dist/Messages Storage Saver.app/Contents/MacOS/MessagesStorageSaver" &')

    def test_app_launch_on_fixture_allowed(self):
        self.assertAllowed('open --env MSS_APP_STORE_DIR=/tmp/mss-fixture "dist/Messages Storage Saver.app"')
        self.assertAllowed("MSS_APP_STORE_DIR=/tmp/mss-fixture swift run MessagesStorageSaver")

    def test_build_and_package_scripts_allowed(self):
        self.assertAllowed("scripts/build-app.sh --debug")
        self.assertAllowed("scripts/make-pkg.sh --format dmg --skip-notarize")
        self.assertAllowed('codesign --verify --deep --strict "dist/Messages Storage Saver.app"')
        self.assertAllowed('spctl --assess --type execute --verbose "dist/Messages Storage Saver.app"')

    def test_messages_app_control_blocked(self):
        self.assertBlocked("osascript -e 'tell application \"Messages\" to quit'")
        self.assertBlocked("open -a Messages")
        self.assertBlocked("open -b com.apple.MobileSMS")

    # --- deletes elsewhere ---
    def test_rm_home(self):
        self.assertBlocked("rm -rf ~/Documents/other")

    def test_rm_root(self):
        self.assertBlocked("rm -rf /")

    def test_rm_relative_outside(self):
        self.assertBlocked("rm -rf build", cwd=HOME)

    # --- file tools ---
    def test_write_into_store(self):
        self.assertBlocked(HOME + "/Library/Messages/x.txt", tool="Write")

    def test_edit_prefs(self):
        self.assertBlocked(HOME + "/Library/Preferences/com.apple.madrid.plist", tool="Edit")

    # --- allowed ---
    def test_ls(self):
        self.assertAllowed("ls -la ~/Library/Messages/")

    def test_du(self):
        self.assertAllowed("du -sh ~/Library/Messages/Attachments")

    def test_sqlite_readonly_select(self):
        self.assertAllowed("sqlite3 -readonly ~/Library/Messages/chat.db 'SELECT COUNT(*) FROM attachment'")

    def test_sqlite_readonly_backup(self):
        self.assertAllowed("sqlite3 -readonly ~/Library/Messages/chat.db \".backup '/tmp/chat-backup.db'\"")

    def test_defaults_read(self):
        self.assertAllowed("defaults read com.apple.madrid CloudKitSyncingEnabled")

    def test_find_print(self):
        self.assertAllowed("find ~/Library/Messages/Attachments -type f -print0 | xargs -0 stat -f '%N %z' > /tmp/manifest.tsv")

    def test_xattr_list(self):
        self.assertAllowed("xattr -l ~/Library/Messages/Attachments/a/b/c/x.heic")

    def test_rm_build(self):
        self.assertAllowed("rm -rf .build")

    def test_rm_tmp(self):
        self.assertAllowed("rm -f /tmp/scratch.txt")

    def test_swift_build(self):
        self.assertAllowed("swift build -c release")

    def test_tool_dry_run(self):
        self.assertAllowed("swift run mss offload --keep-days 30 --dry-run")

    def test_write_in_project(self):
        self.assertAllowed(PROJECT + "/Sources/x.swift", tool="Write")

    # --- fixture databases inside the project are not the live store ---
    def test_fixture_build_script(self):
        self.assertAllowed("python3 scripts/make-fixture.py Tests/Fixtures/store")

    def test_fixture_sqlite_readonly(self):
        self.assertAllowed("sqlite3 -readonly Tests/Fixtures/store/chat.db 'SELECT COUNT(*) FROM attachment'")

    def test_fixture_sqlite_write_allowed(self):
        self.assertAllowed("sqlite3 Tests/Fixtures/store/chat.db 'DELETE FROM attachment WHERE ROWID=1'")

    def test_fixture_rm(self):
        self.assertAllowed("rm -rf Tests/Fixtures/store")

    def test_chat_db_unknown_location_is_store(self):
        self.assertBlocked("python3 probe.py ~/Desktop/chat.db")

    def test_chat_db_bare_name_outside_project(self):
        self.assertBlocked("sqlite3 chat.db 'SELECT 1'", cwd=HOME)

    def test_copy_live_db_over_fixture(self):
        self.assertBlocked("cp ~/Library/Messages/chat.db Tests/Fixtures/store/chat.db")

    def test_redirect_into_chat_db_uri(self):
        self.assertBlocked("echo x > ~/Library/Messages/chat.db-wal")

    def test_empty(self):
        self.assertAllowed("")


if __name__ == "__main__":
    unittest.main(verbosity=1)
