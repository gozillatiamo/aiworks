# The load-test gate — equal-or-better, or it does not ship

A functional suite asks *does it still work*. A load suite asks *how fast, at what error rate,
at what throughput* — and those are numbers, so "the suite is green" is not a verdict about
them. A change can pass every k6 threshold and still make the system measurably slower; the
run reports green and the regression merges.

This gate supplies the missing half: **the same scenario, run on the ticket's base branch, is
the number the candidate has to beat.** Green stays necessary. Equal-or-better is the bar.

## What arms it

One field, on the repo that provides the suite:

```yaml
      - url: git@gitlab.com:your-org/qa/your-k6-tests.git
        kind: test-suite
        suite_kind: load        # ← arms this gate; omit it and the suite stays plain pass/fail
```

`scripts/aiworks config` mirrors it into `dev-cycle.js` as `REPOS[id].suiteKind`. The knobs
live under `loadtest:` in `workspace.config.yaml` (documented in
`workspace.config.example.yaml`): `tolerance_pct`, `noise_runs`, `noise_ceiling_multiple`,
`max_fix_rounds`, `baseline_cache`.

## Three verdicts, and why the third exists

The obvious design — "any metric worse than base fails" — breaks on contact with a real
machine. Two runs of *identical code* on a laptop differ; on the run that motivated this gate,
four percentiles moved between −21% and +75% with no code difference at all. A strict rule
would have blocked a good change on host jitter, and a fixed tolerance would have done the same
whenever the jitter exceeded it.

So the environment is measured before the change is judged:

1. **Noise floor.** The base build runs `noise_runs` times. The spread between those runs is
   what this environment can resolve — the measurement, not overhead.
2. **Effective threshold** per metric = `max(tolerance_pct, noise floor)`. A jittery machine
   widens its own bar; it cannot manufacture a regression.
3. **Ceiling.** If the floor exceeds `tolerance_pct × noise_ceiling_multiple`, the environment
   is too coarse to judge the change *at all*.

| Verdict | Meaning | Effect on the run |
|---|---|---|
| `pass` | every tracked metric is equal-or-better, inside its threshold | proceeds to Merge |
| `fail` | a metric degraded past its threshold, on an environment precise enough to say so | attribution → fix loop, then halt |
| `unavailable` | the noise floor is wider than the effect — no honest verdict exists | loud-skip: banner in the summary, run continues |

`unavailable` is the design's load-bearing piece. Without it a coarse environment forces a
guess, and a guess in either direction is worse than the truth: *the suite is green, and
whether it got slower is unproven here.* The summary says exactly that, and names the run that
would settle it.

## Metrics

Default: every trend metric's `p(95)` and `p(99)` (lower is better), rate/counter metrics such
as `http_req_failed` (lower is better), and `iterations` / `http_reqs` (higher is better). The
qa-planner's automation plan may declare more.

One special case worth knowing: a metric whose base is **0** — almost always the error rate —
has no percentage to take. Rather than skip it, the comparator fails the gate outright when the
candidate moves it off zero. An error rate that was perfect and no longer is, is the single
most important regression a load run can catch; it must not fall through a division guard.

## On a fail: attribute first, fix second

A measured regression is not yet an attributed one, and a developer round spent on jitter is
worse than no round at all. So the loop has two steps, and the first can end it:

1. The **developer** is handed the comparison and must return one of:
   - `attributable` — names the commit, query, lock or added round-trip in *this ticket's diff*
     that explains the move, with `file:line` evidence.
   - `not-attributable` — the diff contains nothing that plausibly explains it.
   - `need-bigger-env` — the effect may be real but this environment cannot show it.
2. Only `attributable` earns a fix. The other two flip the verdict to `unavailable`, and no
   code is touched.

After a fix, the candidate is re-measured against the **cached** baseline — the base SHA has
not moved, so a loop costs one run, not three. `loadtest.max_fix_rounds` bounds it; a
regression still standing at the cap halts the repo (`loadtest-degraded-halt`): nothing merged,
PR/MR left open, evidence on the ticket and the MR.

## The baseline cache

Keyed `<repo>/<scenario>/<base-sha>/<env-fingerprint>` under `loadtest.baseline_cache`,
machine-global by default (`~/.cache/aiworks/loadtest-baselines`).

Machine-global on purpose. A Superset worktree is ephemeral, so a cache inside the repo would
be re-measured for every worktree — several runs of pure wall clock to learn what was already
known. The **base SHA** in the key makes a moved base self-invalidating; the **environment
fingerprint** stops a baseline measured on one machine from being compared against a candidate
measured on another.

## Never fail open

Separate from the baseline comparison, and applying to *every* test-suite gate: a verdict is
only worth its evidence.

The gate must return a **receipt** — the exact command it ran, the exit code, the runner's own
summary line — and a second agent independently reads the ticket looking for the result
comment. If either check comes up empty the gate is recorded as **not run**, not as a pass, and
nothing merges (`test-suite-unverified`).

This is not hypothetical. A run reported `passed: true` having executed nothing, and no result
ever reached the ticket — the failure is invisible precisely because a self-report cannot audit
itself. It mirrors the rule the code reviewer already lives under: a gate that could not run
halts the repo rather than passing.

## Reading the result

The comparator (`.claude/skills/loadtest-baseline-gate/scripts/compare.py`) decides the numbers
— not a model reading a report — so the same inputs give the same verdict every time. It exits
`0` pass, `1` fail, `2` unavailable, `3` bad input, and prints the markdown table that gets
posted to the ticket and the PR/MR: base, candidate, delta, noise floor, threshold, per metric.

Related: `docs/agents/plan-artifacts.md` (where run artifacts live),
`.claude/skills/loadtest-baseline-gate/SKILL.md` (the procedure the runner follows).
