# Triage MCPs cover every deployed environment; only production is gated

**Status:** Accepted

The workspace has two read-only triage MCP servers: one over Postgres (`scripts/db/`), one over
Redis and its Streams (`scripts/redis/`). They exist so an investigation can be grounded in what a
running system actually holds instead of what the code suggests it should.

Redis already reached any target you declared, production or not — `prod=<bool>` per target, chosen
per call. Postgres reached production only. Meanwhile a single flag, `prod_triage.enabled` (default
off), decided whether **either** server was registered at all. Adding staging to Postgres forced the
question that flag had been answering by accident: what is actually being authorized — running a
server, or touching production?

## Staging is not the thing that needs authorizing

The original flag existed for cost, not safety. An agent host spawns every enabled stdio server in
every session, and prod triage is occasional work, so a shared registration would have cost every
teammate an idle process and a screenful of tool names. That reasoning is sound about *spawning* and
says nothing about *access*: neither server can write anything, and the connection/tunnel is lazy,
so an idle server holds nothing.

Access is where the two environments genuinely differ. A staging read touches non-production data by
definition — nothing to authorize, nobody to notify, no PII boundary to respect. A production read
touches real people's data. Gating both behind one flag meant a teammate could not look at staging
without first being handed production, which is exactly backwards.

So the policy splits in two:

    triage:
      enabled: true    # registration — default ON, because staging needs no authorization
      prod: false      # PRODUCTION access — default OFF, per machine

`enabled: false` remains for anyone who wants neither server in their sessions; it is now the
exception rather than the price of entry.

## The production gate lives inside the servers, not in the registration

`triage.prod` could have been enforced at registration time — the reconcile script reads the config
already, and passing an env var at `mcp add` time would have needed no new code. It is enforced
in-process instead (`scripts/lib/triage_policy.py`, read local-first, cached on mtime), because a
registration-time flag freezes into the host's MCP config: editing the YAML would then change
nothing until someone re-ran sync *and* restarted the session, and until they did, the file that
claims to own the policy would disagree with the process enforcing it. Reading it live means the
config is the single source of truth and flipping it takes effect on the next call.

Both servers check it at the one place a connection comes into existence — `_pool()` for Postgres,
`_connect()` for Redis — before the DSN is looked up or the tunnel is spawned. Credentials sitting in
a `.env`, or an IAM role that can reach the box, is not permission. `prod_repro_seed.py` checks the
same gate, since it reads production through the same DSNs without going through the MCP.

The pre-0005 key `prod_triage.enabled` is **removed, with no fallback**. Honouring it would let a
stale personal file decide production access, which is the one thing this ADR is about; instead
`scripts/triage-mcp.sh` reports a leftover copy loudly and the servers name the new key in the error
they raise.

## The names lost their `prod_` prefix

`prod_pg_triage` and `prod_redis_triage` were accurate when production was all they reached. With
the environment selected per call, the prefix describes the riskier half of a two-environment tool,
and a name that overstates its scope is the kind of thing people stop reading. They are now
`pg_triage` and `redis_triage` (files `pg_triage_mcp.py`, `redis_triage_mcp.py`; skills `pg-triage`,
`redis-triage`; script `scripts/triage-mcp.sh`).

The safety the old name was doing is now done by mechanism rather than by connotation: `env` has no
default, so a Postgres call that does not name its environment is an error; every result carries
`env` and `pii_vaulted`; and production is refused outright without the opt-in.
`scripts/triage-mcp.sh sync` deregisters the old names on machines that carry them, so nobody ends up
running two servers over the same fleet.

Environment variable names in a `.env` were deliberately **not** renamed. Those files cannot be read
back by an agent (the `.env` guard) or reviewed in a diff, so a renamed variable would fail as a
silent "unconfigured" on every teammate's machine. `PGPROD_<NAME>` keeps its meaning, and staging
adds `PGSTG_<NAME>` — or a single `PGSTG_DSN` for the common case below.

## Staging Postgres gets a one-instance shortcut, and its data is not PII

A production fleet is usually several hosts, so prod stays one DSN per target. Staging is commonly
the opposite: one instance holding a database per target. Writing one near-identical DSN per target,
differing only in dbname, would be noise in a file nobody may open to check — so `PGSTG_DSN` sets
the instance once, the database defaults to the target name, and `PGSTG_DB_<NAME>` overrides it where
it differs. A per-target `PGSTG_<NAME>` still wins, so a staging split across hosts is unchanged.
That resolution lives in `scripts/lib/pg_staging.py` rather than in either tool, because the triage
MCP and the repro seeder must resolve it identically — two copies would let the seeder pull from a
database the triage read never touched.

PII provenance stays **production-only**, on purpose. The vault is what makes egress redaction
prod-specific: a personal value is masked in a ticket or a chat post if and only if production is
where it came from, which is what lets local and staging work continue untouched. Vaulting staging
values would start masking data that is not personal-in-the-prod-sense and erode the property the
whole design rests on. So a staging read is neither masked nor vaulted, `prod_repro_seed.py` loads a
staging source verbatim, and both surfaces say so (`pii_vaulted: false`).

One consequence is worth stating rather than discovering: the vault is keyed by **value**, so a value
production already fingerprinted stays masked at egress even when it is read from staging. That is
the correct behaviour for a value that is genuinely personal, and `PII_GATE=off` on a single command
is the escape hatch when it is not.
