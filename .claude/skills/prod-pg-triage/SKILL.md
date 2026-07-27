---
name: prod-pg-triage
description: >-
  Use this to get ground truth from the real PRODUCTION Postgres data — read-only — instead
  of guessing from code, memory, or a local/staging copy. Trigger for: a reported symptom that
  only production data can confirm (wrong balance, bad amount, missing/duplicate record, wrong
  status, misconfigured row); a direct ask to look up, grab, verify, or compare a specific row,
  count, or config value in prod or across several configured databases; or grounding another
  skill plan/fix with a real production DB fact. One on-demand, read-only MCP covers every
  configured target and always disconnects when done — it never writes or migrates. Do NOT use
  for the local/dev DB (postgres_main/postgres_secondary), staging, schema migrations, or
  logs/traces.
argument-hint: "[symptom / target / table / ticket-key]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + SQL + commit messages + branch names, and technical / domain terms + proper nouns stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# Prod PG Triage

Production data is the **ground truth** for a data bug — what a balance, transaction, or
config row *actually* is in prod, not what the code says it should be. This skill reads that
truth through a read-only MCP and lands on a finding.

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
  into a ticket / Slack: **inner-system identity** (any `*_code`, internal UUID), an
  **aggregate** (`COUNT(*)` / `GROUP BY` — prefer this), the **reproduce SQL**, and money
  integers. What may **not**: **external-world PII in value form** — phone, email, crypto
  wallet, IBAN / bank account, national-id / passport, and a person's name. Every row this MCP
  returns is fingerprinted into the provenance vault, so the tracker / notify adapters
  **redact exactly those values** (to `<prod-pii:…>`) if they surface in a ticket or a chat
  post — the write still lands, minus the personal value. Do not lean on that: a redacted body
  reads worse than one you wrote as an aggregate in the first place. It also only covers what
  the MCP actually returned, so anything you retype from memory is on you. Prefer a single
  targeted row over `SELECT *` on a wide table. See `docs/agents/pii-provenance.md`.
- **Confirm the target before a heavy query.** Fanning out across every configured target is a
  query per target; be deliberate about whether you need one target or the fan-out.

## Choosing the target

Every data tool takes **`target`** — a name you configured via `PGPROD_<NAME>` in the `.env`
(see `scripts/db/README.md`): `target="main"`, `target="secondary"`, or any name you declared.
Use `list_targets` to see what is configured.

There is **no sharding scheme baked in** — a target is just a database. If your data is split
across several databases, each is its own target (`target="shard0"`, …); to compare a record
across them, query each explicitly and say you did — don't pretend one database is the whole
picture. When you only have an inner-system identifier (e.g. a `*_code`) and don't know which
target holds it, resolve it from whatever registry your schema uses before a blind fan-out.

## Workflow

1. **Resolve language** (above) and **preflight** the MCP.
2. **Frame the question** as a data question with a clear target: which database, which
   table(s), what would confirm or refute the hypothesis.
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
— it masks external PII, is entity-scoped, and loads into a **throwaway `repro_<KEY>` DB**
that `--teardown` DROPs wholesale. Never hand-craft local `INSERT`s from prod values.
Investigation agents (e.g. `performance-triage`) do **not** seed — they read, find, and hand
the fix off.

## Reporting

Keep it tight and evidence-led:

```
# Finding — <one line>
- Target(s): <the target name(s) you queried>
- What the data shows: <the decisive rows/counts, PII-safe>
- Root cause / conclusion: <…>
- Next step: <ticket / fix handoff / further query>  (or: no action)
```

**Watch the money scale.** If your schema stores currency as a fixed-point integer (e.g. an
amount scaled by a fixed number of decimal places), divide by that scale and name the unit
before quoting a human-facing figure (balances, amounts, transaction values, …); never present
the raw integer as the money value.

Post to a ticket/Slack only through the normal adapters, and only the PII-safe summary —
never a raw dump of production rows.
