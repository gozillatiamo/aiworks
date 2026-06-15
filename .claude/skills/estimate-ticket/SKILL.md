---
name: estimate-ticket
description: Estimate and set story points on a ticket based on its effort. Calibrates against 5–10 recently Done tickets from this board first (so a point means what it means HERE), then writes the estimate onto the target ticket — the effort property plus a comment splitting Developer points and QA points with the comparables that justify them. Goes through the tracker adapter (scripts/tracker/), provider-agnostic. Use whenever a ticket needs sizing, pointing, or estimation — the product-owner runs it right after /clarifying-ticket clarifies a ticket, and any user asking to "size", "point", or "estimate" a <KEY> ticket lands here too.
argument-hint: "<KEY> (e.g. FM-12)"
allowed-tools:
  - Bash(scripts/tracker/*)
  # Codegraph (per-repo index): optional shallow skim to sharpen the Dev estimate —
  # codegraph explore/search before Grep/Glob/Read (which stay the last resort).
  - Bash(codegraph *)
  - Read
  - Grep
  - Glob
  - AskUserQuestion
---

# Estimating a ticket

Put a **defensible point estimate** on a ticket. A point value has no absolute meaning —
it only means something **relative to other tickets on the same board**. That is why this
skill always calibrates against the board's own Done tickets before estimating, instead
of applying a generic scale from memory.

All tracker reads/writes go through the **tracker adapter** (provider-agnostic —
`notion`|`jira`); **never** use a tracker MCP/plugin directly:

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  find-tickets.sh         [--query <text>] [--type <name>] [--open] [--limit n] [--json]
  get-ticket-details.sh   <ref>            # title + props (incl. effort) + body
  get-ticket-comments.sh  <ref> [--deep]   # prior estimation notes live here
  upsert-ticket-details.sh <ref> --effort <value> [--dry-run]
  add-ticket-comment.sh   <ref> "text"
```

> **One effort field, two numbers.** The adapter exposes a single `--effort` property
> (Notion "Effort level"; Jira `JIRA_EFFORT_FIELD`). So the **property** carries the
> overall size (the board sorts/filters on it), and the **Dev/QA split lives in a
> structured estimation comment** (step 5). Never write the split into the ticket body —
> the body is the spec, owned by `/clarifying-ticket`, and this skill must not touch it.

## Flow

1. **Read the target ticket.** `get-ticket-details.sh <KEY>` (+ `get-ticket-comments.sh`
   for prior estimation notes). You are estimating the **acceptance criteria**, so if the
   ticket has no AC — or the AC are too vague to size — **stop and say so**: the right
   move is `/clarifying-ticket <KEY>` first, then estimate. An estimate on an unclear
   spec is noise with a number on it. Note any effort value already set (see
   *Re-estimation* below).

2. **Build the calibration set.** List the board and keep Done tickets that actually
   have an effort value:
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/find-tickets.sh --limit 0 --json
   ```
   (The "done" status name comes from `docs/agents/issue-tracker.md` /
   `scripts/tracker/.env`.) From those, pick **5–10**: prefer the same type as the
   target, the most recently finished, and a **spread of sizes** — calibrating only
   against small tickets tells you nothing about where "large" starts. Then read each
   one with `get-ticket-details.sh` — the title alone doesn't reveal effort; the AC do.
   Fewer than 3 usable references → switch to *Low-confidence mode* below.

3. **Derive the bar.** For each reference ticket, line up its effort value against the
   effort signals visible in its spec:
   - number **and depth** of acceptance criteria (5 trivial checks ≠ 5 cross-feature flows)
   - surface touched: one widget vs. a whole flow vs. cross-repo (app + e2e)
   - novelty: repeats an established pattern vs. first-of-its-kind work
   - integration/migration/data risk
   - test burden the AC imply (scenario count, platforms, manual-only steps)

   Write yourself a short scale table — "on this board, a 1 looks like …, a 3 looks
   like …". **Use the values actually observed** — Fibonacci, 1–5, S/M/L, whatever the
   board uses. Don't impose a scale the board doesn't have: an unseen value can be
   rejected outright by a select property, and even when accepted it breaks the board's
   comparability.

4. **Estimate the target — Dev and QA separately.** Match the target's AC against the
   scale table and anchor on the **2–3 closest comparables** (you will name them in the
   comment — an estimate you can't trace to a comparable is a guess).
   - **Dev points** — implementation effort to satisfy the AC: scope of code touched,
     novelty, risk. Optionally sharpen with a shallow code skim (**codegraph first** —
     `codegraph explore`/`codegraph search` in the repo the ticket targets; `Grep`/
     `Glob`/`Read` only as a last resort). Skim to size, not to design — no file paths
     or schemas leak into the ticket.
   - **QA points** — test effort the AC imply: how many BDD scenarios, platforms
     (Android **and** iOS roughly doubles execution), regression surface around the
     change, automatable vs. manual-only checks.

   The two move independently — a one-line logic fix in a payment flow is small Dev,
   large QA. When torn between two values, take the higher: unknowns rarely shrink work.

5. **Write the estimate to the ticket.**
   - Set the effort property, using **exactly a value format seen on the reference
     tickets** (numeric scale → the **total**; select scale like S/M/L → the matching
     level). `--dry-run` first when unsure the value will be accepted:
     ```sh
     "$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <KEY> --effort "<value>"
     ```
   - Post the breakdown as a **comment** (this is where the split and the reasoning
     live — the part a human reads when they challenge the number):
     ```
     Estimation — calibrated against <n> Done tickets
     Dev points: <X> — <one line: dominant effort driver>
     QA points:  <Y> — <one line: scenarios/platforms/regression driver>
     Total: <Z>  (board scale: <observed values>)
     Comparables: <KEY-a> (<pts>) — <why similar>; <KEY-b> (<pts>) — <why similar>
     Assumptions: <anything inferred; "none" if none>
     Confidence: high | medium | low
     ```

6. **Report back** in the compact form under *Output*.

## Low-confidence mode

Fewer than 3 Done tickets with an effort value → there is no bar to calibrate against.
Estimate from first principles against the AC (same Dev/QA reasoning), set
`Confidence: low`, and say **in the comment** that the board lacks calibration history —
never silently pretend calibration happened. These early estimates *become* the bar for
the tickets after them, so the honesty compounds.

## Re-estimation

If the ticket already has an effort value, don't overwrite it silently. Change it only
when the spec changed or the old value clearly contradicts the comparables — and record
the move in the comment: `Re-estimated from <old> to <new> — <reason>`. Otherwise keep
the existing value and note that it was confirmed.

## Guardrails

- **Estimation only.** Never change status, title, priority, or the spec body — this
  skill owns exactly the effort property and its estimation comment.
- Estimate **effort, not value** — how important a ticket is belongs to priority, set
  elsewhere. Mixing the two corrupts both signals.
- Don't ask the user to confirm a routine estimate; do flag (via the comment and the
  output) when confidence is low or the spec forced big assumptions.

## Output

Return a compact summary the caller (product-owner flow) can carry forward:

```
ticket:      <KEY>
dev_points:  <X>
qa_points:   <Y>
effort_set:  <value written to the property>
confidence:  high | medium | low
comparables: <KEY-a>, <KEY-b>[, <KEY-c>]
note:        <only if: low confidence / re-estimated / blocked on missing AC>
```
