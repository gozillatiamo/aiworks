# aiworks-dispatch — Slack `@bot` → Superset on-demand Claude

A long-running service that turns a Slack mention into a Claude agent running in a
fresh Superset worktree on this machine, and lets that agent reply back into the
originating Slack thread itself.

```
Slack  ──@aiworks /prd OFB-123──►  dispatcher (this service, Socket Mode)
                                      │ 1. dedup on event id (Redis)
                                      │ 2. mint correlationId + capture channel/thread/user
                                      │ 3. immediate ack in the thread
                                      │ 4. superset workspaces create  (fresh worktree)
                                      │ 5. write .aiworks/slack-context.json into it
                                      │ 6. superset agents create      (launch Claude)
                                      ▼
                              Claude agent works in the worktree
                                      │ (final step, per its prompt)
                                      ▼
                       scripts/notify/send.sh --thread-ts …  ──►  Slack thread
```

The loop is closed **out-of-band by the agent**, not by a callback: `agents create`
returns a session id, not a result. The agent posts its own summary via the notify
adapter. A Stop-hook backstop (below) covers the case where it can't.

## Why these choices

- **Local `superset` CLI**, not the alpha SaaS SDK. The host service already runs on
  this machine (`superset status`), so a worktree + agent is two CLI calls — no API
  key, no relay, no online-host dependency. The engine sits behind the `Dispatcher`
  interface (`dispatcher.py`) so an SDK or `claude -p` variant can drop in later.
- **Extend the notify adapter** for post-back. `scripts/notify/send.sh` gained a
  `--thread-ts` flag; the agent posts through the **main clone's** copy (absolute
  path in the prompt) because a fresh worktree's own `scripts/notify/.env` is an
  unconfigured stub.
- **Python + slack_bolt** Socket Mode — no public inbound URL.
- **Dedicated Redis** (`docker-compose.yml`): own container, own port `6370`, pinned
  image, git-ignored volume. Dedups Slack's event redelivery so a resend never spawns
  a second worktree.

## Prerequisites

1. **Superset host online.** `superset status` → `running: true, healthy: true`. If
   not: `superset start`.
2. **Project + agent preset.** `superset projects list` (the OFB meta-repo →
   `SUPERSET_PROJECT_ID`), `superset agents list --local` (confirm the `claude` preset).
3. **Slack app** with Socket Mode — see `slack-app-manifest.yaml`. You need a bot
   token (`xoxb-…`, scopes `app_mentions:read` + `chat:write`, plus `channels:history` /
   `groups:history` to read a thread when mentioned inside one, `files:read` for attachment
   support, `files:write` to reply with a file, and `users:read` to resolve names) and an
   app-level token (`xapp-…`, scope `connections:write`). Invite the bot to the trigger channel.
4. **Docker** for the Redis container.

## Setup

```bash
cd scripts/slack-dispatch
cp .env.example .env          # fill in the two Slack tokens; defaults cover the rest
./run.sh --check              # pre-flight: host, project, preset, Redis, notify path
./run.sh                      # start Redis + the Socket Mode service (foreground)
```

`.env` is git-ignored (root `.gitignore` globs `.env` at any depth). Configuration
reference: see `.env.example`. The trigger allowlist **defaults to deny** — set
`ALLOWED_CHANNEL_IDS` and/or `ALLOWED_USER_IDS` or nothing dispatches.

> **`RUNBOOK.md`** is the full run + test drill — prerequisites, the terminal layout,
> every test scenario (first mention, reuse, concurrency, in-thread context), inspect
> commands, teardown, and troubleshooting.

## Usage (in Slack)

```
@aiworks /prd OFB-123
@aiworks /dev-cycle OFB-45
@aiworks investigate why payouts are slow in front-end and open a fix PR
@aiworks role:developer implement OFB-45 following the plan on the ticket
```

A leading slash command runs the matching skill exactly as if typed in a Claude Code
session. Plain text is handled as a task. The bot acks immediately, then replies in
the same thread when the agent finishes (`ref: req-…` ties the messages together).

### Routing to a specific agent — `role:<name>`

A leading `role:<name>` hands the whole request to that **subagent** instead of letting
the dispatched session work it directly. Valid names are the workspace's own agent
definitions — `.claude/agents/<name>.md` (`developer`, `code-reviewer`, `qa-planner`,
`performance-triage`, …) — read per mention, so adding an agent needs no restart.

```
@aiworks role:list                                   # who can I route to?
@aiworks workflow:list                               # what pipelines can I run?
@aiworks role:developer implement OFB-45 following the plan on the ticket
@aiworks role:performance-triage root-cause the slow payout endpoint in staging
@aiworks role:qa-planner /plan-testcases OFB-45      # role + slash command combine
@aiworks workflow:dev-cycle OFB-45                   # same as `/dev-cycle OFB-45`
```

**Discovery.** `role:list` and `workflow:list` are answered **inline, in seconds** — each
name with a one-line summary, read straight from disk (`description:` frontmatter of
`.claude/agents/*.md`; `whenToUse` from a workflow's `meta` in `.claude/workflows/*.js`,
falling back to its `description`). No worktree, no agent session, no busy flag, so they
also answer while a turn is still running. `list` / `lists` are therefore reserved names —
no agent or workflow may be called that.

`workflow:<name> <args>` is sugar: it is rewritten to the `/<name> <args>` slash command
the session already understands, so `workflow:` and `/` are interchangeable. An unknown
name in either family replies with what does exist and dispatches nothing.

- **Why `role:` and not `@developer`.** Slack linkifies an `@handle` that matches a real
  user or usergroup into `<@U…>` / `<!subteam^…>`, and leading mentions are stripped
  before parsing — the routing would silently vanish for exactly the names most likely
  to collide. `role:` is never linkified, so the parser sees what was typed.
- The dispatched session becomes a **router**: it calls the Agent tool with that
  `subagent_type`, waits, then does the post-back itself (a subagent's report goes to
  its caller, never to Slack).
- Unknown name (`role:nobody …`) → the bot replies with the valid list and **dispatches
  nothing** — no worktree is burned on a request routed somewhere that doesn't exist.
  Nobody types `role:` by accident, so it is always treated as intent to route.
- Prefer a workflow when one covers the job: `/dev-cycle` already runs
  planner → developer → review → QA in waves, with the branch prep a bare
  `role:developer` skips.

## Thread continuity

Keep mentioning the bot **in the same thread** and it reuses that thread's worktree
instead of spawning a new one each time — no re-clone, no `setup.sh`, no worktree
spam on the host.

- **Mapping.** `thread:<channel>:<thread_ts>` in Redis → the thread's worktree
  (`workspace_id`, `worktree_path`, `branch`). Lives **`THREAD_TTL_SEC` from creation**
  (fixed 7d default, not refreshed on reuse).
- **What "continue" means.** The `superset` CLI cannot resume a live Claude session, so
  a follow-up launches a *new* agent session in the *same* worktree/branch. Context
  carries via **`.aiworks/thread-log.md`** — each turn reads it for history and appends
  its own summary (the prompt enforces this).
- **Mentioned inside an existing thread.** If the FIRST mention lands in a thread whose
  root did not address the bot, the whole thread up to that mention is pulled in as
  context (each line tagged with its Slack author **name** and **timestamp** — names via
  `users:read`, ids as fallback) and injected into the prompt as untrusted DATA. This
  needs the `channels:history` / `groups:history` bot scopes — if the thread can't be
  read, the bot **hard-fails** (posts what scope to add, dispatches nothing). Capped by
  `THREAD_CONTEXT_MAX_MSGS`. On follow-ups only messages **after** the last turn's
  high-water mark (`last_read_ts` on the mapping) are re-scanned — the rest of the
  history lives in `thread-log.md`.
- **Attachments.** Files on the mention message AND its thread (an image-only post
  counts) are downloaded into `<worktree>/.aiworks/attachments/` and listed in the prompt
  as untrusted DATA with author + timestamp + relative path — the agent Reads them
  itself (images/PDF natively, text-like as text; Claude has no audio/video modality, so
  those are skipped). Downloads are **idempotent** by Slack file id (a re-scanned file
  already on disk is not re-fetched) and **capped** (`ATTACHMENT_MAX_FILES` /
  `ATTACHMENT_MAX_FILE_MB` / `ATTACHMENT_TOTAL_MB`). Needs `files:read`; a missing scope
  **hard-fails** with a fix-it message, while a single broken/oversized/unsupported file
  soft-degrades (noted in the prompt, turn continues). Files download BEFORE the agent
  launches, so they are on disk when it Reads them.
- **Reply with a file (outbound).** When the request asks for a **deliverable file** —
  "give me a csv of…", "export … as a pdf", "สรุปเป็นไฟล์ md" — the agent writes it under
  `<worktree>/.aiworks/out/` (never committed) and attaches it with `scripts/notify/send.sh
  --file`, so one threaded message carries the file plus a caption. `md`/`csv`/`json` are
  written directly; a `pdf` is rendered from an authored `.md`/`.html` via `scripts/pdf/
  render.sh` (Mermaid + images, offline). The notify adapter's **outbound gate** refuses any
  upload that is oversized (`OUTBOUND_MAX_FILE_MB`), carries external PII, or matches a
  secret/token pattern — so "never leak a secret/PII" is a deterministic wall, not just a
  prompt line. Needs `files:write`; a missing scope surfaces a fix-it message.
- **Stale mapping.** If the worktree is gone (`workspaces get` says so) or the mapping
  expired, the next mention transparently starts a fresh worktree and re-maps the thread.
- **Concurrency.** One agent per thread worktree at a time. A mention that lands while
  the previous turn is still running is **refused** ("still working… mention me again"),
  never queued — two agents on one worktree would collide on the git index. A Redis busy
  flag enforces it, freed in three layers: the agent clears it as its final step (from
  the prompt — reliable, doesn't depend on the Stop-hook firing in a Superset session),
  the Stop-hook clears it as a belt, and a `BUSY_TTL_SEC` cap frees it if both fail.
- **Worktree path.** `superset ws create` returns before the worktree materializes
  (worktreePath is null in its response), so the dispatcher polls `ws get` until the dir
  exists before writing `.aiworks/slack-context.json` — otherwise the Stop-hook backstop
  is silently disabled.

## Stop-hook backstop (needs one manual settings edit)

The **primary** post-back is the agent calling `send.sh` itself (instructed in the
prompt preamble in `prompt.py`). `.claude/hooks/slack-postback.sh` (already installed +
executable) fires on session Stop and does two things, but only inside a worktree that
has `.aiworks/slack-context.json` (so it is inert for every normal Claude session):

1. **Frees the thread (belt)** — clears the Redis busy flag, via the service venv at
   `scripts/slack-dispatch/.venv`. The agent normally clears it itself as its last step;
   this covers the case where it can't.
2. **Backstops the reply** — if `.aiworks/slack-posted-<ref>` is absent (the agent forgot
   or crashed), posts the last assistant message so the thread is never left silent.

Editing `.claude/settings.json` is gated, so wire it yourself — add this `Stop` block
under `"hooks"`:

```json
"Stop": [
  {
    "matcher": "*",
    "hooks": [
      {
        "type": "command",
        "command": "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/slack-postback.sh",
        "timeout": 30
      }
    ]
  }
]
```

Without it, only the backstop is lost — the agent's own post-back still works.

## Security

The mention text becomes an agent prompt with repo write access on your machine.
Controls in place:

- **Default-deny allowlist** (channel and/or user). Empty ⇒ every mention refused.
- **Trusted preamble / untrusted data split** in `prompt.py` — the correlationId,
  reply target, and post-back instruction can't be overridden by the user's text.
- **Branch, don't merge** — the agent is told to open a PR/MR for human review. This
  is the real backstop against a bad or injected request; prompt injection via the
  request text can't be fully prevented.
- **Least-privilege agent** — scope the host's `claude` agent (Superset → host
  settings) to a tool allowlist; this service can't set that.
- **No secrets in prompts or workspace names.** Post-back uses the main clone's
  adapter by path; no token is ever interpolated.

## Cost note

Each dispatch creates a fresh worktree, which runs the project's `.superset/setup.sh`
(clones the product repos + installs) — minutes and real disk per request. Tune the
project's setup or reuse worktrees if this is too heavy for your usage.

## Layout

| File | Role |
|---|---|
| `aiworks_dispatch/config.py` | env → typed `Config`, fail-fast |
| `aiworks_dispatch/correlation.py` | `CorrelationContext`, id + git-safe slug |
| `aiworks_dispatch/prompt.py` | trusted preamble + untrusted request block |
| `aiworks_dispatch/store.py` | Redis dedup + correlation/outcome store + thread mapping/busy |
| `aiworks_dispatch/clear_busy.py` | Stop-hook helper: free a thread's busy flag |
| `aiworks_dispatch/dispatcher.py` | `Dispatcher` interface + `SupersetLocalDispatcher` |
| `aiworks_dispatch/slack_app.py` | Socket Mode `app_mention` handler |
| `aiworks_dispatch/__main__.py` | entrypoint / wiring / graceful shutdown |
| `aiworks_dispatch/check.py` | `python -m aiworks_dispatch.check` pre-flight |
| `docker-compose.yml` | dedicated Redis (port 6370) |
| `slack-app-manifest.yaml` | Slack app definition |
| `run.sh` | boot Redis + venv + service |
| `RUNBOOK.md` | operational run + test drill |
