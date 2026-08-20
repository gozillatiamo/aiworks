---
name: monitoring-triage
description: >-
  Read-only GCP Cloud Monitoring, STAGING or PRODUCTION - the managed resource UNDERNEATH our
  services, which we cannot instrument. Use when a trace proves the time is not in our own code
  and the question is what the infrastructure was doing: Memorystore/Valkey or Cloud SQL CPU-
  starved, out of memory, out of connections; a GKE node under pressure or a container throttled
  against its CPU limit; a load balancer whose edge latency exceeds the backend's; capacity,
  saturation, "at its ceiling in the peak window"; a burstable or shared-core tier exhausting its
  allowance. NOT for our own spans and logs (telemetry-triage), app rows (pg-triage), cache or
  streams (redis-triage), cluster objects and pod logs (k8s-triage).
---

Cloud Monitoring answers one question the other triage servers cannot: **what was the managed
resource underneath us doing?** Reach for it when a span shows time leaving our process and not
coming back.

## The division of labour

Getting this wrong wastes a whole investigation, so settle it before the first call:

| the question | the server |
|---|---|
| What did our code do, and how long did each span take? | `telemetry-triage` (SigNoz) |
| What does the row / the balance / the transaction say? | `pg-triage` |
| What is in the cache, the key, the stream, the consumer group? | `redis-triage` |
| Is the pod running, restarting, throttled by its manifest? What did it log? | `k8s-triage` |
| **Was the managed resource itself out of CPU, memory, connections, headroom?** | **this skill** |

The tell that you want this skill: a **plateau**. Our own instrumentation says the operation
executed in microseconds, yet the caller waited hundreds of milliseconds. That gap is never
visible to the thing that was waiting — it is scheduling, queueing, or throttling, and only the
infrastructure's own metrics show it.

## Method

**1. Resolve the target before anything else.** `list_targets` names every declared scope and
says whether it is readable *now* — a `prod` target is refused until `triage.prod` is set on this
machine. A refusal is a policy fact, not an outage; report it as the gap it is rather than
retrying.

**2. Find the resource before the metric.** `list_monitored_resources` says what this project
actually monitors, and what labels address it. Do not guess a resource type from the service's
name — a Memorystore instance may publish as `memorystore_instance` or `redis_instance` depending
on which generation it is, and the project will tell you which.

**3. Ask the catalog what matters, then the API what exists.** `curated_metrics(<resource_type>)`
gives the short list worth reading first for the resources we run, with what each number would
mean if it moved. `list_metrics(<prefix>)` is the exhaustive fallback for anything uncurated —
and it is not a lesser path, just a longer one. A metric type that does not exist fails loudly
on the descriptor lookup, so a wrong guess costs a round-trip, never a wrong answer.

**4. Read the window, then read what the result says about itself.** `read_timeseries` echoes
back the UTC window, the aligner it chose and why, the alignment period, and `series_dropped`.
**Read those four before quoting any number.** They are there because the failure mode of this API
is not an error — it is a plausible figure answering a question you did not ask.

`series_dropped > 0` means your filter matched more series than the cap and you are holding a
**sample**, kept in the API's own order rather than by size — so the largest series you can see is
not the largest that exists. Rank nothing until you have narrowed the filter or collapsed series
with `group_by`; cross-check the total against the matching `aggregate/*` metric where one exists.

Two contracts the server enforces so you cannot get them silently wrong:

- **Time is unambiguous or refused.** Pass epoch milliseconds, or ISO-8601 carrying its offset
  (`2026-08-10T22:00:00+07:00`). A bare local-looking timestamp is rejected rather than guessed —
  under Asia/Bangkok, reading one as local would shift the window seven hours and return a
  confident answer about the wrong hours.
- **The aligner comes from the metric's own descriptor.** A counter reads as a rate, a
  distribution as p99, a level as a mean — and anything that looks like a **saturation** metric
  reads as the *maximum*, because a ceiling held for twenty minutes of an hour averages away to
  nothing. Override with `aligner` only when you can say why the derived one is wrong.

**5. Compare against a baseline, never against intuition.** A number from a peak window means
nothing on its own. Read the same metric over a quiet window of the same length and quote both.
This is the same discipline `root-cause-deployed` asks for, applied to infrastructure.

**6. Disconnect.** `disconnect` drops the minted impersonation tokens. Run it when the
investigation ends — the teardown step, same as every other triage server.

## What a saturated resource looks like

Worth recognizing, because each one is a different fix and they are easy to confuse:

- **Shared-core / burstable exhaustion** — CPU utilization pinned near its ceiling during
  sustained load while the service's own execution times stay flat. The commands are fast; the
  waiting is for a scheduler. The fix is the node tier, not the code.
- **Container throttling** — `limit_utilization` near 1.0 while the *node* is idle. The pod is
  being held to its own manifest. The fix is the limit.
- **Connection ceiling** — backends or clients flat at a maximum. Callers then queue *outside*
  the resource, where its own latency metrics cannot see them.
- **Memory run-up** — utilization climbing with no plateau. Something is unbounded; pair with
  `redis-triage` or `pg-triage` to find which key family or table.

## Boundaries

Read-only, always: the server constructs GET requests only, and the identity holds
`roles/monitoring.viewer`, so a write is refused by Google before it reaches a resource. Never
propose changing an instance tier, a limit, or a config as part of *this* skill's output — a
capacity finding goes into the case file as a recommendation for a human, with the measurement
that supports it.

A time series carries numbers and resource labels, never personal data, so nothing here is
vaulted for egress redaction. Results say `pii_vaulted: false` for that reason, not because the
check was skipped.

If a target is undeclared, the fix is a `monitoring.targets` entry in `workspace.config.yaml`
(see `workspace.config.example.yaml`). If the identity cannot be impersonated or lacks
`roles/monitoring.viewer`, the fix is an owner of that project running
`scripts/k8s/bootstrap-sa.sh` — both are human steps, and reporting the gap is the correct
outcome rather than a workaround. Full adapter notes: `scripts/monitoring/README.md`.
