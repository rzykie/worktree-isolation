#!/usr/bin/env bash
# WorktreeRemove hook (worktree-isolation).
#
# Releases the worktree's slot in the shared registry. Drops the per-worktree
# DB and FLUSHDBs the Redis slot only when the last repo using the slug exits
# (so a sister repo's worktree on the same slug, if any, also has to be
# removed first). Then opportunistically sweeps any other registry entries
# whose paths no longer exist on disk (e.g. removed via raw `git worktree
# remove` or `rm -rf`, bypassing this hook), and drops their orphaned DBs +
# Redis slots too. Failures are logged but never block git worktree removal.

set -euo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/worktree-common.sh
source "$HOOK_DIR/lib/worktree-common.sh"
load_conf "$HOOK_DIR"

STDIN_JSON="$(cat)"
WORKTREE_PATH="$(printf '%s' "$STDIN_JSON" | json_get worktree_path)"
[[ -z "$WORKTREE_PATH" ]] && WORKTREE_PATH="$(printf '%s' "$STDIN_JSON" | json_get path)"
if [[ -z "$WORKTREE_PATH" ]]; then
    NAME="$(printf '%s' "$STDIN_JSON" | json_get name)"
    [[ -z "$NAME" ]] && NAME="$(printf '%s' "$STDIN_JSON" | json_get worktree_name)"
    if [[ -n "$NAME" ]]; then
        SLUG="$(slugify_branch "$NAME")"
        WORKTREE_PATH="$WORKTREES_ROOT/$SLUG"
        log "derived path from name='$NAME': $WORKTREE_PATH"
    fi
fi
if [[ -z "$WORKTREE_PATH" ]]; then
    log "ERR: worktree_path missing from hook input; payload: $STDIN_JSON"
    exit 0
fi

RELEASE_JSON="$(registry_release "$WORKTREE_PATH")"
FOUND="$(printf '%s' "$RELEASE_JSON" | json_get found)"
IS_LAST="$(printf '%s' "$RELEASE_JSON" | json_get is_last)"
DB_NAME="$(printf '%s' "$RELEASE_JSON" | json_get db_name)"
REDIS_DB="$(printf '%s' "$RELEASE_JSON" | json_get redis_db)"
SLUG="$(printf '%s' "$RELEASE_JSON" | json_get slug)"

drop_slot() {
    local slug="$1" db_name="$2" redis_db="$3"
    log "flushing redis://localhost:6379/$redis_db (slug=$slug)"
    redis-cli -n "$redis_db" FLUSHDB 2>&1 | sed 's/^/[redis] /' >&2 \
        || log "WARN: redis FLUSHDB failed for db=$redis_db (may already be clean)"
    log "dropping database $db_name (slug=$slug)"
    psql -d postgres -v ON_ERROR_STOP=1 \
         -c "DROP DATABASE IF EXISTS \"$db_name\" WITH (FORCE);" 2>&1 \
         | sed 's/^/[psql] /' >&2 \
        || log "WARN: DROP DATABASE $db_name failed; you may need to drop manually"
}

if [[ "$FOUND" == "True" ]]; then
    log "released slot for slug=$SLUG (is_last=$IS_LAST db=$DB_NAME redis_db=$REDIS_DB)"
    if [[ "$IS_LAST" == "True" ]]; then
        drop_slot "$SLUG" "$DB_NAME" "$REDIS_DB"
    fi
else
    log "no registry entry for path=$WORKTREE_PATH"
fi

# Opportunistic cleanup: any other registry entries whose paths are gone get
# evicted and their Postgres DBs + Redis slots are reclaimed. This closes
# the loop when worktrees were removed without going through this hook.
SWEPT="$(registry_sweep || true)"
if [[ -n "$SWEPT" ]]; then
    while IFS=$'\t' read -r swept_slug swept_db swept_redis; do
        [[ -z "$swept_slug" ]] && continue
        log "auto-cleanup: evicted stale slug=$swept_slug (db=$swept_db redis_db=$swept_redis)"
        drop_slot "$swept_slug" "$swept_db" "$swept_redis"
    done <<< "$SWEPT"
fi

exit 0
