#!/usr/bin/env bash
# WorktreeCreate hook (worktree-isolation).
#
# Allocates an isolated Postgres DB + Redis logical DB for the new worktree
# (or joins one already created by a sister repo on the same slug), copies
# files from .worktreeinclude, rewrites DATABASE_URL/REDIS_URL in the
# worktree's .env, and runs an optional bootstrap script.
#
# Configuration: <hooks-dir>/worktree-isolation.conf
#   REPO_NAME=...               required
#   WORKTREES_ROOT=...          required
#   REGISTRY_PATH=...           required (shared between sister repos)
#   DB_PREFIX=wt_               default
#   TEMPLATE_DB=                optional; if set, new DBs are created as
#                               TEMPLATE <TEMPLATE_DB>; else CREATE DATABASE only
#   BASE_BRANCH=                optional; default = current HEAD of main checkout
#   BOOTSTRAP_HOOK=             optional; path (relative to worktree) to a script
#                               that receives env: WORKTREE_PATH, DB_NAME, REDIS_DB
#   WORKTREE_INCLUDE_FILE=.worktreeinclude   default

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HOOK_DIR/../.." && pwd)"
# shellcheck source=lib/worktree-common.sh
source "$HOOK_DIR/lib/worktree-common.sh"
load_conf "$HOOK_DIR"

STDIN_JSON="$(cat)"
WORKTREE_NAME="$(printf '%s' "$STDIN_JSON" | json_get name)"
[[ -z "$WORKTREE_NAME" ]] && WORKTREE_NAME="$(printf '%s' "$STDIN_JSON" | json_get worktree_name)"

if [[ -z "$WORKTREE_NAME" ]]; then
    log "ERR: branch name missing from hook input"
    log "ERR: payload contents: $STDIN_JSON"
    exit 1
fi

SLUG="$(slugify_branch "$WORKTREE_NAME")"
if [[ -z "$SLUG" ]]; then
    log "ERR: could not derive slug from name='$WORKTREE_NAME'"
    exit 1
fi

WORKTREE_PATH="$WORKTREES_ROOT/$SLUG"
mkdir -p "$WORKTREES_ROOT"

# CONTRACT: echo worktree_path on the FIRST line of stdout so Claude Code
# can attach the session even if subsequent setup fails.
printf '%s\n' "$WORKTREE_PATH"

log "$REPO_NAME: name=$WORKTREE_NAME slug=$SLUG path=$WORKTREE_PATH"

if [[ -e "$WORKTREE_PATH" ]]; then
    log "WARN: $WORKTREE_PATH already exists; reusing"
elif git -C "$REPO_ROOT" show-ref --verify --quiet "refs/heads/$WORKTREE_NAME"; then
    log "branch '$WORKTREE_NAME' exists; checking it out at $WORKTREE_PATH"
    git -C "$REPO_ROOT" worktree add "$WORKTREE_PATH" "$WORKTREE_NAME" 2>&1 \
        | sed 's/^/[git] /' >&2
else
    EFFECTIVE_BASE="${BASE_BRANCH:-$(git -C "$REPO_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo main)}"
    log "branch '$WORKTREE_NAME' is new; creating from '$EFFECTIVE_BASE' at $WORKTREE_PATH"
    git -C "$REPO_ROOT" worktree add -b "$WORKTREE_NAME" "$WORKTREE_PATH" "$EFFECTIVE_BASE" 2>&1 \
        | sed 's/^/[git] /' >&2
fi

ACQUIRE_JSON="$(registry_acquire "$SLUG" "$REPO_NAME" "$WORKTREE_PATH")"
DB_NAME="$(printf '%s' "$ACQUIRE_JSON" | json_get db_name)"
REDIS_DB="$(printf '%s' "$ACQUIRE_JSON" | json_get redis_db)"
IS_NEW="$(printf '%s' "$ACQUIRE_JSON" | json_get is_new)"
log "registry: db_name=$DB_NAME redis_db=$REDIS_DB is_new=$IS_NEW"

if [[ "$IS_NEW" == "True" ]]; then
    if [[ -n "$TEMPLATE_DB" ]]; then
        log "creating database $DB_NAME via TEMPLATE $TEMPLATE_DB"
        CREATE_SQL="CREATE DATABASE \"$DB_NAME\" TEMPLATE \"$TEMPLATE_DB\";"
    else
        log "creating empty database $DB_NAME"
        CREATE_SQL="CREATE DATABASE \"$DB_NAME\";"
    fi
    if ! psql -d postgres -v ON_ERROR_STOP=1 -c "$CREATE_SQL" 2>&1 \
            | sed 's/^/[psql] /' >&2; then
        log "ERR: CREATE DATABASE failed."
        log "     If template '$TEMPLATE_DB' is in use, stop the process holding it and retry."
        log "     To roll back the registry entry:"
        log "     python3 $HOOK_DIR/lib/registry.py release --path '$WORKTREE_PATH'"
        exit 1
    fi
else
    log "DB $DB_NAME already created by sister repo; reusing"
fi

copy_worktree_includes "$REPO_ROOT" "$WORKTREE_PATH" "$REPO_ROOT/$WORKTREE_INCLUDE_FILE"
apply_env_overrides "$WORKTREE_PATH/.env" "$DB_NAME" "$REDIS_DB"

if [[ -n "$BOOTSTRAP_HOOK" && -x "$WORKTREE_PATH/$BOOTSTRAP_HOOK" ]]; then
    log "running bootstrap: $BOOTSTRAP_HOOK"
    (
        cd "$WORKTREE_PATH"
        WORKTREE_PATH="$WORKTREE_PATH" \
        DB_NAME="$DB_NAME" \
        REDIS_DB="$REDIS_DB" \
        "./$BOOTSTRAP_HOOK" 2>&1 | sed 's/^/[bootstrap] /' >&2
    ) || log "WARN: bootstrap hook exited non-zero; check the worktree manually"
elif [[ -n "$BOOTSTRAP_HOOK" ]]; then
    log "WARN: BOOTSTRAP_HOOK='$BOOTSTRAP_HOOK' set but file missing or not executable"
fi

log "worktree ready: $WORKTREE_PATH (db=$DB_NAME redis_db=$REDIS_DB)"
exit 0
