---
name: ticket-kickoff
description: Resolve a <PREFIX>-<n> ticket from the issue tracker, classify it (Bug vs Feature/Polish), move it to the "in progress" status, and create + check out the correct development branch. Use at the very start of working any ticket. Pass the ticket number as an arg (e.g. FM-12 / APP-123).
argument-hint: [ticket-number]
allowed-tools:
  - Bash(git *)
  - Bash(scripts/tracker/*)
---

# Ticket kickoff

Bootstraps a ticket for development: fetch → classify → in-progress → branch. The issue
tracker is reached **only** through the adapter in `scripts/tracker/` — see
`docs/agents/issue-tracker.md` for this org's provider, ticket-id format, and status
names, and `workspace.config.yaml` for the branch model. Never call a tracker API/MCP
directly.

## Input

A ticket reference (e.g. `FM-12` / `APP-123`, or a bare number). The id prefix is set in
`workspace.config.yaml` (`tracker.ticket_prefix`).

## Steps

1. **Read the ticket.** Fetch details + comments through the adapter:
   ```bash
   scripts/tracker/get-ticket-details.sh  <KEY>
   scripts/tracker/get-ticket-comments.sh <KEY>   # prior QA/bug notes may live here
   ```
   Note the title, type, status, and the acceptance criteria from the body.

2. **Classify → pick base + branch** (branch model from `workspace.config.yaml`):
   - A **bug** → base = `branch_model.fix_base` (default `main`), work branch = `fix/<KEY>`.
   - Otherwise (**feature / polish**) → base = `branch_model.feature_base` (default
     `develop`), work branch = `feature/<KEY>`.

3. **Create the branch** from a fresh base — in the repo's **primary clone at the
   workspace root**, never a submodule checkout. Confirm first: `git rev-parse
   --show-superproject-working-tree` must be **empty** (non-empty ⇒ you're inside a
   submodule — kick off in the primary clone of that repo instead; see the workspace-root
   `docs/agents/submodules.md`).
   ```bash
   git fetch origin
   git checkout <base> && git pull --ff-only origin <base>
   git rev-parse --verify <branch> 2>/dev/null && git checkout <branch> || git checkout -b <branch>
   ```
   If the branch already exists (a resumed/looping ticket), check it out instead of erroring.

4. **Move to in-progress.** Use the org's real "in progress" status name (from
   `issue-tracker.md`):
   ```bash
   scripts/tracker/upsert-ticket-details.sh <KEY> --status "<in-progress status>"
   ```
   Idempotent — fine if it's already there.

5. **Find the design reference.** Scan the ticket body/description for a design URL
   (e.g. a `figma.com` link). Record it (or `null` if absent — do not invent one).

## Output

Return a compact structured summary for the next stage:

```
ticket:        <KEY>
ticket_url:    <tracker url>
title:         <title>
type:          feature | bug | polish
base_branch:   develop | main
work_branch:   feature/<KEY> | fix/<KEY>
design_url:    <url | null>
acceptance:    <bulleted acceptance criteria distilled from the body>
```

Do **not** start coding here — kickoff only prepares the ground.
