# Context handoff — an agent hands off to itself before the ceiling

**Hook:** `.claude/hooks/dev-wrapper/context-handoff.sh` (PostToolUse `*` + SessionStart `compact`) ·
**Shared measurement:** `lib-context-window.sh` · **Skill:** `handoff` in `self <path>` mode ·
**Proof:** the `context-handoff.sh` section of `.claude/hooks/dev-wrapper/guards-selftest.sh` ·
**Decision record:** `docs/adr/0034`.

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
| `requested` | document present, not older than the demand | `additionalContext`: recorded; open nothing new; a subagent RETURNS a partial naming the path; the main session's person can `/compact` | `written` |
| `requested` | document absent | demand again, at most `AIWORKS_HANDOFF_NAGS` (3) times — an agent without a Write tool cannot comply, and a nag that never ends is ignored | `requested` |
| `requested` | window dropped ≥ 20k (compacted without a document) | nothing to hand back | `armed` |
| `written` | SessionStart `compact` fires | stdout = the document plus *continue from its next steps* | `resumed` |
| `written` | window dropped ≥ 20k on a tool call (a compaction the SessionStart leg did not see — a subagent) | `additionalContext` = the same | `resumed` |
| `resumed` | behaves as `armed` | the next crossing writes the next document over the last | |

The document and its state live **outside the workspace** — `AIWORKS_HANDOFF_DIR`, default
`$TMPDIR/aiworks-handoff/<sid>/<agent_id|main>.md` — which is the skill's own rule for handoffs.
Exit 0 always: a measuring hook never breaks the tool call it rides on.

## What the model cannot do, and what stands in for it

- **The model cannot run `/compact`.** In the main session the person does (the recorded message
  says so in a `systemMessage`), or auto-compaction does. `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` moves the
  automatic threshold and is documented to apply to subagents — but it is a **percent of the model's
  window**, and the window differs per model, so it is not set in `settings.json`; set it in
  `settings.local.json` for a known model (75 on a 200k window lands near 150k).
- **A subagent's compaction is a fresh agent.** Its continuation starts from an empty context, so
  the recorded message tells it to RETURN a partial that names the handoff path. `dev-cycle` already
  continues partials (`build.max_continuation_passes`); nothing in the workflows changed.
- **Advice was already there and did not work.** `CONTEXT_DISCIPLINE` rides every dev-cycle brief and
  `posttool-context-budget.sh` warns at 150k; both are prose the model can weigh against the task in
  hand. A `block` is the strongest thing a hook can say, and the first time this hook was wired it
  fired in the session that wrote it, at 161k, and the document was written before the next edit.

## Knobs

| variable | default | meaning |
|---|---|---|
| `AIWORKS_CONTEXT_HANDOFF` | `140000` | window at which the demand fires |
| `AIWORKS_HANDOFF_NAGS` | `3` | demands per cycle before the hook gives up |
| `AIWORKS_HANDOFF_DIR` | `$TMPDIR/aiworks-handoff` | where documents and state live |
| `AIWORKS_CONTEXT_WARN` / `_ALARM` | `150000` / `300000` | the advisory budget hook, unchanged |

`context-handoff.sh --check <n>` prints the transition a window of `n` tokens takes from `armed`.
