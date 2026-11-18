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
scripts/night-watch/run.sh brief [latest|HH:MM|YYYYMMDDTHHMM]   # print a Verdict for a follow-up (read-only)
scripts/night-watch/run.sh resolve <latest|HH:MM|YYYYMMDDTHHMM> <n> --note "<one line>" [--alert]   # mark finding n safe
scripts/night-watch/run.sh unresolve <id>   # remove a resolution
scripts/night-watch/run.sh resolved         # list active resolutions (read-only)
scripts/night-watch/selftest.sh     # offline regression, agent and chat stubbed
```

Progress goes to stderr, one timestamped line per event: the loop's start, `next Tick at ...` before
each wait, each Tick's `START` and end line (state, headline, duration, where it posted), and every
skip or gap. Each line is flushed at once, so a process manager sees it live. stdout carries only
`plan`'s line. Findings and the brief are never printed; read them in chat or `verdicts/`.
Under cron, redirect the output (`>> night-watch.out 2>&1`), or cron mails every Tick.

Run one loop on one machine. The lock makes a second loop skip every slot; two machines would both post.
Run it only in the root checkout: a worktree links this directory, and `tick` and `loop` refuse to run through the link; `brief`, `resolve`, `unresolve` and `resolved` work through it and land in the root's directory.

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

## Resolved cases

After a dig-down concludes that finding `n` of a Verdict is safe, `run.sh resolve <slot> <n> --note "<line>"`
records a **Resolved case** in `agent_logs/night-watch/resolved.json` (atomic write, own short lock). It
runs no Tick and needs no config. The note is one line, at most 200 characters, and must pass the same
PII pattern list as a Verdict. An ALERT finding needs `--alert`. Resolving the same finding twice is a
no-op; `unresolve <id>` removes one.

A later Tick drops a finding when ALL hold: same realm; same rule (`rule_id`, case-insensitive; a `lead`
matches on evidence alone, since its `rule_id` is reworded text); severity not higher; every evidence id
is already in the resolved set. A new id, another realm or rule, or an escalation still posts. Title is
ignored. The script drops it, not the agent, and the state is recomputed.

- All findings dropped: an `OK` thread reply, "only cases already marked resolved (n)".
- Some dropped: the post carries one extra line with the count.
- The dropped findings are kept under `suppressed` in the Verdict file and shown by `brief`.
- Expiry: 7 days; 1 day when every evidence id is a `metric` or `config` (an aggregate names no
  occurrence, so it would repeat every Tick). At most 200 entries. `resolved.json` survives retention.
- Count findings that cite fresh sample trace ids each Tick are not matched. A routine pattern belongs
  in the Playbook's known routine, not in a resolution.

## Files (git-ignored, under `agent_logs/night-watch/`)

- `state.json`: counters, the day's parent message, learned `baselines` and `notes`. A corrupt file is
  kept as `state.json.corrupt-<time>` and the watch starts fresh.
- `ticks.log`: one line per Tick (`<slot> <state> <headline or reason> [ts=...]`); the same line is echoed to stderr.
- `verdicts/<slot>.json`: the Verdict, or the raw agent output of a FAILED Tick.
- `tick.lock`: held while a Tick runs.
- `resolved.json`: the active Resolved cases. A corrupt file is kept as `resolved.json.corrupt-<time>`
  and treated as empty. `resolved.lock`: held for milliseconds while `resolve`/`unresolve` write.

Files older than 7 days are deleted at the end of each Tick, except `state.json`, `tick.lock`,
`ticks.log` and `resolved.json`. Links and directories are never followed or removed.

## Limits

- `caffeinate` (macOS) blocks idle sleep, but a closed lid on battery still sleeps: expect gap lines.
- A DST change can skip one slot (shown as a gap line); the same slot never runs twice.
- `--json-schema` is passed to the CLI but is not enforced by it, so the script extracts the fenced
  JSON from the result and validates it itself. An invalid Verdict is a FAILED Tick.
- The Tick agent's Edit/Write on `agent_logs/night-watch/` and its engine commands (`run.sh`,
  `night_watch.py`) are disallowed; resolutions are read before the agent runs, so a write during a
  Tick changes nothing. `resolve` records no identity: anyone with a shell on the machine can run it.
- Test seams (selftest only): `NIGHT_WATCH_NOW`, `NIGHT_WATCH_CLAUDE`, `NIGHT_WATCH_TIMEOUT_SEC`,
  `NIGHT_WATCH_ALERT_REPEAT_SEC`, `NIGHT_WATCH_PROD_ALLOWED`.
