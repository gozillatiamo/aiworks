# `aiworks doctor` — what is missing, and the command that fixes it

Every repair in this workspace already has an owner. `aiworks sync` clones and onboards,
`aiworks setup` links the adapters, `aiworks harnesses sync` regenerates selected projections,
`aiworks update` moves the tooling forward. What was missing was the surface that tells you
**which of them you need to run** — before a half-finished workspace announces itself three
steps later as an adapter dying on a missing token, an agent grepping a repo that was never
cloned, or a guard that silently stopped firing because its hook lost its `+x` bit.

```
aiworks doctor [<repo>] [--repo a,b] [--only g,…] [--skip g,…]
               [--deep] [--json] [--strict] [--fix [-y]] [-n] [-v] [-h]

aiworks fix [<any doctor option>]     # = doctor --deep --fix -y, then re-checks the findings
```

A default run is **offline and about 4 seconds**. It is safe to run at any time, from any
worktree, in CI, or inside a hook.

## A doctor, not an installer

By default it reads and writes nothing — the same contract `scripts/k8s/setup.sh` and a bare
`aiworks gc` keep. Each finding is printed with the command that fixes it, and you decide.

`--fix` exists, but it **carries no repair logic of its own**: it runs the owner command for
each finding. That keeps exactly one implementation of every write in the workspace, so
nothing here can drift from `add` / `sync` / `setup` / `cursor`.

```
$ aiworks doctor --fix
  … the report …

  will run, in order:
    chmod +x your-tests/scripts/dev.sh                   fast
    aiworks cursor                                       fast
    aiworks sync your-app                                slow
  needs you (a secret or a judgement call):
    tracker (jira): unset in scripts/tracker/.env
      $EDITOR scripts/tracker/.env

  proceed? [y/N]
```

`-y` / `--yes` answers for you and is **required when stdin is not a TTY** — a `--fix` that
quietly proceeded down a pipe would clone repos inside a job that only asked for a report.
`--fix -n` prints the plan and stops.

A fix is only automatable when running it unattended is the whole answer. Anything that opens
an editor, anything whose fix is to go read something, and anything printed as `see: …` (an
install this script has no business performing on your machine — a node switch moves the
global bin dir; Docker Desktop is a GUI app; `scripts/k8s/bootstrap-sa.sh` grants IAM on a GCP
project and needs an owner to run it) is listed under **needs you** instead. A fix that does
not parse as a shell command lands there too, whatever it starts with: a finding whose fix is
prose is advice, and advice must never reach `eval`.

### `aiworks fix`, and why `--fix` re-checks itself

`aiworks fix` is the one-word form of the invocation anybody actually wants: `doctor --deep
--fix -y`. It takes doctor's own options, so `aiworks fix -n` still previews and
`aiworks fix --only triage` still narrows.

**"The command exited 0" is not "the finding is gone."** Measured on a real workspace: `--fix`
reported `3 fixed · 0 failed` and a re-run returned a byte-identical finding set. All three
owner commands exited 0 while closing nothing — one skipped its own stale MCP registration as
if a stranger had written it, one only ever reported failure under `--check`, and one
re-projected a config file nobody had edited. So `--fix` re-runs the same scope afterwards and
reports what actually cleared, and **the exit code comes from that second pass** — the first
pass describes a workspace that no longer exists.

```
  1 ran · 0 failed · 2 need you
  re-checked: 1 cleared · 2 still open
    still open  CLAUDE.md over the 100-line budget
    still open  no .graphifyignore
```

The referee is one check at the only place nothing can bypass, so a future finding whose owner
command silently no-ops is caught without anybody having to remember this failure mode. What
it cannot do is invent a fix: a finding a person owns stays open, by design, and is named.

Two rules follow for anyone adding a check:

- **Never register a command that cannot close the finding.** `./aiworks config` re-projects
  the mirror *from* `workspace.config.yaml`; it cannot decide what that file should say. Such a
  finding takes `$EDITOR <the file>` as its fix and names the mechanical follow-up in the
  detail text.
- **A detector must say what it could not close, and the fix must not be that detector.**
  `aiworks codex --check` exits 1 for drift a reconcile will close and **2** for drift it will
  not (a real path where the canonical link belongs, a generated file somebody edited, a rules
  file whose scope only its author can decide); doctor routes the 2 to **needs you** with the
  paths, rather than re-running a command that will refuse identically forever. The *reconcile*
  form still exits 0 — it did everything it was allowed to do — because the projector interface
  says so and because failing it made `aiworks sync` warn on every run of a workspace holding
  one hand-written `AGENTS.md`. Put the verdict in the check, never in the repair.

## How a check is scored

| | meaning |
|---|---|
| `✓ pass` | fine |
| `✗ fail` | work is blocked right now — a repo is missing, a token is unset, a hook lost `+x` |
| `! warn` | degraded or stale but usable — an index is old, a budget is over, a worktree is orphaned |
| `· skip` | deliberately off (`<feature>.enabled: false`) or `--deep`-only on a default run |

A switched-off feature is a decision, not a defect, and never scores against you.

**Exit 0** when nothing failed, **1** when something did, **2** on misuse (not a workspace, an
unknown flag, an undeclared repo name, `--fix` with no TTY and no `-y`). `--strict` promotes
every warning to a failure — use it in CI when you want drift to break the build.

## The groups

Groups 1–8 run offline by default. 9–12 need `--deep`.

| # | group | what it answers |
|---|---|---|
| 1 | `workspace` | `mani.yaml` present · the config parses and declares repos · no comments in `workspace.config[.local].yaml` · no typo'd feature switch · root `CLAUDE.md` within its 100-line budget |
| 2 | `repos` | every declared repo is cloned with a valid HEAD · `mani.d` and `products[]` still agree · each clone is git-ignored |
| 3 | `adapters` | per provider: the `.env` exists and every **required** var is set · the provider CLI is installed · writer scripts are executable · the `.git/info/exclude` trap · `notify` / `observability` skipped when their `enabled` flag is false |
| 4 | `per-repo` | `scripts/dev.sh` present and executable · `CLAUDE.md` within 100 lines · adapter symlinks (`tracker` + `vcs`) · `.codegraph/` · `skills-lock.json` · no rules file scoped with `globs:` and no `paths:` · **the feature base the workflow mirror will use, against the remote's own default** |
| 5 | `agent-cfg` | every canonical hook exists and is executable · `.claude/skills` installed · selected Cursor/Codex projections present and, under `--deep`, drift-free · declared plugin components installed or projected |
| 6 | `tooling` | the prerequisite binaries are on PATH, each missing one named with the installer that actually owns it |
| 7 | `voice` | delegates `aiworks voice status` — skipped unless `voice.enabled` |
| 8 | `triage` | the three read-only triage MCPs are registered (offline) · `--deep` · the Kubernetes triage identity reads and cannot write — skipped unless `triage.enabled` |
| 9 | `mcp` | `--deep` · the shared MCP compose stack is up |
| 10 | `services` | `--deep` · every host port published by `.superset/mcp-compose.yml` answers |
| 11 | `credentials` | `--deep` · each adapter's own reader authenticates against the live API |
| 12 | `disk` | `--deep` · delegates `aiworks gc` and reads its orphan **count** |

Narrow with `--only` / `--skip`, or pass a repo name (`aiworks doctor your-app`) to look at
one repo — the groups that are not repo-scoped then report as skipped.

### The base check, and why it grades in two tiers

The base a ticket's branch is cut from lives as a constant in the generated workflow mirror, and
nothing validated it. Measured on a real ticket: two repos were projected onto a base 99 and 157
commits behind their actual trunk — one of them a 16-file scaffold last touched a year earlier — so
a ticket's branch was cut off a dead branch, missing shared code the specs import, at the cost of a
whole round per repo. Group 4 now compares what the mirror will use against
`git symbolic-ref refs/remotes/origin/HEAD` in the clone:

- **absent from the remote → FAIL.** Not a style question: the open-PR step hard-stops on a base
  that is not there, so no ticket can finish in that repo until it is corrected.
- **present, but not the remote's default → WARN.** Sometimes entirely legitimate — a repo really
  can run its own branch policy. The warning says how to declare that deliberately (`feature_base:`
  on the repo's `products[].repos[]` entry) rather than inheriting a workspace default that does not
  fit it. See
  [ADR 0025](../adr/0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md).

The full detail line is ellipsised in the text view; `--json` carries it whole.

### What is deliberately *not* checked, and why

A green tick that means nothing is worse than an honest gap, so three things are left unproven
on purpose:

- **Harness projection drift** and **version currency** are `--deep`, not because they need the network but
  because they are slow: `aiworks cursor --check` walks every repo (~8s) and `brew outdated`
  costs ~13s. Both are four times the whole command's budget. The default run answers the cheap
  half of each — is the selected projection even *there*, is the binary even on PATH.
- **Version currency covers the brew-owned half only.** `aiworks update -n` cannot answer it:
  dry-run prints the commands it *would* run and closes with "0 version(s) moved" whether or not
  anything is behind. rustup, gcloud, claude and codegraph carry their own updaters and are not
  checked.
- **notify has no credential probe.** `send.sh --dry-run` previews without contacting Slack, so a
  green there would prove the flags parse and nothing about the token; the call that *would*
  prove it posts a message, and a health check must not put noise in a team channel. Reaching
  `auth.test` directly is out — adapters are the only sanctioned door to Slack. Group 3 still
  confirms the token is *set*.

## In a linked worktree

Superset and slack-dispatch worktrees are a first-class place to run this. Doctor detects one
(`git rev-parse --git-dir` ≠ `--git-common-dir`), prints the branch and the main clone, and
keeps the **severity the same** — a stub `.env` blocks a workflow just as hard there. What
changes is the instruction: the fix is a copy from the main clone, not "go make a token".

```
  ⚡ worktree: slack/req-a1b2c3d4e5
     main clone: /Users/you/projects/ai-workspace

  adapters     ✗ tracker (jira): scripts/tracker/.env is a stub
                 unset: JIRA_API_TOKEN
                 → cp /Users/you/projects/ai-workspace/scripts/tracker/.env scripts/tracker/.env
```

## The `.env` rule

**Doctor never reads a secret.** The only thing it does to an adapter's `.env` is
`grep -q '^VAR=.\+'` — quiet, so the exit code is the entire answer and not one byte of the
file reaches stdout, stderr, `--json`, or this process's environment. That is the idiom
`CLAUDE.md` prescribes and the one `pretool-env-guard.sh` allows by name:

```
# grep prints matching lines (⇒ leaks values) UNLESS it is quiet:
# -q/--quiet/--silent only sets the exit code, printing nothing —
# that is the sanctioned "is this var set?" idiom, so allow it.
```

Two rules follow, and both are asserted by the selftest: the script never enables `set -x`
anywhere (an xtrace line would print the grep's arguments), and no `--json` field can carry a
value. A file-exists check was considered and rejected — it cannot see a worktree stub, where
the file is present and non-empty but the token is blank, which is exactly the shape that has
broken a dev-cycle run before.

### The required-var table

`provider_required_vars()` mirrors each provider's own `*_require_config`, the single authority
on what that provider cannot start without:

| provider | required |
|---|---|
| `tracker/jira` | `JIRA_BASE_URL` · `JIRA_EMAIL` · `JIRA_API_TOKEN` |
| `tracker/notion` | `NOTION_TOKEN` · `NOTION_DB_ID` |
| `tracker/linear` | `LINEAR_API_KEY` |
| `notify/slack` | `SLACK_BOT_TOKEN` **or** `SLACK_WEBHOOK_URL` |
| `observability/signoz` | `SIGNOZ_BASE_URL` · `SIGNOZ_API_KEY` |
| `vcs/gitlab` · `vcs/github` | no `.env` contract — the CLI (`glab` / `gh`) must be installed |

It is a copy of a contract that lives elsewhere, so the selftest fails the moment a provider
directory exists that the table does not know about. A new provider cannot be added without
doctor learning about it.

## Selftest

```
./scripts/aiworks-doctor-selftest.sh      # writes nothing outside its own fixtures
```

Fixtures are built from scratch in a temp dir, so the suite runs in a clone with no live
config. Three families of case matter most:

- **The leak test** plants a recognisable fake secret in a fixture `.env` and greps every byte
  doctor emits — both streams, in text, `-v`, `--json`, `--strict` and `--fix -n`, and again
  against a stubbed `.env` where the failure path has to *name* the variable it could not find.
  A single `grep -n` added while debugging fails it.
- **The false-positive pins.** The first draft demanded four adapter symlinks per repo when
  `aiworks add` links two, flagged 44 correctly-configured rules files, and reported orphaned
  worktrees on a workspace whose `gc` output said `orphaned: 0`. All three looked entirely
  convincing in real output. Every false positive costs somebody a real investigation, so the
  shapes that must stay quiet are pinned as cases.
- **The referee.** One case runs `--fix` for real — the only one that does, and its fixture is
  built so the entire plan is a single `chmod +x` inside the temp dir, with every other finding
  routed to *needs you*. It asserts that a closed finding is counted as cleared, that a
  surviving one is named, and that the exit code follows the second pass rather than the first.
  Without it, "reports fixed, finding persists" is a regression nothing would catch.
