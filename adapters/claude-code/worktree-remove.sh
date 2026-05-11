#!/usr/bin/env bash
# Claude Code WorktreeRemove adapter for `wti`.
#
# Wired in .claude/settings.json:
#   "WorktreeRemove": [{"hooks": [{"type": "command",
#       "command": ".claude/hooks/worktree-remove.sh"}]}]
#
# Reads Claude Code's stdin JSON. Resolves either a `worktree_path`/`path`
# or a `name`/`worktree_name` (which `wti remove` will slugify) and calls
# `wti remove`. Failures here are logged but never block git's worktree
# removal — same forgiving posture as the legacy hook.
set -euo pipefail

read -r WORKTREE_PATH NAME < <(python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print(" "); sys.exit(0)
p = d.get("worktree_path") or d.get("path") or ""
n = d.get("name") or d.get("worktree_name") or ""
print(p, n)
')

if [[ -n "${WORKTREE_PATH:-}" ]]; then
    wti remove --path "$WORKTREE_PATH" || true
elif [[ -n "${NAME:-}" ]]; then
    wti remove "$NAME" || true
else
    echo "[claude-code-adapter] WARN: no worktree path or name in hook input" >&2
fi
exit 0
