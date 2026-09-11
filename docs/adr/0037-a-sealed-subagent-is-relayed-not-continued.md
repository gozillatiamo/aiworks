# A sealed subagent is relayed, not continued

**Status:** Accepted. Amends [ADR-0034](0034-an-agent-hands-off-to-itself-before-the-ceiling.md), which
established the self-handoff and assumed the agent that wrote one could carry on in place.

## Context

ADR-0034 gave every agent a way to write a handoff document for itself at the context ceiling, and
assumed two things would then carry it across: auto-compaction would restore the window, and the
agent would continue where it left off. Reported from real runs, neither held often enough.

The hook could only *ask* a subagent to stop. Its own words — "If you are a SUBAGENT, RETURN now
with a partial result that names this handoff path" — are prose, weighed against an instruction to
finish the task, and finishing wins. So the document got written, the agent kept going, and it
walked into the kill band holding everything it had not committed. The measured cost of that ending
is already recorded in `dev-cycle.js`: attempts cut off at ~8.4M, ~12.5M and ~12.9M cache-read
tokens, each replaced by an agent starting from an empty context.

For the main session the assumption failed differently and more simply: the model cannot run
`/compact`. The document was written and then, unless a person happened to compact, never used.

## Decision

**A subagent that has written its self-handoff is sealed, and a sealed subagent is replaced.**

- **Seal.** Once the document exists the agent gets a bounded run of tool calls — the grace window,
  20 by default — to make durable the one thing the document cannot carry: an uncommitted tree.
  After that a PreToolUse hook denies every tool call. Starved of tools, the only move left is to
  return. A deny is a mechanism; the prose it replaces was not.
- **Relay.** The sealed agent returns a literal `HANDOFF_RELAY:<document>` token. Inside a workflow
  the `agent()` wrapper reads it off the value it awaited, ends the attempt and spawns a fresh
  agent for the same step, told to read the document first and continue from it.

  For a subagent spawned from a session it takes two events, and which one does what was measured
  rather than assumed (`scripts/hook-relay-probe.sh`). The Agent tool launches **asynchronously**:
  its `PostToolUse` fires at *launch*, where `tool_response` is launch metadata and `tool_input`
  still holds the brief — so the first wiring read nothing of the child's result, and reading the
  payload at large relayed a child whose **brief** merely mentioned the token. `SubagentStop` fires
  at completion and carries `last_assistant_message`, the child's own final text and none of the
  brief; that is the only field read. It records a pending relay and returns no decision — on a
  Stop event `block` means "do not stop" and would be fed to the sealed agent, which would spin
  against its own closed seal. The parent's next tool call is what gets told.
- **Bounded, with its own budget.** Five relays per step, counted separately from
  `build.max_continuation_passes` and `review.max_rounds` — those are sized for work that remains,
  and a relay is not a failed pass. When the budget is spent the last result goes back as the
  partial it is: the repo stays out of `ready` and the item is RECORDED (ADR-0027, ADR-0028). No
  new way for a run to stop.
- **The main session is exempt entirely.** No demand, no seal, no relay. It is the one agent nobody
  can respawn, and auto-compaction already restores its window. The `SessionStart(compact)`
  re-injection leg existed only for it and is removed — a subagent never receives that event.

## Consequences

A subagent now ends deliberately at the ceiling instead of being killed past it, and its
replacement starts from a document written on purpose rather than from nothing. In-place
compaction is still the better ending when the runtime gets there first, so it keeps winning: a
window that collapses during grace hands the document back and re-arms.

What this costs: a relayed step pays for a fresh agent to re-establish context from the document,
which is cheaper than re-reading the repo but not free. And a sealed agent that keeps trying tools
instead of returning pays a full window per denied call — nothing can force a return. That case
degrades to the old behaviour rather than below it: the runtime ends it, the document survives, and
the relay still picks it up.
