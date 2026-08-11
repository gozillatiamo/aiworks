# Cloud Monitoring triage adapter

Read-only access to GCP Cloud Monitoring, for the one question the other triage servers cannot
answer: what was the **managed resource underneath our services** doing? Memorystore, Cloud SQL,
GKE nodes and containers, load balancers — things GCP runs for us and we therefore cannot
instrument ourselves.

| file | what it is |
|---|---|
| `monitoring_triage_mcp.py` | the MCP server — read-only, staging + prod |
| `metric-catalog.json` | the curated shortlist per resource type: what to read first, and why |

There is no bootstrap script here. The identity this server uses is the **same one** the
Kubernetes server uses, created and granted by `scripts/k8s/bootstrap-sa.sh`, and diagnosed by
`scripts/k8s/setup.sh`. See [why](#why-it-shares-the-kubernetes-identity).

## Where it sits among the triage servers

SigNoz shows what our code did. This shows what the infrastructure did while our code waited.

The case that motivated it: a hot write path's latency degraded every night during the traffic
peak. Traces proved the cache `XADD` **executed in 12 µs** while the call took **190–215 ms**, and
that the database spans in the same trace never moved. Our own instrumentation had gone as far as
it could — it could prove the time was not being spent inside anything we wrote, but not where it
went.

The answer was CPU pressure on the managed cache. Note *which* answer, because the first guess was
wrong: we expected a burstable tier pinned at its ceiling, and the measurement showed 71% mean /
82.5% max — heavily queued, never capped. Queueing under load, not throttling against a limit.
Those need different fixes, and only the metric tells them apart.

That shape generalizes: **a plateau our spans cannot explain is an infrastructure question.**

## Why it shares the Kubernetes identity

`k8s-triage@<project>.iam.gserviceaccount.com` already exists per project, is reached only by
**impersonation** (no key file exists anywhere), and is already bootstrapped by a human who owns
the project. Giving it `roles/monitoring.viewer` alongside `roles/container.clusterViewer` costs
one more role binding. A second service account would cost a second bootstrap ceremony, a second
`serviceAccountTokenCreator` grant per teammate, and a second thing to diagnose — all for the
same trust boundary, since both roles are viewers.

Read-only is enforced by **Google**, not by this file: a write is refused by the API before it
reaches a resource. The code shape backs that up — there is one GET builder, no method parameter,
and no caller-supplied URL, which `--selftest` asserts on every run.

## Targets are configured, not derived

The Kubernetes server derives its targets from the kubeconfig, because GKE writes
`gke_<project>_<region>_<cluster>` identically on every machine. A Cloud Monitoring scope has no
such fingerprint — it is a bare project id — so it is declared once as org data:

```yaml
monitoring:
  targets:
    app/staging: my-project-123456
    app/prod: my-project-123456
```

The `<env>` half of the key is what the **production gate** reads. An `.../prod` target is
refused until `triage.prod` is true on this machine (`scripts/lib/triage_policy.py`); staging
needs no opt-in. There is no second flag — `triage.prod` governs every triage server.
One project holding both environments is normal; the two keys still gate differently.

## The correctness contract

Cloud Monitoring's failure mode is not an error. Name the wrong aligner or pass a naive timestamp
and it returns a **plausible number for a different question**. Two things are therefore decided
by the server, not the caller:

- **Time is unambiguous or refused.** Epoch milliseconds, or ISO-8601 carrying an offset. A bare
  `2026-08-10T22:00:00` is rejected — read as local time under Asia/Bangkok it would shift the
  window seven hours and answer confidently about the wrong hours. (We have been bitten by
  exactly this: `scripts/observability/find-traces.sh` does read ISO-8601 as local.)
- **The aligner is derived from the metric's own descriptor.** Counter → `ALIGN_RATE`.
  Distribution → `ALIGN_PERCENTILE_99`. Level → `ALIGN_MEAN`. Anything whose type reads as a
  utilization or ratio → **`ALIGN_MAX`**, because a ceiling held for twenty minutes of an hour
  averages away to nothing, and saturation is the question these metrics are usually asked.

Every result echoes the resolved UTC window, the aligner, the reason it was chosen, and the
alignment period. Quote a number without reading those and you are guessing.

Output is bounded (`MAX_SERIES`, `MAX_POINTS`, `MAX_DESCRIPTORS`) and anything dropped is
reported as `truncated` / `returned`, so a partial answer can never read as a complete one.

## The catalog

`metric-catalog.json` holds the short list worth reading first per resource type we actually run,
with what each number would mean if it moved — judgement the API cannot supply. `list_metrics`
says what *exists*; the catalog says what *matters*.

Keep it short. It is a shortcut, never a limit: anything absent is still reachable through
discovery, which is the whole reason the tools are generic over resource type instead of one tool
per GCP service. An exhaustive hand-maintained catalog would be stale the week after it was
written.

A metric type in the catalog is a best-known name, not a guarantee — Google renames and splits
metric families between service generations. A wrong type is safe: `read_timeseries` resolves the
descriptor first, so it fails loudly instead of returning the wrong number. When one errors, fall
back to `list_metrics` on the prefix.

## Checks

```sh
uv run scripts/monitoring/monitoring_triage_mcp.py --selftest              # deps, targets, policy, source scan
uv run scripts/monitoring/monitoring_triage_mcp.py --verify app/staging    # live read-only acceptance run
```

`--selftest` needs no GCP access: it proves the config parses, the targets resolve, the policy is
wired, the time contract refuses what it must, the aligner logic picks correctly, and — the
regression guard — that no write verb is constructed anywhere in the source.

`--verify` mints a token and performs real reads against one target. Run it after
`bootstrap-sa.sh` to prove the grant landed.

`scripts/k8s/setup.sh` — the doctor for this shared identity — probes `roles/monitoring.viewer`
alongside the cluster role, so a project bootstrapped before `docs/adr/0010` reports the missing
grant instead of reading as ready. `bootstrap-sa.sh` skips roles that are already granted, so the
re-run that fixes it only adds the new one.

## Related

- `docs/adr/0005` — the triage servers and the production gate
- `docs/adr/0007` — why triage uses a separate read-only identity
- `docs/adr/0010` — extending that identity to Cloud Monitoring, and the correctness contract
- `scripts/k8s/README.md` — the sibling adapter, and the bootstrap that serves both
