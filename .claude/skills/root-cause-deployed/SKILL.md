---
name: root-cause-deployed
description: >-
  Root-cause a failure that exists ONLY in a DEPLOYED environment and cannot be reproduced locally
  - you have telemetry and a running system, not a repro. Triggers: a staging or production
  symptom with a trace id, log line, error rate or screenshot and no way to trigger it on a
  laptop; a request that reached the gateway but left no trace in the service; failures that are
  intermittent, load-dependent, or hit only some users or replicas; a suspected deploy, migration
  or infrastructure change. For a bug you CAN trigger locally use `diagnosing-bugs` - its loop
  starts by reproducing, which this situation forbids.---

# Root cause in a deployed environment

The scene is **cold**. The request is gone, the pod that served it may be gone, Kubernetes events
expired an hour after they fired. You cannot step through it, so the whole method is: measure
first, then let competing explanations kill each other on evidence.

Two failure patterns have produced wrong root causes here, both ending in confident tickets:
reading source until a plausible mechanism appears, and generalising from a single sighting.
Both survive any amount of care. Only the sequence below stops them, because it withholds the
step where a story gets written until the evidence that would kill the story is in hand.

## Step 1 — Base rate, before any hypothesis

Count the failure class before explaining any instance of it. One trace tells you a thing
happened; the **base rate** tells you what kind of thing it is.

```bash
scripts/observability/find-traces.sh --service <svc> --status <code> --since -7d --interval 1h
scripts/observability/find-traces.sh --service <svc> --status <code> --since -7d --by <attribute>
scripts/observability/get-logs.sh --service <svc> --env prod --body-contains '<phrase>' --from -7d
```

The shape of the answer already eliminates whole families of cause:

| shape | what it rules out |
|---|---|
| **clustered** in a few buckets | anything steady — request content, a always-wrong code path, a constant misconfiguration |
| **spread** evenly | anything episodic — a deploy, an eviction, a one-off node event |
| concentrated on **one** route/host/pod | anything shared — the gateway itself, a dependency every route uses |

Then place the hot buckets against events with known timestamps: deploy and rollout times
(`Deployment.status.conditions`, `managedFields[].time`), pod replacement, migration runs.
Correlation here is worth more than any amount of reading.

**Done when:** you can state how many times this happened, over what window, and whether it is
clustered or spread. `n = 1` is a legitimate answer — but record it, because it caps the verdict
in Step 4.

## Step 2 — Ledger, at least two entries

Write the **ledger** before gathering more evidence. Each entry must predict something
*different*, or it is not a second hypothesis — it is the first one restated.

| # | hypothesis | predicts we would ALSO see | evidence for | evidence against | status |
|---|---|---|---|---|---|
| 1 | … | … | … | … | open |
| 2 | … | … | … | … | open |

A single-entry ledger is the failure pattern with a table drawn around it. If only one
explanation comes to mind, the missing ones are usually: a layer you have not looked at (network,
scheduler, gateway, DNS), the *absence* of something rather than a fault in it, and "the
component we trust is the broken one".

**Done when:** two or more entries exist and each one's *predicts* cell names an observation the
others do not predict.

## Step 3 — Discriminator

Find the cheapest observation whose result differs across the ledger, then go get it. A test
every hypothesis passes is not evidence, however much work it took.

Where the discriminating facts actually live:

- **`k8s_triage`** — the running cluster. Pod restarts and replacements, `previous=true` logs from
  a container that already died, endpoint membership, `ApisixRoute`/`ApisixUpstream` timeouts and
  retries, node pressure, `Deployment` strategy and `preStop`. Anything about *why the request
  never arrived* is here and nowhere else.
- **`pg_triage` / `redis_triage`** — what the deployed data actually holds, versus what the code
  implies it should.
- **`find-traces.sh` / `get-trace.sh` / `get-logs.sh`** — rates, distributions, and one request's
  span waterfall.
- **the repo** — read source to *interpret* a measurement or to find what a layer would log. Read
  it to *generate* the root cause and you are back in failure pattern one.

Update every ledger row from the result, including rows the result weakened. A discriminator that
only ever confirms the favourite is being read, not run.

**Done when:** at least one row is ruled out on evidence, or you can state why no available
observation separates the survivors.

## Step 4 — Verdict

Grade honestly. The tier is the deliverable; a mechanism with the wrong tier on it is what sent
the last two investigations wrong.

- **CONFIRMED** — reproduced, or direct evidence of the mechanism firing at that time, or a
  discriminator ran and left exactly one row standing.
- **LEADING** — fits every piece of evidence and survived a discriminator, but competitors are
  weakened rather than dead. Carries a confidence and the specific missing evidence.
- **SPECULATIVE** — consistent with the evidence, nothing has been ruled out. **`n = 1` cannot
  exceed this**, however well the story fits.

A ticket may quote a SPECULATIVE finding as a lead. It must not state one as the cause.

Report: symptom · base rate · ledger with final statuses · the discriminator that moved things ·
verdict and tier · what would change it · what to fix, separated into *this cause* and *latent
defects found on the way* — those are different claims and get different tickets.

## Reading a cold scene

- **Events expire in about an hour.** Their absence is not evidence of absence. Say so rather
  than inferring calm.
- **Pods are replaced, not just restarted.** `restarts: 0` on a young pod does not mean nothing
  happened; compare `creationTimestamp` against the incident, and treat an age younger than the
  symptom as "the witness is gone".
- **A truncated query is not a finding.** A tool that reports `truncated` has told you it stopped
  looking, not that the rest is empty.
- **Timestamps: pass epoch ms.** `get-logs.sh` and `find-traces.sh` read ISO-8601 as LOCAL time,
  while every trace and log timestamp from SigNoz is UTC. Handing a UTC clock time straight back
  silently queries a different hour and returns a confidently wrong answer.
