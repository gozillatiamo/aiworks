# The dev-cycle session orchestrates, never implements

**Status:** Accepted

## Context

A `/dev-cycle` run that ended blocked or halted was followed, in the SAME session, by the
orchestrator itself going on to make **17 Edits inside product repos** and hand-write **8**
dev-cycle run-state rows (`agent_logs/<ticket>-dev-cycle-state/*.json`). None of that work ever
went through a build/review/gate agent: it was not checkpointed the way the run's own agents
checkpoint, it was never reviewed, and the run-state rows it fabricated described milestones
that had not actually happened. The next invocation of `/dev-cycle` for that ticket would have
read those forged rows as proof and skipped work that was never really done.

This workspace already tried the prose-only fix once, for a related problem
([ADR-0015](0015-code-minimalism-is-a-plugin-not-a-prompt.md),
[docs/agents/workflow-resume.md](../agents/workflow-resume.md)): CLAUDE.md, this repo's own
skills, and a prompt directive all told an agent not to hand-edit a persisted run script.
Measured result: the ONE mechanical gate that existed (an `hcat`-size denial) produced
compliance; three separate prose directives asking for the same discipline produced close to
none. A hand-edit inside a product repo after a dev-cycle run is the same shape of problem —
a session that is supposed to orchestrate reaching for the tool it always has (Edit, Bash) to
just do the thing instead — and prose alone was not going to hold here either.

## Decision

Two mechanisms, together:

1. **`pretool-orchestrator-guard.sh`** (C6) — a `PreToolUse` hook on `Bash` and
   `Write|Edit|NotebookEdit` that denies, ONLY once armed (see below) and ONLY when it can
   positively identify the caller as the MAIN session (never a subagent — see "The
   discriminator"): a `Write`/`Edit`/`NotebookEdit` landing inside a product repo or under any
   `agent_logs/*-dev-cycle-state/` run-state directory, and a mutating `git` verb
   (`commit|apply|am|rebase|merge|cherry-pick|revert|reset|push|stash`) run against a product
   repo. Read-only git, and anything under `.claude/`, `docs/`, `scripts/`, the root
   `agent_logs/` (run summaries), or outside the workspace root entirely (the scratchpad),
   stays untouched.
2. **A run marker** (C7) — `agent_logs/<ticket>-dev-cycle-state/orchestrator-guard.json`,
   `{"session_id","ticket","armed","run_state","recorded_at"}`. Kickoff writes it
   `armed:false` (the run's OWN agents must stay free to edit repos while it works); the
   Summary phase — reached by every terminal path — REPLACES it with `armed:true` once the
   run is over. A resumed invocation's own Kickoff flips it back to `false`, so a resume is
   never blocked by the previous ending.

**Continuation is `/dev-cycle <KEY>` (run state scopes it to what is unfinished) or a
read-only diagnosis agent — deliberately NO `--repair`/`--fix-state` flag.** A flag would make
hand-repair a supported mode of this workflow, and the run state (ADR-0018) already scopes a
resume to exactly what is unproven; a repair flag would be a second, competing way to say the
same thing, and the one most likely to be reached for under pressure instead of a clean resume.

### The discriminator (why arming happens at the END, not the start)

Per the official hooks reference, a `PreToolUse` payload carries `agent_id`/`agent_type` ONLY
when a subagent issues the call. This guard treats three signals as proof of "not main" —
`.agent_id` present, `.transcript_path` containing the substring `/subagents/` (covers both a
plain subagent transcript and a WORKFLOW agent's `subagents/workflows/wf_*/agent-*.jsonl`), or
`CLAUDE_CODE_CHILD_SESSION=1` (measured true in a subagent's own Bash environment this
session) — and an EMPTY/unknown `transcript_path` as inconclusive, never a reason to deny. Only
a non-empty transcript_path naming none of those is treated as MAIN.

The probe has since been run for real (`scripts/hook-signal-probe.sh`, wired temporarily as a
PreToolUse hook). Three measured facts now govern the design:

1. **`agent_id` discriminates** — present in the hook payload for a subagent's tool call,
   absent for the main session's own. It is the guard's one real signal.
2. **`CLAUDE_CODE_CHILD_SESSION` does not** — the hook subprocess sees `child=1` on EVERY
   call, main and subagent alike (the hook process is itself a Claude-spawned child). An
   early allow on it made the guard permanently inert; it is no longer consulted.
   `transcript_path` pointed at the MAIN transcript for both callers, so its allow survives
   only as belt-and-braces.
3. **A user's own `!`-typed command fires hooks too, main-shaped** — indistinguishable from
   the model's call in the payload. The Merge/Distribute ship steps are deliberately human
   `!` commands (`git merge`, `git push` in product repos), so those two verbs are exempt
   from the deny set; the measured leak (edits, commits, a destructive rebase, forged state
   rows) stays fully covered.

With the discriminator confirmed, arming moved from Summary to **Kickoff**: the marker is
written `armed:true` at run start, so the main session is held to orchestration DURING the run
as well as after it. The run's own agents pass on `agent_id`; Summary still rewrites the marker
with `run_state:"ended"`.

## Consequences

- The guard is deliberately **permanent for the rest of the session** once a run has ended in
  it — there is no "off" switch other than resuming the run (which re-arms `false`) or
  starting a fresh session.
- Scratchpad work, `.claude/`, `docs/`, `scripts/`, and root `agent_logs/` summaries stay
  writable throughout; read-only git diagnosis (`status`/`log`/`diff`/`show`) is never blocked.
- A stale marker from a crashed run stays `armed:true` for that session — which is the correct
  reading: a crashed run is exactly when hand-fixing tempts, and the next Kickoff refreshes the
  marker anyway.
- An inert guard (the failure direction whenever the discriminator cannot positively identify
  main) remains the chosen residual: a payload with no `agent_id`, no `/subagents/` transcript
  and an EMPTY transcript_path is inconclusive and passes. `git merge`/`git push` in a product
  repo pass by design — they are the ship verbs a human runs via `!`, and hooks fire
  main-shaped on those too (measured).
