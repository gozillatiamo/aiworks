# The handoff document lives inside the workspace

**Status:** Accepted. Amends the location in
[ADR-0034](0034-an-agent-hands-off-to-itself-before-the-ceiling.md); the loop in
[ADR-0037](0037-a-sealed-subagent-is-relayed-not-continued.md) is unchanged.

## Context

ADR-0034 put the self-handoff document outside the workspace, in the OS temp directory, following
the `handoff` skill's rule for ordinary handoffs. That directory is outside a session's working
directories. Under auto permission mode the permission classifier judges each action against the
territory the session was given, and it refused every step of the loop that touched the temp path:

- a planner subagent's `Write` of its own handoff document, at the path the hook named;
- a developer subagent's later `Edit` of that document;
- the parent session's `Agent` call whose brief told the replacement to read that path.

So the document was demanded and could not be written, or was written and could not be relayed.
No allow rule covered the path, and none should: the path is per-user and per-machine, and the
brief is judged as text, so only a broad `Agent` grant would have let it through.

The temp default carried two more defects. A workflow brief spelled the path as `${TMPDIR:-/tmp}`,
which the agent expands in its own shell while the hook expands it in the hook process; where the
two differ, the replacement looks in the wrong place. With `TMPDIR` unset the default was a shared
`/tmp` directory that another local user can read or create first.

## Decision

The default directory is `<project>/agent_logs/handoff/`:

```
agent_logs/handoff/<session>/<agent>.md            the document
agent_logs/handoff/<session>/<agent>.state|.mark   the hook's state
agent_logs/handoff/<session>/pending-relay/<type>  a relay not yet delivered
agent_logs/handoff/<session>/relay-<type>.count    the relay budget
agent_logs/handoff/by-key/<key>.md                 a workflow step's document
```

`handoff_dir` in `lib-context-window.sh` is the one place that defines it, and both
`context-handoff.sh` and `posttool-agent-relay.sh` call it. `AIWORKS_HANDOFF_DIR` still overrides.
The temp directory remains only where no project directory is set.

Workflow briefs name `agent_logs/handoff/by-key/<key>.md` under the workspace root, with no shell
variable to expand. The keys, the sanitiser and the state format are unchanged.

A demand first prunes the hook's own files older than 7 days, and the directories that leaves
empty. The number is fixed; there is no knob.

No permission rule is added and no `Agent` permission is widened.

## Consequences

- Documents sit in the workspace tree. `agent_logs/` is git-ignored, so they are never committed,
  but an editor's indexer may read them. The skill's redaction rule matters as before.
- Cleanup is ours. A workflow paused for more than 7 days loses its step document and starts fresh.
- The prune matches only the hook's file shapes at the hook's depths, because an override may point
  at a directory that holds other things. An override should still be a directory of its own.
- A linked worktree has its own project directory, so its documents stay in its own `agent_logs/`.
- A workflow run already in flight keeps the brief it started with, so its replacement misses the
  step document once and starts fresh. The relay itself still works: the token carries the
  absolute path.
- Whether the classifier accepts the new path cannot be proven by a test in this repository. It is
  server-side; only a real session under auto permission mode shows it.

## Rejected

- **The harness scratchpad.** Its path is not in the hook payload, it does not survive a resume in
  a new session, and only one harness has it.
- **An allow rule on the temp directory.** It opens a temp path to auto-approval, needs a
  per-machine generated rule, and does not fix the refused `Agent` brief.
