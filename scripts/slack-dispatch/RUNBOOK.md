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
cd /Users/employee/projects/bluepi/ai-workspace/scripts/slack-dispatch
cp .env.example .env
# edit .env — set SLACK_BOT_TOKEN (xoxb-) and SLACK_APP_TOKEN (xapp-).
```

The other keys default correctly for this workspace (project id, base branch, Redis on
`6370`, channel allowlist `C04NZCMAG94`).

> ⚠️ **Do not uncomment `WORKSPACE_ROOT` with the placeholder.** `.env.example` ships it
> commented as `/Users/you/...`. Leaving it commented lets the service auto-resolve the
> real repo root. If you uncomment it, set the real path
> (`/Users/employee/projects/bluepi/ai-workspace`) or pre-flight fails with
> `send.sh missing`. Same for `SUPERSET_HOST_ID` / `SUPERSET_API_KEY` — keep them
> commented when using `--local` + OAuth.

## 2. Pre-flight

```bash
cd /Users/employee/projects/bluepi/ai-workspace/scripts/slack-dispatch
./run.sh --check
```

Expect five `✓`: host, project, agent preset `claude`, Redis, `send.sh`.

## 3. Start the service

`./run.sh` runs in the foreground and blocks the terminal — so use **three places**:

- **Terminal 1** — the service (leave it running; Ctrl-C stops it):
  ```bash
  cd /Users/employee/projects/bluepi/ai-workspace/scripts/slack-dispatch
  ./run.sh
  ```
  It starts Redis, ensures the venv, runs pre-flight, then connects. The last line should
  read `connecting to Slack (Socket Mode)…`. Logs stream here as JSON.
- **Terminal 2** — a second shell for the inspect commands in §5/§6.
- **Slack** — the real Slack client, where you `@<bot> …` in `#dev-oneforbet`.

Prefer a single terminal? Run it in the background:
```bash
cd /Users/employee/projects/bluepi/ai-workspace/scripts/slack-dispatch
nohup ./run.sh > dispatch.log 2>&1 &
tail -f dispatch.log      # watch logs
# stop later:  pkill -f aiworks_dispatch
```

> After editing any Python code, **restart** the service to load it (Ctrl-C + `./run.sh`,
> or `pkill -f aiworks_dispatch` then start again).

## 4. Test scenarios

### T1 — first mention (plumbing)
In `#dev-oneforbet`:
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
  unsupported / secrets, the bot posts the skip reason(s) + `:no_entry_sign: ไม่มีไฟล์ที่อ่านได้เลย …`
  and **does not dispatch** (no busy claim, no worktree, no agent). The event is recorded under
  Redis `ignored:<event_key>`. e.g. attach a single >15MB image, or a lone `.mp4`.
- **Partially usable → dispatches + notes**: mention with ≥1 usable file (or real text) plus a bad
  one → it proceeds, posts the size/type skip notice for the bad file, and the agent's context
  notes it under "ATTACHMENTS SKIPPED". NB: a slash command with a stray oversized file still
  stops (all-files-unusable rule) — re-mention without the file.

### T7 — reply with a file (outbound deliverable)
Ask for a downloadable deliverable:
```
@<bot> ขอ csv รายชื่อ repo ทั้งหมดในเวิร์กสเปซ
@<bot> export ADR-0003 เป็น pdf ให้หน่อย
```
Expected: the agent writes the file under `<worktree>/.aiworks/out/`, then attaches it via
`scripts/notify/send.sh --file` — **one** threaded message carrying the file + a caption. The
file is **not** committed to the branch. Variants:
- **Format inference**: no format named → the agent picks by content (table→csv, records→json,
  report→pdf, else md). `pdf` renders through `scripts/pdf/render.sh` (Mermaid + images).
- **Outbound gate refuses**: the upload is blocked (exit non-zero, nothing sent) when the file is
  over `OUTBOUND_MAX_FILE_MB` (default 15), carries external PII, or matches a secret/token
  pattern. Quick offline check:
  `printf 'x,y\na,alice@example.com\n' > /tmp/p.csv && scripts/notify/send.sh --channel '#dev-oneforbet' --file /tmp/p.csv --dry-run` → refuses.
- **Missing scope**: without `files:write`, the upload fails with a `missing_scope` fix-it note
  (add the scope, reinstall, retry).

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
cd /Users/employee/projects/bluepi/ai-workspace/scripts/slack-dispatch && docker compose down

# delete the test worktrees:
superset ws list --json | jq -r '.[] | select(.name|startswith("slack/")) | .id' | xargs -I{} superset ws delete {}
```

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Pre-flight `send.sh missing — /Users/you/…` | `WORKSPACE_ROOT` uncommented with the placeholder. Comment it out or set the real path (§1). |
| No ack in Slack | Bot not in the channel · wrong `SLACK_APP_TOKEN` (xapp-) · Socket Mode off. Check Terminal 1 log. |
| Ack, but no "Created worktree" | Log shows `dispatch failed` with the raw superset error. Check `superset status`. |
| Agent finished but no reply in thread | Post-back token (`scripts/notify/.env`) broken, or that bot isn't in the channel (redo §0/`send.sh --channel '#dev-oneforbet' test`). The Stop-hook backstop should post `:warning: Session ended (backstop…)` instead. |
| Every follow-up says "still working" | Busy flag stuck. The agent clears it as its last step and the Stop-hook is the belt; a stuck flag frees itself after `BUSY_TTL_SEC`. Clear manually: `docker exec aiworks-slack-dispatch-redis redis-cli del 'thread:<ch>:<ts>:busy'`. |
| `:lock: …can't read its history` | Missing `channels:history` / `groups:history` scope. Add, reinstall the app, restart. |
| `:lock: …couldn't download the file(s)` | Missing `files:read` scope. Add it (+ `users:read` for names), reinstall the app, restart. |
| Attachment `skipped (unsupported type …)` in the agent's context | Not a bug — audio/video/binary aren't Read-able. Widen `_TEXT_EXT` in `attachments.py` only for text-like types. |
| Context lines show raw ids (`U0…`) not names | Missing `users:read` scope (names degrade to ids by design). Add it, reinstall the app. |
| Code change not taking effect | Restart the service — the running process holds the old code (§3). |
