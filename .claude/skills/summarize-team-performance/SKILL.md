---
name: summarize-team-performance
description: >-
  Summarize per-role token usage and processing time for one Agent Team mission (TeamCreate ->
  TeamDelete), from the teammates' JSONL transcripts. Use when the user wants a token/time
  breakdown per role plus a total for a finished team job.
---

# Summarize Team Performance

Produces a per-role bullet summary of **token usage** and **processing time** for one Agent Team **mission**, plus a team total. Reads the teammates' conversation transcripts directly (the team config/tasks dirs are deleted on `TeamDelete`, but the JSONL transcripts persist).

## What is a "mission"?
A **mission** = one directive taken end-to-end by an ephemeral team: the persistent lead receives a command → `TeamCreate` → the team executes (spawn roles → pipeline → gates → ship) until the job is done → lead `TeamDelete`s. The lead lives across many missions; the team lives only for one. This skill measures exactly that `TeamCreate → TeamDelete` window, per role.

## When to use
- A team mission has finished (or is winding down) and the user wants a cost/time recap per role.
- Typically paired with a mission-summary file. Keep it in `agent_logs/`, named `<work-key>-MISSION-SUMMARY.md` (e.g. `agent_logs/FM-8-MISSION-SUMMARY.md`) — alongside the per-role work logs. Note `agent_logs/` is git-ignored, so the summary is local-only.

## How to run

```bash
python3 .claude/skills/summarize-team-performance/scripts/parse_team_usage.py <team-name> [--project-dir <dir>] [--table]
```

- `<team-name>` — the `TeamCreate` name (e.g. `fm8-pipeline`). The script finds every transcript whose system/spawn prompt contains ``on team `<team-name>` `` (falls back to a plain mention).
- **Default output is a complete, paste-ready Markdown table** — caveat line + a per-role row with one column per token aspect (`Turns | Input | Cache-write | Cache-read | Output | Mission | Alive`), ranked by Mission spend, plus a bold TEAM TOTAL row, the mission wall-clock, and a lead-not-counted note. Run it and drop the output straight into the mission-summary report — no re-composing needed.
- `--project-dir` — the `~/.claude/projects/<encoded-cwd>` dir to scan. Defaults to the encoding of the current working directory (`/foo/bar` → `-foo-bar`).
- `--table` — print a plain fixed-width ASCII table (terminal-friendly) instead of the Markdown table.

## Finish by appending the usage table to the summary file
**Always end a mission-summary write by running the script and pasting its result as a table at the bottom of the summary file.** This is a required final step, not optional:

1. Write the narrative mission-summary (decisions, what shipped, per-role notes) to `agent_logs/<work-key>-MISSION-SUMMARY.md`.
2. As the **last step**, run the parser for the mission's team and capture the Markdown table it prints:

   ```bash
   python3 .claude/skills/summarize-team-performance/scripts/parse_team_usage.py <team-name>
   ```

3. Append the script's output **verbatim** to the **bottom** of the summary file, under a `## Token & time usage` heading. The default output is already a paste-ready Markdown table (caveat line + per-role rows + bold TEAM TOTAL + mission wall-clock) — do not re-compose or hand-edit the numbers.

So every finished mission-summary file ends with the live `parse_team_usage.py` table.

## Reading the output — important caveats
- **Tokens (this mission):** `MISSION` = fresh `input` + `cacheWrite` + `output` — the new tokens actually processed during the mission. It deliberately **excludes cache-read re-reads** (already-counted context re-sent every turn), which otherwise balloon the number ~15–50× and don't represent work done this mission. `out` is the generated-token subset.
- **Processing time = wall-clock "alive" span** (first→last message in that agent's transcript). Teammates stay **alive and idle** between messages, so this *includes idle waiting* and **overstates active compute**. **Do not sum per-role spans** — they overlap. For true elapsed, use the mission window the script prints (min→max timestamp across all teammates ≈ TeamCreate→TeamDelete).
- The team lead (your own session) is not a teammate transcript; report it separately if needed.

## Notes
- Role + name are parsed from the spawn prompt pattern `You're <Name>, <role>, on team ...`. If a teammate was spawned with a different prompt shape, its role may show as `?`; use `--table` and relabel by hand.
- One transcript per teammate even if it was messaged many times (persistent session), so usage is cumulative for that role.
