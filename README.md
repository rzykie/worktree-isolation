# worktree-isolation

Per-worktree Postgres + Redis isolation for parallel Claude Code agents.

`git worktree` gives you isolated *files*. It does not give you isolated
databases, Redis instances, or queues, so two parallel agents on the same
repo stomp each other's data. This package wires two hooks into Claude
Code's `WorktreeCreate` / `WorktreeRemove` lifecycle that allocate a
dedicated Postgres database and a Redis logical DB (1-15) per worktree,
rewrite the worktree's `.env` to point at them, and clean up on removal.

It also self-heals: when a worktree disappears without going through the
remove hook (manual `git worktree remove`, `rm -rf`, branch deletion
after PR merge), the next acquire or remove operation evicts the stale
registry entry and reclaims the slot.

## Quickstart

From inside a git repository:

```bash
curl -sSL https://raw.githubusercontent.com/rzykie/worktree-isolation/v0.1.0/install.sh \
  | bash -s -- \
      --repo myapp \
      --worktrees-root "$HOME/.claude/worktrees/myapp" \
      --registry "$HOME/.myapp-worktrees.json" \
      --db-prefix myapp_ \
      --template-db myapp_dev \
      --base-branch develop \
      --bootstrap .claude/hooks/bootstrap.sh
```

This drops four files into `.claude/hooks/`:

```
.claude/hooks/
├── worktree-create.sh
├── worktree-remove.sh
├── worktree-isolation.conf      (generated from your flags)
├── bootstrap.sh.example         (copy → bootstrap.sh, edit for your project)
└── lib/
    ├── worktree-common.sh
    └── registry.py
```

Then wire the hooks into Claude Code's settings (`.claude/settings.json`):

```json
{
  "hooks": {
    "WorktreeCreate": [{"hooks": [{"type": "command",
      "command": ".claude/hooks/worktree-create.sh"}]}],
    "WorktreeRemove": [{"hooks": [{"type": "command",
      "command": ".claude/hooks/worktree-remove.sh"}]}]
  }
}
```

Create a worktree from Claude Code and it will land in
`$WORKTREES_ROOT/<slug>/` with its own database `myapp_<slug>` and Redis
DB number assigned from the pool.

## Lifecycle

### `WorktreeCreate`

1. Slugify the branch name (strips `feat/`, `fix/`, etc.; lowercase;
   non-alphanumerics → `_`; truncated to 30 chars).
2. `git worktree add` from `BASE_BRANCH` (or current HEAD if unset).
3. Acquire a slot in the shared registry. If the slug is new, allocate
   the next free Redis DB (1-15) and reserve a unique Postgres DB name
   `${DB_PREFIX}${slug}`. If another repo already created this slug,
   join its slot instead of creating a new one.
4. `CREATE DATABASE` (with `TEMPLATE <TEMPLATE_DB>` if configured).
5. Copy untracked files listed in `.worktreeinclude` (e.g. `.env`)
   from the main checkout into the worktree.
6. Rewrite `DATABASE_URL`, `ALEMBIC_DATABASE_URL`, and `REDIS_URL` in
   the worktree's `.env` to point at the allocated DB and Redis slot.
7. Run `BOOTSTRAP_HOOK` if configured (e.g. `uv sync`, `npm install`,
   migrations) with `WORKTREE_PATH`, `DB_NAME`, `REDIS_DB` in the env.

### `WorktreeRemove`

1. Release the slot from the registry. If this was the last repo using
   the slug, drop the Postgres database and `FLUSHDB` the Redis slot.
2. Sweep: any other registry entries whose member paths no longer exist
   on disk are evicted, and their orphaned databases + Redis slots get
   cleaned up too. This is what makes the registry self-healing — it
   does not rely on this hook firing for every removal.

## Sister-repo coupling

Two repos that point at the same `REGISTRY_PATH` share slots. When their
slugified branch names match, the second repo's `WorktreeCreate` will
join the first one's slot instead of allocating new resources.

Example — a backend (`feat/checkout-flow`) and a frontend (`checkout-flow`)
both slugify to `checkout_flow` and share one Postgres DB + one Redis slot.

The slot is only released and the DB only dropped after **all** member
worktrees have been removed.

## Configuration reference

`.claude/hooks/worktree-isolation.conf` (sourced as bash):

| variable | required | default | meaning |
|---|---|---|---|
| `REPO_NAME` | yes | – | logical name stored alongside this repo's slugs in the registry |
| `WORKTREES_ROOT` | yes | – | where new worktrees land (one subdir per slug) |
| `REGISTRY_PATH` | yes | – | shared registry JSON file (sister repos point here too) |
| `DB_PREFIX` | yes | – | prefix for generated DB names; final = `${DB_PREFIX}${slug}` |
| `TEMPLATE_DB` | no | empty | if set, `CREATE DATABASE ... TEMPLATE <TEMPLATE_DB>` |
| `BASE_BRANCH` | no | current HEAD | branch to fork new worktrees from |
| `BOOTSTRAP_HOOK` | no | empty | path (relative to worktree) to project setup script |
| `WORKTREE_INCLUDE_FILE` | no | `.worktreeinclude` | listing of untracked files to copy into each worktree |

The bootstrap script receives `WORKTREE_PATH`, `DB_NAME`, `REDIS_DB` in the
environment, runs from `cd $WORKTREE_PATH`, and may exit non-zero — that
is logged as a warning but does not fail the worktree creation. See
`hooks/bootstrap.sh.example`.

## Manual ops

```bash
# Inspect the registry.
python3 .claude/hooks/lib/registry.py inspect

# Force a sweep (evict stale slugs, drop orphaned DBs and Redis slots).
# Usually unnecessary — the create and remove hooks both sweep automatically.
python3 .claude/hooks/lib/registry.py sweep

# Manually release a slot (does NOT drop the DB — that only happens via
# the remove hook or sweep).
python3 .claude/hooks/lib/registry.py release --path /path/to/worktree
```

## Requirements

- bash ≥ 4
- python3 ≥ 3.9
- `psql` reachable as the user running the hook (no password prompts —
  use `~/.pgpass` or a trust/peer auth setup for `localhost`)
- `redis-cli` reachable on `redis://localhost:6379`
- a Postgres role with `CREATE DATABASE` privileges

The hooks assume Postgres on `localhost` and Redis on `localhost:6379`.
Override by editing `worktree-common.sh` (the `apply_env_overrides` regex)
if you need something different.

## Versioning

The `install.sh` URL pins to a tag: `…/refs/tags/v0.1.0/install.sh`.
Re-running the installer with the same flags upgrades the lib in place,
keeping your `worktree-isolation.conf` and `bootstrap.sh` untouched.
Pass `--ref <tag-or-branch>` to install a different version.

## License

MIT — see `LICENSE`.
