---
name: prod-redis-triage
description: >-
  Use this to get ground truth from the real OFB PRODUCTION (or staging) Redis — read-only —
  instead of guessing from code, memory, or a local copy. Trigger for: a cache/session symptom
  only the live keyspace can confirm (stale or wrong `user_balance`, stale `game:*` /
  `ranked_games:*` cache, a session or agent token that should exist and doesn't, a key with
  the wrong TTL, a `rate_limit:*` or `idemp:hash` that blocks a request); a Redis **Stream**
  question — `bet_stream` / `daily_checkin_stream` / `lotto_transaction_stream` /
  `refund_raindrop` entries, or a consumer group (campaign-sub, live-sub, bet-aggregator)
  lagging, stalled, or holding pending entries; a direct ask to look up, verify, or compare a
  specific key, TTL, stream entry, or leaderboard score in prod or staging; or grounding
  another skill's plan/fix with a real Redis fact. One on-demand MCP owns its own SSH tunnel
  and always disconnects when done — it never writes, expires, or trims. Do NOT use for the
  local dev Redis (`mcp__redis`), for Postgres rows (prod-pg-triage), or for logs/traces
  (telemetry-triage).
argument-hint: "[symptom / key or pattern / stream name / ticket-key]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + key names + commit messages + branch names, and technical / domain terms + proper nouns (`bet_stream`, `player_code`, `PEL`, Arabic numerals) stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# Prod Redis Triage

Redis is where OFB keeps the state that is *true right now* — cached balances, sessions and
tokens, rate limits, and the Stream backbone every subscriber reads. When a symptom is "the
number is stale", "the event never arrived", or "the session vanished", the live keyspace is
the **ground truth**; the code only says what should have been written. This skill reads that
truth through a read-only MCP and lands on a finding. It is the cache/stream sibling of
`prod-pg-triage` (rows) and `telemetry-triage` (logs/traces).

## Preflight

Check the tools are present (`list_targets`). If `mcp__prod_redis_triage__*` is **missing**,
stop and tell the user to register it — do not improvise another route to a deployed Redis
(no `gcloud`, no `redis-cli`, and never the local `mcp__redis`, which points at
`localhost:6379` and would answer a prod question with dev data):

> The prod-redis-triage MCP isn't registered in this session. One-time setup (see
> `scripts/redis/README.md`): `gcloud auth login`, then set `prod_triage.enabled: true` in
> `workspace.config.local.yaml` and run `scripts/prod-triage-mcp.sh sync`, and restart the
> session.

## Safety — non-negotiable

- **Read-only, and the tool surface IS the guarantee.** This fleet has no ACL user and no
  read-only replica, so — unlike Postgres, which has a read-only role — nothing server-side
  stops a write. What stops it is that only typed read tools exist: no command passthrough, an
  attribute allow-list on the client, and a source scan in `--selftest`. Do not ask for a
  command that isn't a tool; the answer is that it deliberately doesn't exist.
- **An O(N) read is an outage.** Redis is single-threaded: one `KEYS *` blocks every player.
  `KEYS` is absent — use `scan_keys` (bounded, cursor-based). Always `inspect_key` before a
  bulk read; `hgetall_fields` / `set_members` refuse above 1000 elements and name the cursor
  tool to use instead.
- **Prod masks credentials at the source.** On `target="prod"`, a value that is a credential
  by key name or by shape comes back as `<redis-secret:sha8>`. The digest is stable, so
  "same token" vs "different token" and "exists" vs "missing" are all still answerable — that
  is nearly always the actual question. On `target="staging"` values are raw: staging is not
  the prod boundary.
- **Know the egress line.** What may leave into a ticket / Slack: key names, inner-system
  identity (`player_code` / `site_code` / any `*_code`, UUID, `agency_id`), TTLs, counts,
  stream ids, group lag, money integers, and the masked digest. What may **not**:
  external-world PII in value form (phone, email, crypto wallet, bank account, national id,
  a person's name) and any unmasked credential. Every prod value this MCP returns is
  fingerprinted into the provenance vault, so the tracker / notify adapters redact exactly
  those values at egress — don't lean on it; prefer a count or a masked digest in the first
  place. See `docs/agents/pii-provenance.md`.
- **Amounts are scaled ×1,000,000.** A cached `user_balance:*` of `100000000` is `100`. Divide
  by `1e6` and name the unit before quoting a figure.

## Choosing the target

`target` is required — `"staging"` or `"prod"`. There is no default, so **prod is only ever
reached by asking for it**. Reach for `staging` when the question is about a bug you can
reproduce there; `prod` when only production state can settle it.

Both targets run cluster mode enabled with a **single master**, so one forwarded node covers
the whole keyspace. Should that ever change, `cluster_topology` reports `coverage: PARTIAL`
and a key on another shard answers with a redirection error naming the owning node — in that
case `scan_keys` and `dbsize` are *node-scoped*, and "not found" does not mean "absent".

## The keyspace

Key **names** are inner-system identity and safe to quote; values are what needs care.

| Pattern | Holds |
|---|---|
| `bet_stream`, `daily_checkin_stream`, `lotto_transaction_stream`, `refund_raindrop` | Streams + consumer groups — bet-aggregator produces, campaign-sub / live-sub consume |
| `user_balance:<player>`, `aggregator_txn_bucket:…` | cached balance / transaction buckets (×1e6) |
| `game:<id>`, `game:<a>:<b>`, `ranked_games:*`, `provider_games_ranking:*`, `player_game:*` | game-lib cache |
| `token:{agent:<id>}:*`, `agent_tokens:{agent:<id>}`, `sso:*`, `init_password:*`, `init_secondary_password:*`, `player_auth_username:*` | auth + credentials — **masked on prod** |
| `site:<id>:package`, `site_code:<code>:package`, `site_provider:*` | site/package config |
| `rate_limit:*`, `idemp:hash` | rate limiting, idempotency |
| `live:<id>:viewer`, `raindrop:*`, `active_daily_checkin:*`, `active_wheel_of_fortune:*`, `user_daily_checkin_progress:*`, `wheel_of_fortune_eligibility:*` | live + campaign state |

A `{…}` in a key is a **hash tag**: it pins a whole family (every `token:{agent:X}:*`) to one
slot. `keyslot_of` resolves it.

## Workflow

1. **Resolve language**, then **preflight**.
2. **Frame the question against a key**, not a hunch: which pattern, which target, and what
   value/TTL/count would confirm or refute the hypothesis. If you can't name a key pattern,
   `scan_keys` a namespace from the table first.
3. **Orient** — `dbsize`, `scan_keys "<pattern>"`, then `inspect_key` on the candidates. Done
   when you know each key's type, TTL and cardinality; that is what decides which reader is
   safe to call next.
4. **Read** the narrowest thing that answers it: one field (`hget_field`), one member
   (`set_is_member`), one score (`zset_score`) beats a bulk read. For a stream, go
   `stream_info` → `stream_groups` (lag + pending per group) → `stream_range` (tail first) →
   `stream_consumers` / `stream_pending` when a group is stuck.
5. **Interpret** — state what the keyspace shows and the finding, tied to the exact keys you
   read. A TTL and an absence are findings too: a key that is *gone* explains as much as a key
   that is wrong.
6. **Teardown** — call `disconnect`. The watchdog also kills any tunnel idle past 120s, so a
   forgotten session self-closes; calling it is still how you leave zero connections
   deliberately rather than eventually.

## Reproducing locally

Reading here is transient. Prod Redis values **never** get persisted locally — not by hand,
not by copying a value out of a result. Two sanctioned routes, in order:

1. **Fix forward with a test.** Take the *shape* you observed (type, field names, TTL, the
   malformed payload's structure) into a unit/integration test in the repo, then fix against
   that. Most cache and serialization bugs end here and need no live state.
2. **`capture_shape` → `scripts/redis/replay_shape.py`** when the repro genuinely needs keys
   in a local Redis. What crosses the boundary is a schema — types, TTLs, cardinalities, field
   names, value *kinds* — with every value synthesized inside the MCP; the replay writes them
   into LOCAL Redis only, under one `repro:<label>:` prefix, and tears them down by that
   prefix.

Consumer-group state is the honest exception: a PEL entry's delivery count and idle time are
server-side history that no replay can recreate. For a wedged-consumer bug, read the live
group (`stream_groups`, `stream_pending`, `stream_consumers`) and fix forward.

## Reporting

```
# Finding — <one line>
- Target: <prod | staging>  ·  Keys read: <the exact keys/patterns>
- What the keyspace shows: <decisive values / TTLs / counts / group lag — PII-safe>
- Root cause / conclusion: <…>
- Next step: <ticket / fix handoff / further read>  (or: no action)
```

Post to a ticket or Slack only through the normal adapters, and only the PII-safe summary —
never a raw dump of production values.
