---
name: prod-redis-triage
description: >-
  Use this to get ground truth from the real PRODUCTION (or staging) Redis — read-only — instead
  of guessing from code, memory, or a local copy. Trigger for: a cache/session symptom only the
  live keyspace can confirm (a cached value that disagrees with the database, a session or token
  that should exist and doesn't, a key with the wrong TTL, a rate-limit or idempotency key that
  blocks a request); a Redis **Stream** question — stream entries, or a consumer group lagging,
  stalled, or holding pending entries; a direct ask to look up, verify, or compare a specific
  key, TTL, stream entry, or sorted-set score in prod or staging; or grounding another skill's
  plan/fix with a real Redis fact. One on-demand MCP owns its own SSH tunnel and always
  disconnects when done — it never writes, expires, or trims. Do NOT use for a local dev Redis
  (`mcp__redis`), for Postgres rows (prod-pg-triage), or for logs/traces.
argument-hint: "[symptom / key or pattern / stream name / ticket-key]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + key names + commit messages + branch names, and technical / domain terms + proper nouns (`PEL`, stream names, Arabic numerals) stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# Prod Redis Triage

Redis holds the state that is *true right now* — caches, sessions and tokens, rate limits, and
the Stream backbone your services read. When a symptom is "the number is stale", "the event
never arrived", or "the session vanished", the live keyspace is the **ground truth**; the code
only says what should have been written. This skill reads that truth through a read-only MCP and
lands on a finding. It is the cache/stream sibling of `prod-pg-triage` (rows).

## Preflight

Check the tools are present (`list_targets`). If `mcp__prod_redis_triage__*` is **missing**,
stop and tell the user to set it up — do not improvise another route to a deployed Redis (no
`gcloud`, no `redis-cli`, and never a local `mcp__redis`, which points at `localhost:6379` and
would answer a production question with dev data):

> The prod-redis-triage MCP isn't registered in this session. One-time setup (see
> `scripts/redis/README.md`): declare your targets in `scripts/redis/.env`, set
> `prod_triage.enabled: true` in `workspace.config.local.yaml`, run
> `scripts/prod-triage-mcp.sh sync`, and restart the session.

If `list_targets` returns **no targets**, the `.env` is missing or empty — same fix, and say so
rather than guessing a target name.

## Safety — non-negotiable

- **Read-only, and the tool surface IS the guarantee.** Redis has no read-only role and no
  read-only transaction, and a managed Redis commonly exposes neither an ACL user nor a
  read-only replica — so unlike Postgres, nothing server-side stops a write. What stops it is
  that only typed read tools exist: no command passthrough, an attribute allow-list on the
  client, and a source scan in `--selftest`. Do not ask for a command that isn't a tool; the
  answer is that it deliberately doesn't exist.
- **An O(N) read is an outage.** Redis is single-threaded: one `KEYS *` blocks every user.
  `KEYS` is absent — use `scan_keys` (bounded, cursor-based). Always `inspect_key` before a
  bulk read; `hgetall_fields` / `set_members` refuse above 1000 elements and name the cursor
  tool to use instead.
- **A `prod=true` target masks credentials at the source.** A value that is a credential by key
  name or by shape comes back as `<redis-secret:sha8>`. The digest is stable, so "same token"
  vs "different token" and "exists" vs "missing" are all still answerable — that is nearly
  always the actual question. A `prod=false` target (a staging box) returns raw values.
- **Know the egress line.** What may leave into a ticket / chat: key names, inner-system
  identity (any `*_code`, UUID), TTLs, counts, stream ids, group lag, amounts, and the masked
  digest. What may **not**: external-world PII in value form (phone, email, crypto wallet, bank
  account, national id, a person's name) and any unmasked credential. Every value a `prod=true`
  target returns is fingerprinted into the provenance vault, so the tracker / notify adapters
  redact exactly those values at egress — don't lean on it; prefer a count or a masked digest in
  the first place. See `docs/agents/pii-provenance.md`.
- **Watch the money scale.** If your services cache amounts as fixed-point integers, divide by
  that scale and name the unit before quoting a figure — a raw cached integer is not the money
  value.

## Choosing the target

`target` is required — one of the names configured in `scripts/redis/.env` (`list_targets` shows
them). There is no default, so **a production target is only ever reached by asking for it**.
Reach for a staging target when the question is about a bug you can reproduce there; production
when only production state can settle it.

`cluster_topology` states what the reached node actually covers. With cluster mode enabled and
more than one master it reports `coverage: PARTIAL` — then `scan_keys` and `dbsize` are
*node-scoped* ("not found" does not mean "absent"), and a key on another shard answers with a
redirection error naming the owning node. `keyslot_of` resolves which shard a key belongs to; a
`{…}` hash tag in a key pins a whole family to one slot.

## The keyspace

Key **names** are inner-system identity and safe to quote; values are what needs care. Learn the
namespaces before guessing: `dbsize`, then `scan_keys "*"`, then `scan_keys "<prefix>:*"`.

Typical shapes, and where each tends to hide a bug:

| Kind | Read with | Typical bug |
|---|---|---|
| cached read-model (`cache:*`, a per-entity key) | `get_value`, `hgetall_fields` | stale, or disagrees with the DB row |
| session / token (`session:*`, `*token*`) | `inspect_key` (TTL!), `get_value` | missing, expired early, or never refreshed |
| Streams + consumer groups | `stream_info` → `stream_groups` → `stream_range` | producer fine, consumer lagging or wedged |
| counters / sorted sets (leaderboards, quotas) | `zset_score`, `zset_range` | drifted from the source of truth |
| rate limit / idempotency | `inspect_key`, `get_value` | a stuck key blocking a legitimate request |

> **Adopting this skill:** replace the table above with *your* namespaces — the actual prefixes,
> stream names and consumer groups your services use. A named keyspace is what turns this from a
> generic Redis browser into a triage tool.

## Workflow

1. **Resolve language**, then **preflight**.
2. **Frame the question against a key**, not a hunch: which pattern, which target, and what
   value/TTL/count would confirm or refute the hypothesis. If you can't name a key pattern,
   `scan_keys` a namespace first.
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

Reading here is transient. Production Redis values **never** get persisted locally — not by
hand, not by copying a value out of a result. Two sanctioned routes, in order:

1. **Fix forward with a test.** Take the *shape* you observed (type, field names, TTL, the
   malformed payload's structure) into a unit/integration test in the repo, then fix against
   that. Most cache and serialization bugs end here and need no live state.
2. **`capture_shape` → `scripts/redis/replay_shape.py`** when the repro genuinely needs keys in
   a local Redis. What crosses the boundary is a schema — types, TTLs, cardinalities, field
   names, value *kinds* — with every value synthesized inside the MCP; the replay writes them
   into LOCAL Redis only, under one `repro:<label>:` prefix, and tears them down by that prefix.

Consumer-group state is the honest exception: a PEL entry's delivery count and idle time are
server-side history that no replay can recreate. For a wedged-consumer bug, read the live group
(`stream_groups`, `stream_pending`, `stream_consumers`) and fix forward.

## Reporting

```
# Finding — <one line>
- Target: <target name>  ·  Keys read: <the exact keys/patterns>
- What the keyspace shows: <decisive values / TTLs / counts / group lag — PII-safe>
- Root cause / conclusion: <…>
- Next step: <ticket / fix handoff / further read>  (or: no action)
```

Post to a ticket or chat only through the normal adapters, and only the PII-safe summary — never
a raw dump of production values.
