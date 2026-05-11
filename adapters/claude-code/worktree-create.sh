#!/usr/bin/env bash
# Claude Code WorktreeCreate adapter for `wti`.
#
# Wired in .claude/settings.json:
#   "WorktreeCreate": [{"hooks": [{"type": "command",
#       "command": ".claude/hooks/worktree-create.sh"}]}]
#
# Reads Claude Code's stdin JSON ({"name": "<branch>"}), invokes
# `wti create --json`, and prints the resulting worktree path on the
# first line of stdout (Claude Code's session-attach contract). All
# progress logs from wti continue to flow through stderr.
set -euo pipefail

NAME="$(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
print(d.get("name") or d.get("worktree_name") or "")
')"

if [[ -z "$NAME" ]]; then
    echo "[claude-code-adapter] ERR: branch name missing from hook input" >&2
    exit 1
fi

RESULT="$(wti create "$NAME" --json)"
printf '%s\n' "$RESULT" | python3 -c '
import json, sys
print(json.load(sys.stdin)["path"])
'
