---
name: summarize-workflow-performance
description: Summarize per-role token usage and processing time for one dev-cycle (or any tagged) Workflow run, from the workflow agents' JSONL transcripts. The Workflow-engine counterpart of summarize-team-performance. Use when the user wants a token/time breakdown per role and a total for a finished workflow run.
---

# Summarize Workflow Performance

Produces a per-role bullet/table summary of **token usage** and **processing time** for one **Workflow run** (e.g. a `dev-cycle FM-9` run), plus a run total. This is the Workflow-engine twin of [[summarize-team-performance]]: same token accounting and caveats, but the run's agents are subagents spawned by the `Workflow` tool — not `TeamCreate` teammates — so they are matched by the **`[dev-cycle <ticket> role=… phase=… round=…]` marker** that `dev-cycle.js` prefixes onto every agent prompt, not by an `on team` spawn line.

## What is a "run"?
A **run** = one `Workflow({name:'dev-cycle', args:'FM-<n>'})` invocation taken end-to-end: plan → build & gates → PR → review → merge → distribute. Each phase spawns one or more role agents (development-planner, developer, qa, guardian-engineer, performance-engineer, code-reviewer), each writing its own JSONL transcript. This skill measures that whole run, per role.

## When to use
- A dev-cycle workflow run has finished and the user wants a cost/time recap per role.
- Pair it with a run-summary file in the **workspace (org) root** `agent_logs/`, named `<ticket>-DEV-CYCLE-SUMMARY.md` (e.g. `agent_logs/FM-9-DEV-CYCLE-SUMMARY.md`) — never inside a product repo's `agent_logs/`. `agent_logs/` is git-ignored, so the summary is local-only.

## How to run

```bash
python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py <ticket> [--project-dir <dir>] [--workflow <name>] [--csv]
```

- `<ticket>` — the work-key the run was launched with (e.g. `FM-9`). The script finds every transcript whose **first user message** carries the `[<workflow> <ticket> role=…]` marker.
- `--workflow` — the workflow name in the marker (default `dev-cycle`). Set this if you tag another workflow with the same `[<name> <ticket> role=…]` convention.
- `--project-dir` — narrow the scan to one `~/.claude/projects/<encoded>` dir. **By default the parser scans the whole projects root** (`~/.claude/projects`) recursively and filters by the run's marker, so it finds the transcripts even when the run wrote them under a project dir that doesn't match the current cwd — notably a **git-worktree run** (e.g. `dev-cycle` inside `.superset/worktrees/<id>/…`), whose encoded dir differs from the launch cwd. (Claude Code encodes a project path by replacing both `/` and `.` with `-`, so `/Users/me/.superset/x` → `-Users-me--superset-x`.) On zero matches the parser fails loudly with the root scanned, the count of transcripts read, and the marker — never an empty/absent table.
- `--csv` — emit raw CSV instead of the paste-ready Markdown table.
- **Default output is a paste-ready Markdown table** — a caveat line + one row per `role#round` (`Turns | Input | Cache-write | Cache-read | Output | Run | Alive`), ranked by Run spend, a bold **RUN TOTAL** row, and the run wall-clock. Drop it straight into the run-summary file.

## Finish by appending the usage table to the summary file
**Always end a run-summary write by running the script and pasting its result at the bottom of the summary file.** Required final step:

1. Write the narrative run-summary (what shipped, gate/review rounds, per-role notes, the PR/MR + distribution links the workflow returned) to `agent_logs/<ticket>-DEV-CYCLE-SUMMARY.md` at the workspace (org) root.
2. As the **last step**, run the parser for the run's ticket and capture the Markdown table:

   ```bash
   python3 .claude/skills/summarize-workflow-performance/scripts/parse_workflow_usage.py FM-9
   ```

3. Append the output **verbatim** under a `## Token & time usage` heading — do not re-compose the numbers.

## Reading the output — important caveats (identical to the team skill)
- **Tokens (this run):** `RUN` = fresh `input` + `cacheWrite` + `output` — the new tokens actually processed during the run. It deliberately **excludes cache-read re-reads** (already-counted context re-sent every turn), which otherwise balloon the number ~15–50×.
- **Processing time = wall-clock "alive" span** (first→last message in that agent's transcript). It **includes idle waiting** and **overstates active compute**. **Do not sum per-role spans** — they overlap; for true elapsed, use the run window the script prints (min→max timestamp across all agents).
- The orchestrating session (your own / the `Workflow` driver) is not a role transcript; report it separately if needed.

## Notes
- Role + round are parsed from the `role=` / `round=` keys in the marker. One transcript per spawned agent — a workflow spawns a fresh agent per `agent()` call, so unlike a persistent teammate, each round shows as its own row (`developer#2`, `qa#1`, …). That is the intended granularity: it shows where the rounds cost.
- The coarse per-phase `spend[]` array the `dev-cycle` workflow returns is an output-token-only approximation read live from `budget.spent()`; this transcript-based table is the faithful per-role accounting.
