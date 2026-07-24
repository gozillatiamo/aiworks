---
name: telemetry-triage
description: Investigate what ACTUALLY happened in a running environment (local/dev/staging/prod) from SigNoz logs + traces — the ground truth for root-causing a live or reported issue instead of guessing from code. Use when something is failing / erroring / slow / misbehaving in a deployed env ("why is X erroring in prod", "what happened to request Y", "check the logs/traces for Z", "pull the trace", "root cause this incident"), BEFORE building a local repro when the bug only shows in a deployed env, and when another skill or agent needs runtime telemetry to ground a plan or a fix. Read-only investigation ending in a root-cause finding; the developer branch then drives the fix.
argument-hint: [symptom / service / env / trace-id / ticket-key]
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the root-cause finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every section heading + labels/enum values, ALL code + identifiers + commit messages + branch names, and technical / transliterated / domain terms + proper nouns (service names, `severity_text`, `trace_id`, Arabic numerals) stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** (a written-up finding in `agent_logs/`) are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# Telemetry Triage

Telemetry is the **ground truth** of what the running system actually did — logs and traces from the real environment, not a theory read off the code. This skill reconstructs the incident **timeline** from that ground truth and lands on a root cause. When a bug only shows in a deployed env, telemetry is the fastest (often the only) way in.

## Rules of engagement

- **Only through the adapter.** `scripts/observability/get-logs.sh` and `get-trace.sh`. Never curl the SigNoz API directly, never read `scripts/observability/.env` (the adapter loads it; reading it is a hard-blocked secret leak).
- **Filters are structured flags, and they matter.** Free-text query is gone on purpose — this SigNoz instance silently ignored it and returned unfiltered logs. Use `--service` / `--severity` / `--env` / `--body-contains` / `--trace-id`. If a result looks wrong (a service you didn't ask for, a severity you didn't ask for), suspect a typo'd flag value, not a broken filter.
- **Read-only until Phase 5.** Phases 1–4 change nothing. Only the developer branch (Phase 5) edits code.

## Environments

`local` · `dev` · `staging` · `prod` — all one SigNoz instance, selected by `--env` (a `deployment.environment` value). **Always pass `--env`**: a finding that doesn't name its environment is meaningless, and omitting it silently mixes prod into your evidence.

## Phase 1 — Frame the incident

Pin down, before querying:

- [ ] The **exact symptom** (error text, wrong value, latency) — in the user's terms.
- [ ] The **service(s)** likely involved (a `service.name`, e.g. `agent-webservice`).
- [ ] The **env** (`--env`).
- [ ] A **time window** (`--from`/`--to`; start tight, e.g. `-1h`, widen if empty).

A ticket key as the arg → read the ticket first for these. Guessing the window/service wide wastes rows on noise.

## Phase 2 — Pull the ground truth

Start at the symptom and pull threads:

```bash
# Error logs for the suspect service in the env + window
scripts/observability/get-logs.sh --env staging --service agent-webservice --severity ERROR --from -1h

# Narrow to the symptom text
scripts/observability/get-logs.sh --env staging --service agent-webservice --body-contains 'timeout' --from -1h

# A suspect log line references a request → get its full cross-service trace
scripts/observability/get-trace.sh <trace_id> [--span <span_id>]

# All logs emitted under that trace, across every service it touched
scripts/observability/get-logs.sh --env staging --trace-id <trace_id>
```

The **`trace_id` ↔ logs** link is the spine of a distributed investigation: a trace gives you the span waterfall (who called whom, where the time or the error is); `--trace-id` on logs gives you every service's log lines for that one request. Pivot between them.

> Not every `trace_id` seen in a log line has a stored span waterfall — sampling and logs-only emitters mean `get-trace.sh` can come back empty for a real id. That's expected, not a broken tool: when a trace is empty, reconstruct the timeline from the correlated logs (`--trace-id`) instead.

## Phase 3 — Build the timeline, locate the failure

- Order the evidence into a **timeline**: what happened, in what order, in which service.
- Find the **first thing that goes wrong** — the earliest span with `HasError`, the latency jump in the waterfall, the first error log — not a downstream symptom of it.
- If you will fix it, map that failing span/service to code (`codegraph` / Grep) so the finding points at a real location.

## Phase 4 — Root-cause finding — advisory/gate roles STOP HERE

Completion criterion — a finding that is **checkable**, not a hunch. It must carry:

- [ ] **Symptom** + the **env** it was observed in.
- [ ] **Evidence** pasted from telemetry: exact log line(s), the `trace_id`, the failing span with its service + timing.
- [ ] **Suspected root cause**, tied to that evidence (not to a general theory).
- [ ] **Suggested fix direction** — one sentence pointing at the code/config to change.

This is read-only. **The gate is by role capability, not a fixed roster:** only the role that OWNS the code fix continues to Phase 5; every other consumer STOPS here and routes the finding into its own output. Where the caller takes it:

- **cto** — fold into a risk / architecture note; decide if it needs a ticket (`/clarifying-ticket`).
- **development-planner** — fold into the implementation plan as grounding, so the plan targets the real cause.
- **performance-engineer** — treat a latency/throughput finding like any perf finding: anchor it as a PR/MR comment (critical regression) or file an Improvement ticket (nice-to-have) via `/clarifying-ticket`. Never edits code.
- **QA (qa-planner / qa-runner)** — fold into the test verdict / bug report on the ticket: is a deployed-env red a real app fault or an env issue? Never edits app code.
- **developer** — OWNS the fix: continue to Phase 5.
- **any future consumer** — same rule: finding only, unless it owns the code fix.

## Phase 5 — Apply the fix — CODE-OWNER ONLY (the developer)

Do **not** edit against a prod symptom directly. Convert the ground truth into a red loop first:

1. **Seed `/diagnosing-bugs`** with the captured telemetry — the trace + the request payload from the logs is exactly its "replay a captured trace" loop. That turns "it fails in staging" into a local, red-capable, deterministic loop.
2. Fix **test-first** via `/tdd` (or the repo's `coding-feature` loop): red → green → refactor.
3. Verify the loop goes green, then the normal PR flow (`/open-pr`).

The telemetry finding is the *seed* for the fix loop, never a substitute for reproducing the bug.

## Relationship to `diagnosing-bugs`

Two halves of one job. **telemetry-triage** answers *"what actually happened in the running system"* — ground truth from a deployed env. **diagnosing-bugs** answers *"make it fail on demand, then fix it"* — a local red loop. A prod/staging-only bug: triage first to get the trace + payload, then hand that to diagnosing-bugs to lock the repro. A bug you can already reproduce locally: skip triage, go straight to diagnosing-bugs.
