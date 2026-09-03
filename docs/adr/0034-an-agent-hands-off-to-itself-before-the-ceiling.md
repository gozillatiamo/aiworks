# An agent hands off to itself before the ceiling

## Context

What ends a spawned agent is context, not turns: of 235 `dev-cycle` agents measured, 90 were killed
mid-work, 84 of them past 160,000 input tokens, and the ones that finished averaged 71,000
(`docs/agents/headroom.md`, `scripts/agent-context-ceiling.sh`). The kill takes the structured result
— the agent's last action — so the step scores as never run and is re-spawned against the same brief.
Well before the kill, the work itself degrades: past roughly 140k the model reasons over a window that
is mostly stale tool output.

Three answers were already in place, all prose: `CONTEXT_DISCIPLINE` and `RETURN_DISCIPLINE` on every
workflow brief, and `posttool-context-budget.sh` warning at 150k. Prose is weighed against the task in
hand and loses; the headroom page records the same lesson for `hcat` — months of documentation went
unused until a blocking hook replaced it.

Compaction is the remedy for the window, but its summary is written by a model already in the degraded
state, about work it did not plan to summarise. The `handoff` skill writes a better seed on purpose —
today only for the *next* agent, and only when someone asks.

## Decision

1. **A hook demands the handoff, at 140k, from the agent itself.** `context-handoff.sh`
   (PostToolUse `*`) measures the caller's own window and, on crossing `AIWORKS_CONTEXT_HANDOFF`,
   answers with `decision: block` and the demand: invoke `handoff` with `self <path>`, the path chosen
   by the hook, outside the workspace. At most three demands per cycle — an agent without a Write
   tool cannot comply.
2. **The hook hands the document back after the compaction.** SessionStart `compact` re-injects it
   in the main session; a window that shrinks between two tool calls — which nothing but a compaction
   does — re-injects it where SessionStart does not fire. Then the cycle re-arms, so a long task writes
   a fresh document every ~140k until it is done, and the ordinary handoff to the next agent is
   untouched.
3. **A subagent is measured on its own transcript.** The payload names the main transcript inside a
   subagent, so `lib-context-window.sh` resolves `subagents/agent-<id>.jsonl` (or the workflow layout)
   from `agent_id`, and the advisory budget hook now shares that resolver — before this it reported the
   parent's window for a child.
4. **In a workflow the document is keyed by the step, and the compaction point is moved.** Measured
   on one machine: 2,552 workflow agents, 13 ever compacted (142k–167k, the runtime's default point,
   inside the death band), 191 killed with no result. So `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=75` goes in
   `.claude/settings.json` (project scope; it applies to subagents and can only lower the default —
   ~150k on a 200k window, unreachable on a 1M one), putting demand, compaction and kill in that
   order; and every `agent()` in `dev-cycle.js`, `brd.js` and `prd.js` is wrapped to append
   `HANDOFF_KEY: <ticket>/<stepKey>` (or `<workflow>/<label>`), which the hook reads off the brief to
   file the document under `by-key/<key>.md`, and which the wrapper tells the agent to look for
   first. A replacement for the same step — after a partial, or after a kill that returned nothing —
   inherits its predecessor's state through a path the workflow can name without any agent id. The
   key is stable across invocations because `agent()` is memoised on the prompt. Nothing else in the
   workflows changes: the recorded message tells the agent to RETURN a partial naming the path, and
   `dev-cycle`'s existing partial continuation carries it.

## Consequences

- Every agent, in every harness that runs these hooks, writes its own continuation seed before the band
  where it would be killed, and resumes from it instead of from a compaction summary or an empty
  context. The first time the hook was wired it fired in the session wiring it, at 161k, and the
  document was written before the next edit.
- Proof lives in `guards-selftest.sh`, against the on-disk transcript layout, not a scratch script.
- The threshold is a number in a hook, re-derivable with `scripts/agent-context-ceiling.sh` when the
  runtime moves the wall.
- Not solved here: making the main session compact itself. That remains the person's `/compact` or
  the runtime's auto-compaction; the hook says so, once, when the document is recorded.
