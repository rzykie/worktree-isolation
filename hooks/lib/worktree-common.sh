#!/usr/bin/env bash
# Shared helpers for worktree-isolation hooks. Sourced by repo-specific
# create/remove scripts. This file is identical across all consumer repos.

set -euo pipefail

HOOK_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
REGISTRY_PY="$HOOK_LIB_DIR/registry.py"

log() { printf '[worktree-hook] %s\n' "$*" >&2; }

# Source <hooks-dir>/worktree-isolation.conf if present, then export the
# WORKTREE_ISOLATION_* env vars that registry.py reads. Conf values
# already-set in the environment take precedence (so install-time values
# win, but a caller can still override per-invocation).
load_conf() {
    local hooks_dir="$1"
    local conf="$hooks_dir/worktree-isolation.conf"
    if [[ -f "$conf" ]]; then
        # shellcheck disable=SC1090
        source "$conf"
    fi
    : "${REPO_NAME:?REPO_NAME must be set in worktree-isolation.conf}"
    : "${WORKTREES_ROOT:?WORKTREES_ROOT must be set in worktree-isolation.conf}"
    : "${REGISTRY_PATH:?REGISTRY_PATH must be set in worktree-isolation.conf}"
    : "${DB_PREFIX:=wt_}"
    : "${BASE_BRANCH:=}"
    : "${TEMPLATE_DB:=}"
    : "${BOOTSTRAP_HOOK:=}"
    : "${WORKTREE_INCLUDE_FILE:=.worktreeinclude}"
    export WORKTREE_ISOLATION_REGISTRY_PATH="$REGISTRY_PATH"
    export WORKTREE_ISOLATION_DB_PREFIX="$DB_PREFIX"
}

# Derive a slug from a branch name. Strips common prefixes, lowercases,
# replaces '/' and '-' with '_', truncates at 30 chars. Two repos working
# on the same logical branch (`feat/foo` in one, `foo` in the other) get
# the same slug and so co-allocate to the same DB.
slugify_branch() {
    local branch="$1"
    branch="${branch#feat/}"; branch="${branch#feature/}"
    branch="${branch#fix/}"; branch="${branch#bugfix/}"
    branch="${branch#chore/}"; branch="${branch#exp/}"
    printf '%s' "$branch" | tr '/-' '__' | tr '[:upper:]' '[:lower:]' | cut -c1-30
}

registry_acquire() {
    local slug="$1" repo="$2" path="$3"
    python3 "$REGISTRY_PY" acquire --slug "$slug" --repo "$repo" --path "$path"
}

registry_release() {
    local path="$1"
    python3 "$REGISTRY_PY" release --path "$path"
}

registry_sweep() {
    python3 "$REGISTRY_PY" sweep
}

# Read a JSON object from stdin, return the value at a top-level (or dotted) key.
# Booleans render as "True"/"False" (Python repr); callers compare with == "True".
# NOTE: uses `python3 -c <script>` (not a heredoc) so stdin stays free for the JSON.
json_get() {
    local field="$1"
    python3 -c '
import json, sys
field = sys.argv[1]
data = json.loads(sys.stdin.read())
v = data
for k in field.split("."):
    if isinstance(v, dict):
        v = v.get(k)
    else:
        v = None
    if v is None:
        break
print("" if v is None else v)
' "$field"
}

# Copy each file listed in <main_root>/<include_file> into the worktree,
# preserving relative paths. Used for env files and other untracked but
# necessary local files. Lines starting with `#` are ignored. Missing
# include file = no-op.
copy_worktree_includes() {
    local main_root="$1" worktree_root="$2" include_file="$3"
    if [[ ! -f "$include_file" ]]; then
        log "no $include_file at $include_file; skipping copy"
        return 0
    fi
    while IFS= read -r rel || [[ -n "$rel" ]]; do
        [[ -z "$rel" || "$rel" =~ ^[[:space:]]*# ]] && continue
        rel="$(printf '%s' "$rel" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        local src="$main_root/$rel"
        local dst="$worktree_root/$rel"
        if [[ -f "$src" ]]; then
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            log "copied $rel"
        else
            log "skipped (not in main): $rel"
        fi
    done < "$include_file"
}

# Rewrite DATABASE_URL / ALEMBIC_DATABASE_URL / REDIS_URL in an env file
# in place, preserving creds + host. Idempotent. No-op if file missing.
apply_env_overrides() {
    local env_path="$1" db_name="$2" redis_db="$3"
    if [[ ! -f "$env_path" ]]; then
        log "skip env override (file missing): $env_path"
        return 0
    fi
    python3 - "$env_path" "$db_name" "$redis_db" <<'PY'
import re, sys
path, db_name, redis_db = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r") as f:
    lines = f.read().splitlines()

PG_KEY = re.compile(r'^\s*(DATABASE_URL|ALEMBIC_DATABASE_URL)\s*=')
REDIS_KEY = re.compile(r'^\s*REDIS_URL\s*=')

def swap_pg(line, new_db):
    return re.sub(
        r'^(\s*(?:DATABASE_URL|ALEMBIC_DATABASE_URL)\s*=\s*postgresql(?:\+asyncpg|\+psycopg|\+psycopg2)?://[^/\s]+/)[^\s]+',
        r'\g<1>' + new_db,
        line,
    )

def swap_redis(line, n):
    return re.sub(
        r'^(\s*REDIS_URL\s*=\s*redis://[^/\s]+)/\d+',
        r'\g<1>/' + n,
        line,
    )

out = []
for line in lines:
    s = line
    if PG_KEY.match(s):
        s = swap_pg(s, db_name)
    if REDIS_KEY.match(s):
        s = swap_redis(s, redis_db)
    out.append(s)

with open(path, "w") as f:
    f.write("\n".join(out) + "\n")
PY
    log "rewrote DB/Redis URLs in $env_path"
}
