# Night Watch

An unattended, read-only watch over production. Once per slot (a **Tick**), a headless `oncall` agent
reads production guided by a workspace-owned **Playbook** and returns a **Verdict**. This script
validates the Verdict, keeps memory, and posts it to chat through `scripts/notify/`. The agent never
posts: its notify, tracker and vcs tools are disallowed for the run
([ADR 0047](../../docs/adr/0047-the-night-watch-script-owns-posting.md)).

## Setup

1. `triage.prod: true` in `workspace.config.local.yaml` on the machine that runs it, and the triage
   MCPs registered (`scripts/triage-mcp.sh sync`). With production off, every Tick is `BLIND`.
2. A **bot token**: `SLACK_BOT_TOKEN` in `scripts/notify/.env` with `chat:write`, the bot invited to
   the channel. Webhooks cannot thread and do not return a message `ts`, so a webhook-only setup cannot
   run Night Watch (the first threaded post fails with a clear message).
3. A Playbook: copy `playbook.template.md` to `docs/night-watch/playbook.md` and fill it in.
4. A `night_watch:` block in `workspace.config.yaml` (keys documented in
   `workspace.config.example.yaml`; no comments in the live file).

Post prose follows `case_report_language` (falls back to `language`). Finding titles carry identifiers
only. The English follow-up brief is not posted: it is kept in the Verdict file under
`agent_logs/night-watch/verdicts/` for an agent asked to dig further.

## Run

```sh
scripts/night-watch/run.sh tick     # one Tick now, then exit (cron or launchd friendly)
scripts/night-watch/run.sh loop     # wait for each slot, Tick, repeat; Ctrl-C stops it
scripts/night-watch/run.sh plan     # print the current slot, whether it is active, and the next one
scripts/night-watch/selftest.sh     # offline regression, agent and chat stubbed
```

Progress goes to stderr, one timestamped line per event: the loop's start, `next Tick at ...` before
each wait, each Tick's `START` and end line (state, headline, duration, where it posted), and every
skip or gap. Each line is flushed at once, so a process manager sees it live. stdout carries only
`plan`'s line. Findings and the brief are never printed; read them in chat or `verdicts/`.
Under cron, redirect the output (`>> night-watch.out 2>&1`), or cron mails every Tick.

Run one loop on one machine. The lock makes a second loop skip every slot; two machines would both post.

## States and posting

| Outcome | Post |
|---|---|
| `OK` | thread reply under that day's parent message (one parent per day) |
| `SUSPICIOUS` | top-level, mentions: headline, a count per severity, one numbered block per finding (realm, rule, title, up to 4 evidence ids), the conclusion, the realms not checked |
| `ALERT` | like `SUSPICIOUS`; after 1 minute a short repeat (mention and headline only) |
| `BLIND` | first: top-level with mention and what to re-authenticate. Later consecutive ones: thread reply, no mention, until a Tick succeeds |
| FAILED (timeout, crash, invalid Verdict) | gap line in the thread; mentions only after 2 failures in a row |
| missed slots | ONE gap line naming them; never replayed |

Baseline learning: for the first 24 successful Ticks a count-based finding is labelled and mentions
nobody (and an `ALERT` made only of count findings is not repeated). Fixed-rule findings mention from
Tick 1. A Verdict containing personal data (email, bank-account-like numbers, ...) is rejected before
posting and counts as FAILED; every post also goes through the adapter's PII gate.

## Files (git-ignored, under `agent_logs/night-watch/`)

- `state.json`: counters, the day's parent message, learned `baselines` and `notes`. A corrupt file is
  kept as `state.json.corrupt-<time>` and the watch starts fresh.
- `ticks.log`: one line per Tick (`<slot> <state> <headline or reason> [ts=...]`); the same line is echoed to stderr.
- `verdicts/<slot>.json`: the Verdict, or the raw agent output of a FAILED Tick.
- `tick.lock`: held while a Tick runs.

## Limits

- `caffeinate` (macOS) blocks idle sleep, but a closed lid on battery still sleeps: expect gap lines.
- A DST change can skip one slot (shown as a gap line); the same slot never runs twice.
- `--json-schema` is passed to the CLI but is not enforced by it, so the script extracts the fenced
  JSON from the result and validates it itself. An invalid Verdict is a FAILED Tick.
- Test seams (selftest only): `NIGHT_WATCH_NOW`, `NIGHT_WATCH_CLAUDE`, `NIGHT_WATCH_TIMEOUT_SEC`,
  `NIGHT_WATCH_ALERT_REPEAT_SEC`, `NIGHT_WATCH_PROD_ALLOWED`.
