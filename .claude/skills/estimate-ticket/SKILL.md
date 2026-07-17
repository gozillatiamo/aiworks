---
name: estimate-ticket
description: Estimate and set story points on a ticket based on its effort. Calibrates against the 10 most-recent estimated Done tickets from this board first (so a point means what it means HERE), then writes the estimate onto the target ticket — the Developer-points and QA-points are written into the tracker's dedicated point FIELDS (not just a comment); the overall total is DERIVED by the tracker from those two, never written by hand. Adds a comment carrying the comparables and reasoning that justify them. Goes through the tracker adapter (scripts/tracker/), provider-agnostic. Use whenever a ticket needs sizing, pointing, or estimation — the product-owner runs it right after /clarifying-ticket clarifies a ticket, and any user asking to "size", "point", or "estimate" a <KEY> ticket lands here too.
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

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write every ticket description, spec, acceptance criterion, and comment you post (the ticket Summary/title itself stays on the English spine) in **Thai prose with an English spine** — titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns stay English (Arabic numerals always); the sentences themselves are Thai. **Code, checked-in repo docs** (`docs/`, `README`, ADRs, committed PRD/BRD files), **and ANY file you author with a `.md` extension** (plans, testcases, PRD/summary Markdown in `agent_logs/`) are **never** Thai — the `th` prose rule applies to chat, tickets, PR/MR discussion, Slack, and `.html` docs only. Default **`en`** = unchanged; this block is a no-op. Full policy: `docs/agents/language.md`.

Put a **defensible point estimate** on a ticket. A point value has no absolute meaning —
it only means something **relative to other tickets on the same board**. That is why this
skill always calibrates against the board's own Done tickets before estimating, instead
of applying a generic scale from memory.

All tracker reads/writes go through the **tracker adapter** (provider-agnostic —
`notion`|`jira`); **never** use a tracker MCP/plugin directly:

```
$CLAUDE_PROJECT_DIR/scripts/tracker/
  find-tickets.sh         [--query <text>] [--type <name>] [--open|--done] [--estimated] [--limit n] [--json]
  get-ticket-details.sh   <ref>            # title + props + body + an "Estimate: Dev … · QA …" line
  get-ticket-comments.sh  <ref> [--deep]   # prior estimation notes live here
  upsert-ticket-details.sh <ref> --dev-points <n> --qa-points <n> [--dry-run]
  add-ticket-comment.sh   <ref> "text"
```

> **Two human inputs — Dev and QA — and nothing else.** You estimate exactly two numbers,
> the **Dev points** and the **QA points**, and write them to their fields with
> `--dev-points` / `--qa-points` (Notion "Developer Points" / "QA Points"; Jira
> `JIRA_DEV_POINTS_FIELD` / `JIRA_QA_POINTS_FIELD`). **The overall total is DERIVED** — the
> tracker computes it from Dev + QA (this org's Jira automation owns that field). **Never
> write the total yourself**, and never reach past the adapter to a raw API to set a point
> field — a hand-written total desyncs the automation.
>
> **"Effort" is not a field — it is what you are measuring.** Effort is the work to take
> the ticket to Done, i.e. to satisfy every acceptance criterion by the approach the
> **ticket description spells out ("how to develop this requirement")**. The Dev and QA
> points *are* your estimate of that effort; there is no separate "effort" property to
> set, so never pass `--effort` here.
>
> **Numbers go in fields; only the reasoning goes in the comment.** A point a human can't
> filter or sum on is half a point — never leave the split living only in a comment. The
> estimation **comment** (step 5) carries what no field can hold: the comparables, the
> per-side drivers, the assumptions, the confidence. Never write any of this into the
> ticket body — the body is the spec, owned by `/clarifying-ticket`, off-limits here.
>
> If the adapter's `Changed:` line shows it did **not** write the point fields (a provider
> with no point fields configured — e.g. Jira without `JIRA_*_POINTS_FIELD`), say so in
> the output's `note:` rather than pretending the numbers persisted.

## Flow

1. **Read the target ticket.** `get-ticket-details.sh <KEY>` (+ `get-ticket-comments.sh`
   for prior estimation notes). You are estimating the **effort to satisfy every
   acceptance criterion** — and that effort lives in the description's *how to develop
   this* explanation, not just the count of AC. So if the ticket has no AC, no described
   approach, or either is too vague to size — **stop and say so**: the right move is
   `/clarifying-ticket <KEY>` first, then estimate. An estimate on an unclear spec is
   noise with a number on it. Note any Dev/QA points already set — `get-ticket-details.sh`
   prints them on its `Estimate:` line (see *Re-estimation* below).

2. **Build the calibration set — one fixed query, every run.** Pull the **10 most-recent
   estimated Done tickets** (same input → same baseline):
   ```sh
   "$CLAUDE_PROJECT_DIR"/scripts/tracker/find-tickets.sh --done --estimated --limit 10 --json
   ```
   The `--json` rows already carry each ticket's Dev/QA points (the adapter requests the
   configured point fields), so you have the values without a second call. Read each one's
   spec with `get-ticket-details.sh` — the title alone doesn't reveal effort; the
   description's "how to develop" approach and the AC do.
   Fewer than 3 rows returned → switch to *Low-confidence mode* below.

3. **Derive the bar.** For each reference ticket, line up its Dev and QA points against the
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
   - Write the two points into their **fields** in one call — `--dev-points` and
     `--qa-points` (plain integers). Do **not** pass `--effort` — effort is not a field
     (see the callout); the Dev/QA points are the estimate, the total is derived.
     ```sh
     "$CLAUDE_PROJECT_DIR"/scripts/tracker/upsert-ticket-details.sh <KEY> \
       --dev-points <X> --qa-points <Y>
     ```
     Confirm the adapter's `Changed:` line lists the point fields. If it doesn't, the
     provider has no point fields configured — note it in the output (see the callout).
   - Post the **reasoning** as a comment — *not* the numbers as the source of truth (those
     live in the fields now), but the justification a human reads when they challenge the
     estimate:
     ```
     Estimation — calibrated against <n> estimated Done tickets
     Dev points: <X> — <one line: dominant effort driver>
     QA points:  <Y> — <one line: scenarios/platforms/regression driver>
     Total: <X+Y>  (derived by the tracker from Dev + QA)
     Comparables: <KEY-a> (Dev <d>/QA <q>) — <why similar>; <KEY-b> (…) — <why similar>
     Assumptions: <anything inferred; "none" if none>
     Confidence: high | medium | low
     ```

6. **Report back** in the compact form under *Output*.

## Low-confidence mode

Fewer than 3 estimated Done tickets returned → there is no bar to calibrate against.
Estimate from first principles against the AC (same Dev/QA reasoning), set
`Confidence: low`, and say **in the comment** that the board lacks calibration history —
never silently pretend calibration happened. These early estimates *become* the bar for
the tickets after them, so the honesty compounds.

## Re-estimation

If the ticket already has Dev/QA points set, don't overwrite them silently. Read the
current values first — `get-ticket-details.sh <KEY>` prints them on its `Estimate:` line.
Change them only when the spec changed or the old values clearly contradict the
comparables — and record the move in the comment: `Re-estimated from <old> to <new> —
<reason>`. Otherwise keep the existing values and note that they were confirmed.

## Guardrails

- **Estimation only.** Never change status, title, priority, or the spec body — this
  skill owns exactly the Dev/QA point fields and its estimation comment.
- **Dev and QA only; the total is the tracker's.** Write points through `--dev-points` /
  `--qa-points` and nothing else — never set the derived total, and never bypass the
  adapter to a raw tracker API to poke a point field.
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
total:       <X+Y> (derived by the tracker — not written here)
confidence:  high | medium | low
comparables: <KEY-a>, <KEY-b>[, <KEY-c>]
note:        <only if: low confidence / re-estimated / blocked on missing AC / point fields not configured>
```
