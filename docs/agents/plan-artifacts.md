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
| Production case file | `<script-repo>/agent_logs/<CASE>-report.md` |
| dev-cycle run state | `<workspace-root>/agent_logs/<KEY>-dev-cycle-state/<repo>-<milestone>.json` |

The **case file** is the one artifact that is not per touched repo: a production case is
investigated across whatever repos the symptom crosses and often names none of them, so it lands in
the repo declared `kind: script` — the same repo that holds the reusable troubleshooting scripts its
runbook cites. `<CASE>` is the ticket key when one exists, else `<YYYY-MM-DD>-<short-slug>`. Written
by **oncall** via `/case-report`.

The **dev-cycle run state** is the second artifact that is not per touched repo — it is per *run*.
It is written by the run's own phase agents and read by the next invocation of the same ticket, so
it lives in a directory at the workspace root beside `<KEY>-DEV-CYCLE-SUMMARY.md`, never inside a
product repo. It is **one file per checkpoint** (`<repo>-<milestone>.json`, e.g.
`front-end-built.json`), not one shared file — a phase agent's tool grant is an explicit allowlist
of specific Bash patterns with no shell-append primitive in it, so a single append-only file was
unwritable by design; the Write tool every phase agent already has replaces a whole file, and a
distinct path per checkpoint means up to eight parallel build agents never touch the same file and
a re-run just overwrites its own. It is never committed: the workspace root's `.gitignore` covers
`agent_logs/`, same as every product repo. See
`docs/adr/0018`.

`<KEY>` is the ticket key (`APP-1944`). `<repo>` is the repo's directory name,
which is why the same ticket produces `APP-1944-your-api-plan.md` and
`APP-1944-your-migrations-plan.md`, not one file mentioning both.

**Who authors which.** A repo's `kind` decides the planning agent, and `dev-cycle`
already encodes it: a code repo is planned by **development-planner** and built by
**developer**; a `kind: test-suite` repo is planned by **qa-planner** and built by
**qa-runner** (no code review phase). So the automation plan in the table above is a
QA artifact, produced by qa-planner's own chain — `/plan-testcases` writes
`<KEY>-testcases.md` first, then `/plan-automate` turns it into the automation plan
against that repo's Page Object Model. A development-planner writing into a
test-suite repo is a routing mistake: the file may sit at the right path, but it will
be a developer-shaped slice list where qa-runner expects Page Objects, specs, and
selectors.

## Why per repo, not one file

This is a multi-repo workspace. `dev-cycle` runs plan → build → review **per
repo in dependency waves**, and each build agent is spawned with its own repo as
cwd and handed the plan path *inside that repo*. A single plan file covering
three repos, written into one of them, is therefore unreadable by the other two:
their build agents receive a path that does not exist where they are standing.

A plan is not a report about several repos. It is the input contract for one
repo's build agent.

The workflow derives these paths in `.claude/workflows/src/dev-cycle.js` (see
`planMeta`); it is the executable expression of this document, not a second
source of truth.

## Never committed

`agent_logs/` is git-ignored in every product repo, deliberately. A plan is a
working artifact of one run — it is superseded by the next planning pass, and
committing it puts churn (and, for the HTML render, ~100 KB of inlined engine)
into a service's history where no reviewer wants it.

Publish a plan **by reference**:

- as a shareable page — publish the HTML render as a Claude **Artifact** and
  hand over the URL
- onto the ticket — as the single `[plans · <KEY>]` durable record, which is **nothing but
  links**: one line per repo, rendered from the `artifact_published` run-state rows so it never
  has to be merged by hand ([ADR 0026](../adr/0026-a-ticket-is-a-record-not-a-transcript.md))

**A plan's BODY does not go on the ticket.** It is a working artifact superseded by the next
planning pass, which is the same reason `agent_logs/` is git-ignored — and a ticket run seven times
would otherwise carry seven of them with no way to tell which is current. If neither
`planning.to_html` nor `artifacts.enabled` produced a URL, **post nothing**: not an empty record,
not a filesystem path no teammate can open.

The one exception is the QA **BDD test plan**, which stays a body under
`[qa-plan · <repo>]` — it is the artifact the team reads to know what will be tested, not an
implementation plan. The QA **automation** plan is never published at all.

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

`pretool-plan-path-guard.sh` deliberately does **not** inspect the run-state file above: it only
examines basenames matching `*-plan.md`/`*-plan.html`, and a `.json` path exits at its early
extension check. `guards-selftest.sh` pins that with an explicit allow case
(`run-state json ignored`) rather than leaving it as an untested gap.

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
