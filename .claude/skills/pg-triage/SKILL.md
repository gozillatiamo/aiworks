---
name: pg-triage
description: >-
  Use this to get ground truth from the real DEPLOYED Postgres — PRODUCTION or STAGING,
  read-only — instead of guessing from code, memory, or a local copy. Trigger for: a reported
  symptom that only deployed data can confirm (wrong balance, bad amount, missing/duplicate
  record, wrong status, misconfigured row); a direct ask to look up, grab, verify, or compare a
  specific row, count, or config value in prod or staging, or across several configured
  databases; checking what a migration or a deploy actually did to the STAGING data; or
  grounding another skill plan/fix with a real deployed DB fact. One on-demand, read-only MCP
  covers both environments and always disconnects when done — it never writes or migrates. Do
  NOT use for the local/dev DB (postgres_main/postgres_secondary), schema migrations,
  logs/traces, or cache / session / Redis-Stream state (redis-triage).
argument-hint: "[symptom / target / table / ticket-key] [staging|prod]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + SQL + commit messages + branch names, and technical / domain terms + proper nouns stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# PG Triage — staging + production

Deployed data is the **ground truth** for a data bug — what a balance, transaction, or config row
*actually* is on the server, not what the code says it should be. This skill reads that truth
through a read-only MCP and lands on a finding.

One MCP covers **two environments**, chosen per call: `env="staging"` and `env="prod"`. Which one
answers the question is the first thing to settle (see **Choosing the environment**).

The whole session is **read-only and reversible-by-nature**: no writes, no migrations, and a
`disconnect` at the end so nothing lingers.

## Preflight — is the MCP available?

The `pg_triage` MCP lives in **local scope**, deliberately not in the shared `.mcp.json`. It is
registered by `scripts/triage-mcp.sh sync`, which each person runs themselves (`aiworks sync` does
not — `docs/adr/0009`), and the DSNs are per-machine too. Before anything else,
check that its tools are present and what is configured — call `list_targets`, which also reports
`prod_allowed` and, when tunnel sidecars are declared, `tunnel_open` per target.

If the `mcp__pg_triage__*` tools are **missing**, stop and tell the user to do the
one-time setup — do not improvise another route to prod:

> The pg-triage MCP isn't registered in this session. Setup (see `scripts/db/README.md`): copy
> `scripts/db/.env.example` → `scripts/db/.env`, fill in the **read-only** DSNs (`PGSTG_*` for
> staging, `PGPROD_*` for prod), run `scripts/triage-mcp.sh sync`, and restart the session.


If a **prod** call comes back with a `triage.prod` PermissionError, that machine has not opted in to
production. Do not reroute to another path or quietly answer from staging instead — say which
environment you can reach and ask:

> Production is off on this machine (`triage.prod`). Add `triage: {prod: true}` to
> `workspace.config.local.yaml` (takes effect immediately, no restart) — or tell me to answer from
> **staging**, which is reachable now but is NOT the same data.

This is a fail-loud gate on purpose: silently falling back to the local `postgres_*` MCPs
would answer a prod question with dev data and mislead the whole investigation.

## Safety — non-negotiable

- **Always say which environment a finding came from.** Every result carries `env`; every claim you
  make must name it (`prod`, or `staging`). "The balance is 0" with no environment is the one
  failure mode this tool exists to prevent.
- **Staging rows are NOT vaulted** (`pii_vaulted: false` in every staging result) — staging is not
  the production boundary, so its values pass into tickets and chat as-is. That is deliberate, and
  it also means you own the judgement there. One wrinkle to expect: a value production already
  vaulted stays masked at egress even when read from staging, because the vault is keyed by value —
  if a legitimately-staging value comes out as `<prod-pii:…>`, that is why (`PII_GATE=off` on that
  one command is the escape hatch).
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

## Choosing the environment

Every data tool takes **`env`** — `"staging"` or `"prod"`, **required**, never defaulted (an omitted
`env` is an error, so prod is never reached by accident).

- **`env="prod"`** — the question is about what really happened to real data. Needs the machine's
  `triage.prod` opt-in.
- **`env="staging"`** — the question is about a build, a migration, a seeded scenario, or a bug
  reported on staging; or you are exploring schema/shape and staging answers it just as well. No
  opt-in, no PII vaulting, cheaper to be wrong.

**Which one?** Match the environment where the symptom was observed — never "the one that is easier
to reach". If a report doesn't say, ask before touching prod. If you answered from staging because
prod was unavailable, say so in the finding rather than presenting it as prod truth.

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
7. **Teardown**: call `disconnect` to close every prod pool **and any open tunnel sidecars**.
   Always do this when the investigation is done — it leaves zero open connections to prod and
   zero tunnel processes. Call `tunnel_status` afterwards to confirm the local port was released.

## Persisting to a local repro (developer, `/diagnosing-bugs` only)
Reading prod here is transient and read-only. If a bug needs the *actual* rows reproduced
against local source, that is a **developer** step inside `/diagnosing-bugs`, and the only
sanctioned way to move prod-derived data onto local disk is **`scripts/db/prod_repro_seed.py`**
— it masks external PII, is entity-scoped, and loads into a **throwaway `repro_<KEY>` DB**
that `--teardown` DROPs wholesale. Never hand-craft local `INSERT`s from prod values.
Investigation agents (e.g. `oncall`) do **not** seed — they read, find, and hand
the fix off.

## Tunnel sidecars

Some targets require a `gcloud compute ssh` port-forward because the Postgres host is inside a
VPC. These are declared in `scripts/db/.env` as `PGPROD_<NAME>_TUNNEL=...` sidecars. When one
is configured, the MCP opens and manages the tunnel automatically — you do not need a `gcloud`
grant.

- **`list_targets`** includes `tunnel_open` per entry when a sidecar is declared.
- **`tunnel_status`** shows open tunnels, pid, idle time and time-to-reap mid-session.
- **`disconnect`** closes both pools and tunnels and returns a `tunnels_closed` key.

**Port-in-use failure:** if `127.0.0.1:<local>` is already listening when the MCP tries to
open a tunnel, the call fails with a clear error naming `scripts/db/tunnel.sh status|kill`.
This means a previous session's tunnel is orphaned. The remedy is human-only:

```bash
scripts/db/tunnel.sh status     # see what is open
scripts/db/tunnel.sh kill       # clear orphans
```

This script is not granted to agents. See `docs/adr/0017`.

## Reporting

Keep it tight and evidence-led:

```
# Finding — <one line>
- Environment: <prod | staging>            ← never omit; a finding without it is unusable
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
