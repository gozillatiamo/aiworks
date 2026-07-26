# Plan artifacts — where a plan lives, and why it is never committed

**This file is the single source of truth for planning-artifact paths.** Other
files (agent definitions, workflows, hooks, skills) must *link here* rather than
restate the paths. A convention restated in two places drifts; this one already
did, and cost a real ticket (see [History](#history)).

## The paths

One plan file **per touched repo**, inside that repo:

| Artifact | Path |
|---|---|
| Plan, code repo | `<repo>/agent_logs/development-planner/<KEY>-<repo>-plan.md` |
| Plan, test-suite repo | `<repo>/agent_logs/<KEY>-automation-plan.md` |
| Interactive HTML render | `<repo>/agent_logs/<KEY>-<repo>-plan.html` |
| Test cases | `<repo>/agent_logs/<KEY>-testcases.md` |
| Logged bugs (bug round) | `<repo>/agent_logs/<KEY>-bugs.md` |
| Run report | `<repo>/agent_logs/<KEY>-report.md` |

`<KEY>` is the ticket key (`APP-1944`). `<repo>` is the repo's directory name,
which is why the same ticket produces `APP-1944-your-api-plan.md` and
`APP-1944-your-migrations-plan.md`, not one file mentioning both.

## Why per repo, not one file

This is a multi-repo workspace. `dev-cycle` runs plan → build → review **per
repo in dependency waves**, and each build agent is spawned with its own repo as
cwd and handed the plan path *inside that repo*. A single plan file covering
three repos, written into one of them, is therefore unreadable by the other two:
their build agents receive a path that does not exist where they are standing.

A plan is not a report about several repos. It is the input contract for one
repo's build agent.

The workflow derives these paths in `.claude/workflows/dev-cycle.js` (see
`planMeta`); it is the executable expression of this document, not a second
source of truth.

## Never committed

`agent_logs/` is git-ignored in every product repo, deliberately. A plan is a
working artifact of one run — it is superseded by the next planning pass, and
committing it puts churn (and, for the HTML render, ~100 KB of inlined engine)
into a service's history where no reviewer wants it.

Publish a plan **by reference**:

- onto the ticket — `scripts/tracker/add-ticket-comment.sh` (prose follows the
  workspace `language` policy; the `.md` file itself is always English)
- as a shareable page — publish the HTML render as a Claude **Artifact** and
  hand over the URL

`git add -f` to get one committed anyway is blocked by
`.claude/hooks/dev-wrapper/pretool-git-guard.sh`. If a path genuinely belongs in
a repo, change that repo's `.gitignore` in its own reviewed commit.

## Gates

- **`planning.to_html`** — when on, each plan is also rendered to the interactive
  HTML above (via the `write-interactive-docs` skill).
- **`artifacts.enabled`** — when on, that HTML is published to a shareable
  Artifact and the URL travels with the hand-over.

Both resolve local-first: `workspace.config.local.yaml`, else
`workspace.config.yaml` (see `docs/adr/0003`).

⚠️ **Publishing an Artifact requires the `Artifact` tool, which subagents do not
have.** A planning subagent must therefore return the HTML path *plus* an
explicit "needs publish" flag, and the orchestrator that spawned it does the
publish. A subagent that silently skips the step leaves a doc nobody can open —
and `pretool-notify-guard.sh` will block a chat message that cites the local
`.html` with no URL.

## Enforcement

| Guard | Blocks |
|---|---|
| `pretool-plan-path-guard.sh` | writing a plan artifact anywhere but the canonical path |
| `pretool-git-guard.sh` | `git add -f`, and committing a git-ignored staged path |
| `pretool-agent-brief-guard.sh` | a delegation brief that dictates a non-canonical plan path |
| `pretool-notify-guard.sh` | a chat message citing `agent_logs/` or a URL-less `.html` |

Regression suite: `.claude/hooks/dev-wrapper/guards-selftest.sh`.

## History

A three-repo ticket (2026-07-25) produced a single
`<primary-repo>/agent_logs/<KEY>-plan.md` that also carried the other two repos'
sections, force-added it past `.gitignore` into that repo's history along with a
121 KB HTML render, and opened an MR containing nothing else — so the other two
build agents had no plan to read, and a reviewer was asked to review artifacts.
Two sources of truth disagreed at the time — `dev-cycle.js` said
`agent_logs/development-planner/<KEY>-<repo>-plan.md`, the planner's own
definition said `agent_logs/George_development-planner/<KEY>-plan.md` — and the
orchestrator's brief invented a third path. This document replaces all three.
