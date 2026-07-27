# scripts/redis — production Redis, read-only

`prod_redis_mcp.py` is an **on-demand, read-only MCP server** over your **production** (and
staging) Redis. One process serves as many targets as you configure; which one a tool touches is
chosen **per call** by a `target` argument, and there is **no default** — a production target is
only ever reached by naming it.

It is the cache/stream counterpart of `scripts/db/` (Postgres rows): ground-truth live state for
root-causing an issue, read-only, with a clean teardown. The driving skill is `prod-redis-triage`
(`.claude/skills/prod-redis-triage/`).

A managed Redis is usually not reachable from a laptop, so **the server owns its own SSH
tunnel** — or skips it, with `tunnel=none`, when you already have a route.

## Targets

Declared in `scripts/redis/.env`, one variable per target (see `.env.example`), addressed as
`target="<name>"`:

```
REDISPROD_<NAME>=host=<addr>;port=6379;local=<port>;prod=<bool>;tunnel=gcloud;vm=<vm>;zone=<zone>
```

| Key | Meaning |
|---|---|
| `host` · `port` | the Redis as seen from the tunnel host (or from you, with `tunnel=none`) |
| `local` | the loopback port to forward to — **never 6379**, which is normally your LOCAL dev Redis; shadowing it would answer a production question with dev data |
| `prod` | `true` (default) ⇒ credential masking + PII provenance · `false` ⇒ a staging box, values as-is |
| `tunnel` | `gcloud` (default) ⇒ the server runs `gcloud compute ssh <vm> --zone=<zone> -- -N -L …` · `none` ⇒ already reachable |

Nothing in that file is a credential — the access gate is your cloud IAM / network — but it is
per-machine on purpose: a machine with no `.env` has no targets, which is the opt-in.

## Setup (one-time, per machine)

```bash
cp scripts/redis/.env.example scripts/redis/.env    # declare your targets (git-ignored)
gcloud auth login                                   # only for tunnel=gcloud targets
uv run scripts/redis/prod_redis_mcp.py --selftest   # deps + guards + your target specs, no network
```

Then opt in with one line in your personal, git-ignored `workspace.config.local.yaml` and let
`aiworks` register the server for you (it does the same for `prod_pg_triage`):

```yaml
prod_triage:
  enabled: true
```

```bash
./aiworks setup                          # or, on its own: scripts/prod-triage-mcp.sh sync
scripts/prod-triage-mcp.sh status        # policy + what is registered
```

Restart the session so it connects; the `mcp__prod_redis_triage__*` tools then appear. Flipping
the flag back to `false` and re-running deregisters it again.

It is deliberately **not** in the shared `.mcp.json`. Claude Code spawns every enabled stdio
server at session start, so a shared entry would run this process (~13 MB, idle) and put its
whole tool surface in front of every teammate in every session, for a tool a given person uses a
handful of times a month. Nothing about that spawn is dangerous — the tunnel is lazy, so an idle server
holds zero connections and never invokes `gcloud` — it is simply cost with no payer. The flag is
read **local-first**, so opting in is per person and the shared default stays off.

By hand, if you prefer (what the script runs):

```bash
claude mcp add prod_redis_triage --scope local -- uv run --quiet "$(pwd)/scripts/redis/prod_redis_mcp.py"
claude mcp remove prod_redis_triage --scope local
```

Auto mode also needs the authorization paragraph in your personal settings — see **Prod triage
authorization** in the root [`README.md`](../../README.md).

## Tools

Typed read tools only. There is no `execute_command`, and no write-shaped command exists.

| Tool | Purpose |
|---|---|
| `list_targets` · `tunnel_status` · `disconnect` | session control: what is configured, what is open, teardown |
| `cluster_topology` · `keyslot_of` | whether cluster mode is on, what the reached node covers, which slot owns a key |
| `server_info` · `dbsize` | `INFO <section>` (section required), key count on the forwarded node |
| `scan_keys` · `inspect_key` | bounded SCAN by pattern; a key's type/TTL/cardinality/encoding/memory |
| `get_value` | string value, truncated, credential-masked on prod |
| `hget_field` · `hgetall_fields` · `hscan_fields` | one field, the whole hash (guarded), or a cursor page |
| `list_length` · `list_range` | list size and a 200-element page |
| `set_card` · `set_is_member` · `set_members` · `set_scan` | set size, membership, whole set (guarded), cursor page |
| `zset_card` · `zset_score` · `zset_range` | sorted-set size, one member's score+rank, a page with scores |
| `stream_length` · `stream_range` · `stream_info` · `stream_groups` · `stream_consumers` · `stream_pending` | Streams and consumer groups: tail entries, lag, PEL summary, per-consumer idle |
| `capture_shape` | a key's *shape* with synthesized values, for a local repro (see below) |

Every data tool takes `target` (`staging` | `prod`) and an optional `db` (default 0).

## Safety model (all layers are client-side — deliberately)

Redis offers no read-only role and no read-only transaction, and a managed Redis commonly
exposes neither an ACL user you can scope to `+@read` nor a read-only replica. So unlike
`prod_pg_mcp.py` — whose guarantee is a read-only DB role — nothing server-side stops a write
here. Every layer below *is* the guarantee, not a convenience on top of one. (If your Redis
*does* offer an ACL user or a replica, point the target at it — that is a real server-side
guarantee and strictly better than any of these.)

1. **Typed read tools only.** No command passthrough, so an arbitrary command string never
   reaches Redis. The read-looking commands that actually write (`GETDEL`, `GETEX`, `SPOP`,
   `LPOP`, `SORT … STORE`, `XREADGROUP`, `XAUTOCLAIM`, `EVAL`, `MIGRATE`, `RESTORE`, `COPY`,
   `SWAPDB`) have no route to the wire. `CLUSTER` is a subcommand dispatcher, so its
   subcommands are allow-listed too — `CLUSTER RESET` is rejected.
2. **A client proxy allow-list** checked at attribute access, so a careless future edit inside a
   tool still cannot call `.set` / `.delete` / `.xadd`.
3. **`--selftest` scans this file's own source** for write-command call sites — the regression
   guard for layers 1 and 2, plus masking unit cases and the "no default target" rule.
4. **Availability guards**, because an O(N) read on a single-threaded server is an outage:
   `KEYS` is absent entirely (bounded `SCAN` instead, ≤10 iterations, ≤200 keys per call), a
   cardinality check refuses a bulk read above 1000 elements and names the cursor tool, results
   page at 200, and every connection carries a 15s socket timeout plus a
   `claude-redis-triage-<user>` client name so ops can see and kill it.
5. **Secret masking at the source, on `prod=true` targets.** A value that is a credential by
   key name (`*token*`, `*session*`, `*auth*`, `*secret*`, `*password*`, …) or by shape (JWT,
   long hex, opaque base64) is returned as `<redis-secret:sha8>`. The digest is stable, so
   "same token / different token / missing" is still answerable; inside a JSON payload the
   decision is per FIELD, so the inner-system ids and amounts around it stay readable. A
   `prod=false` target returns raw values.
6. **Provenance.** Prod values are fingerprinted into the vault
   (`scripts/lib/pii_provenance.py`), so the tracker/notify adapters redact exactly those values
   at egress and leave identical-looking staging/local data alone
   (`docs/agents/pii-provenance.md`).
7. **The tunnel closes itself.** Lazy: no tunnel exists until the first call for a target. A
   watchdog kills any tunnel idle for 120s; `disconnect` closes on demand; atexit/SIGTERM close
   on exit; a `SessionEnd` hook (`.claude/hooks/prod-redis-tunnel-reap.sh`) reaps an orphan left
   by a hard-killed session. "Must disconnect when done" is mechanical, not remembered.

The agent is never granted `gcloud`. That is on purpose: `gcloud compute ssh <vm> -- <command>`
is a shell on the production VM, so the tunnel lives inside this server, where the argv is built
from the parsed target spec and no tool argument can reach the command line.

## Verifying it

```bash
uv run scripts/redis/prod_redis_mcp.py --selftest            # guards + masking, no network
uv run scripts/redis/prod_redis_mcp.py --verify <target>     # live read-only acceptance run
uv run scripts/redis/prod_redis_mcp.py --verify <target> --verify-idle   # + prove the watchdog reaps
uv run scripts/redis/prod_redis_mcp.py --smoke <target>      # 3 cheap reads, then teardown
PROD_REDIS_FORCE_MASK=1 uv run scripts/redis/prod_redis_mcp.py --verify <staging-target>   # exercise the prod masking path without prod
```

`tunnel.sh` is the human's view of the tunnels — deliberately **not** granted to agents:

```bash
scripts/redis/tunnel.sh status          # what is open, or "nothing open"
scripts/redis/tunnel.sh kill [<target>…]
```

## Local repro — `replay_shape.py`

There is **no seed tool for Redis, on purpose**. Unlike a historical Postgres row, cache and
stream state is largely reconstructible by running the service, and copying a live session or
agent token onto local disk would spread a credential to widen a repro. So the order is:

1. **Fix forward with a test** — take the observed shape into a unit/integration test. Most
   cache and serialization bugs end here.
2. **`capture_shape` → `replay_shape.py`** when the repro genuinely needs keys present. What
   crosses the boundary is a *schema* (types, TTLs, cardinalities, field names, value kinds)
   with every value synthesized inside the MCP; the replay writes only to **loopback** Redis,
   under one `repro:<label>:` prefix, and tears down by that prefix.

```bash
uv run scripts/redis/replay_shape.py --selftest
uv run scripts/redis/replay_shape.py --shape shape.json --label APP-123 --dry-run
uv run scripts/redis/replay_shape.py --shape shape.json --label APP-123
uv run scripts/redis/replay_shape.py --label APP-123 --teardown
```

A consumer group's pending-entry history (delivery counts, idle times) is server-side and cannot
be replayed. For a wedged-consumer bug, read the live group and fix forward.
