---
name: pg-triage
description: >-
  Use this to get ground truth from the real OFB DEPLOYED Postgres — PRODUCTION or STAGING,
  read-only — instead of guessing from code, memory, or a local copy. Trigger for: a reported
  player or agency symptom that only deployed data can confirm (wrong balance, bad payout,
  missing/duplicate transaction, wrong status, misconfigured site/theme, out-of-sync
  aggregator mapping); any which-shard-is-this-agency/player-on or MAD-vs-shard question —
  the fleet is one master (MAD) plus 16 hex shards (0-f), a topology no local DB has; a
  direct ask to look up, grab, verify, or compare a specific row, count, or config value in
  prod or staging, a named shard, or across the fleet; checking what a migration or a deploy
  actually did to the STAGING data; or grounding another skill plan/fix with a real deployed
  DB fact. One on-demand, read-only MCP covers both environments and always disconnects when
  done — it never writes or migrates. Do NOT use for the local/dev DB
  (postgres_ass/postgres_mad), schema migrations (agent-db), logs/traces (telemetry-triage),
  or cache / session / Redis-Stream state (redis-triage).
argument-hint: "[symptom / agency_id / shard hex / table / ticket-key] [staging|prod]"
---

## Output language — resolve BEFORE writing (do this FIRST)

**A `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line already in your prompt is AUTHORITATIVE — obey it verbatim, do NOT re-resolve over it.** Otherwise, as your FIRST action, resolve it: read `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a `language:` line, else `workspace.config.yaml` — never from memory — and state the resolved value + source in one line before producing output.

When the resolved language is **`th`**, write your **prose** — the finding, ticket/PR comments, chat, Slack — in **Thai with an English spine**: titles + every heading + labels/enum values, ALL code + identifiers + SQL + commit messages + branch names, and technical / domain terms + proper nouns (`agency_id`, shard names, `MAD`, Arabic numerals) stay English; the sentences themselves are Thai. **Code, checked-in repo docs, and ANY file you author with a `.md` extension** are **never** Thai. Default **`en`** = unchanged. Full policy: `docs/agents/language.md`.

# PG Triage — staging + production

Deployed data is the **ground truth** for a data bug — what a balance, transaction, or agency row
*actually* is on the server, not what the code says it should be. This skill reads that truth
through a read-only MCP and lands on a finding. It is the DB sibling of `telemetry-triage` (which
does the same for SigNoz logs/traces).

One MCP covers **two environments**, chosen per call: `env="staging"` and `env="prod"`. Which one
answers the question is the first thing to settle (see **Choosing the environment**).

The whole session is **read-only and reversible-by-nature**: no writes, no migrations, and a
`disconnect` at the end so nothing lingers.

## Preflight — is the MCP available?

The `pg_triage` MCP lives in **local scope**, deliberately not in the shared `.mcp.json`. It is
registered on every machine by `aiworks sync`, but the DSNs are per-machine. Before anything else,
check that its tools are present and what is configured — call `list_targets`, which also reports
`prod_allowed`.

If the `mcp__pg_triage__*` tools are **missing**, stop and tell the user to do the one-time setup
— do not improvise another route:

> The pg-triage MCP isn't registered in this session. Setup (see `scripts/db/README.md`): copy
> `scripts/db/.env.example` → `scripts/db/.env`, fill in the **read-only** DSNs (`PGSTG_DSN` for
> staging, `PGPROD_*` for prod), run `scripts/triage-mcp.sh sync`, and restart the session.

If a **prod** call comes back with a `triage.prod` PermissionError, that machine has not opted in
to production. Do not reroute to another path or quietly answer from staging instead — say which
environment you can reach and ask:

> Production is off on this machine (`triage.prod`). Add `triage: {prod: true}` to
> `workspace.config.local.yaml` (takes effect immediately, no restart) — or tell me to answer
> from **staging**, which is reachable now but is NOT the same data.

This is a fail-loud gate on purpose: silently falling back to the local `postgres_*` MCPs — or to
staging when the question was about prod — would answer with the wrong data and mislead the whole
investigation.

## Safety — non-negotiable

- **Read-only, always.** Only `SELECT` / `WITH` / `TABLE` / `VALUES` (via `execute_sql`) and
  `EXPLAIN` (via `explain_query`). The server + read-only role reject writes, but do not try
  them — you are investigating, not changing anything. This holds for **staging too**: the DSN is
  a read-only role there as well, and a "quick fix" through this MCP is not a thing.
- **`explain_query(analyze=True)` actually runs the query.** Leave `analyze` off unless you
  specifically need real timings; a plan (`analyze=False`) is free.
- **Always say which environment a finding came from.** Every result carries `env`; every claim
  you make must name it (`prod`, or `staging`). "The balance is 0" with no environment is the one
  failure mode this tool exists to prevent.
- **Production data is sensitive — know the egress line.** What may leave the prod boundary
  into a ticket / Slack: **inner-system identity** (`player_code` / `site_code` / any `*_code`,
  internal UUID), an **aggregate** (`COUNT(*)` / `GROUP BY` — prefer this), the **reproduce
  SQL**, and money integers. What may **not**: **external-world PII in value form** — phone,
  email, crypto wallet, IBAN / bank account, national-id / passport, and a person's name.
  Every row a **prod** target returns is fingerprinted into the provenance vault, so the tracker /
  notify adapters **redact exactly those values** (to `<prod-pii:…>`) if they surface in a
  ticket or a Slack post — the write still lands, minus the personal value. Do not lean on
  that: a redacted body reads worse than one you wrote as an aggregate in the first place.
  It also only covers what the MCP actually returned, so anything you retype from memory is
  on you. Prefer a single targeted row over `SELECT *` on a wide table.
  See `docs/agents/pii-provenance.md`.
- **Staging rows are NOT vaulted** (`pii_vaulted: false` in every staging result) — staging is not
  the prod boundary, so its values pass into tickets and Slack as-is. That is deliberate, and it
  also means you own the judgement there: don't paste a staging dump into a ticket just because
  nothing would stop you. One wrinkle to expect: a value production already vaulted stays masked
  at egress even when you read it from staging, because the vault is keyed by value — if a
  legitimately-staging value comes out as `<prod-pii:…>`, that is why (`PII_GATE=off` on that one
  command is the escape hatch).
- **Confirm env + target before a heavy query.** A cross-shard scan is 16 queries; be deliberate
  about whether you need MAD, one shard, or a fan-out — and prefer staging for anything
  exploratory that staging can answer.

## Choosing the environment

Every data tool takes **`env`** — `"staging"` or `"prod"`, **required**, never defaulted (an
omitted `env` is an error, so prod is never reached by accident).

- **`env="prod"`** — the question is about what really happened to a real player, agency, or
  payout. Needs the machine's `triage.prod` opt-in.
- **`env="staging"`** — the question is about a build, a migration, a seeded scenario, or a bug
  reported on the staging site; or you are exploring schema/shape and staging answers it just as
  well. No opt-in, no PII vaulting, cheaper to be wrong.

**Which one?** Match the environment where the symptom was observed — never "the one that is
easier to reach". If a report doesn't say, ask before touching prod. If you answered from staging
because prod was unavailable, say so in the finding rather than presenting it as prod truth.
Staging topology is one instance holding one database per target (names come from `.env`), so the
same `target` selectors work unchanged — `list_targets` shows the resolved database per target.

## Choosing the target

Every data tool also takes **`target`** or **`agency_id`** (exactly one):

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
2. **Frame the question** as a data question with a clear **environment** and target: staging or
   prod, which agency/shard or MAD, which table(s), what would confirm or refute the hypothesis.
3. **Orient** with the metadata tools when you don't know the schema: `list_schemas` →
   `list_objects` → `get_object_details`. Cheap, read-only — and free of consequence on staging.
4. **Query** with `execute_sql`. Start narrow (a `COUNT`, a single keyed row) before pulling
   sets. Add `ORDER BY` so pagination is stable, and page through with `page` / `page_size`
   when `has_more` is true.
5. **Check the plan** with `explain_query` if a query is slow or you're unsure it's indexed
   — plan-only first.
6. **Interpret**: state what the data shows and the finding (root cause / confirmation /
   refutation), tied to the specific **env**, target, and rows you saw. If it grounds a ticket or
   fix, hand that off — this skill does not write code or change any environment.
7. **Teardown**: call `disconnect` to close every pool (both envs). Always do this when the
   investigation is done — it leaves zero open connections.

## Persisting to a local repro (developer, `/diagnosing-bugs` only)
Reading here is transient and read-only. If a bug needs the *actual* rows reproduced against local
source, that is a **developer** step inside `/diagnosing-bugs`, and the only sanctioned way to move
deployed data onto local disk is **`scripts/db/prod_repro_seed.py`** — its spec names the source
`env`, it is entity-scoped, and it loads into a **throwaway `ofb_repro_<KEY>` DB** that
`--teardown` DROPs wholesale. A `prod` source is masked + vaulted; a `staging` source loads
verbatim. Never hand-craft local `INSERT`s from deployed values. Investigation agents (e.g.
`oncall`) do **not** seed — they read, find, and hand the fix off.

## Reporting

Keep it tight and evidence-led:

```
# Finding — <one line>
- Environment: <prod | staging>            ← never omit; a finding without it is unusable
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
never a raw dump of deployed rows, and always labelled with the environment it came from.
