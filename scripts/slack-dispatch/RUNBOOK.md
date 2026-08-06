# Runbook — run & test aiworks-dispatch

Step-by-step to bring the Slack dispatcher up on this machine and exercise every path
by hand. See `README.md` for architecture; this is the operational drill.

## 0. Prerequisites (one-time)

- **Superset host online:** `superset status` → `running: true, healthy: true`.
- **Docker** running (for the dedicated Redis).
- **Slack app** with Socket Mode, installed to the workspace, bot invited to the
  trigger channel. Bot scopes required:
  - `app_mentions:read`, `chat:write` — receive mentions + post replies.
  - `channels:history` (+ `groups:history` for private channels) — read a thread when
    first mentioned inside one. **Add a scope ⇒ reinstall the app.**
  - `files:read` — download files attached to the mention + its thread. `files:write` —
    upload the agent's deliverable files (md/pdf/csv/json) back into the thread. `users:read`
    — resolve author ids to display names in context lines. **Add a scope ⇒ reinstall.**
  - App-level token (`xapp-…`) with `connections:write` — Socket Mode.
- Import `slack-app-manifest.yaml` to create/align the app.

### Two bot identities — know which token posts what

| Message | Token source |
|---|---|
| Ack + progress ("On it…", "Created worktree…") | `scripts/slack-dispatch/.env` → `SLACK_BOT_TOKEN` |
| The agent's final reply + Stop-hook backstop | `scripts/notify/.env` → `SLACK_BOT_TOKEN` |

For one consistent bot identity in the thread, put the **same** bot token in both files.
Both bots must be members of the trigger channel.

## 1. Configure `.env`

```bash
cd /path/to/ai-workspace/scripts/slack-dispatch
cp .env.example .env
# edit .env — set SLACK_BOT_TOKEN (xoxb-) and SLACK_APP_TOKEN (xapp-).
```

The other keys default correctly for this workspace (project id, base branch, Redis on
`6370`, channel allowlist `C0123456789`).

> ⚠️ **Do not uncomment `WORKSPACE_ROOT` with the placeholder.** `.env.example` ships it
> commented as `/path/to/...`. Leaving it commented lets the service auto-resolve the
> real repo root. If you uncomment it, set the real path
> (`/path/to/ai-workspace`) or pre-flight fails with
> `send.sh missing`. Same for `SUPERSET_HOST_ID` / `SUPERSET_API_KEY` — keep them
> commented when using `--local` + OAuth.

## 2. Pre-flight

```bash
cd /path/to/ai-workspace/scripts/slack-dispatch
./run.sh --check
```

Expect five `✓`: host, project, agent preset `claude`, Redis, `send.sh`.

## 3. Start the service

`./run.sh` runs in the foreground and blocks the terminal — so use **three places**:

- **Terminal 1** — the service (leave it running; Ctrl-C stops it):
  ```bash
  cd /path/to/ai-workspace/scripts/slack-dispatch
  ./run.sh
  ```
  It starts Redis, ensures the venv, runs pre-flight, then connects. The last line should
  read `connecting to Slack (Socket Mode)…`. Logs stream here in the pretty shape —
  one aligned line per event:
  ```
  2026-07-25 16:30:15.438 INFO  main       │ aiworks-dispatch starting (project=abc123 base=develop agent=claude)
  2026-07-25 16:30:15.439 INFO  slack_app  │ accepted correlation=7f3a9b channel=C0123456789 user=U0123456789 continuing=False agent=-
  2026-07-25 16:30:15.512 ERROR dispatcher │ dispatch failed for 7f3a9b | KeyError: 'nope' at dispatcher.py:213
  ```
- **Terminal 2** — a second shell for the inspect commands in §5/§6.
- **Slack** — the real Slack client, where you `@<bot> …` in `#your-channel`.

Prefer a single terminal? Run it in the background:
```bash
cd /path/to/ai-workspace/scripts/slack-dispatch
nohup ./run.sh > dispatch.log 2>&1 &
tail -f dispatch.log      # watch logs
# stop later:  pkill -f aiworks_dispatch
```

Redirected like that, the log shape flips to one-line JSON (`LOG_FORMAT=auto`) so the file
stays greppable — `grep 7f3a9b dispatch.log | jq -r .msg` follows one correlation id, and
`ERROR` lines carry the full `exc` traceback. A message carrying a payload (superset CLI
response, Slack API body) also gets it as a nested object, so pull fields straight out:
```bash
grep 'workspace created' dispatch.log | jq -r '.data.worktreePath'
``` Want the pretty shape in the file too:
```bash
LOG_FORMAT=pretty nohup ./run.sh > dispatch.log 2>&1 &   # pretty, no colour (not a TTY)
```
Pretty lines flatten a traceback to `| ExcType: msg at file:line`; when that is not enough,
re-run with `LOG_FORMAT=json` for the whole stack.

> After editing any Python code, **restart** the service to load it (Ctrl-C + `./run.sh`,
> or `pkill -f aiworks_dispatch` then start again).

## 4. Test scenarios

### T1 — first mention (plumbing)
In `#your-channel`:
```
@<bot> reply in this thread with a one-line hello. do not modify files or open a PR.
```
Expected sequence:
1. **immediately** — `:hourglass: On it — creating a worktree… (ref: req-xxxx)`
2. **after minutes** (first run clones 21 repos via setup.sh) — `:white_check_mark: Created worktree slack/req-xxxx — Claude is on it (session …)`
3. **on completion** — the agent posts its own summary in the thread.

> First dispatch is minutes-slow because of worktree setup — normal. The ack is instant.

### T2 — follow-up in the same thread (reuse)
Reply **in the same thread** and mention again:
```
@<bot> now also append the word goodbye
```
Expected: ack says `continuing this thread` → `:white_check_mark: Reusing worktree slack/req-xxxx`
(fast, no re-clone). The agent should have read/extended `.aiworks/thread-log.md`.

### T3 — concurrency (reject while busy)
While T1/T2's agent is **still running**, mention again in that thread:
```
@<bot> another request while busy
```
Expected: `:hourglass: I'm still working on the previous request in this thread…`. No second
worktree. When the running session ends the busy flag clears (agent clears it itself; Stop-hook
is the belt) and the next mention proceeds.

### T4 — first mention *inside* an existing thread (thread-context pull)
Find a thread whose root was **not** addressed to the bot (a normal human discussion), then
reply in it mentioning the bot:
```
@<bot> summarize what this thread is asking for and propose a fix
```
Expected: the agent's reply reflects the **earlier messages** in the thread (they were pulled
in as context). If the bot lacks `channels:history`, it hard-fails:
`:lock: I was mentioned inside a thread but can't read its history…` — add the scope,
reinstall, restart, retry.

### T5 — dedup & allowlist
- **Dedup**: Slack occasionally redelivers an event — the log shows `duplicate event … skipping`
  and no second worktree.
- **Allowlist**: mention from a channel/DM not in `ALLOWED_CHANNEL_IDS`/`ALLOWED_USER_IDS` →
  `:no_entry: I'm not enabled for this channel or user.`

### T6 — attachments (image / file)
Attach an image (or PDF/text file) to the mention message:
```
@<bot> what does this screenshot show? [attach image]
```
Expected: the log shows `attachment downloaded id=F… name=…`; the agent's reply reflects the
file's contents. Verify the file landed in `<worktreePath>/.aiworks/attachments/`. Variants:
- **Image-only parent**: reply-mention inside a thread whose parent is an image with no text —
  the agent still sees it (image-only messages are no longer dropped).
- **Idempotent follow-up**: mention again in the same thread — the log should NOT re-download an
  already-present file (only messages after `last_read_ts` are re-scanned).
- **Missing scope**: without `files:read`, the bot hard-fails with
  `:lock: …couldn't download the file(s)…`. Add the scope, reinstall, retry.
- **All attachments unusable → STOP (no worktree)**: if the mention's files are ALL too big /
  unsupported / secrets, the bot posts the skip reason(s) + `:no_entry_sign: None of the attached files could be read …`
  and **does not dispatch** (no busy claim, no worktree, no agent). The event is recorded under
  Redis `ignored:<event_key>`. e.g. attach a single >15MB image, or a lone `.mp4`.
- **Partially usable → dispatches + notes**: mention with ≥1 usable file (or real text) plus a bad
  one → it proceeds, posts the size/type skip notice for the bad file, and the agent's context
  notes it under "ATTACHMENTS SKIPPED". NB: a slash command with a stray oversized file still
  stops (all-files-unusable rule) — re-mention without the file.

### T7 — reply with a file (outbound deliverable)
Ask for a downloadable deliverable:
```
@<bot> give me a csv of every repo in the workspace
@<bot> export ADR-0003 as a pdf
```
Expected: the agent writes the file under `<worktree>/.aiworks/out/`, then attaches it via
`scripts/notify/send.sh --file` — **one** threaded message carrying the file + a caption. The
file is **not** committed to the branch. Variants:
- **Format inference**: no format named → the agent picks by content (table→csv, records→json,
  report→pdf, else md). `pdf` renders through `scripts/pdf/render.sh` (Mermaid + images).
- **Outbound gate refuses**: the upload is blocked (exit non-zero, nothing sent) when the file is
  over `OUTBOUND_MAX_FILE_MB` (default 15), carries external PII, or matches a secret/token
  pattern. Quick offline check:
  `printf 'x,y\na,alice@example.com\n' > /tmp/p.csv && scripts/notify/send.sh --channel '#your-channel' --file /tmp/p.csv --dry-run` → refuses.
- **Missing scope**: without `files:write`, the upload fails with a `missing_scope` fix-it note
  (add the scope, reinstall, retry).

### T8 — route to a subagent / run a workflow (`agent:` / `workflow:`)
```
@<bot> agent:list
@<bot> workflow:list
@<bot> agent:developer implement APP-45 following the plan on the ticket
@<bot> agent:qa-planner /plan-testcases APP-45
@<bot> workflow:dev-cycle APP-45
@<bot> agent:nobody do stuff
```
Both `:list` forms answer **inline within a second or two** — every name + a one-line
summary from disk — with no worktree, no agent session and no busy flag; run one while
another turn is working to confirm it still replies. `workflow:dev-cycle APP-45` must behave
exactly like `/dev-cycle APP-45` (it is rewritten to that before dispatch).
Expected: the ack line carries `— routed to `<name>``, and the dispatched session
delegates via the Agent tool (`subagent_type` = that name) instead of doing the work
itself; the post-back to the thread still comes from the dispatched session. Names are
whatever `.claude/agents/*.md` defines — no restart needed after adding one. The unknown
name replies with the valid list and dispatches **nothing** (no worktree, no busy flag —
`store.mark_ignored` records why). Prefix is `agent:` and not `@name` on purpose: Slack
linkifies an `@handle` that collides with a real user/usergroup, and leading mentions are
stripped before parsing. Offline check of the parser:
```bash
./.venv/bin/python - <<'PY'
from aiworks_dispatch.catalog import (agent_duties, available_agents, available_workflows,
                                      is_agent_list, split_agent, split_workflow,
                                      workflow_summaries)
agents, flows = available_agents("../.."), available_workflows("../..")
print(sorted(agents), sorted(flows))
print(split_agent("agent:developer implement APP-45", agents))  # ('developer', 'implement APP-45', '')
print(split_agent("agent:nobody do stuff", agents))             # ('', 'agent:nobody do stuff', 'nobody')
print(split_agent("@developer implement APP-45", agents))       # ('', '@developer implement APP-45', '')
print(split_workflow("workflow:dev-cycle APP-45", flows))       # ('dev-cycle', 'APP-45', '')
print(is_agent_list("agent:list"), is_agent_list("list the repos"))   # True False
print(*agent_duties("../.."), *workflow_summaries("../.."), sep="\n")
PY
```

## 5. Inspect state (Terminal 2)

```bash
C=aiworks-slack-dispatch-redis

# all keys (seen / corr / outcome / thread / busy)
docker exec $C redis-cli keys '*'

# busy flags + remaining TTL (should be empty when no agent is running)
for k in $(docker exec $C redis-cli keys 'thread:*:busy'); do echo "$k ttl=$(docker exec $C redis-cli ttl "$k")"; done

# thread → worktree mappings + TTL
for k in $(docker exec $C redis-cli keys 'thread:*' | grep -v ':busy'); do echo "$k ttl=$(docker exec $C redis-cli ttl "$k")"; done

# dispatch outcome for a ref
docker exec $C redis-cli get outcome:req-xxxx | jq .

# worktrees the dispatcher created
superset ws list --json | jq -r '.[] | select(.name|startswith("slack/")) | "\(.name)\t\(.worktreePath)\t\(.worktreeExists)"'

# per-thread running log + context file (substitute the worktreePath)
cat "<worktreePath>/.aiworks/thread-log.md"
cat "<worktreePath>/.aiworks/slack-context.json"
```

## 6. Teardown

```bash
# stop the service: Ctrl-C in Terminal 1  (or: pkill -f aiworks_dispatch)

# stop Redis:
cd /path/to/ai-workspace/scripts/slack-dispatch && docker compose down

# delete the test worktrees:
aiworks gc --dispatch --ttl-days 0
```

`superset ws delete` alone leaves the worktree directory, the `git worktree` registration
and the local branch behind — `aiworks gc` removes all four, and refuses any worktree that
is still in use. In normal operation you never run this: the service sweeps on an interval
(`GC_ENABLED` / `GC_INTERVAL_SEC` / `GC_TTL_DAYS`, see `.env.example`). Use `aiworks gc` with
no arguments to see what it would collect.

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Pre-flight `send.sh missing — /path/to/…` | `WORKSPACE_ROOT` uncommented with the placeholder. Comment it out or set the real path (§1). |
| No ack in Slack | Bot not in the channel · wrong `SLACK_APP_TOKEN` (xapp-) · Socket Mode off. Check Terminal 1 log. |
| Ack, but no "Created worktree" | Log shows `dispatch failed` with the raw superset error. Check `superset status`. |
| Agent finished but no reply in thread | Post-back token (`scripts/notify/.env`) broken, or that bot isn't in the channel (redo §0/`send.sh --channel '#your-channel' test`). The Stop-hook backstop should post `:warning: Session ended (backstop…)` instead. |
| Every follow-up says "still working" | Busy flag stuck. The agent clears it as its last step and the Stop-hook is the belt; a stuck flag frees itself after `BUSY_TTL_SEC`. Clear manually: `docker exec aiworks-slack-dispatch-redis redis-cli del 'thread:<ch>:<ts>:busy'`. |
| `:lock: …can't read its history` | Missing `channels:history` / `groups:history` scope. Add, reinstall the app, restart. |
| `:lock: …couldn't download the file(s)` | Missing `files:read` scope. Add it (+ `users:read` for names), reinstall the app, restart. |
| Attachment `skipped (unsupported type …)` in the agent's context | Not a bug — audio/video/binary aren't Read-able. Widen `_TEXT_EXT` in `attachments.py` only for text-like types. |
| Context lines show raw ids (`U0…`) not names | Missing `users:read` scope (names degrade to ids by design). Add it, reinstall the app. |
| Code change not taking effect | Restart the service — the running process holds the old code (§3). |
