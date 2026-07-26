# Personal config overrides apply at runtime only, never in the committed mirror

**Status:** Accepted

Some config is a personal preference, not a team default — most obviously `language`, where one
teammate may want `th` without switching it on for everyone. We support this with a git-ignored
**`workspace.config.local.yaml`** (the analogue of `.claude/settings.local.json`): it overrides
`workspace.config.yaml` for everything read **at runtime** — this chat, the Agent-tool agents,
and interactive skills.

The hard constraint comes from [0001](0001-headless-workflow-config-mirror.md): the workflow
`AIWORKS:CONFIG` mirror is a **committed, tracked** file. So the local override must never reach
it — `scripts/aiworks-config.sh` regenerates the mirror from the **shared** `workspace.config.yaml`
only, and merely warns when a local file is present. A personal `language` still reaches a
headless workflow run, because the spawned agents read `language` at runtime through their
per-agent pointer, not the baked `const LANGUAGE`.

The line we draw for *which* keys may be overridden this way is **output preference vs control
flow**. An output preference decides what a human ends up reading — `language`, and
`planning.to_html` (does a plan also get an interactive HTML render beside its markdown?). Control
flow decides what the pipeline *does* — `planning.auto_approve`, `vcs.auto_merge`, the status
lifecycle, `REPOS`. Only the first group is runtime-resolved: a shared run's approval gate or merge
policy must never change because of one teammate's git-ignored file. So `dev-cycle.js` resolves
`language` **and** `planning.to_html` local-first in one `resolve-runtime-config` sub-agent Read,
and treats the baked `const LANGUAGE` / `const PLAN_TO_HTML` as fallback defaults; it then states
the resolved `to_html` **explicitly** in each planner prompt (ON *and* OFF), so a planner that would
otherwise self-resolve from disk can never diverge from the run.

## Consequences

- Precedence, everywhere read at runtime: `workspace.config.local.yaml` → else
  `workspace.config.yaml`.
- The merge is **shallow per top-level key**: a local `planning:` block replaces the shared one
  whole, so a key omitted from it falls to its own default rather than inheriting the shared value.
  Every reader (agent files included) must resolve it that way, and `planning.auto_approve` is read
  from the shared file *only* — never from the local one — so a local `planning:` block that sets
  just `to_html` cannot silently loosen the approval gate.
- Your personal preference can **never** land in git via the generator — the committed mirror
  stays shared-only by construction.
- `.superset/setup.sh` symlinks `workspace.config.local.yaml` (and `.claude/settings.local.json`)
  into each per-ticket worktree, so personal prefs follow you into a superset run (opt out with
  `SUPERSET_LOCAL=skip`).

## Rejected alternatives

- **Bake the local override into the mirror.** Rejected: the mirror is tracked, so a personal
  preference would leak into git and reach the whole team on the next commit.
- **No local override for headless workflows.** Rejected: a personal `language: th` would then
  be silently ignored by `dev-cycle`/`prd`; routing it through the runtime per-agent pointer
  keeps the override honest without touching the committed mirror.
