# AI Workspace

The workspace for running one **agent team** through selected Agent harnesses across every product repo: one command
takes a ticket through the whole delivery cycle. This is the meta-repo — the product repos
clone into it but stay independent. This glossary is the workspace's ubiquitous language; each
term links to its canonical home where a fuller one exists.

## Language

**Term** definitions are one line each. When several words compete for one concept, the
canonical term is the heading and the rest are listed under `_Avoid_`.

## Orchestration

**Workflow**:
A deterministic, multi-agent orchestration script (`.claude/workflows/*.js`) run headless — it
fans out and sequences agents rather than reasoning turn-by-turn. Claude runs it natively; Cursor
and Codex run the same source through the shared Workflow runtime.

**Workflow runtime**:
The local adapter behind `aiworks workflow` that supplies a Workflow's orchestration primitives
through a selected Agent harness without copying or rewriting the canonical script.
_Avoid_: generated workflow, harness-specific workflow

**dev-cycle**:
The end-to-end delivery Workflow for a single ticket: plan → build → PR/MR → review → test gate
→ merge → distribute. → `.claude/workflows/dev-cycle.js`

**Invocation**:
One `Workflow` call. A run that is stopped and started again is a second invocation of the same
ticket, not a continuation of the first: it re-reads the script, replays whatever the engine's
cache still covers, and does the rest live. This is what a human means by "the third round".
*Avoid*: round, pass, attempt, retry.

**Review round**:
One turn of a single repo's review↔fix loop, counted per repo and capped. Several review rounds
happen inside one invocation, and a new invocation restarts a repo's rounds at one — the *counter*
restarts, never the mode: a gate that already did its first pass re-visits. *Avoid*: round
(unqualified), review cycle.

**First pass**:
A gate's one complete review of a change set — its whole sweep, every must-fix reported together.
There is exactly one per gate per repo, and it survives a re-run: what it found is the **closed
finding set**, and no later round or later invocation adds to it. *Avoid*: first review round
(conflates the pass with the counter), initial review.

**Re-visit**:
A gate confirming its own closed finding set is addressed, raising nothing new — the mode every
pass after the first one runs in. Not a second first pass. The one thing it may raise is a
regression the fix itself caused, which is handed straight back to the developer as a must-fix
inside its own attempt budget ([ADR 0027](docs/adr/0027-the-review-loop-does-not-halt-on-a-finding.md)).
*Avoid*: re-review (reads as "review again from scratch", the exact thing it is not).

**Review ledger**:
What a gate leaves behind so a later invocation knows what it already did: its tagged threads on
the PR/MR (the finding set) plus one `gate_<key>` run-state row per repo (that a first pass
happened, and whether it passed). → [ADR 0021](docs/adr/0021-a-passed-gate-is-recorded-not-re-derived.md),
[docs/agents/review-ledger.md](docs/agents/review-ledger.md)

**Frozen gate**:
A gate whose ledger row says it passed, or whose PR/MR carries an **approval tick**. It is not
re-reviewed and not re-visited, on any later round or invocation — deliberately, and deliberately
not invalidated by commits landing afterwards. The code reviewer's test-green receipt is the one
exempt part: findings stay closed, the suite re-runs. *Avoid*: cached gate, skipped gate.

**Approval tick**:
The forge's own approve marker on a PR/MR — GitLab MR approve, GitHub `APPROVE` review — posted
by the **orchestrator**, never by a gate, once the ticket-wide bar is met, with a verdict line
naming the suite that proved it. It says "cleared the bar" and nothing more: it is not a merge,
and with `auto_merge` off the PR/MR is left open for a human. Readable back as
`yes`/`no`/`unknown`, where `unknown` means the forge would not answer and counts as unapproved.
→ [ADR 0022](docs/adr/0022-the-run-ticks-its-own-approval-the-merge-stays-human.md).
*Avoid*: approval (unqualified — conflates the marker with a person's opinion), sign-off, LGTM.

**Test-report comment**:
The one durable comment a suite repo owns on a ticket, identified by a visible
`[test-report · <repo>]` marker line and **rewritten** by each later run rather than re-posted.
Its context is the repo, so a ticket run through four suite repos carries four of them. Each
carries a run stamp (run number, UTC, candidate shas) — the only thing that says which run the
body describes, once the body is overwritten. *Avoid*: test result comment (reads as one per
run, the thing it replaces), report thread.

**Thread resolution**:
The forge's own record that a finding is settled — GitLab "Resolve thread", GitHub "Resolve
conversation", written through `scripts/vcs/pr-resolve-thread.sh`. The fixer ticks what it fixed;
the owning gate makes the final call and may not pass while a thread it owns is unresolved.
*Avoid*: closing a comment, marking done.

**Wave**:
A dependency batch of repos, derived from each repo's declared upstreams. Waves order the merge,
not the build: every scoped repo builds concurrently. *Avoid*: stage, phase, batch.

**Repo status** (dev-cycle):
The verdict one repo's pipeline returns. `ready` is the only one that lets the change set proceed.
Since [ADR 0027](docs/adr/0027-the-review-loop-does-not-halt-on-a-finding.md) the review loop does
not stop on a finding, so **`review-unresolved` is the one review outcome that is not `ready`**: the
loop worked to `review.max_rounds` and hands back whatever it could not close as **blocking items**
(an unrunnable suite, a regression it could not undo, a stall, a cross-repo gap, a second open
PR/MR). The remaining statuses are the states with no loop to continue into: `build-unresolved` (the
build handed back no complete state, so there is no diff to review), `pr-unresolved` (no PR/MR
number, which every reviewer prompt needs) and `target-branch-halt` (the base is missing from the
remote, so `git diff base...head` cannot be computed at all).

**Repair loop**:
A bounded fix→verify→re-run cycle a gate runs itself instead of halting, when the cause is named
and owned inside the run. The verify step is role-specific: a **Scoped re-gate** for a cross-repo
escalation, a **Scoped quality check** for a same-repo QA-attributed fix.

**Cross-repo escalation**:
A review-fix pass proving, with observed evidence, that a finding's root fix must land in ANOTHER
repo of the same run (`upstream_fix_needed`), and the workflow routing a scoped fix pass there
instead of re-confirming the gap every round. One level deep, and bounded per (repo, finding) by
`review.max_escalation_attempts`; a target outside the run's scope, or a budget that runs out,
becomes a **blocking item** rather than a halt — the loop carries on with this repo's other
findings and the repo still cannot reach `ready`. *Avoid*: upstream sync (that is bringing
an EXISTING upstream fix forward — escalation is asking for one that does not exist yet).
→ [ADR-0020](docs/adr/0020-a-cross-repo-finding-escalates-instead-of-looping.md)

**Scoped re-gate**:
The code-review gate run over ONLY the commits a cross-repo escalation landed on an
already-reviewed branch — fix diff + suite green, never a fresh full review. Approval refreshes
that repo's `reviewed` checkpoint; anything less halts. Never fails open. Not a **Scoped quality
check**: different trigger (an escalation, not a QA red) and a different gate role.

**Scoped quality check**:
The guardian and/or performance gates — only the ones a repo declares — run over ONLY a
QA-attributed fix's diff inside the test-suite **repair loop**: does this fix reintroduce the
smell, debt or slow path the original review would have held? Never the code reviewer (already
cleared at Review), never a fresh audit, and never a pass on an un-run check. A rejection returns
the same red to the developer within a bounded per-red retry — never a silent pass-through to the
suite re-run. → [ADR 0024](docs/adr/0024-a-qa-attributed-fix-is-quality-checked-not-re-reviewed.md).
*Avoid*: re-review, gate review (both name the step this replaced).

**Gate-only verification**:
A suite is EXECUTED at its gate, against the reviewed candidate — never during the build that
authors it.

**Orchestrator session**:
The session that launched a workflow; it directs agents and never implements the work itself.

**Run budget**:
The token ceiling a run stops itself at, at a phase boundary, leaving a resumable checkpoint.
Counted in **OUTPUT tokens, per invocation** — measured at roughly 1/29th of a run's total tokens,
so the number is far smaller than it reads.
*Avoid*: token budget (it invites reading the value as a total-token cap).

**Run base**:
The branch each repo's work targets on THIS run — resolved once from the run's own arguments,
recorded on the `planned` run-state row, and authoritative on every resume. Not a default, not
something a downstream step may re-derive: the forge's own `target_branch` is asserted against it
after the PR/MR is opened and again before approval.
→ [ADR 0025](docs/adr/0025-the-runs-base-is-state-and-the-pr-is-asserted-against-it.md).
*Avoid*: base branch, default branch (both name the repo's habit, not this run's decision).

**Blocking item**:
A condition a loop worked on, could not close, and RECORDED. From the **review loop**: a regression
it could not undo, an unrunnable suite, a cross-repo gap, a second open PR/MR. From the **test-suite
gate**: a red whose fix its scoped check never cleared, a gate that could not be made to run, the
round budget, a standing load regression, reds already red on base, a red no repo in scope owns. The
loop keeps working every other finding; a repo cannot reach `ready` while one stands and a GREEN
suite cannot read as passed, so nothing is approved and nothing merges. Not a halt, and not a pass.
Both producers write into ONE list, so a run has one "Blocking — needs a person" section. It is also
**state**: a `blocked` run-state row carries it to the next invocation, where it demotes that repo's
ledgered-PASSED gates to re-visit and goes to the first fix pass as a must-fix — re-worked, never
re-asserted on sight, since a person may have fixed it between runs. A run that ends clean rewrites
the row empty, which is how one is cleared.
→ [ADR 0027](docs/adr/0027-the-review-loop-does-not-halt-on-a-finding.md),
[ADR 0028](docs/adr/0028-the-test-suite-gate-does-not-halt-on-a-red.md).
*Avoid*: halt, blocker (both suggest the loop stopped, which it does not).

**Suite gate status** (dev-cycle):
Three endings mean *the gate did not pass*, and reading only for one of them mis-reads the other two.
`test-suite-failed` — the suite is red. `test-suite-unverified` — no verifiable result exists (no
receipt, or no result comment for this run), which is never a pass however green the claim.
`test-suite-unresolved` — the suite is **GREEN** and the run is blocked anyway, by what the gate
recorded. → [ADR 0028](docs/adr/0028-the-test-suite-gate-does-not-halt-on-a-red.md)

**Red kind**:
The gate's own classification of each failure, which decides who is sent at it: `app` (a product
defect, to the repo the gate attributed it to), `automation` (the spec, Page Object or fixture is
wrong, to the suite repo), `prereq` (the suite never reached an assertion — harness, candidate stack,
or a missing migration/seed — to a code repo). All three are routed; before ADR 0028 only `app` was,
so the other two ticked a round away without any agent being asked to fix them. *Avoid*: flaky,
environmental (that is a verdict about a red, not a classification of it).

**Declared cannot**:
`cannot_fix[]` — the one sanctioned way an agent ends a single condition's attempts early, refused
unless it carries the evidence (a command + exit code, or the number) AND what was ruled out first.
It closes that condition, records it, and leaves the rest of the repo's findings — or the gate's
other reds — being worked. Read in both loops: `suite-unverified`, `regression`, `gate-red`,
`gate-unrunnable`, `loadtest-regression`.

**Durable record**:
One marker-keyed comment per (kind, scope) that a run REWRITES on every later invocation, rather
than appending another — `[dev-status · <repo>]`, `[regression · <repo>]`, `[qa-plan · <repo>]`,
`[test-report · <repo>]`, `[plans · <KEY>]`. A ticket carries the current state of the work, not a
transcript of the runs that produced it.
→ [ADR 0026](docs/adr/0026-a-ticket-is-a-record-not-a-transcript.md).
*Avoid*: status comment, progress update (both describe a transcript entry).

**Record ledger**:
The append-only `agent_logs/<KEY>-<kind>-history.tsv` a durable record renders its history from —
one `printf >>` per run. It exists because asking an agent to carry old history lines forward into a
rewritten body is lossy, measurably: it produced three test reports that contradicted their own runs.

**prd** / **brd**:
Workflows that produce a Product / Business Requirements Document from a brief.

**Reference ticket**:
A ticket the board has already finished (status *done*). It counts as coverage and as the
estimation calibration set, and agents read it freely — but no automated run rewrites,
re-parents, re-sprints or re-estimates one. Shipped work is a record, not a work item.

**Writable ticket**:
A ticket an automated run may write to: any covering ticket that is not a **reference ticket**,
plus a key a human named explicitly. The distinction is enforced in code, not by instruction.

**Deferred scope**:
Part of a ticket's scope that a repo's build cannot finish because it belongs to another owner — a
repo outside this workspace, or an access only a person holds. It is not unfinished work: what the
repo owns is green. A build that reports it hands back **deferred**, and the run carries on to
review and the test gate, naming the deferral on the PR/MR and the ticket rather than merging over
it in silence. Unfinished work of the repo's own is **partial**, and that still stops the repo. The
distinction is enforced in code, not by instruction.

**Skill**:
A packaged, named instruction set (`.claude/skills/`) invoked to do one kind of task the repo's
way — the reusable procedure a Workflow or agent steps through.

**Agent** / **the agent team**:
The roles that run the pipeline (CEO, CPO, CTO, developer, code-reviewer, QA, …); each is a
`.claude/agents/*.md` definition reused by *both* the Agent tool and the headless Workflows.
→ `.claude/agents/`

**Code-shaping agent**:
The subset of the agent team whose output becomes code — planner, developer, reviewer, guardian,
qa-runner, and the def-less builders. The only spawns **ponytail** is injected into; named by
`PONYTAIL_SUBAGENT_MATCHER`. → `docs/agents/ponytail.md`

**Ponytail** / **the ladder**:
The code-minimalism baseline (`ponytail:ponytail`; `/ponytail` in Cursor). Before writing code an
agent stops at the first rung that holds: YAGNI → reuse → stdlib → native platform feature →
installed dependency → one line → minimum that works. Governs *what gets built*, as **caveman**
governs *what gets said*. → `docs/agents/ponytail.md`

**Carve-out** (ponytail):
One of the three places this workspace overrides ponytail — a repo's own **test suite**, a ticket's
**acceptance criteria**, and the provider **adapters**. Injected beside the ladder on every spawn
path; the ladder shortens the implementation, never the requirement.

**mani**:
The cross-repo CLI (`sync` · `list projects` · `exec` · `run`) driven by the generated
`mani.d/<product>.yaml` files.

**Superset**:
The parallel run harness (`.superset/`) that gives each ticket its own git **worktree** so
several `dev-cycle` runs proceed at once.

**Worktree**:
An isolated git checkout Superset provisions per ticket; git-ignored root state (`.env*`, the
personal local config) is symlinked into it.

**`Human:` review**:
The convention where a human reviewer's PR/MR comments prefixed `Human:` are blocking,
top-priority directives the agents auto-route and resolve. → `docs/agents/human-review.md`

## Providers

**Agent harness**:
An execution environment through which the agent team works — `claude`, `cursor`, or `codex`.
_Avoid_: provider, agent provider, editor

**Harness set**:
The organization-wide selection of Agent harnesses that `setup` and `sync` keep supported across
the workspace and its repos.
_Avoid_: provider selection, personal harness preference

**Harness projection**:
A derived, harness-specific face of the canonical agent configuration. It uses symlinks where the
harness accepts the canonical format and generated adapters where it does not.
_Avoid_: copy, duplicate configuration, second source of truth

**Canonical agent configuration**:
The authored `.claude/` tree from which every Harness projection is derived. Codex discovers its
skills through `.agents/skills`, which is a directory symlink to `.claude/skills` rather than a
second owner.
_Avoid_: neutral agent tree, bidirectional skill ownership

**Harness parity**:
The guarantee that a selected Agent harness exposes the required agent-team capabilities without
silently dropping behavior or widening safety constraints. An unimplemented safety mapping fails
the projection check and blocks the feature from being considered complete.
_Avoid_: best-effort support, partial compatibility

**Adapter**:
A script wrapper (`scripts/vcs` · `scripts/tracker` · `scripts/notify`) agents call *instead of*
`gh`/`glab`/Notion/Jira/Slack directly, so the provider is swappable in one place.
_Avoid_: wrapper, integration

**Provider**:
The concrete tool behind an adapter — `github`|`gitlab`, `jira`|`notion`, `slack` — selected in
`workspace.config.yaml`.
_Avoid_: agent harness

**vcs** / **tracker** / **notify**:
The three adapter families: pull/merge requests, tickets, and chat notifications.

**voice**:
The adapter that makes the workspace speak and listen (`scripts/voice/`) — a spoken
acknowledgement per prompt, a closing line on every finished turn, a voice note on Slack,
hold-to-dictate. `th`-only and off by default, per person. Full doc: `docs/agents/voice.md`.

**Sunmi** (ซันมี่):
The assistant's spoken name, used by the summarizer and (deferred) as the wake word.

**closing line**:
The spoken result at the end of a turn. Every finished turn gets one — the ack says what is
starting, this says what came out of it. `voice.autoplay.milestone_every_turn: false` reverts to
tag-only.

**chattiness**:
`voice.autoplay.chattiness: terse | balanced | chatty | max` — how MUCH the ack and closing line say,
never whether they speak. `terse` is the length the feature shipped with; `balanced` adds a softener,
a short reaction word and the second fact; `chatty` adds the third fact and the follow-through; `max`
adds the fourth, narrates the STEPS in the order they happen (the only level allowed to — the others
forbid it) and tightens the heartbeat to 10 beats from 45 s, so a long run keeps saying where it is.
The budget is a ceiling, not a quota, and bad news keeps the plain register at every level.
`aiworks voice audition "…"` speaks all four.

**`VOICE:` tag**:
A `VOICE[group]: <one line>` line in a reply, which is how a turn writes its own closing line
(`green` · `red` · `ship` · `needs-you` · `incident`). Free and exact; without one the reply is
summarized instead, and the model gets the last word on the work.

**mute**:
`aiworks voice mute on` — one machine-global file that disables what THIS MACHINE says (and so its
spend). It does not reach the Slack voice note (`voice.notify_voice.enabled`, audio for the team) or
dictation. There is deliberately no automatic call detection: a browser meeting has no process to
find, so an auto-detect would cover some calls and silently miss others.

**triage server**:
One of the four read-only MCPs over a DEPLOYED environment — `pg_triage`, `redis_triage`,
`k8s_triage`, `monitoring_triage`. All four share one production gate (`triage.prod`, per machine)
and one teardown habit (`disconnect`). The first three read what **we** produce: our rows, our
keys, our cluster objects. The fourth reads what the **cloud provider** measures for us.

**tunnel sidecar**:
An opt-in companion variable (`PGPROD_<NAME>_TUNNEL` / `PGSTG_<NAME>_TUNNEL`) declared beside a
triage target's DSN. It tells the MCP server to open a `gcloud compute ssh -N -L` port-forward
lazily when that target is first queried, and to reap it on idle or disconnect. The sidecar is
additive — the DSN is unchanged — and the MCP owns the tunnel lifecycle so no agent ever needs a
`gcloud` Bash grant.
→ [ADR 0017](docs/adr/0017-triage-tunnels-are-declared-beside-the-dsn.md)

**reachability**:
Being able to open a TCP connection to a host — via a tunnel, a VPN, or direct routing. A
reachable target is not the same as an authorized one: the `triage.prod` gate (ADR 0005) is
permission; reachability is a prerequisite, not a bypass. A tunnel sidecar provides reachability;
it does not grant access.
→ [ADR 0005](docs/adr/0005-deployed-env-triage-and-the-prod-gate.md)

**plateau**:
The tell that an investigation has reached the infrastructure boundary: our own instrumentation
says the operation executed in microseconds while the caller waited hundreds of milliseconds, and
the surrounding spans never moved. The gap is invisible to the thing that was waiting — it is
scheduling, queueing or throttling — so no amount of further tracing explains it. A plateau is
what sends you to `monitoring-triage`.

**saturation metric**:
A metric whose type reads as a utilization or a ratio, and which must therefore be aligned with
the **maximum**, never the mean. A resource pinned at its ceiling for twenty minutes of a one-hour
window averages out to comfortable, which is the exact opposite of the finding. `monitoring_triage`
derives this from the metric descriptor rather than trusting a caller to remember it.

## Repos

**Product**:
A top-level grouping in `workspace.config.yaml` (`products[]`) that owns a set of repos.

**Repo**:
A clone declared under `products[].repos[]` — its own independent clone with its own git
history and `CLAUDE.md`, git-ignored inside the workspace.
_Avoid_: submodule (a submodule is a read-only pointer to a repo that is *also* a primary clone
at the root — never develop in the submodule checkout; see `docs/agents/submodules.md`)

**kind**:
A repo's role tag — `backend`, `web-app`, `package`, `migration`, `test-suite`, `document`.

**green**:
A repo's own definition of "tests pass" (the `green:` string), e.g. "unit + integration tests
passed". The bar a change must clear before it ships.

**guardian_focus**:
The security concerns the guardian reviews for that repo — `secrets`, `data-protection`,
`injection attacks`.

**distribute**:
A repo's build-distribution target after merge (`none` when nothing is distributed).

**lang**:
A repo's primary stack — `rust`, `next.js`, `cypress`, `postgres`, … — steering which tooling
the agents use.

## Language

**English spine, Thai prose**:
The `language: th` model — write prose in Thai while keeping an English spine.
→ `docs/agents/language.md`, [ADR-0002](docs/adr/0002-workspace-output-localization.md)

**Spine bucket**:
One of the three categories kept English under `th` — **Structure** (titles, headings, labels,
enum values), **Code** (all code & comments, identifiers, commits, branch names), **Terms**
(technical/transliterated words, domain jargon, proper nouns).

**Collaboration surface**:
A working/communication surface — this chat, tickets, Slack, PR/MR discussion, plans shown to
you — which is **Thai** under `th`.
_Avoid_: working surface

**Committed-beside-code**:
A file committed into a repo (`docs/`, `README`, ADRs, PRD/BRD files committed into a product
repo) — always **English**, even under `th`, since it lives beside the code.

## Config

**`workspace.config.yaml`**:
The shared source of truth — Harness set, providers, ticket prefix, status lifecycle, policies,
and the `products[].repos[]` registry. `aiworks sync` sets the workspace up from it.

**Personal override** / **`workspace.config.local.yaml`**:
A git-ignored, per-user file (analogue of `.claude/settings.local.json`) that overrides the
shared config at **runtime only**. → [ADR-0003](docs/adr/0003-personal-runtime-config-overrides.md)

**Config mirror** / **`AIWORKS:CONFIG` block**:
The generated `const` block `scripts/aiworks-config.sh` writes into `dev-cycle.js`/`prd.js` so
headless Workflows can read config; regenerated by `aiworks config`, never hand-edited.
→ [ADR-0001](docs/adr/0001-headless-workflow-config-mirror.md)

**Directive injection**:
Appending a `const` directive string (`LANGUAGE_DIRECTIVE`, `FIGMA_DIRECTIVE`) to an agent's
prompt — empty when the feature is off, so a default run is a no-op.

**Codegraph index** / **`-p` rule**:
The per-repo symbol/edge database under `<repo>/.codegraph/` (the marker is
`codegraph.db`, not the directory — `~/.codegraph/` is the CLI's own install dir).
Queried CLI-first: `query` `explore` `node` `callers` `callees` `impact` `affected`,
each of which **must** carry `-p $CLAUDE_PROJECT_DIR/<repo>` as an absolute path,
because a relative one resolves against whatever cwd this call reports — never
reliably where an earlier call's `cd` left it — and makes codegraph answer from
the wrong repo with exit 0. Enforced by
`pretool-codegraph-guard.sh`; kept current by `posttool-codegraph-sync.sh`.
Reads code only — never shell or prose, which is the **doc graph**'s half.
→ [ADR-0013](docs/adr/0013-codegraph-keeps-the-code-graphify-maps-the-prose.md)

**Doc graph**:
This repo's graph over prose — `docs/`, `docs/adr/`, and the markdown under
`.claude/` and `scripts/`. Concept and rationale nodes joined by cross-document
edges, carrying no source text: it answers *where a thing is decided*, never
*what a symbol contains*. The codegraph index's counterpart, for the shell and
markdown the code index does not read.
_Avoid_: knowledge graph, graphify index
→ [ADR-0013](docs/adr/0013-codegraph-keeps-the-code-graphify-maps-the-prose.md)

## Agent harnesses

**Cursor layer**:
The Cursor Harness projection: the `AGENTS.md` + `.cursor/` face of the same agent config, present
at the workspace root and in every repo. Generated by `aiworks cursor`, never hand-edited:
symlinks back to the `.claude/` files wherever the format already matches, plus the generated
files. Workflows use the shared Workflow runtime with Cursor `auto` routing.
→ [`docs/agents/cursor.md`](docs/agents/cursor.md) ·
[ADR-0004](docs/adr/0004-cursor-as-a-generated-mirror.md)

**Codex layer**:
The Codex Harness projection: `AGENTS.md`, `.agents/skills`, and generated `.codex/` agents,
configuration, hook wiring, rule index, MCP registry, and native status line. Generated by
`aiworks codex`, checked by `aiworks codex --check`, and never a second authored source.
→ [ADR-0023](docs/adr/0023-agent-harnesses-project-from-claude-canonical-source.md)

**Root slice** / **`.cursor/rules/repos/<repo>/`**:
One product repo's project instruction and rules, re-expressed so they work for a Cursor session
opened at the **workspace root** — every glob prefixed with the repo directory (`src/**` →
`<repo>/src/**`), so the rule fires on that repo's files and no other's. Generated by
`aiworks cursor` from `scripts/cursor/root-rule.awk`. Gitignored **by file**
(`.cursor/rules/repos/**/*.mdc`) — ignoring the *directory* makes Cursor prune the tree and lose
every rule in it.

**About card** / **`about.mdc`**:
The one rule per repo that carries a `description:` and **no** `globs:`, which is what makes it
Cursor's *Agent Requested* type — the agent pulls it in when a question is about that repo, with no
file of it open. The glob-scoped slices beside it only fire once a matching file is in context, so
the card is what answers "what is X's convention?" asked at the workspace root. Holds the repo's
`CLAUDE.md` inline plus an index of its rules, never their full text.

**Dual-key rule**:
A rule file whose frontmatter carries both `paths:` (what Claude Code scopes on) and `globs:`
(what Cursor scopes on), so one file serves both tools through a symlink. Each tool ignores the
key it does not know. `aiworks cursor` maintains the pair.

**Hook shim** / **`hook-shim.sh`**:
The translator that lets a Claude-shaped hook run under Cursor — event name, `Shell`↔`Bash`,
`Task`↔`Agent`, and the two context/deny output shapes. Copied into each repo (the one deliberate
copy in the Cursor layer) from `scripts/cursor/hook-shim.template.sh`, hash-checked by
`aiworks cursor --check`.
