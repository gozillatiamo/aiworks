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
  read `connecting to Slack (Socket Mode)…`. Logs stream here as JSON.
- **Terminal 2** — a second shell for the inspect commands in §5/§6.
- **Slack** — the real Slack client, where you `@<bot> …` in `#your-channel`.

Prefer a single terminal? Run it in the background:
```bash
cd /path/to/ai-workspace/scripts/slack-dispatch
nohup ./run.sh > dispatch.log 2>&1 &
tail -f dispatch.log      # watch logs
# stop later:  pkill -f aiworks_dispatch
```

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
superset ws list --json | jq -r '.[] | select(.name|startswith("slack/")) | .id' | xargs -I{} superset ws delete {}
```

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Pre-flight `send.sh missing — /path/to/…` | `WORKSPACE_ROOT` uncommented with the placeholder. Comment it out or set the real path (§1). |
| No ack in Slack | Bot not in the channel · wrong `SLACK_APP_TOKEN` (xapp-) · Socket Mode off. Check Terminal 1 log. |
| Ack, but no "Created worktree" | Log shows `dispatch failed` with the raw superset error. Check `superset status`. |
| Agent finished but no reply in thread | Post-back token (`scripts/notify/.env`) broken, or that bot isn't in the channel (redo §0/`send.sh --channel '#your-channel' test`). The Stop-hook backstop should post `:warning: Session ended (backstop…)` instead. |
| Every follow-up says "still working" | Busy flag stuck. The agent clears it as its last step and the Stop-hook is the belt; a stuck flag frees itself after `BUSY_TTL_SEC`. Clear manually: `docker exec aiworks-slack-dispatch-redis redis-cli del 'thread:<ch>:<ts>:busy'`. |
| `:lock: …can't read its history` | Missing `channels:history` / `groups:history` scope. Add, reinstall the app, restart. |
| Code change not taking effect | Restart the service — the running process holds the old code (§3). |
