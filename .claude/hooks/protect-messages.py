#!/usr/bin/env python3
"""PreToolUse guard for the Messages Storage Saver project.

Blocks any tool call that could modify the live Messages store
(~/Library/Messages: chat.db, sync.db, Attachments, ...) or the Messages
preference domains. Also confines file deletion to the project, temp dirs
and the build directory, and refuses to run the storage-saver tool itself
in execution (non dry-run) mode. Real offload steps are typed by the user.

Protocol: reads the hook JSON on stdin. Exit 2 = block (reason on stderr).
Exit 0 = allow. Any internal error also blocks (fail closed).
"""
import json
import os
import re
import sys

HOME = os.path.expanduser("~")
PROJECT = os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()

PROTECTED_DIRS = [
    os.path.join(HOME, "Library", "Messages"),
    os.path.join(HOME, "Library", "Containers", "com.apple.iChat"),
]
PROTECTED_FILE_RE = re.compile(
    r"/Library/Preferences/com\.apple\.(iChat|madrid|imagent|Messages|MobileSMS|imservice|messages)[^/]*\.plist$",
    re.I,
)

# Unconditional mentions of the live store or the Messages preference domains.
MESSAGES_RE = re.compile(
    r"(Library/Messages|"
    r"com\.apple\.(iChat|madrid|imagent|Messages|MobileSMS|imservice|messages)|"
    r"KeepMessageForDays|Containers/com\.apple\.iChat)",
    re.I,
)
# Database file names that exist in the live store. A token naming one of
# these counts as a store mention unless its path clearly resolves inside the
# project or a temp directory (test fixtures are also called chat.db).
STORE_DB_RE = re.compile(r"(chat\.db|sync\.db|LiteSegmentStore|prewarm\.db)", re.I)

# Tokens that can mutate files, run arbitrary code, or control daemons.
MUTATING_RE = re.compile(
    r"(\b(rm|rmdir|unlink|mv|srm|shred|truncate|dd|tee|cp|rsync|ditto|chflags|chmod|chown|chgrp|"
    r"ln|touch|mkdir|install|python[0-9.]*|swift|swiftc|perl|ruby|node|osascript|launchctl|"
    r"kill|killall|pkill|tmutil|diskutil|open)\b"
    r"|-delete\b|-exec(dir)?\b|-ok(dir)?\b|xattr\s+-[dwc]\b|sed\s+-i\b|perl\s+-i\b|"
    r"plutil\s+-(replace|insert|remove)\b)"
)
REDIRECT_RE = re.compile(r"(?<![0-9&])>{1,2}\s*([^\s;|&]+)")
DELETE_CMD_RE = re.compile(r"\b(rm|rmdir|unlink|srm|shred)\b|-delete\b")
SQLITE_RO_RE = re.compile(r"(-readonly\b|mode=ro\b|immutable=1\b)")
SQLITE_WRITE_RE = re.compile(
    r"(\b(INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|VACUUM|REINDEX|ATTACH|DETACH)\b|\bREPLACE\s+INTO\b|"
    r"\.(restore|import|load|shell|system|excel)\b)",
    re.I,
)
DEFAULTS_WRITE_RE = re.compile(
    r"\bdefaults\s+(-currentHost\s+)?(write|delete|import|rename)\b.*"
    r"(com\.apple\.(iChat|madrid|imagent|Messages|MobileSMS|imservice|messages)|KeepMessageForDays)",
    re.I,
)
DAEMON_CONTROL_RE = re.compile(
    r"\b(launchctl|kill|killall|pkill)\b.*(imagent|imtransfer|imdpersistence|imautomatic|identityservicesd|Messages)",
    re.I,
)
TOOL_EXEC_RE = re.compile(
    r"(\bmss\b|MessagesStorageSaver|StorageSaver|\.build/).*(--yes\b|--execute\b|--apply\b|--no-dry-run\b|--force\b)",
    re.I,
)
SYNC_NOW_RE = re.compile(r"\bmss\s+sync-now\b")
EXEC_FLAG_RE = re.compile(r"(--yes\b|--execute\b|--apply\b|--no-dry-run\b|--force\b)")
# Debug builds refuse the live store without this variable; Claude never sets it.
ALLOW_REAL_STORE_RE = re.compile(r"MSS_ALLOW_REAL_STORE")
# Launching the menu-bar app: only against a fixture store (MSS_APP_STORE_DIR=...).
# A release app on the live store could start an automatic run 10 minutes later.
APP_LAUNCH_RE = re.compile(
    r"(\bopen\b[^|;&]*Messages ?Storage ?Saver\.app|"
    r"\bswift\s+run\s+MessagesStorageSaver\b|"
    r"\.build/\S*/MessagesStorageSaver(\s|$)|"
    r"Storage ?Saver\.app/Contents/MacOS/MessagesStorageSaver)",
    re.I,
)
APP_FIXTURE_RE = re.compile(r"MSS_APP_STORE_DIR=")
# Quitting or launching Messages.app is the user's click, never a command.
MESSAGES_APP_CONTROL_RE = re.compile(
    r"(\bosascript\b.*\bMessages\b|\bopen\b\s+(-a|-b)\s+[\"']?(Messages\b|com\.apple\.MobileSMS))",
    re.I,
)

ALLOWED_DELETE_ROOTS = [
    os.path.realpath(PROJECT),
    "/tmp",
    "/private/tmp",
    os.path.realpath(os.environ.get("TMPDIR", "/tmp")),
]


def block(reason):
    sys.stderr.write("BLOCKED by .claude/hooks/protect-messages.py: " + reason + "\n")
    sys.exit(2)


def expand(token, cwd):
    t = token.strip("\"'")
    t = t.replace("$HOME", HOME).replace("${HOME}", HOME)
    t = t.replace("$CLAUDE_PROJECT_DIR", PROJECT).replace("${CLAUDE_PROJECT_DIR}", PROJECT)
    t = t.replace("$TMPDIR", os.environ.get("TMPDIR", "/tmp"))
    t = os.path.expanduser(t)
    # Strip from the first glob character onward so the prefix is checked.
    m = re.search(r"[*?\[]", t)
    if m:
        t = t[: m.start()]
    if not os.path.isabs(t):
        t = os.path.join(cwd, t)
    return os.path.normpath(t)


def under(path, roots):
    rp = os.path.realpath(path)
    for r in roots:
        r = os.path.realpath(r)
        if rp == r or rp.startswith(r + os.sep):
            return True
    return False


def path_like(token):
    t = token.strip("\"'")
    return t.startswith(("/", "~", "$HOME", "./", "../", "$CLAUDE_PROJECT_DIR", "$TMPDIR")) or "/" in t


def check_file_tool(tool_input):
    path = tool_input.get("file_path") or tool_input.get("notebook_path") or ""
    if not path:
        return
    p = os.path.normpath(os.path.expanduser(path))
    if under(p, PROTECTED_DIRS):
        block("file tools may never write under ~/Library/Messages (" + p + ")")
    if PROTECTED_FILE_RE.search(p):
        block("file tools may never write Messages preference plists (" + p + ")")


def check_bash(command, cwd):
    cmd = command.strip()
    if not cmd:
        return

    if DEFAULTS_WRITE_RE.search(cmd):
        block("writing Messages preference domains (com.apple.iChat / com.apple.madrid / ...) is reserved for the user to type")
    if DAEMON_CONTROL_RE.search(cmd):
        block("controlling Messages daemons (imagent, IMTransferAgent, ...) is reserved for the user to type")
    # `mss sync-now --yes` only asks the Messages daemon for an iCloud sync pass
    # (nothing is removed or changed); the user asked for it to be runnable.
    # Every clause that carries an execution flag must be a sync-now clause.
    if TOOL_EXEC_RE.search(cmd):
        clauses = re.split(r"[;&|]+", cmd)
        flagged = [c for c in clauses if EXEC_FLAG_RE.search(c)]
        if not flagged or not all(SYNC_NOW_RE.search(c) for c in flagged):
            block("running the storage-saver tool in execution mode (--yes/--execute/--apply/--force) is reserved for the user; Claude runs dry-runs only")
    if ALLOW_REAL_STORE_RE.search(cmd):
        block("MSS_ALLOW_REAL_STORE is reserved for the user; Claude works on fixture stores (MSS_APP_STORE_DIR / --messages-dir) or release read-only commands")
    if APP_LAUNCH_RE.search(cmd) and not APP_FIXTURE_RE.search(cmd):
        block("launching the app against the live Messages store is reserved for the user; Claude launches it only with MSS_APP_STORE_DIR=<fixture>")
    if MESSAGES_APP_CONTROL_RE.search(cmd):
        block("quitting or launching Messages.app is reserved for the user")

    mentions_store = bool(MESSAGES_RE.search(cmd))
    if not mentions_store:
        for tok in re.split(r"\s+", cmd):
            if STORE_DB_RE.search(tok):
                t = tok.strip("\"'").split("?", 1)[0]
                if t.startswith("file:"):
                    t = t[5:]
                target = expand(t, cwd)
                if under(target, PROTECTED_DIRS) or not under(target, ALLOWED_DELETE_ROOTS):
                    mentions_store = True
                    break
    if mentions_store:
        if MUTATING_RE.search(cmd):
            m = MUTATING_RE.search(cmd)
            block("command references the live Messages store and contains a mutating/scripting token (" + m.group(0).strip() + "). Use read-only commands (ls, du, stat, cat, xattr -l, sqlite3 -readonly, defaults read) or work on a scratch copy.")
        for m in REDIRECT_RE.finditer(cmd):
            target = m.group(1)
            if target.startswith("/dev/"):
                continue
            if MESSAGES_RE.search(target) or STORE_DB_RE.search(target) or under(expand(target, cwd), PROTECTED_DIRS):
                block("redirecting output into the live Messages store is not allowed")
        if re.search(r"\bsqlite3\b", cmd):
            if not SQLITE_RO_RE.search(cmd):
                block("sqlite3 on a Messages database requires -readonly (or a ?mode=ro / ?immutable=1 URI)")
            if SQLITE_WRITE_RE.search(cmd):
                block("write statements / restore-import dot-commands against a Messages database are not allowed even on a read-only connection")

    # Deletion anywhere: confine targets to the project, temp dirs and .build.
    if DELETE_CMD_RE.search(cmd):
        effective_cwd = cwd
        cd = re.search(r"(?:^|[;&|]\s*)cd\s+([^\s;&|]+)", cmd)
        if cd:
            effective_cwd = expand(cd.group(1), cwd)
            if not under(effective_cwd, ALLOWED_DELETE_ROOTS):
                block("cd + delete outside the project/temp directories (" + effective_cwd + ")")
        tokens = re.split(r"\s+", cmd)
        saw_target = False
        for tok in tokens:
            if tok.startswith("-") or tok in ("rm", "rmdir", "unlink", "srm", "shred", "find", "xargs", "&&", "||", ";", "|"):
                continue
            if path_like(tok):
                saw_target = True
                target = expand(tok, effective_cwd)
                if under(target, PROTECTED_DIRS):
                    block("deleting inside ~/Library/Messages is never allowed (" + target + ")")
                if not under(target, ALLOWED_DELETE_ROOTS):
                    block("deletion targets must stay inside the project or temp directories (" + target + ")")
        if not saw_target and not under(effective_cwd, ALLOWED_DELETE_ROOTS):
            block("relative delete with a working directory outside the project/temp directories (" + effective_cwd + ")")


def main():
    try:
        raw = sys.stdin.read()
        data = json.loads(raw) if raw.strip() else {}
        tool = data.get("tool_name", "")
        tool_input = data.get("tool_input", {}) or {}
        cwd = data.get("cwd") or os.getcwd()
        if tool == "Bash":
            check_bash(tool_input.get("command", ""), cwd)
        elif tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
            check_file_tool(tool_input)
    except SystemExit:
        raise
    except Exception as e:  # fail closed
        block("guard hook error (failing closed): " + repr(e))
    sys.exit(0)


if __name__ == "__main__":
    main()
