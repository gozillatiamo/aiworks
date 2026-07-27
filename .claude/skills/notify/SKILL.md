---
name: notify
description: Post a review-request notification — a "Please review, <KEY> <title>." digest of a ticket's open PR/MR per repo — to the team chat through the notify adapter (scripts/notify/). Use as the dev-cycle's Notify phase, or when a user wants to ping the team to review a ticket's open PR(s)/MR(s).
argument-hint: [ticket-number]
allowed-tools:
  - Bash(scripts/notify/*)
---

# Notify (review request)

Post a **review-request notification** for a ticket — the "please review" digest of its
open PR/MR across every repo — to the team chat. **One command does the whole job:**

```bash
scripts/notify/send.sh --review <KEY> --channel '#dev-oneforbet'
```

`send.sh --review` gathers the ticket's open PR/MR from **every** workspace repo (matched
by the ticket key in the PR/MR title or branch) and posts this digest:

```
Please review, <KEY> <title>.
<ticket endpoint URL>
- <repo>: <pr_url>
- <repo>: <pr_url>
```

The title + the ticket endpoint URL come from the tracker adapter. The gather, the format,
and the send all live in the script — so no repo is ever missed. **Do not hand-assemble the
list.** Run from the workspace (org) root (the dir holding `.claude/`); never `cd` into a repo.

- **Channel**: defaults to `NOTIFY_CHANNEL` from `scripts/notify/.env`; when that is unset,
  pass `--channel` with the workspace's `notify.channel` from `workspace.config.yaml`
  (`#dev-oneforbet`).
- **Confirm first**: add `--dry-run` to print the assembled digest without posting.

## Result

Success prints `ok=1` and (with a Slack bot token) a `permalink=<url>` → report
`sent: true` with the permalink + channel. `send.sh` exits non-zero with the reason when
there is **nothing to announce** (no open PR/MR for the ticket) or the provider rejects the
send (e.g. no `SLACK_BOT_TOKEN` / `SLACK_WEBHOOK_URL` in `scripts/notify/.env`) → report
`sent: false` with that stderr. Don't retry more than once; a failed send never undoes the
open PR/MR, so it never changes the caller's outcome.

## When to use

- The dev-cycle's **Notify** phase (auto-merge off → the validated PR/MR await a human).
- A user asks to ping the team to review a ticket's open PR(s)/MR(s).

**Post it without asking** for either of those — a ticket's review request is part of finishing
the step, not a favour to check on (`CLAUDE.md` §Notifications).

## When NOT to use

- **An MR with no ticket key**, and in particular **a change to the `ai-workspace` meta-repo
  itself** (agents, skills, hooks, adapters, docs, config). That is not sprint traffic the channel
  is waiting on: report it in chat and **ask** before posting. `--review <KEY>` cannot even compose
  a digest without a ticket, so a hand-written raw message is the tell that you are outside this
  skill's job.
- Retracting one that went out anyway:
  `scripts/notify/send.sh --delete <permalink>` (bot-token only; deletes only what this bot
  posted). It disappears for new readers, not for whoever already saw it — if it mattered, say so
  in the channel instead of pretending it never happened.
