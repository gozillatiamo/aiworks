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

## Consequences

- Precedence, everywhere read at runtime: `workspace.config.local.yaml` → else
  `workspace.config.yaml`.
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
