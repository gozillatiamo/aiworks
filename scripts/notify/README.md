# Notify adapter

Provider-agnostic shell scripts for posting team notifications (chat). One entry
script; `lib.sh` dispatches to a provider implementation chosen by `NOTIFY_PROVIDER`
(`slack` today), reading secrets from a git-ignored `.env`.

| Script | Does |
|---|---|
| `send.sh` | Post a message to the configured chat provider; prints `ok=1` + `permalink=` (where available) |

`send.sh` accepts `--channel <id\|#name>` (defaults to `NOTIFY_CHANNEL`) and `--dry-run`.
The message text is the first positional arg, or stdin.

```sh
printf '%s' "$msg" | scripts/notify/send.sh --channel '#reviews'
```

Three message modes:
- **raw** — `[text]` arg or stdin (the default).
- **`--review <KEY>`** — compose + post the "please review" digest of a ticket's open PR/MR
  across every repo (the dev-cycle Notify phase).
- **`--reply <KEY>`** — post `[text]` as a **threaded reply under the review-request** for the
  ticket: it finds the newest channel message containing the key (the requester's "please
  review") via `conversations.history` and replies in that thread. **No thread found ⇒ it
  skips** (`skipped=1`, posts nothing — never a stray top-level message). This is how the
  reviewers land their verdict where the request was made. Needs a **bot token** (a webhook
  can't read history, so it always skips); a bot token can't use `search.messages`, hence the
  history scan over `conversations.history` (`channels:history`/`groups:history`). **The
  channel must resolve to an id:** `conversations.history` takes an id, not a `#name`, so set
  `NOTIFY_CHANNEL` (or `--channel`) to the channel **id** — a `#name` only resolves when the
  bot also has `channels:read`/`groups:read`, and without it reply mode silently skips.

```sh
scripts/notify/send.sh --reply FM-2098 '✅ FM-2098 — approved. Standards clean, 0 must-fix.'
```

## Where it's used

The **dev-cycle** workflow's *Notify* phase (the last phase) posts a "please review"
digest of the open PR/MR per repo — but **only** when `notify.enabled: true` **and**
`vcs.auto_merge: false` in `workspace.config.yaml`. With auto-merge on the run merges +
distributes itself, so there is nothing left to review and the phase is skipped.
`send.sh` itself is the low-level primitive: it always sends when invoked; the
"should we notify" policy lives upstream.

## Layout

```
notify/
├── lib.sh          # provider dispatch (+ loads .env)
├── slack/impl.sh   # Slack implementation (bot token or incoming webhook)
├── send.sh         # entry script
└── .env.example    # NOTIFY_PROVIDER / NOTIFY_CHANNEL + the Slack secret
```

A provider impl defines: `notify_require_config`, `notify_send CHANNEL TEXT [DRY] [THREAD]`,
and `notify_find_thread CHANNEL KEY` (return empty if the provider can't search — reply mode
then always skips). **To add a provider** (e.g. Teams, Discord), drop a new `<provider>/impl.sh`
implementing those — nothing else changes.

## Auth (Slack)

Set **one** of these in `scripts/notify/.env`:
- `SLACK_BOT_TOKEN` — used with `chat.postMessage`. Honours the target channel (`#name`
  or id) and returns a message permalink. Needs the `chat:write` scope and the bot
  invited to the channel.
- `SLACK_WEBHOOK_URL` — an Incoming Webhook. Simplest, but the channel is **fixed by the
  webhook** (so `--channel` / `NOTIFY_CHANNEL` are ignored) and there is no permalink.

`aiworks sync` seeds `NOTIFY_PROVIDER` + `NOTIFY_CHANNEL` from `workspace.config.yaml`;
the secret is added by hand.
