#!/usr/bin/env python3
"""Atomic JSON registry for git-worktree DB/Redis slot allocation.

Each worktree gets an isolated Postgres DB and Redis logical DB (1-15).
Multiple repos that share the same registry path can co-allocate to the
same slug (e.g. a frontend + backend repo working on the same feature
branch will share one DB).

Configuration via environment:
    WORKTREE_ISOLATION_REGISTRY_PATH  path to the JSON registry file
                                      (default: ~/.worktree-isolation.json)
    WORKTREE_ISOLATION_DB_PREFIX      prefix for generated db names
                                      (default: "wt_")
    WORKTREE_ISOLATION_MAX_REDIS_DB   highest Redis logical DB to allocate
                                      (default: 15; Redis ships with 0-15)

Usage:
    registry.py acquire --slug <slug> --repo <name> --path <abs_path>
    registry.py release --path <abs_path>
    registry.py sweep
    registry.py inspect

Outputs JSON to stdout (or TSV for `sweep`). Lock contention is handled
via fcntl.flock on the registry file.
"""
import argparse
import datetime as _dt
import fcntl
import json
import os
import sys
from pathlib import Path

REGISTRY_PATH = Path(
    os.environ.get("WORKTREE_ISOLATION_REGISTRY_PATH")
    or (Path.home() / ".worktree-isolation.json")
)
DB_PREFIX = os.environ.get("WORKTREE_ISOLATION_DB_PREFIX", "wt_")
MAX_REDIS_DB = int(os.environ.get("WORKTREE_ISOLATION_MAX_REDIS_DB", "15"))


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _load(f) -> dict:
    raw = f.read().strip()
    if not raw:
        return {"slugs": {}}
    data = json.loads(raw)
    data.setdefault("slugs", {})
    return data


def _save(f, data: dict) -> None:
    f.seek(0)
    f.truncate()
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")


def _open_locked():
    REGISTRY_PATH.parent.mkdir(parents=True, exist_ok=True)
    REGISTRY_PATH.touch(exist_ok=True)
    f = REGISTRY_PATH.open("r+")
    fcntl.flock(f.fileno(), fcntl.LOCK_EX)
    return f


def _first_free_redis_db(data: dict) -> int:
    used = {entry["redis_db"] for entry in data["slugs"].values()}
    for n in range(1, MAX_REDIS_DB + 1):
        if n not in used:
            return n
    raise SystemExit(f"ERR: all {MAX_REDIS_DB} Redis DB slots are in use")


def _sweep_stale(data: dict) -> list[dict]:
    """Drop members whose path no longer exists on disk. Slugs left with zero
    live members are removed entirely. Returns one dict per evicted slug
    ({slug, db_name, redis_db}) so callers can clean up the corresponding
    Postgres DB and Redis slot.

    This keeps the registry honest when a worktree disappears without going
    through the WorktreeRemove hook (manual `git worktree remove`, `rm -rf`,
    branch deletion after PR merge, etc.). Called from cmd_acquire and
    cmd_sweep while the registry lock is held.
    """
    evicted = []
    for slug in list(data["slugs"].keys()):
        entry = data["slugs"][slug]
        live = [m for m in entry["members"] if Path(m["path"]).exists()]
        if not live:
            evicted.append({
                "slug": slug,
                "db_name": entry["db_name"],
                "redis_db": entry["redis_db"],
            })
            del data["slugs"][slug]
        elif len(live) != len(entry["members"]):
            entry["members"] = live
    return evicted


def cmd_acquire(args) -> None:
    f = _open_locked()
    try:
        data = _load(f)
        evicted = _sweep_stale(data)
        if evicted:
            slugs = ", ".join(e["slug"] for e in evicted)
            print(f"swept stale slugs: {slugs}", file=sys.stderr)
        if args.slug in data["slugs"]:
            entry = data["slugs"][args.slug]
            paths = {m["path"] for m in entry["members"]}
            if args.path not in paths:
                entry["members"].append({"repo": args.repo, "path": args.path})
            is_new = False
        else:
            entry = {
                "db_name": f"{DB_PREFIX}{args.slug}",
                "redis_db": _first_free_redis_db(data),
                "created_at": _now_iso(),
                "members": [{"repo": args.repo, "path": args.path}],
            }
            data["slugs"][args.slug] = entry
            is_new = True
        _save(f, data)
        result = {
            "slug": args.slug,
            "db_name": entry["db_name"],
            "redis_db": entry["redis_db"],
            "is_new": is_new,
        }
    finally:
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        f.close()
    print(json.dumps(result))


def cmd_release(args) -> None:
    empty_result = {"found": False, "is_last": False, "db_name": None, "redis_db": None, "slug": None}
    if not REGISTRY_PATH.exists():
        print(json.dumps(empty_result))
        return
    f = _open_locked()
    try:
        data = _load(f)
        target_slug = None
        for slug, entry in data["slugs"].items():
            if any(m["path"] == args.path for m in entry["members"]):
                target_slug = slug
                break
        if target_slug is None:
            print(json.dumps(empty_result))
            return
        entry = data["slugs"][target_slug]
        entry["members"] = [m for m in entry["members"] if m["path"] != args.path]
        result = {
            "found": True,
            "is_last": len(entry["members"]) == 0,
            "db_name": entry["db_name"],
            "redis_db": entry["redis_db"],
            "slug": target_slug,
        }
        if result["is_last"]:
            del data["slugs"][target_slug]
        _save(f, data)
    finally:
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        f.close()
    print(json.dumps(result))


def cmd_sweep(_args) -> None:
    """Evict registry entries whose member paths are gone from disk.

    Output: one TSV line per evicted slug — `<slug>\\t<db_name>\\t<redis_db>`.
    Empty stdout means nothing was stale. Bash-friendly so worktree-remove.sh
    can pipe into a `while read` loop and drop the corresponding DBs.
    """
    if not REGISTRY_PATH.exists():
        return
    f = _open_locked()
    try:
        data = _load(f)
        evicted = _sweep_stale(data)
        _save(f, data)
    finally:
        fcntl.flock(f.fileno(), fcntl.LOCK_UN)
        f.close()
    for e in evicted:
        print(f"{e['slug']}\t{e['db_name']}\t{e['redis_db']}")


def cmd_inspect(_args) -> None:
    if not REGISTRY_PATH.exists():
        print(json.dumps({"slugs": {}}, indent=2))
        return
    sys.stdout.write(REGISTRY_PATH.read_text())


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("acquire", help="claim a slot for a worktree")
    a.add_argument("--slug", required=True)
    a.add_argument("--repo", required=True, help="logical repo name (any string)")
    a.add_argument("--path", required=True)
    a.set_defaults(func=cmd_acquire)

    r = sub.add_parser("release", help="release a worktree's slot")
    r.add_argument("--path", required=True)
    r.set_defaults(func=cmd_release)

    s = sub.add_parser("sweep", help="evict slugs whose member paths no longer exist on disk")
    s.set_defaults(func=cmd_sweep)

    i = sub.add_parser("inspect", help="dump the registry")
    i.set_defaults(func=cmd_inspect)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
