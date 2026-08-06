# Worktree GC — reclaiming disk without serializing builds

`aiworks gc` reclaims disk from Superset worktrees. Run it with no arguments and it only
reports; it changes nothing until you pass a selector.

```bash
aiworks gc                            # what is orphaned / idle / past TTL, and how much
aiworks gc --all -n                   # preview a real run
aiworks gc --orphans                  # reap the UI-Delete leftovers
aiworks gc --artifacts --idle-days 7  # clear target//node_modules from week-idle worktrees
aiworks gc --dispatch --ttl-days 3    # reap stale slack/req-* dispatch worktrees
aiworks gc --enable-sccache           # one-time: parallel-safe rebuild cache for Rust
aiworks gc --install-schedule         # one-time: weekly --orphans --artifacts
```

## What leaks, and why

Superset's UI **Delete** removes the workspace row from its database and stops there. Left
behind, measured on one machine on 2026-08-06:

- the worktree **directory**, build artifacts and all,
- the `git worktree` **registration** plus `.git/worktrees/<name>` in the parent repo,
- the local **branch**.

The slack-dispatch service leaked the same way but faster: it creates a worktree per
`@`-mention and, before this existed, had no cleanup path at all — only a manual one-liner
in its RUNBOOK. One OFB project had **16.4 GiB** of orphaned worktrees plus a further
**24.8 GiB** of build artifacts inside live ones.

The cost is structural, not incidental. A Superset workspace of this repo is one worktree
of the meta-repo plus ~21 nested product clones, each of which builds its own `target/` and
installs its own `node_modules`. That is why a single workspace reached 17 GiB.

## The parallelism invariant

**Every worktree must stay able to build concurrently with every other worktree.** That
requirement is what makes this a reaper rather than a shared cache.

The obvious disk fix — point every worktree at one shared `CARGO_TARGET_DIR` — is
disqualified: cargo takes an **exclusive lock per target directory**, so a second
worktree's `cargo build` would block until the first finished. The same objection retires
any shared, mutable, lock-guarded build directory.

So the GC never creates shared state. It only deletes per-worktree state, and only from
worktrees it has proven are idle. Three invariants, enforced in `scripts/aiworks-gc.sh`:

| | Invariant |
|---|---|
| **I1** | Nothing is ever made shared. Each worktree keeps its own `target/` and `node_modules`. No new lock, no new contention point, no change to how a build runs. |
| **I2** | Nothing is touched unless provably idle — three **independent** liveness checks, any one of which vetoes: a recent mtime anywhere in the tree, a held `target/*/.cargo-lock`, or a running process whose cwd is inside. |
| **I3** | `--force` relaxes the **git** safety refusal (dirty / unpushed) and never the I2 checks. Deleting `target/` under a running build corrupts it; no flag buys that. |

`scripts/aiworks-gc-selftest.sh` proves I2 and I3 against real processes and real open file
descriptors — including that a busy orphan survives `--force`. Run it after touching the
GC. It caught one real defect during development: `lsof` reports the *physical* path, so
comparing against an unresolved path silently disabled the cwd check under a symlinked
ancestor (`/var` → `/private/var` on macOS). A safety check that never fires is worse than
no check, because it is trusted.

### The rebuild cost, answered without a lock

I1 means a reaped worktree rebuilds from scratch. `--enable-sccache` installs
[sccache](https://github.com/mozilla/sccache) and wires it as `rustc-wrapper`. sccache is a
concurrency-safe **server**, not a locked directory, so N worktrees compile at once and
still reuse each other's objects.

It does **not** shrink `target/` — nothing that preserves parallelism can. It makes reaping
cheap, which is the point: reap freely, rebuild fast.

For Node, the pnpm-based repos already share `~/Library/pnpm/store` via hardlinks, which is
both parallel-safe and nearly free on APFS. The npm-based repos (`backoffice`,
`seamless-api`, the Cypress suites) copy instead. Converting them would mean replacing
committed `package-lock.json` files and whatever CI depends on them — out of scope here,
and noted rather than done.

## Source of truth

Which workspaces still exist is read from `superset ws list --json`, **never** from
`~/.superset/*.sqlite`.

Reading the sqlite file directly under-reported live workspaces during development — it
missed 2 of 6, including a 17 GiB one that was still in active use. A GC that trusts it
deletes live work. Relatedly, the GC **aborts** when the CLI returns an empty list rather
than concluding that every worktree on disk is garbage.

## Classification

Each directory under `worktrees/<project>/` is classified against the live set:

| Result | Rule | Action |
|---|---|---|
| **alive** | exact match against a live `worktreePath` | eligible for `--artifacts` only |
| **container** | a live path starts with it (e.g. `slack/` holding `slack/req-*`) | descend into it |
| **orphan** | neither | reap candidate; do not descend — its children are its content |

Deriving "container" from the live set instead of hardcoding `slack/` is what keeps this
correct for any branch name containing a `/`.

## Git safety

Before removing anything, the GC checks the candidate **and every repo nested inside it**
for uncommitted or unpushed work. Checking only the top level would happily delete a
colleague's afternoon, since a workspace holds ~21 nested clones with independent state.

Removal then matches the shape found on disk: a real worktree (`.git` is a *file*) goes
through `git worktree remove` + `prune` so the parent's metadata is cleaned; a standalone
clone (`.git` is a *directory*) and a plain session directory are simply removed. The local
branch is deleted with `git branch -d`, never `-D` — an unmerged branch survives on purpose.

## Automatic sweeping

The slack-dispatch service runs the GC itself, on an interval, via
`aiworks_dispatch/sweeper.py`. It decides only *when*; all judgement stays in the script, so
a human running the command by hand and the daemon running it unattended cannot diverge.

| Env var | Default | Meaning |
|---|---|---|
| `GC_ENABLED` | `1` | run the sweeper at all |
| `GC_INTERVAL_SEC` | `21600` (6h) | how often |
| `GC_TTL_DAYS` | `0` | age threshold; `0` derives it from `THREAD_TTL_SEC`, rounded up |

The derived default matters: a Slack thread reuses its worktree for `THREAD_TTL_SEC`, so
deriving the threshold from it means a worktree a live thread could still be routed back to
is out of the sweeper's reach **by construction**, not by a comment asking someone to keep
two numbers in sync.

### The UI-Delete leftovers get their own job

The dispatcher sweeps **only its own** worktrees, and only while it is running. The
UI-Delete leftovers are the larger leak and have nothing to do with that service, so they
get a host-level weekly job rather than being bolted onto the dispatcher:

```bash
aiworks gc --install-schedule     # macOS launchd, Sundays 03:00
aiworks gc --schedule-status      # installed? loaded? when did it last run?
aiworks gc --uninstall-schedule
```

It runs `--orphans --artifacts` — deliberately **not** `--dispatch`, which would race the
dispatcher's own sweep over the same worktrees. On a non-Darwin host, `--install-schedule`
prints the equivalent crontab line instead of installing anything.

Two details the plist has to get right, both covered by the selftest:

- **The idle threshold defaults to 7 days, not the interactive 3.** Unattended, wiping a
  `target/` that someone returns to on Monday costs them a long rebuild, so a full week of
  silence is the bar. `--idle-days N` at install time overrides it.
- **`PATH` is set explicitly.** A launchd job inherits a minimal environment, and the GC
  needs `git`, `jq` and the `superset` CLI — without this the job runs and silently fails
  its own precondition check.

Output goes to `~/Library/Logs/aiworks-gc.log`. Verify a fresh install actually works with
`launchctl kickstart -k gui/$UID/dev.aiworks.gc` and read that log — a weekly job that has
never run is a weekly job nobody has tested.
