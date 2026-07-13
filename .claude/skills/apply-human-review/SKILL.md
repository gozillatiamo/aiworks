---
name: apply-human-review
description: Apply a human reviewer's required changes to an open PR/MR — the human left directives marked `Human:` on the MR review threads and wants them fixed. Use when the user says "take my review", "process/address/apply my review comments", "handle my feedback on the MR", "fix what my review flagged", or "apply my Human: comments" — the user need NOT type the `Human:` prefix to trigger this. Also reachable by the dev-cycle or code-reviewer after a human reviews an open MR.
---

# Apply human review

The user reviewed an open PR/MR and left required changes as **`Human:`** directives on its
review threads. Scan them, route each to the right role, and drive each to
fixed-and-resolved. The convention — what a `Human:` directive is, its blocking authority,
the routing rubric, and the fix→reply→resolve mechanics — is **`docs/agents/human-review.md`**;
read it first and hold it as the base for every step below.

You **orchestrate**; the role sub-agents do the work. Spawn them with the Agent tool
(`development-planner`, `developer`, `qa-runner`), independent directives in parallel.

## Steps

1. **Resolve the target MR number(s).** From the arg: a bare number is the MR; an MR URL → its
   last path segment; a ticket key (e.g. `FM-12`) → `scripts/vcs/find-prs.sh <KEY>`, then take
   each URL's last path segment. No arg → ask which MR (or ticket). A ticket that spans repos has
   one MR per repo — do every one.
   *Done when:* you have every target MR number.

2. **Scan for live directives.** For each MR: `scripts/vcs/pr-threads.sh <number>`. Collect every
   thread that is `[unresolved]` **and** whose body's first line starts with `Human:`.
   *Done when:* you hold the list of `{mr, thread-id, file:line, body}` — or there are none, in
   which case report "no unresolved Human: directives on <mr>" and stop.

3. **Classify each directive** per the routing table in `docs/agents/human-review.md` → `developer`
   (code), `qa-runner` (test), or `development-planner` (scope/plan). Ambiguous → `developer`.
   *Done when:* every directive has exactly one target role.

4. **Dispatch.** Spawn one sub-agent per directive (independent directives in a single message so
   they run concurrently). Give each: the MR number, `thread=<id>`, `file:line`, the verbatim
   directive body, and the instruction to fix it, reply, and **resolve the thread** per
   `docs/agents/human-review.md`. A **scope/plan** directive goes to `development-planner` for a
   revised plan first, then to `developer` to implement and resolve.
   *Done when:* every directive has been dispatched and its sub-agent has reported back.

5. **Confirm — nothing dropped.** Re-run `scripts/vcs/pr-threads.sh <number>` per MR. Report each
   `Human:` thread as resolved (with the fixing SHA) or still-open (with why).
   *Done when:* every directive is resolved, or reported still-open with a reason — never silently
   dropped. Any still-open directive keeps the merge/Done gate closed.
