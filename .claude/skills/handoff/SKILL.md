---
name: handoff
description: >-
  Compact the current conversation into a handoff document another agent can pick up.
argument-hint: "What will the next session be used for?"
---

Write a handoff document summarising the current conversation so a fresh agent can continue the work. Save to the temporary directory of the user's OS - not the current workspace.

Include a "suggested skills" section in the document, which suggests skills that the agent should invoke.

Do not duplicate content already captured in other artifacts (PRDs, plans, ADRs, issues, commits, diffs). Reference them by path or URL instead.

Redact any sensitive information, such as API keys, passwords, or personally identifiable information.

If the user passed arguments, treat them as a description of what the next session will focus on and tailor the doc accordingly.

## `self <path>` — a handoff to yourself

When the argument is `self <path>` you are the next agent. A hook (`context-handoff.sh`) asked for this because your context window crossed the handoff threshold; a compaction follows and the same hook hands this document back to you afterwards. So:

- Write to exactly `<path>` (create its directory, overwrite an old file) — nowhere else, or it is never found.
- Optimise for continuing, not for explaining: the task and its acceptance criteria; what is DONE and where it lives (commits, branch, paths, PR/MR and ticket ids, review threads); what is IN FLIGHT and its exact state; the NEXT steps in order; decisions taken and why, so they are not re-litigated; the files and outputs you already read whose conclusions you carry, so they are not re-read; suggested skills.
- Then continue the step in flight. Do not stop, do not wait for the compaction, and do not hand off to another agent yet — that happens once the work is done, exactly as before.
