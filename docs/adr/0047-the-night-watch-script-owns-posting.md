# The Night Watch script owns posting; the agent only returns a Verdict

**Status:** Accepted.

## Context

Night Watch is an unattended production watch. It must post on a schedule, keep one thread per day,
mention people on the right states, repeat an alert, and stay quiet when nothing changed. The `oncall`
agent it runs can post by its own grant (its tools include the notify, tracker and vcs adapters). If
the agent posts, each of those behaviours is a prompt instruction that drifts, and an agent that times
out or crashes posts nothing: silence on the one night that matters.

## Decision

The Tick agent returns a structured **Verdict** and nothing else. The Tick launch removes the notify,
tracker and vcs tools (`--disallowedTools`), so the agent cannot post even if told to. The script
validates the Verdict (the CLI's `--json-schema` is accepted but not enforced, so it extracts the
fenced JSON from the result and checks it itself), owns the memory, and posts only through
`scripts/notify/`. A missing, unparseable or invalid Verdict is itself reported as a FAILED Tick.

## Consequences

- Mentions, threading, the ALERT repeat, the BLIND and failure counters and baseline learning are code,
  covered by an offline selftest, not prompt text.
- A dead agent still produces a post: the gap line.
- Personal data is checked twice: the script rejects a Verdict that matches the PII pattern list, and
  `send.sh` redacts by provenance with its PII gate on.
- The notify adapter now prints `ts=` and `channel=` after a bot-token send, because threading needs
  the message `ts`. A webhook cannot thread, so Night Watch needs a bot token.
- The agent stays the `oncall` agent, unchanged. The script owns `state.json`; the agent can only
  propose `baselines` and `notes` through the Verdict.

Rejected: letting the agent post through `send.sh` (untestable, silent on failure), and letting the
agent write the state file (script-owned counters would become agent-mutable).
