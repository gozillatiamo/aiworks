# ADR 0017 — Triage tunnels are declared beside the DSN

**Status:** accepted  
**Date:** 2026-08-16  
**Cited by:** `scripts/db/pg_triage_mcp.py`, `scripts/lib/gcloud_tunnel.py`, `scripts/db/tunnel.sh`  
**Cites:** [ADR 0005](0005-deployed-env-triage-and-the-prod-gate.md) (the prod gate + no-rename rule)

---

## Context

A managed Postgres instance is usually unreachable from a developer's laptop — the host is
inside a VPC, behind a load balancer, or simply not exposed on a public IP. `redis_triage`
already solves an identical problem by owning its own `gcloud compute ssh -N -L` port-forward;
`pg_triage` had no equivalent, making a tunnelled target silently unusable.

The shape of the problem is the same across both tools, and the solution should be consistent.
Two options were considered for expressing the tunnel configuration:

**Option A — overload the DSN.** Encode the tunnel parameters inside the connection string
(e.g. as query-string keys: `?tunnel=gcloud&vm=bastion&local=15432`).

**Option B — a sidecar variable beside the DSN** (`PGPROD_MAIN_TUNNEL` beside
`PGPROD_MAIN`).

Option A was rejected:

1. **A DSN is an opaque string a human writes into a file that no agent may ever read back.**
   ADR 0005 names the constraint: env-var *names* must never be renamed because an agent
   cannot read the file back to verify — and overloading the DSN value has the same
   unreadability property as a rename. A tunnel shape embedded in the DSN is invisible to
   every reader of the config: `tunnel.sh`, operators, and the MCP itself.
2. **`tunnel.sh` needs structured access.** The human-side status/kill script (`tunnel.sh`)
   must be able to awk out the local port and VM name without parsing a full PostgreSQL
   connection string. A separate sidecar variable with a simple `key=value;key=value` format is
   directly awk-able.
3. **The sidecar is additive.** `PGPROD_MAIN` keeps its exact meaning; the sidecar is opt-in.
   ADR 0005's no-rename rule is not triggered.

## Decision

A named target may declare an optional tunnel sidecar as a companion variable:

```
PGPROD_<NAME>=postgresql://...  # existing DSN — unchanged
PGPROD_<NAME>_TUNNEL=tunnel=gcloud;host=<remote-host>;port=5432;local=<local-port>;vm=<vm>[;zone=<z>][;project=<p>][;iap=true]
```

Staging uses the same pattern (`PGSTG_<NAME>_TUNNEL`).

### Why the framework only port-forwards

The framework spawns `gcloud compute ssh <vm> --tunnel-through-iap -- -N -L ...`. The trailing
`--` makes everything after it SSH flags, not a remote command. The framework explicitly does NOT:

- Run a remote command (`docker exec`, a remote shell, a `ProxyCommand`)
- Accept a `--` operand from user input (the `argv()` function in `gcloud_tunnel.py` builds a
  list, never a shell string, so no tool argument can reach the command line)

This makes the tunnel a read-only gateway with no code-execution surface.

### Why the helper is shared but the Redis migration is deferred

`scripts/lib/gcloud_tunnel.py` is the shared tunnel helper. It is `stdlib-only` so both
`pg_triage_mcp.py` and `redis_triage_mcp.py` can import it without carrying each other's
third-party dependencies (`psycopg`, `redis`).

Migrating `redis_triage_mcp.py` onto the helper was deliberately excluded from this change set:
the migration is a pure refactor with no user-visible change, it was not part of the ticket, and
it carries its own risk surface (the Redis readiness probe is a PING, not a TCP connect). The
`gcloud_tunnel.open_tunnel` `ready=` parameter exists so that migration is a later deletion, not
a rewrite.

A `ponytail:` comment in `scripts/db/tunnel.sh` records the deliberate duplication with
`scripts/redis/tunnel.sh` and the condition that collapses it, so `/ponytail-debt` can harvest it.

### The prod gate ordering

Per ADR 0005, the production gate (`triage_policy.assert_prod_allowed`) fires at the **one place
a connection comes into existence** — `_pool()` in `pg_triage_mcp.py` — **before** the DSN is
looked up and before any tunnel is spawned. Having credentials present (the DSN) is not
permission; and a reachable box (the tunnel) is also not permission. The gate remains the first
check inside `_pool()`.

### Enumeration hazard

`PGPROD_<NAME>_TUNNEL` and `PGSTG_<NAME>_TUNNEL` share the target-variable prefix. Without a
filter, they show up as phantom targets named `main_tunnel` in `list_targets` and `--selftest`.
Both `_configured_targets()` in `pg_triage_mcp.py` and `configured_targets()` in
`pg_staging.py` skip any key ending with `_TUNNEL`. The consequence is stated in
`scripts/db/.env.example`: **a target may not be named `…_tunnel`**, the same class of
limitation `pg_staging.RESERVED` already documents for the name `dsn`.

### Port safety

The framework refuses to adopt a tunnel it did not open (ADR 0005 principle: credentials being
present is not permission — this extends to reachability). If `127.0.0.1:<local_port>` is
already listening, `gcloud_tunnel.open_tunnel` raises immediately, naming
`scripts/db/tunnel.sh status|kill` as the human remedy.

The `--selftest` guards two additional invariants: local ports must be unique across all
configured specs (two specs sharing a port would race), and no spec may use port 5432 (the
conventional local dev Postgres — a production query answered by local dev data is a
data-integrity hazard).

## Consequences

- A new `tunnel_status` MCP tool is granted to `oncall` alongside the other `pg_triage` tools.
- `scripts/db/tunnel.sh` is the human-side complement — NOT granted to any agent (a different
  `--` operand to `gcloud compute ssh` is a shell on the production VM).
- A hard-killed session can orphan a pg tunnel. `atexit`/SIGTERM handle a clean exit; a
  `.claude/hooks/` SessionEnd generalisation is deferred (see plan §6). Manual remedy:
  `scripts/db/tunnel.sh kill`.
- No new key in `workspace.config*.yaml`; no new Python dependency in either MCP.
