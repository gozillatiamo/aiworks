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
`scripts/db/tunnel.sh status|kill` as the human remedy. (Narrowed for `tunnel=gost` by the
adoption addendum below: an identified gost is adopted for connecting, never for killing.)

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

## Addendum — `tunnel=gost` (SOCKS proxy, one shared process)

Some fleets reach production Postgres only through a local SOCKS5 proxy, `gost -C gost.yaml`.
The sidecar gained a second kind, `tunnel=gost;local=<port>`, declared beside the DSN exactly
like `gcloud`. The path to that config is operator configuration — `PG_TRIAGE_GOST_CONFIG` in
`scripts/db/.env` (absolute, or relative to the workspace root) — never a path baked into the
framework.

- **What the sidecar carries.** Only `local` — the `gost.yaml` service port that serves the
  target. Hosts stay in `gost.yaml`; `host`/`port`/`vm`/`zone`/`project`/`iap` are rejected for
  gost so the same fact never lives in two files.
- **One process, many holders.** gost binds every service port at once, so the MCP runs ONE
  `gost -C <PG_TRIAGE_GOST_CONFIG>` (fixed argv, no tool input reaches it; cwd = that file's
  directory) and every gost target holds a `Tunnel` on that shared process. The per-target
  lifecycle (lazy open, idle reap, `disconnect`, `_close_all`) is unchanged; gost itself is
  terminated only when the LAST holder closes, and a stale holder from a crashed generation
  never kills a newer process.
- **Port rule refined.** gcloud ports unique; gost ports may repeat (two targets per host) but
  must not overlap gcloud ports; nothing on 5432. No adoption (superseded for an identified
  gost — see the adoption addendum below): any `gost.yaml` port already listening refuses the
  spawn and names `scripts/db/tunnel.sh status|kill`.
- **Preflight is loud.** `gost` missing from `PATH` prints a `!!!` banner with `brew install gost`
  and the README section; `PG_TRIAGE_GOST_CONFIG` unset or naming a missing file, `socks.auth`
  missing beside it (existence only — never opened) and an undeclared `local` port are reported
  the same way, in `--selftest`, `--verify` and at runtime. A prod target with no sidecar gets a
  non-failing `WARN` (hard enforcement deferred).
- **Why generalise `gcloud_tunnel.py` rather than a sibling module.** Every MCP call site speaks
  only `open_tunnel` / `close_tunnel` / `is_alive` on a per-target `Tunnel`; dispatching on
  `spec.kind` inside those keeps the MCP diff to one condition plus display, and the module name
  is already cited here and in `tunnel.sh`.

## Addendum — an identified gost is adopted for connecting, never for killing

**Context.** "Port safety" refuses any tunnel the framework did not open, and the gost addendum
applied that to every `gost.yaml` port. But the setup guide tells a person to run gost by hand
(for a GUI client or `psql`) and to leave it running. With that process up, every gost target
refused, so a person had to choose between their own manual access and the MCP. The refusal
protected against two things: a listener that "may point somewhere else entirely", and the MCP
later stopping a process it does not own. Only the second needs an absolute rule.

**Decision.** For `tunnel=gost` only, a running gost is ADOPTED — used, never started or stopped
— when the process table proves it is the gost for this config: ONE process listens on
127.0.0.1 on EVERY declared port, its command is `gost`, it runs as this user, its `-C` argument
resolves (against its own cwd) to the file `PG_TRIAGE_GOST_CONFIG` names, it started after that
file last changed, and it is not an orphan of an earlier MCP session (ppid 1 with the MCP's own
absolute argv). The check reads `lsof`/`ps` only: nothing is sent to the ports, because a connect
to gost dials prod upstream. Any failed condition refuses exactly as before, naming the failed
condition and `scripts/db/tunnel.sh status|kill`. `tunnel=gcloud` is unchanged — it has no
config the process could be checked against.

**Never for killing.** An adopted `Tunnel` holds no process handle (`proc=None`, `adopted_pid` set)
and never joins the shared-gost holder count; `close_tunnel` returns on it before touching any
process. Every MCP teardown path — `disconnect`, the idle reaper, `_close_all` at exit or signal,
the dead-tunnel branch — goes through `close_tunnel`, so none of them can stop it; the selftest
proves it for each live path. Releasing an adopted target drops only the MCP's pool. Liveness is a
signal-0 existence probe of the pid, never a connect.

**Visibility.** `tunnel_status` reports `owner: self | adopted` with the real pid and a `teardown`
sentence; `disconnect` lists adopted targets under `adopted_left_running`; `tunnel.sh status` labels
each gost `MCP-owned | MCP orphan | manual | detached manual`, and `tunnel.sh kill` spares a manual
one.

**What is not proven.** Process identity is not far-end identity: gost's `tcp` handler accepts before
it dials, so neither an adopted nor a self-spawned gost proves the SOCKS path or the database behind
it. That proof is the DSN's own `sslmode=verify-full`. No protocol probe was added — psycopg's first
connect already is one.

**Supersedes.** "Port safety" and the gost addendum's "No adoption" bullet, for an identified gost
only. Everything else they say stands.

## Addendum — the shard role is declared, never baked in

**Context.** Some fleets split one logical database across up to sixteen physical ones, keyed
by a single hex digit `0`–`f`, and route a record to its database by the first character of a
routing key. The triage tools are more useful when they can follow that route themselves —
`target="a"`, `resolve_shard(routing_key)` — but a framework that *assumed* the sixteen-way,
first-character scheme would be wrong for every fleet that does not use it, and silently so.

**Decision.** The shard role is **opt-in, by declaration**, in the same `.env` the DSNs live in:

- a **shard token** in the var name — `PGPROD_SHARD_<HEX>` or `PGPROD_<LABEL>_SHARD_<HEX>`,
  `<LABEL>` free-form; or
- a **shard sidecar** beside a named var — `PGPROD_<NAME>_SHARD=<hex>` — for a var whose name
  cannot change. Refused on a name that already carries the token.

Either yields the target key `shard_<hex>`; `list_targets` reports `kind: shard` and the var
that backs it. A var with neither is a **named target**, exactly as before. Declare nothing and
nothing changes — `list_targets` for a shard-free `.env` is identical except for the additive
`kind: named`.

**Fail closed on a conflict.** Two vars claiming one hex is not resolved by precedence: the
shard reads as *unconfigured*, `list_targets` carries `conflict: [vars]` for it, `--selftest`
FAILs the file, and `resolve_shard` says so. A guess here would answer a production question
from the wrong database.

**The one keyspace assumption.** `resolve_shard(routing_key)` — first character, hex — is the
only place the framework assumes how records are keyed. It engages only once a shard is
declared, and a routing key outside `0`–`f` is refused, not defaulted. Anything else (a master,
a fleet size, a padding of undeclared shards) is deliberately absent.

**Staging.** One pattern, `PGSTG_DB_SHARD_FMT` (default `shard_%s`), names the staging database
of every shard target — not sixteen `PGSTG_DB_SHARD_<HEX>` lines. An explicit `PGSTG_DB_<NAME>`
still wins.

**Migration.** A var that ended in `_SHARD_<hex>` or `_SHARD` used to be an ordinary named
target and is now a declaration; `--selftest`'s file report names every key it reinterprets.
