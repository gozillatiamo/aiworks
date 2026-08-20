---
name: loadtest-baseline-gate
description: >-
  Judge a load-test run against the SAME run on the ticket's base branch, so a change cannot ship
  a slower system while the suite still reports green. Use for a `suite_kind: load` repo, when
  acceptance criteria name latency or throughput, or when asked whether a change degraded
  performance against develop/main. Measures the environment's noise floor first and returns pass,
  fail or unavailable - never a verdict the environment cannot support.
argument-hint: "[ticket]"
arguments: [ticket]
---

# Load-test baseline gate

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

A green load suite proves the system still *works*. It says nothing about whether it got
**slower**, which is the only thing a load suite is for. This gate supplies the missing half:
the same scenario, run on the ticket's base branch, as the number to beat.

Green is necessary and not sufficient. **Equal-or-better against the base is the bar.**

## Arm check (step 0)

This gate applies only to a repo declared `suite_kind: load` in `workspace.config.yaml`. Any
other suite is plain pass/fail — say so and stop. Read the `loadtest:` block for
`tolerance_pct`, `noise_runs`, `noise_ceiling_multiple`, `baseline_cache`.

## The three verdicts

Every run ends on exactly one, and **`unavailable` is a real answer, not a failure to decide**:

- **pass** — every tracked metric is equal-or-better than base, inside its threshold.
- **fail** — at least one metric degraded past its threshold on an environment precise
  enough to say so.
- **unavailable** — the environment's own **noise floor** is wider than the effect being
  measured, so no honest verdict exists. A loud skip (it must reach the run summary as a
  banner), never a quiet pass.

## Steps

1. **Resolve the pair.** Base = the branch this ticket's PR/MR actually *targets* (not the
   repo's default branch — an epic or release base is common), at its current SHA. Candidate =
   the ticket's work branch HEAD. Record both SHAs; they go in the report.
2. **Fingerprint the environment.** CPU count, total RAM, container runtime, and whether the
   backend runs locally or against a deployed environment. A baseline is only comparable to a
   candidate measured on the same fingerprint.
3. **Get the baseline.** Look in `<baseline_cache>/<repo>/<scenario>/<base-sha>/<env-fp>.json`.
   On a hit, reuse it. On a miss, check out the base build and run the scenario `noise_runs`
   times, then write the results there. Two runs of the same code on the same machine differ;
   that spread **is** the measurement, not waste.
4. **Run the candidate** — the same scenario, same shape, same duration, once. **Mark the
   start first** (`touch agent_logs/.loadtest-start`): the suite repo's own runs are driven
   by you, not by `scripts/dev.sh`, so that marker is what step 6 dates the run's reports
   against — without it a report left over from an earlier ticket reads as this run's.
5. **Compare.** Run the comparator; do not do this arithmetic yourself:
   ```
   python3 .claude/skills/loadtest-baseline-gate/scripts/compare.py \
     --base <run1.json> --base <run2.json> --candidate <cand.json> \
     --tolerance-pct <tolerance_pct> --noise-ceiling-multiple <noise_ceiling_multiple>
   ```
   Per metric it takes the effective threshold as `max(tolerance_pct, noise floor)` — so a
   jittery machine cannot manufacture a regression — and returns `unavailable` when the floor
   exceeds `tolerance_pct × noise_ceiling_multiple`. Its exit code is the verdict (0/1/2).
6. **Report, whatever the verdict.** Post the comparator's markdown table — both SHAs, both
   report paths, every tracked metric with its delta, noise floor, and threshold — to the
   ticket **and** the PR/MR (`scripts/vcs/pr-comment.sh`). A verdict nobody can read did not
   happen.

   On the ticket this is **one durable comment per suite repo, updated in place** — a load gate
   re-runs on every fix round, and a fresh comment per round buries which numbers are current:
   ```sh
   scripts/tracker/upsert-ticket-comment.sh <KEY> --marker "[test-report · <this repo>]" < <the report>
   ```
   Same marker, stamp and **Run history** rules as `/report-test-results` (§4-5 there) — the
   body must contain its own marker line or the call refuses, and each round's line is appended
   to the history rather than replacing the last. Run it **bare**: it is a writer, and a
   compound call is denied silently.

   **Attach the candidate run's own report as a picture**, so the numbers arrive with the
   thing that produced them. Ask the harness what the run wrote — never guess a path:
   ```sh
   scripts/dev.sh artifacts --since agent_logs/.loadtest-start
   ```
   Take the `report` row (the suite's HTML run report), render it, and embed it under the
   table on the TICKET (the PR/MR comment keeps the table alone — a reviewer reading a diff
   wants the deltas, not a poster):
   ```sh
   scripts/pdf/render.sh <that report.html> agent_logs/<KEY>-artifacts/<KEY>-loadtest.png --png --expand
   ```
   `--expand` is not optional here. A run report is a TABBED page and a screenshot is one
   frozen state, so without it the picture carries only whichever tab was open — on a real
   k6-reporter report that means the metrics table and NOT the checks, which is the half a
   reader most wants (measured: 2756px tall without it, 4496px with).

   Upload and embed it per **`/update-ticket` §4** (rename → `--embed-id` → the image alone
   on its own line). No `report` row — a suite that writes no HTML report — is fine: post
   the table and say the run produced no report. The **table** is the verdict; the picture
   is corroboration, and a missing picture never changes pass/fail/unavailable.

**Done when** the comparator has run on real files produced by this session, both comments
are posted, and you can name the base SHA, the candidate SHA, and the exit code.

## Receipt

Return the **receipt** with the verdict: the exact command line, its exit code, the summary
line it printed, and the paths of every run file compared. A verdict without a receipt is
treated by the caller as `unavailable` and re-run — so a run you did not actually perform buys
nothing.

Two specific traps, both of which have shipped a false green here before:

- Reporting from a report file you did not produce **this session** (a stale `reports/` artifact
  from an earlier ticket reads exactly like a fresh one).
- Returning `pass` because the suite exited 0. Exit 0 is the *green* half; this gate is the
  *baseline* half, and it needs the base run to exist.

## On a fail

Do **not** diagnose it and do **not** touch application code — you work in the test-suite repo
only. Hand the caller: the failing metrics with their deltas, both SHAs, and both run files.
Attributing the regression to a specific commit is the developer's job; deciding whether the
environment can support the claim at all has already been done in step 5.
