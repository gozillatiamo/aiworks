# A ticket description is a short page

**Status:** Accepted. Extends [ADR 0026](0026-a-ticket-is-a-record-not-a-transcript.md) (a ticket is a record, not a transcript) from the comments to the description itself.

## Context

Ticket descriptions written by the agents reached 13,000 characters. A reader opening such a
ticket had to scroll past architecture notes, a full reproduce runbook, CTO findings and
estimation prose before finding what was actually wanted. The `/prd` workflow made it worse by
slicing one request into several tickets, each with its own long body, so a single bug report
could land on the board as three pages nobody read.

Images the reporter pasted into the conversation were lost on the way: the workflow runtime has
no filesystem, and nothing told the Product Owner to attach them, so the evidence that made the
request concrete never reached the ticket.

## Decision

1. **A description is a short page, split automatically.** The tracker adapter caps every
   description it writes at `tracker.max_description_chars` (default 5000; a personal override
   in `workspace.config.local.yaml` is allowed). The author writes the core first — what is
   wanted or wrong, who is affected, how to see it in 5 steps or fewer, at most 6 acceptance
   checks, links — and everything else under a `## Details` heading. When the body exceeds the
   cap, the adapter keeps the core on the ticket and attaches the full body as ONE
   `<KEY>-details.md` file (the **Details attachment**), replacing the previous one on every
   write. A later write that fits under the cap leaves a stale attachment in place and logs a
   warning; it is never deleted, because deleting an attachment on a ticket someone may have
   linked is worse than a stale file. Trackers that cannot attach files (Notion, Linear) fall
   back to a `[details · <KEY>]` durable record carrying the overflow.
2. **One request produces one ticket.** In `/prd`, a ticket key or URL, a path under
   `agent_logs/`, or free text is a single request: the CPO returns one brief, any extra briefs
   are collapsed into the first, and the Product Owner writes exactly one ticket, however large
   it estimates. There is no points ceiling, no split and no "oversized" flag; a human runs
   `/decompose-ticket` later if a split is wanted. Only a BRD reference (`phase-N`,
   `docs/brd/<key>.md`, a doc-space URL, a one-word work-key) yields one ticket per feature.
   `args.single` overrides the classifier either way.
3. **User images are embedded in the description core.** The invoking agent collects the
   image paths the user pasted and passes them as `args.images`; the Product Owner attaches
   each one and embeds it under a short `## Evidence` heading in the core with a one-line
   caption. Images do not count toward the cap. A missing or unreadable path is a warning,
   never a failure.

## Consequences

- A ticket page reads in one screen. The long form is still there, one click away, and a
  reader who needs it knows where it is.
- Every writer of a description — `/clarifying-ticket`, `/update-ticket`, `/to-prd`,
  `/qa-subtasks`, the product-owner agent — follows the same template: core first, `## Details`
  last. The cap is enforced in the adapter, so a writer that forgets still produces a short
  page, only with a less deliberate cut.
- A single request never fans out into sibling tickets the reporter did not ask for. The cost
  is a larger ticket; that cost is visible, estimated, and the human's to split.
- Existing tickets are untouched until the next write to them.
- Not verified live at the time of writing: Jira's handling of a same-name attachment
  replace, the Notion/Linear record fallback, and the image embed. Each is covered by the
  selftests on the adapter and the workflow (`scripts/tracker/description-cap-selftest.sh`,
  `scripts/prd-workflow-selftest.sh`).
