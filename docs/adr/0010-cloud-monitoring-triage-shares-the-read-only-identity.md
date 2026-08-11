# Cloud Monitoring triage shares the read-only identity, and owns its correctness contract

**Status:** Accepted

`docs/adr/0007` gave Kubernetes triage a separate read-only service account rather than borrowing
the human's credential. This extends that decision to a second GCP surface — Cloud Monitoring —
and records two things `0007` had no reason to settle: whether the second surface gets its own
identity, and who is responsible for a query being *right*.

## Why there is a fourth triage server at all

The three existing servers all read things **we** produce: our spans, our rows, our keys. None of
them can see the managed resource underneath.

The gap was found the hard way. A hot write path's latency degraded nightly during the traffic
peak. Traces established that the cache `XADD` **executed in 12 µs** while the caller waited
**190–215 ms**, and that the database spans in the same trace never moved — which proved the delay
was not in anything we wrote, and then stopped. Our instrumentation cannot observe a scheduler it
is queued behind.

The answer was CPU pressure on the managed cache, which is visible only in Cloud Monitoring — and
worth recording precisely, because the first hypothesis was wrong. We assumed a burstable tier
exhausting its allowance and pinning at a ceiling. Measured, the busiest CPU ran 53% at trough and
71% mean / 82.5% max at peak: badly queued, never capped. Around 80% utilization a caller waits
several times the service time, which fully explains hundreds of milliseconds sitting behind 12 µs
of execution. **Queueing under load, not throttling against a limit** — two different fixes, and
only a real measurement separates them. That is the argument for the server, stated as its own
first result.

Generalized: **a plateau our own spans cannot explain is an infrastructure question**, and we had
no way to ask it. That is the whole justification for the server; it is not "metrics, but again".
`telemetry-triage` reads what we instrument, `monitoring-triage` reads what GCP measures for us.

## One identity for every deployed-GCP read

The monitoring server authenticates as the **same** `k8s-triage@<project>.iam.gserviceaccount.com`
that `0007` created, now holding `roles/monitoring.viewer` alongside
`roles/container.clusterViewer`. `scripts/k8s/bootstrap-sa.sh` grants both.

The alternative — a dedicated `monitoring-triage@` account — was rejected. It buys a smaller blast
radius on paper and costs a real, recurring ceremony: a second account to create per project, a
second `roles/iam.serviceAccountTokenCreator` grant per teammate, a second thing for the doctor to
diagnose and for a newcomer to discover is missing. And the blast radius it protects is small to
begin with: both roles are **viewers**, so the marginal capability of holding them together is
the ability to read a metric. Bootstrap friction is what actually stops a read-only path from
being adopted; we have paid that cost once and should not pay it again per API.

The property that matters is unchanged and is the reason this is safe: **read-only is enforced by
Google, not by our Python.** A write is refused by the API before it reaches a resource. The code
shape reinforces it — one GET builder, no method parameter, no caller-supplied URL — and
`--selftest` asserts that no other verb appears anywhere in the source, so a later edit that
introduced one would go red.

## Targets are configured, not derived

`0007` derived Kubernetes targets from the kubeconfig, on the grounds that GKE writes
`gke_<project>_<region>_<cluster>` identically on every machine, so a derived target cannot drift
between teammates. A Cloud Monitoring scope has no such fingerprint — it is a bare project id,
present in nothing a laptop already holds — so deriving is not available.

It is therefore declared, as **org data** in `workspace.config.yaml`:

```yaml
monitoring:
  targets:
    app/staging: my-project-123456
    app/prod: my-project-123456
```

The `<env>` half of each key is load-bearing: it is the input to the production gate. This
deliberately does **not** introduce a second flag. `triage.prod` (`docs/adr/0005`) continues to
govern every triage server, so there is one place a person opts into production and one place to
audit who has. A project that holds both environments appears twice, and the two keys still gate
differently — which is the point.

## The correctness contract belongs to the server

This is the part with no precedent in `0005` or `0007`, because the other servers do not have
this failure mode.

A Postgres query that is wrong usually errors. A Cloud Monitoring query that is wrong **returns a
plausible number for a different question**. Two ways, both silent:

- **A naive timestamp.** Under Asia/Bangkok, an ISO-8601 string read as local time shifts the
  window by seven hours. The result is a confident, well-formed answer about the wrong hours.
  This is not hypothetical: `scripts/observability/find-traces.sh` has exactly this bug, and it
  cost real investigation time before it was noticed.
- **The wrong aligner.** `ALIGN_MEAN` on a cumulative counter reports a meaningless running
  total. `ALIGN_RATE` on a gauge reports the slope of a level. Worst of all, `ALIGN_MEAN` on a
  utilization metric averages away the ceiling — a node pinned at its limit for twenty minutes of
  a one-hour window reports as comfortable, which is the precise opposite of the finding.

Leaving either to the caller means the agent must remember, every single call, a rule it has no
feedback loop for. So the server decides:

- Time is **epoch milliseconds or ISO-8601 carrying an offset**, and anything else is **refused**
  rather than guessed. A rejection is a cheap, loud failure; a shifted window is an expensive,
  silent one.
- The aligner is **derived from the metric's own descriptor** — counter to `ALIGN_RATE`,
  distribution to `ALIGN_PERCENTILE_99`, level to `ALIGN_MEAN`, and anything reading as a
  utilization or ratio to **`ALIGN_MAX`**. A caller may still override, which is why the reason is
  returned alongside the choice.
- Every result **echoes the resolved UTC window, the aligner, why it was chosen, and the
  alignment period**, so a number is never quotable without the terms that produced it.

Bounded output follows the same principle as the sibling servers: what was dropped is reported
(`returned`, `truncated`) rather than silently cut, so a partial answer cannot read as complete.

## Discovery over a hand-maintained catalog

The tools are generic over resource type — `list_monitored_resources`, `list_metrics`,
`read_timeseries` — rather than one tool per GCP service. Cloud Monitoring publishes
`monitoredResourceDescriptors` and `metricDescriptors`, so "what is even here" is answerable from
the API. A per-service tool set would need a code change for every service we adopt; discovery
needs none, and the request that motivated this server explicitly asked for Memorystore, Cloud
SQL, GKE nodes "and etc."

`metric-catalog.json` is a small curated shortlist on top of that, holding the one thing discovery
cannot supply: which five metrics matter for a given resource, and what each would mean if it
moved. It is deliberately short and explicitly not authoritative — a catalog attempting to cover
every GCP service is stale the week it is written. A stale entry is safe: `read_timeseries`
resolves the descriptor first, so a renamed metric type fails loudly instead of answering wrongly.

## Consequences

- `aiworks sync` still does not bootstrap anything (`docs/adr/0009` holds). The new server is
  registered by `scripts/triage-mcp.sh` under the existing `triage.enabled` key; the IAM grant
  remains a human step run by a project owner.
- A workspace that upgrades gets the server but no targets until someone declares them. It starts
  and reports "no targets declared" rather than guessing at a project — the same posture as a
  missing DSN elsewhere.
- Existing bootstrapped projects need `bootstrap-sa.sh` re-run once to pick up
  `roles/monitoring.viewer`. `--verify` is the proof that it landed.
- The `oncall` agent gains the skill and the tool grants. No autonomous gate consumes it: like its
  siblings it is on-demand, invoked when an investigation reaches the infrastructure boundary.
