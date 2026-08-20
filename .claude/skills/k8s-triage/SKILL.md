---
name: k8s-triage
description: >-
  Read-only ground truth from the DEPLOYED Kubernetes clusters, PRODUCTION or STAGING - not
  manifests or memory. Triggers: a request that reached the gateway but left no trace in the
  service (502/504/503, "upstream response status", APISIX/ingress errors); pods crashing,
  restarting, OOMKilled, CrashLoopBackOff, ImagePullBackOff, Pending, failing probes; container
  LOGS, including a dead pod's previous instance; replicas, last restart, which node; in-cluster
  routing and gateway config - ApisixRoute, ApisixUpstream, ApisixConsumer, Ingress, Service,
  Endpoints, timeouts, retries, is the pod really in the endpoint list; node/pod CPU and memory
  pressure, HPA, evictions; what a rollout did to running workloads; any custom resource. NOT for
  app data (pg-triage), cache or streams (redis-triage), traces and logs (telemetry-triage).
---

# Kubernetes triage (read-only)

Ground an investigation in what the cluster is actually running.

## The identity is not yours

Every call authenticates as `k8s-triage@<project>.iam.gserviceaccount.com`, which holds `view`
plus nodes/metrics/CRD reads. Writes come back **403 from the API server**, not from a check in
the tool — so there is no way to mutate a cluster through this server, and no need to be careful
about trying.

You have **no `kubectl` and no `gcloud`**. That is deliberate (`docs/adr/0007`); this MCP is the
only path. Do not try to work around it — ask the user to run a command themselves with `!kubectl`
if something genuinely falls outside these tools.

`Secrets` are unreadable by design. If an investigation seems to need one, it needs a different
answer: check the Secret's *name* on the pod spec (`env[].valueFrom`, `volumes[].secret`), or ask
the user.

## Always start here

```
list_targets()
```

Returns every addressable cluster as `product` + `env`. **Both are required on every other call
and neither has a default** — there is no "current context" to inherit, which is what stops an
unnamed environment from resolving to production.

A target that is listed is not necessarily bootstrapped. If a call fails with "could not
impersonate", report the command the error names; do not retry.

`env="prod"` is refused unless `triage.prod: true` on this machine. Staging needs no opt-in — when
a symptom reproduces on staging, prefer staging.

## Tools

| tool | use it for |
|---|---|
| `list_targets()` | what exists, and whether prod is unlocked |
| `list_resources(product, env, kind, api_version, namespace, label_selector, limit, full)` | any kind, including CRDs |
| `get_resource(product, env, kind, name, api_version, namespace)` | one object, in full |
| `get_logs(product, env, namespace, pod, container, tail_lines, since_seconds, previous)` | container logs |
| `list_events(product, env, namespace, warnings_only, limit)` | why something will not start |
| `top_pods` / `top_nodes` | live CPU/memory |
| `disconnect()` | drop clients and tokens when finished |

`list_resources` returns a compact projection; pass `full=true`, or use `get_resource`, when you
need spec and status. When a result is cut short it says so (`truncated`) — never treat a
truncated list as the whole picture; narrow it with a namespace or a `label_selector`.

## Recipes

**A request the gateway logged but the service never saw.** The gateway and the service are
usually in different namespaces, so look at both:

```
list_resources(product="agent", env="prod", kind="Pod", namespace="gateway")
list_resources(product="agent", env="prod", kind="Pod", namespace="agent")
```
Then the routing that produced the upstream error:
```
list_resources(product="agent", env="prod", kind="ApisixRoute",    api_version="apisix.apache.org/v2")
list_resources(product="agent", env="prod", kind="ApisixUpstream", api_version="apisix.apache.org/v2")
```
`ApisixUpstream` is where timeouts, retries and health checks live — a 502 with no downstream
trace is often the gateway giving up, not the service answering. Check `Endpoints` for the service
too: a pod missing from the endpoint list receives nothing while still looking healthy in `get pods`.

**A pod that already restarted.** The interesting log is the dead instance's:
```
get_logs(..., pod="...", previous=True)
```
Pair it with `list_events(warnings_only=True)` and the pod's `last_terminated` reason. A pod whose
age is younger than the incident restarted since — say so rather than reading the live log as if
it covered the event.

**Something will not start.** `list_events(warnings_only=True)` first; the reason is almost always
there (ImagePullBackOff, FailedScheduling, Unhealthy, OOMKilled) and saves reading any spec.

## Prod output is fingerprinted

Logs read from `env="prod"` are recorded for egress redaction, so a token, email or IP appearing
in one is masked if it later reaches a ticket or Slack. Player codes, money and round ids are not
touched. Staging is never vaulted. Every result carries `env` and `pii_vaulted` — quote them when
reporting a finding, so a reader knows which environment answered.

## When you are done

Call `disconnect()`. Nothing is held until the next call.
