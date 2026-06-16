---
name: estimate-ticket
description: Estimate and set story points on a ticket based on its effort. Calibrates against 5–10 recently Done tickets from this board first (so a point means what it means HERE), then writes the estimate onto the target ticket — the Developer-points and QA-points are written into the tracker's dedicated point FIELDS (not just a comment), plus the overall effort property, plus a comment carrying the comparables and reasoning that justify them. Goes through the tracker adapter (scripts/tracker/), provider-agnostic. Use whenever a ticket needs sizing, pointing, or estimation — the product-owner runs it right after /clarifying-ticket clarifies a ticket, and any user asking to "size", "point", or "estimate" a <KEY> ticket lands here too.
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
  upsert-ticket-details.sh <ref> --effort <value> --dev-points <n> --qa-points <n> [--dry-run]
  add-ticket-comment.sh   <ref> "text"
```

> **The numbers go in fields; only the reasoning goes in the comment.** The Dev and QA
> points are first-class tracker fields — write them with `--dev-points` / `--qa-points`
> (Notion "Developer Points" / "QA Points" number properties; Jira
> `JIRA_DEV_POINTS_FIELD` / `JIRA_QA_POINTS_FIELD`). **Never leave the split living only
> in a comment** — the board sorts, sums and reports on the fields, so a point a human
> can't filter on is half a point. `--effort` still carries the overall size (Notion
> "Effort level"; Jira `JIRA_EFFORT_FIELD`). The estimation **comment** (step 5) then
> carries only what no field can hold: the comparables, the per-side drivers, the
> assumptions and the confidence. Never write any of this into the ticket body — the body
> is the spec, owned by `/clarifying-ticket`, and this skill must not touch it.
>
> If the adapter's `Changed:` line shows it did **not** write the point fields (a provider
> with no point fields configured — e.g. Jira without `JIRA_*_POINTS_FIELD`), say so in
> the output's `note:` rather than pretending the numbers persisted as fields.

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
   - Write the points into their **fields** in one call — `--dev-points` and `--qa-points`
     (plain integers), and `--effort` for the overall size using **exactly a value format
     seen on the reference tickets** (numeric scale → the **total**; select scale like
     S/M/L → the matching level). `--dry-run` first when unsure the effort value will be
     accepted by a select property:
     ```sh
     "$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <KEY> \
       --dev-points <X> --qa-points <Y> --effort "<value>"
     ```
     Confirm the adapter's `Changed:` line lists the point fields (e.g.
     `Developer Points, QA Points`). If it doesn't, the provider has no point fields
     configured — note it in the output (see the callout above).
   - Post the **reasoning** as a comment — *not* the numbers as the source of truth (those
     now live in the fields), but the justification a human reads when they challenge the
     estimate:
     ```
     Estimation — calibrated against <n> Done tickets
     Dev points: <X> — <one line: dominant effort driver>
     QA points:  <Y> — <one line: scenarios/platforms/regression driver>
     Total: <Z>  (board scale: <observed values>)   # echoes the fields for readability
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

If the ticket already has an effort value or points set, don't overwrite them silently.
Change them only when the spec changed or the old values clearly contradict the
comparables — and record the move in the comment: `Re-estimated from <old> to <new> —
<reason>`. Otherwise keep the existing values and note that they were confirmed (read the
current point fields back with `get-ticket-details.sh` before deciding).

## Guardrails

- **Estimation only.** Never change status, title, priority, or the spec body — this
  skill owns exactly the effort property, the Dev/QA point fields, and its estimation
  comment.
- Estimate **effort, not value** — how important a ticket is belongs to priority, set
  elsewhere. Mixing the two corrupts both signals.
- Don't ask the user to confirm a routine estimate; do flag (via the comment and the
  output) when confidence is low or the spec forced big assumptions.

## Output

Return a compact summary the caller (product-owner flow) can carry forward:

```
ticket:      <KEY>
dev_points:  <X>   (written to the Developer-points field)
qa_points:   <Y>   (written to the QA-points field)
effort_set:  <value written to the effort property>
confidence:  high | medium | low
comparables: <KEY-a>, <KEY-b>[, <KEY-c>]
note:        <only if: low confidence / re-estimated / blocked on missing AC / point fields not configured>
```
