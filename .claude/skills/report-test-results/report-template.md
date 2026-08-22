**[test-report · {{ suite repo name, e.g. e2e-suite }}]**

<!-- THE LINE ABOVE IS THE COMMENT'S IDENTITY — do not reword it, do not translate it, do not
     drop the brackets. `upsert-ticket-comment.sh --marker '[test-report · <repo>]'` finds this
     comment by that exact text and rewrites it, which is what stops a re-run from posting a
     second report. It has to be VISIBLE text: an HTML comment does not survive the
     Markdown → tracker → text round trip, so it could never be found again. One such comment
     per suite repo per ticket — four suite repos on a ticket means four comments, each with
     its own repo in the marker. -->

Test results — {{ Ticket Number }} · {{ PASS | FAIL }} · {{ per-tool marks from the harness SUMMARY, e.g. cypress ✓ · newman ✗ }}

`run {{ r<n> }} · {{ UTC timestamp, e.g. 2026-08-20T09:14Z }} · candidate {{ repo@sha, comma-separated for a multi-repo candidate }}`

<!-- THE RUN STAMP, and it is not decoration. dev-cycle proves its test-suite gate actually ran
     by having a second agent find THIS run's result on the ticket; with the report updated in
     place, the stamp is the only thing that distinguishes this run's report from last run's.
     A missing or stale stamp makes the gate read as NOT RUN. -->

{{ One-line verdict: X of Y planned scenarios automated; the outcome; bug count if any. }}

## Results

<!-- One row per TC in agent_logs/<KEY>-testcases.md. Keep cells terse:
     ✅ pass · ❌ fail · — not automated. Evidence = ✅ when a screenshot for this TC was
     attached, — when none was captured. Add one Result column per tool the harness's
     SUMMARY reported; a single-tool run has a single column. -->

| TC | Scenario | {{ Result-column per tool }} | Evidence | Notes |
|---|---|---|---|---|
| TC001 | {{ scenario title from the test plan }} | {{ ✅ \| ❌ \| — }} | {{ ✅ \| — }} | {{ short note / bug ref / "manual-only" }} |
| TC002 | {{ scenario title }} | {{ ✅ \| ❌ \| — }} | {{ ✅ \| — }} | {{ … }} |

Legend: ✅ pass · ❌ fail · — not automated (manual-only / partial)

<!-- Pass screenshots go here, ALL ON ONE LINE, so they render as a thumbnail strip.
     Delete this line if the run captured none. -->
![TC001](attachment:{{ id }}) ![TC002](attachment:{{ id }})

## Failures

<!-- Keep this section ONLY if a row is ❌. One block per failing TC; concise, no raw logs.
     The screenshot goes ALONE on its own line so it renders full-width. -->

### {{ TC00n }} — {{ failing scenario title }}
- **Expected:** {{ the test plan's `Then` }}
- **Actual:** {{ what the app did — from agent_logs/<KEY>-bugs.md }}
- **Why:** {{ the `scripts/dev.sh why test` line — error + frame }} (log: `{{ path }}`)

<!-- Backtick every path and identifier. A bare snake_case path in prose is read as
     Markdown emphasis by some trackers and loses its underscores silently. -->


![{{ TC00n }} failure](attachment:{{ id }})

## Coverage

- **Automated:** {{ n }}/{{ total }} planned scenarios.
- **Not automated:** {{ TC id(s) marked Manual-only/Partial in the automation plan + one-line reason, or "none" }}.
- **Regressions:** {{ status of the test plan's regression checks, or "none requested" }}.
- **Run report:** {{ the rendered report image, or the report path, or "none produced" }}.

![run report](attachment:{{ id }})

**Run video**

<!-- EVERY video the run produced, green or red: failing specs first, then the rest, then the
     run-wide one, each ALONE on its own line, while the running total stays under 25 MB.
     Delete this whole block only when `scripts/dev.sh artifacts` listed no `video` row at all —
     and say "no video captured" under Coverage instead, so a reader knows it was absent rather
     than withheld. -->

![{{ spec or TC the video covers }}](attachment:{{ id }})

<!-- One line per video you did NOT attach, with its real size and path. Never drop one in
     silence: a report that omits evidence without saying so reads like a report that had none. -->
_Not attached_ — `{{ file }}` ({{ n }} MB, over the 25 MB budget): {{ path }}

## Run history

<!-- RENDERED FROM THE LEDGER, never re-typed from the record being replaced. Append this run's
     one line to agent_logs/<KEY>-test-report-history.tsv, then render the whole file:
       awk -F'\t' '{printf "- %s · %s · %s\n", $1, $2, $3}' agent_logs/<KEY>-test-report-history.tsv
     Re-merging history by hand is what produced three reports that contradicted their own runs.
     On the FIRST run the ledger holds exactly one line — this run's. -->

- `r1` · {{ UTC }} · {{ PASS | FAIL }} {{ n/total }} · candidate {{ repo@sha }}
- `r2` · {{ UTC }} · {{ PASS | FAIL }} {{ n/total }} · candidate {{ repo@sha }}
