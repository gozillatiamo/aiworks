# Code minimalism (ponytail)

Every code-writing session and **every code-shaping agent** in this workspace builds through the
`ponytail:ponytail` plugin skill: YAGNI, reuse before re-implementation, stdlib and native platform
features before a new dependency, one line before fifty. This is the home of *how it reaches each
spawn path*, *who it deliberately skips*, and *the three places it stops*. The operative one-liner
lives in the root `CLAUDE.md`; the decision behind it is
[ADR 0015](../adr/0015-code-minimalism-is-a-plugin-not-a-prompt.md).

Ponytail is caveman's other half and the two never touch: caveman shrinks what an agent **says**,
ponytail shrinks what it **builds**. Caveman leaves code byte-for-byte exact; ponytail stays out of
the prose. See [`caveman.md`](caveman.md).

## The ladder

Before writing code, stop at the first rung that holds:

1. Does this need to exist at all? (YAGNI)
2. Already in this repo? Reuse it — re-implementing what is a few files over is the common slop.
3. Stdlib does it? Use it.
4. Native platform feature covers it? A DB constraint over app code, CSS over JS, `<input type="date">`
   over a picker component.
5. An already-installed dependency solves it? Use it. Never add one for what a few lines can do.
6. One line? One line.
7. Only then: the minimum that works.

The ladder runs **after** you understand the problem, never instead of it. The smallest change in the
wrong place is not lazy, it is a second bug. A bug fix is the root cause, not the symptom.

## How it reaches each spawn path

Four paths. Three of them are mechanical rather than remembered, and the fourth is the plugin's own.

| Spawn path | Mechanism |
|---|---|
| **Main session** | the plugin's `SessionStart` hook |
| **Any subagent** (named or def-less) | the plugin's `SubagentStart` hook, filtered by `PONYTAIL_SUBAGENT_MATCHER` |
| **Direct `Agent` spawn** | `pretool-agent-context.sh` adds the workspace carve-outs |
| **Workflow spawn** (`dev-cycle`) | `PONYTAIL_DIRECTIVE` baked into the plan, build and pr-fix prompts |

The split matters. The **ladder** is upstream text and we never re-state it: the plugin injects its own
ruleset verbatim, which is the artifact the published benchmark measured. What this workspace adds is
only the part ponytail cannot know — the three carve-outs below. Restating the ladder in our own words
would be roughly 1.5 KB of duplicate tokens in the exact place the matcher exists to make cheaper.

`dev-cycle` is the one exception, and it is deliberate: a workflow spawn is not a path the plugin's
`SubagentStart` hook has been measured on here, and the build stage is where an unapplied ladder costs
a whole ticket of over-built code. It carries a condensed ladder plus the carve-outs — ~250 tokens of
possible overlap bought as insurance against a silent miss.

## Who gets it, and why not everyone

`PONYTAIL_SUBAGENT_MATCHER` (set in `.claude/settings.json` `env`, converged into every repo) is the
cost lever. Unset, the plugin injects its ruleset into **every** subagent — including the ones that
never write a line of code.

Injected into: `developer` · `development-planner` · `qa-runner` · `code-reviewer` ·
`guardian-engineer` · `general-purpose` · `claude` · `Plan` · `caveman:cavecrew-builder`.

Skipped: `oncall`, `performance-engineer`, `qa-planner`, `product-owner`, `ceo`, `cpo`, `cto`,
`documentor`, both `ux-ui-*`, `graphic-designer`, `Explore`, `caveman:cavecrew-investigator`,
`caveman:cavecrew-reviewer`.

The planner is on the list on purpose, and it is the highest-leverage entry: a plan that over-builds
is executed faithfully by the developer, so the cheapest place to delete code is before it is written.
A `/prd` or `/brd` run spawns ten-plus agents that all fall on the skip side — for those runs the
matcher removes the injection entirely, at zero cost to accuracy, because none of them ship code.

The level is pinned to **`full`** via `PONYTAIL_DEFAULT_MODE`. `full` is the benchmarked arm.
`ultra` — "challenge the rest of the requirement in the same breath" — is not something to point at a
settlement or commission path, and pinning it in `env` means a stray
`~/.config/ponytail/config.json` on one machine cannot quietly change what the team's agents do
(ponytail resolves env before its config file).

## Where it stops

Three carve-outs. They are not caveats — they are the places where this workspace overrides ponytail,
and they are injected alongside it on every path above.

**1. Tests.** Ponytail settles for "ONE runnable check… no frameworks, no fixtures". Here, the repo's
own suite — Cypress, Newman, k6, `cargo test`, `scripts/dev.sh test` — is standing scope, permanently
"explicitly requested", and a gate **never fails open**: no receipt means recorded as *not run*
([`loadtest-gate.md`](loadtest-gate.md)). Ponytail may not shrink a suite, skip `/tdd`, or answer a
gate with a self-check.

**2. Scope.** Ponytail is told to "ship the lazy version and question it in the same response". A
ticket's acceptance criteria are the contract. The ladder shortens the **implementation**, never the
**requirement**. Work that genuinely belongs to someone else leaves through the existing
`deferred`/`partial` handoff with evidence ([ADR 0011](../adr/0011-deferred-scope-does-not-stop-a-run.md)),
never as a one-line aside in a reply.

**3. Adapters.** Rung 5 says an already-installed dependency wins. Read straight, that licenses
`gh`, `glab`, a raw Jira call — all of them banned here. The adapter under
`scripts/{vcs,tracker,notify,observability}/` **is** the installed dependency; rung 2 (reuse what this
repo already has) points at it, and rung 5 never overrides that.

Ponytail's own refusals still hold on top of these: validation at trust boundaries, error handling that
prevents data loss, security and accessibility are never simplified away. On a multi-tenant betting
platform that is the load-bearing half of the skill, not a footnote.

## Commands

`/ponytail [lite|full|ultra|off]` · `/ponytail-review` (over-engineering in the current diff) ·
`/ponytail-audit` (whole repo) · `/ponytail-debt` (harvest deferred `ponytail:` shortcuts) ·
`/ponytail-gain` · `/ponytail-help`. In Cursor the plugin form does not resolve — the vendored copy is
`/ponytail`, exactly as with caveman ([`cursor.md`](cursor.md)).

`/ponytail-review` is a human's on-demand call. It is deliberately **not** wired into the `dev-cycle`
review phase: the reviewers already read the diff, and buying a whole extra spawn to re-read it for one
dimension is precisely the over-build ponytail exists to refuse.

## Installing it

Declared in `.claude/settings.json` (`enabledPlugins` + `extraKnownMarketplaces`) at the root and,
through `aiworks-add.sh`, in every repo — so a repo-only session (`cd <repo> && claude`) is covered too.
⚠️ **Declaring is not installing.** The install is a machine-local step done once at **user** scope by
`ensure_claude_plugins` in `.superset/lib.sh` (setup step 3), which reads the same `enabledPlugins`
list. A repo carrying both keys with no install answers NOT-FOUND for `ponytail:ponytail` — measured
for caveman, and the same trap here.

`aiworks sync` **does not close it**: sync converges the settings into every repo and stops. The
skills still resolve, because `aiworks cursor` vendors and links them independently of the plugin —
so nothing looks broken while the **hooks** are absent, which is the entire point of the plugin.
`aiworks doctor` reports the gap by name under `agent-cfg`, and `--fix` runs
`ensure_claude_plugins` for you. For a teammate the whole sequence is:

```
git pull && aiworks sync && aiworks doctor --fix
```

…then restart Claude Code.

A plugin update needs a Claude Code **restart**: a running session keeps the old cache directory's
rules.
