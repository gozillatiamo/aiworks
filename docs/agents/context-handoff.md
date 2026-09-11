# Context handoff — a subagent hands off to itself, is sealed, and is replaced

**Hooks:** `.claude/hooks/dev-wrapper/context-handoff.sh` (PostToolUse `*` **and** PreToolUse `*`) ·
`posttool-agent-relay.sh` (SubagentStop `*` **and** PostToolUse `*`) ·
**Shared measurement:** `lib-context-window.sh` ·
**Skill:** `handoff` in `self <path>` mode ·
**Proof:** the `context-handoff.sh` section of `.claude/hooks/dev-wrapper/guards-selftest.sh`, and
the relay cases in `scripts/workflows/selftest.mjs` ·
**Decision records:** `docs/adr/0034` (why the document exists), `docs/adr/0037` (seal and relay).

⚠️ **The main session takes no part in this.** `agent_id` empty ⇒ the hook exits immediately: no
demand, no seal, no relay. The model cannot run `/compact`, so a demand there bought a document
that paid off only if a person happened to compact afterwards; auto-compaction already restores
the window on its own. Everything below is about SUBAGENTS.

## Why

Two things go wrong past roughly 140k tokens of context, both measured on this workspace's own runs
(`docs/agents/headroom.md`, `scripts/agent-context-ceiling.sh`): the runtime kills a spawned agent
somewhere past 160k with no last step to tidy up in, and well before that the work degrades — the
model reasons over a window that is mostly stale tool output it can no longer weigh. Compaction fixes
the window, but the built-in summary is written by a model already in that state, about work it did
not plan to summarise.

A handoff document written **on purpose**, by the agent, while it still knows what matters, is a
better seed. The `handoff` skill already writes one for the *next* agent. This hook makes every agent
write one for **itself** at a path the hook names, then hands it back after the compaction — and
repeats until the work is done, when the ordinary handoff to the next agent happens exactly as before.

## The loop

Keyed per (session, agent). A subagent is measured on **its own** transcript, never the parent's:
the payload's `transcript_path` names the main transcript even inside a subagent
(`scripts/hook-signal-probe.sh`), so the library resolves `<proj>/<sid>/subagents/agent-<id>.jsonl`
or the workflow layout under `subagents/workflows/<run>/`.

| phase | what the hook sees | what it does | next |
|---|---|---|---|
| `armed` | window ≥ `AIWORKS_CONTEXT_HANDOFF` (140k) | PostToolUse `decision: block` with the demand: *invoke `handoff` with `self <path>`* | `requested` |
| `requested` | document present, not older than the demand | `additionalContext`: recorded, **sealed in N tool calls** — make the tree durable, then return with `HANDOFF_RELAY:<doc>` | `grace` |
| `requested` | document absent | demand again, at most `AIWORKS_HANDOFF_NAGS` (3) times — an agent without a Write tool cannot comply, and a nag that never ends is ignored | `requested` |
| `requested` | window dropped ≥ 20k (compacted without a document) | nothing to hand back | `armed` |
| `grace` | a PreToolUse call, counter > 0 | allow, decrement, stderr countdown | `grace` |
| `grace` | a PreToolUse call, counter spent | **deny (exit 2)** with the seal text | `sealed` |
| `sealed` | any PreToolUse call | deny — except a write to the document itself, which is always allowed | `sealed` |
| `grace`/`sealed` | window dropped ≥ 20k on a tool call (the runtime compacted it in place first) | `additionalContext` = the document plus *continue from its next steps* — the better ending, so it still wins | `resumed` |
| `resumed` | behaves as `armed` | the next crossing writes the next document over the last | |

The grace window pays for the one thing the document cannot carry: an **uncommitted tree**. Commit
or park it and return. Findings, verdicts, ledger rows and ticket notes belong *in* the document —
the relay posts them — so 20 calls is slack, not a dependency.

The document and its state live **outside the workspace** — `AIWORKS_HANDOFF_DIR`, default
`$TMPDIR/aiworks-handoff/<sid>/<agent_id|main>.md` — which is the skill's own rule for handoffs.
Exit 0 always: a measuring hook never breaks the tool call it rides on.

## Workflows — where this actually pays

Measured on one machine's transcripts: **2,552** workflow agents, **13** ever compacted (all between
142k and 167k — the runtime's default threshold, which sits inside the death band), **191** killed
with no result. So for a workflow agent a "compaction" is a death and a re-spawn, and the re-spawn
started from an empty context. Two layers close that, one mechanical and one deterministic:

1. **Auto-compaction moved below the death band.** `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75` in
   `.claude/settings.json` (project scope, documented to apply to subagents; it can only lower the
   default). On a 200k window that is ~150k: the demand at 140k, the compaction at ~150k, the kill
   past 160k — in that order. The hook's collapse detection then hands the document back and the
   agent continues **in place**, no re-spawn — still the cheapest ending, and still the first one
   tried. The seal is what happens when the compaction does *not* arrive in time. On a 1M window
   75% is 750k, which these agents never reach, so the knob is harmless there.
2. **The document is keyed by the STEP, not the agent.** Every `agent()` in `dev-cycle.js`, `brd.js`
   and `prd.js` runs through a wrapper that appends `HANDOFF_KEY: <ticket>/<stepKey>` (dev-cycle) or
   `<workflow>/<label>` to the brief. The hook reads the key off the first user message of the
   agent's own transcript and files the document under `by-key/<key>.md` instead of by agent id.
   The wrapper also tells every agent to `test -f` that path **first** and, if it exists, to read it,
   verify it against the branch, and continue from it. So a replacement — spawned for the same step
   after a partial, or after the runtime killed its predecessor with no result at all — inherits the
   predecessor's state through a path the workflow could name without knowing any agent id.
3. **The wrapper relays.** `relayed()` sits between every `agent()` call and the engine's own: a
   result carrying `HANDOFF_RELAY:` ends that attempt and spawns the next one for the same step.
   This is what replaced the original design's hope that the agent would return on its own
   (`docs/adr/0037`); the step's phase never sees the sealed attempts, only the last result.

The key is deliberately **stable across invocations**: `agent()` is memoised on the prompt, so a
per-invocation token would re-run every producing step on resume. Per-agent state stays per agent,
so a replacement is asked for its *own* document and the predecessor's — older than the demand — is
never mistaken for it. Known ceiling (`ponytail:` in dev-cycle.js): two rounds of one gate share a key,
so round 2 may read round 1's document; it is told to verify before trusting, and the skill stamps
every self-handoff with a UTC timestamp for exactly that reason.

## The relay — who spawns the replacement

A sealed agent returns `HANDOFF_RELAY:<document>`. Two readers act on it, and neither is prose:

- **Inside a workflow**, the `agent()` wrapper (`relayed()` in `dev-cycle.js`, `brd.js`, `prd.js`)
  ends the attempt and calls `rawAgent` again for the same step with a continuation brief pointing
  at the document. Budget `HANDOFF_RELAYS` = 5, **per step**, and deliberately not charged to
  `build.max_continuation_passes` or `review.max_rounds` — a relay is not a failed pass. Spent, the
  last result goes back as the partial it is (repo out of `ready`, RECORDED — `docs/adr/0027`,
  `0028`), never as a new run ending.
- **Outside one**, `posttool-agent-relay.sh` rides **two** events. `SubagentStop` fires at the
  child's completion and carries `last_assistant_message` — its own final text — which is the only
  field read; it records a pending relay and answers nothing, because on a Stop event `block` means
  *do not stop* and would be fed to the sealed agent, which would spin against its own closed seal.
  The parent's next `PostToolUse` then delivers the directive once and consumes the marker. Budget
  5 per (session, `agent_type`) — ponytail: the coarsest honest key, so two unrelated children of
  one role share a budget; the error runs toward fewer relays, never more.

  ⚠️ **Not the Agent tool's own `PostToolUse`.** It launches asynchronously, so that event fires at
  *launch*: `tool_response` is launch metadata and `tool_input` still holds the brief. Wiring the
  relay there reads nothing of the result — and reading the payload at large relays a child whose
  BRIEF merely mentioned the token. Both were observed; `scripts/hook-relay-probe.sh` re-measures
  the payload shapes after a CLI update.

The continuation brief is a pure function of `(brief, document)` — no clock, no counter, no id — so
a resume replays it unchanged. `selftest.mjs` pins that by running the same workflow twice and
comparing prompt hashes.

## What the model cannot do, and what stands in for it

- **The model cannot run `/compact`.** Auto-compaction does, at the
  `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` point above — a **percent of the model's window**, so ~150k on a
  200k model and 750k on a 1M one; override it in `settings.local.json` for a machine whose models
  differ. When it gets there before the seal closes, the agent continues in place and no relay
  happens at all, which is the cheaper ending.
- **The model cannot be forced to return.** The seal denies its tools; it cannot make it stop
  trying them, and each denied call still bills a full window. A sealed agent that loops instead of
  returning degrades to the pre-`0037` ending — the runtime kills it, the document survives, the
  relay picks it up — rather than to something worse.
- **A subagent that is killed before it compacts is a fresh agent.** Its continuation starts from an
  empty context — unless it finds the by-key document, which is what the workflow wrappers make it
  look for first.
- **Advice was already there and did not work.** `CONTEXT_DISCIPLINE` rides every dev-cycle brief and
  `posttool-context-budget.sh` warns at 150k; both are prose the model can weigh against the task in
  hand. A `block` is the strongest thing a hook can say, and the first time this hook was wired it
  fired in the session that wrote it, at 161k, and the document was written before the next edit.

## Knobs

| variable | default | meaning |
|---|---|---|
| `AIWORKS_CONTEXT_HANDOFF` | `140000` | window at which the demand fires |
| `AIWORKS_HANDOFF_NAGS` | `3` | demands per cycle before the hook gives up |
| `AIWORKS_HANDOFF_GRACE` | `20` | tool calls between the document landing and the seal closing |
| `AIWORKS_HANDOFF_RELAYS` | `5` | re-spawns a parent will be pushed into, per (session, agent type) |
| `AIWORKS_HANDOFF_DIR` | `$TMPDIR/aiworks-handoff` | where documents and state live |
| `AIWORKS_CONTEXT_WARN` / `_ALARM` | `150000` / `300000` | the advisory budget hook, unchanged |
| `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` | `75` (settings.json) | runtime auto-compaction point, percent of the model window; applies to subagents |

`context-handoff.sh --check <n>` prints the transition a window of `n` tokens takes from `armed`.
