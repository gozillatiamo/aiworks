# Code minimalism is a plugin, scoped by agent, not a prompt

**Status:** Accepted

Ponytail joins this workspace the way caveman did — as the **upstream plugin, declared and enabled,
with its ruleset scoped by `PONYTAIL_SUBAGENT_MATCHER` and three workspace carve-outs layered on top**.
It is not forked, not re-worded into our own directive, and not applied to every agent.

Anyone arriving with "why not just paste the ladder into `CLAUDE.md` and every agent file — it is only
a prompt?" should read this before doing it.

## What ponytail offers

A decision ladder an agent climbs before writing code (YAGNI → reuse → stdlib → native → installed
dependency → one line → minimum that works), plus an explicit list of things it may never simplify
away: validation at trust boundaries, error handling that prevents data loss, security, accessibility.

The published measurement is a headless agent editing a real FastAPI + React repo across twelve
feature tickets, scored on the `git diff` it leaves, against the same agent with no skill:

| vs no-skill baseline | LOC | tokens | cost | time | safe |
|---|--:|--:|--:|--:|--:|
| **ponytail** | **-54%** | **-22%** | **-20%** | **-27%** | **100%** |
| caveman (terse-prose control) | -20% | +7% | +3% | +2% | 100% |
| a bare "YAGNI + one-liners" prompt | -33% | -14% | -21% | -30% | **95%** |

Two rows matter here. The third is the honest comparison for "just write the rule ourselves": a
hand-rolled minimalism prompt gets most of the token win and **drops a safety guard doing it**. On a
multi-tenant betting platform, 95% is the number that disqualifies the shortcut. The second row is the
skill this workspace already runs — caveman compresses prose and *raises* token cost slightly on
agentic work, because it never touches what gets built. The two are complements, not alternatives, and
their author says so.

## Why the plugin rather than our own prose

Three reasons, in order of weight.

**The measured artifact is the text.** The benchmark scored ponytail's `SKILL.md`, not its idea. A
paraphrase in our own words is an unmeasured skill wearing a measured skill's numbers — and the
yagni-oneliner row is what a paraphrase actually scores.

**It already solves the subagent problem we solved by hand.** Caveman ships `SessionStart` and
`UserPromptSubmit` hooks only, which never reach a subagent — which is why this workspace carries
`CAVEMAN_DIRECTIVE` in `pretool-agent-context.sh` and in three workflows. Ponytail ships a
`SubagentStart` hook with a matcher env var. That is the machinery we would otherwise write, maintained
upstream.

**Upstream keeps it current.** A vendored paraphrase is a fork with no update path. `aiworks cursor`
already content-syncs vendored plugin skills byte-for-byte, so a plugin update propagates on the next
run and the committed copy stays a copy rather than a divergence.

## Why not on every agent

Unscoped, the plugin injects ~1.5 KB into **every** subagent spawn. A `/prd` or `/brd` run spawns ten
or more agents — CEO, CPO, CTO, product owner, both designers, documentor — none of which write a line
of code. Paying the ruleset there is pure waste with no accuracy to lose, which is exactly the trade
the skill itself is about.

`PONYTAIL_SUBAGENT_MATCHER` limits injection to the agents that shape code: `developer`,
`development-planner`, `qa-runner`, `code-reviewer`, `guardian-engineer`, `general-purpose`, `claude`,
`Plan`, `cavecrew-builder`. The planner is deliberately on that list and is the highest-leverage entry
— an over-built plan is executed faithfully, so the cheapest place to delete code is before it exists.

The matcher is a single string in `env`, converged into every repo by `aiworks-add.sh`, and
`pretool-agent-context.sh` reads that same string to decide who gets the carve-outs. One source of
truth: a spawn that gets no ladder must not get carve-outs for a ladder it never received.

## Why the level is pinned

`PONYTAIL_DEFAULT_MODE=full`, in `env`, everywhere.

`full` is the benchmarked arm. `ultra` is described by its author as "YAGNI extremist… challenge the
rest of the requirement in the same breath" — a persona nobody should point at a settlement, commission
or payout path. Pinning it in `env` also beats ponytail's own config file in its resolution order, so
one engineer's `~/.config/ponytail/config.json` cannot change what the team's agents do on their
machine and nowhere else.

## Why three carve-outs, and only three

Ponytail cannot know a workspace it was not written for. Three of its rules collide with rules here,
and in each case ours wins. They are stated once in
[`docs/agents/ponytail.md`](../agents/ponytail.md) and injected verbatim on every spawn path.

1. **Tests.** "ONE runnable check… no frameworks, no fixtures" is the correct default for a stranger's
   repo and wrong here: the repo's own suite is standing scope and a gate never fails open.
2. **Scope.** "Ship the lazy version and question it in the same response" is how a ticket requirement
   quietly disappears into a one-line aside. Deferral already has a channel with an evidence bar
   (ADR 0011); it does not need a second, cheaper one.
3. **Adapters.** Rung 5 — "an already-installed dependency solves it" — reads as a licence for `gh`,
   `glab` or a raw Jira call, all banned here. Rung 2 already points at the adapter; rung 5 must not
   override it.

Everything else ponytail says is adopted unchanged, including its own refusals.

## What was rejected

**Forking the skill to fold the carve-outs in.** It kills the update path and makes every future
upstream change a merge. The carve-outs are ours, so they travel in our own hook and workflow text,
where a reader can see they are ours.

**Wiring `/ponytail-review` into the `dev-cycle` review phase.** The reviewers already read the diff.
Buying a whole extra agent spawn to re-read it for one dimension is the over-build the skill exists to
refuse. It stays a human's on-demand call.

**Harvesting `ponytail:` debt comments on a schedule.** `/ponytail-debt` exists and works by hand. A
scheduled job for a ledger nobody has asked to read yet is speculative. YAGNI applies to the
integration too.
