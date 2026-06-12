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

A provider impl defines: `notify_require_config`, `notify_send CHANNEL TEXT [DRY]`.
**To add a provider** (e.g. Teams, Discord), drop a new `<provider>/impl.sh` implementing
those — nothing else changes.

## Auth (Slack)

Set **one** of these in `scripts/notify/.env`:
- `SLACK_BOT_TOKEN` — used with `chat.postMessage`. Honours the target channel (`#name`
  or id) and returns a message permalink. Needs the `chat:write` scope and the bot
  invited to the channel.
- `SLACK_WEBHOOK_URL` — an Incoming Webhook. Simplest, but the channel is **fixed by the
  webhook** (so `--channel` / `NOTIFY_CHANNEL` are ignored) and there is no permalink.

`aiworks sync` seeds `NOTIFY_PROVIDER` + `NOTIFY_CHANNEL` from `workspace.config.yaml`;
the secret is added by hand.
