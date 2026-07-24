---
name: prod-pg-triage
description: >-
  Use this to get ground truth from the real OFB PRODUCTION Postgres data — read-only —
  instead of guessing from code, memory, or a local/staging copy. Trigger for: a reported
  player or agency symptom that only production data can confirm (wrong balance, bad payout,
  missing/duplicate transaction, wrong status, misconfigured site/theme, out-of-sync
  aggregator mapping); any which-shard-is-this-agency/player-on or MAD-vs-shard question —
  the fleet is one master (MAD) plus 16 hex shards (0-f), a topology only production has; a
  direct ask to look up, grab, verify, or compare a specific row, count, or config value in
  prod, a named shard, or across the fleet; or grounding another skill plan/fix with a real
  production DB fact. One on-demand, read-only MCP covers the whole fleet and always
  disconnects when done — it never writes or migrates. Do NOT use for local/dev DB
  (postgres_ass/postgres_mad), staging, schema migrations (agent-db), or logs/traces
  (telemetry-triage).
argument-hint: "[symptom / agency_id / shard hex / table / ticket-key]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + SQL + commit messages + branch names, and technical / domain terms + proper nouns (`agency_id`, shard names, `MAD`, Arabic numerals) stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# Prod PG Triage

Production data is the **ground truth** for a data bug — what a balance, transaction, or
agency row *actually* is in prod, not what the code says it should be. This skill reads that
truth through a read-only MCP and lands on a finding. It is the DB sibling of
`telemetry-triage` (which does the same for SigNoz logs/traces).

The whole session is **read-only and reversible-by-nature**: no writes, no migrations, and a
`disconnect` at the end so nothing lingers against prod.

## Preflight — is the prod MCP available?

The `prod_pg_triage` MCP is **opt-in and personal** — deliberately not in the shared
`.mcp.json`, so it only exists on a machine that has been set up with read-only prod
credentials. Before anything else, check that its tools are present (e.g. call
`list_targets`).

If the `mcp__prod_pg_triage__*` tools are **missing**, stop and tell the user to do the
one-time setup — do not improvise another route to prod:

> The prod-pg-triage MCP isn't registered in this session. One-time setup (see
> `scripts/db/README.md`): copy `scripts/db/.env.example` → `scripts/db/.env`, fill in the
> **read-only** DSNs, then
> `claude mcp add prod_pg_triage --scope local -- uv run --quiet "$(pwd)/scripts/db/prod_pg_mcp.py"`
> and restart the session.

This is a fail-loud gate on purpose: silently falling back to the local `postgres_*` MCPs
would answer a prod question with dev data and mislead the whole investigation.

## Safety — non-negotiable

- **Read-only, always.** Only `SELECT` / `WITH` / `TABLE` / `VALUES` (via `execute_sql`) and
  `EXPLAIN` (via `explain_query`). The server + read-only role reject writes, but do not try
  them — you are investigating, not changing prod.
- **`explain_query(analyze=True)` actually runs the query.** Leave `analyze` off unless you
  specifically need real timings; a plan (`analyze=False`) is free.
- **Production data is sensitive — know the egress line.** What may leave the prod boundary
  into a ticket / Slack: **inner-system identity** (`player_code` / `site_code` / any `*_code`,
  internal UUID), an **aggregate** (`COUNT(*)` / `GROUP BY` — prefer this), the **reproduce
  SQL**, and money integers. What may **not**: **external-world PII in value form** — phone,
  email, crypto wallet, IBAN / bank account, national-id / passport. The tracker adapter's
  egress gate (`tracker_assert_no_pii`, backed by `scripts/lib/pii-patterns.txt`) **hard-blocks**
  a ticket body carrying that PII; treat a block as a signal to re-state as an aggregate, not
  something to override. Prefer a single targeted row over `SELECT *` on a wide table.
- **Confirm the target before a heavy query.** A cross-shard scan is 16 queries against
  prod; be deliberate about whether you need MAD, one shard, or a fan-out.

## Choosing the target

Every data tool takes **`target`** or **`agency_id`** (exactly one):

- **`target="mad"`** — the master DB. Explicit only; it is never resolved from an agency id,
  so shard traffic can't accidentally hit the master.
- **`target="<hex>"`** — a specific shard, `0`–`f`.
- **`agency_id="<id>"`** — resolves to the shard = the **first character** of the agency id.
  Use `resolve_shard` first if you want to confirm the mapping before querying.

**Which one?** If the question is scoped to an agency/player, pass `agency_id` and let it
resolve. If it's about master/global data, use `mad`. If you must compare a record across
the fleet, fan out over shards `0`–`f` explicitly and say so — don't pretend one shard is
the whole picture.

**Resolving a target from a `player_code`.** OFB `player_code`s begin with their 5-char
**`site_code`** — e.g. `GC78900000021` → site `GC789` (`ABCDE00000001` → `ABCDE`). When you
only have a player_code and need the shard, resolve that site to its `agency_id` (the
`master_site` registry on `mad` maps sites to agencies), then the shard is `agency_id[0]` as
above. This beats a blind 16-shard fan-out — reach for the fan-out only when the site/agency
genuinely can't be resolved.

## Workflow

1. **Resolve language** (above) and **preflight** the MCP.
2. **Frame the question** as a data question with a clear target: which agency/shard or MAD,
   which table(s), what would confirm or refute the hypothesis.
3. **Orient** with the metadata tools when you don't know the schema: `list_schemas` →
   `list_objects` → `get_object_details`. Cheap, read-only.
4. **Query** with `execute_sql`. Start narrow (a `COUNT`, a single keyed row) before pulling
   sets. Add `ORDER BY` so pagination is stable, and page through with `page` / `page_size`
   when `has_more` is true.
5. **Check the plan** with `explain_query` if a query is slow or you're unsure it's indexed
   — plan-only first.
6. **Interpret**: state what the data shows and the finding (root cause / confirmation /
   refutation), tied to the specific target and rows you saw. If it grounds a ticket or fix,
   hand that off — this skill does not write code or change prod.
7. **Teardown**: call `disconnect` to close every prod pool. Always do this when the
   investigation is done — it leaves zero open connections to prod.

## Persisting to a local repro (developer, `/diagnosing-bugs` only)
Reading prod here is transient and read-only. If a bug needs the *actual* rows reproduced
against local source, that is a **developer** step inside `/diagnosing-bugs`, and the only
sanctioned way to move prod-derived data onto local disk is **`scripts/db/prod_repro_seed.py`**
— it masks external PII, is entity-scoped, and loads into a **throwaway `ofb_repro_<KEY>` DB**
that `--teardown` DROPs wholesale. Never hand-craft local `INSERT`s from prod values. Investigation
agents (e.g. `performance-triage`) do **not** seed — they read, find, and hand the fix off.

## Reporting

Keep it tight and evidence-led:

```
# Finding — <one line>
- Target(s): <mad | shard hex | agencies…>
- What the data shows: <the decisive rows/counts, PII-safe>
- Root cause / conclusion: <…>
- Next step: <ticket / fix handoff / further query>  (or: no action)
```

**Amounts are scaled ×1,000,000.** OFB stores currency as integers with 6 implied decimal
places — a stored `100000000` is `100`, `1000000` is `1`. Divide a raw amount by `1e6` and
name the unit before quoting a human-facing figure (balances, `bet`/`payout`, `turnover`,
transaction `amount`, …); never present the raw integer as the money value.

Post to a ticket/Slack only through the normal adapters, and only the PII-safe summary —
never a raw dump of production rows.
