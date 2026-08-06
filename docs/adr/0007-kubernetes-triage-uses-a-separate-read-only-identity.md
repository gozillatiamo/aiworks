# Kubernetes triage authenticates as a separate read-only identity, not as you

**Status:** Accepted

The workspace already reaches deployed Postgres and Redis read-only (`docs/adr/0005`). Kubernetes
was the missing half: a 502 with no matching trace in the service, a pod that restarted before
anyone looked, an APISIX route whose upstream timeout is not in any repo. All of it is only
visible from the cluster, and none of it needs write access.

## The credential problem

The Postgres servers get their guarantee from a read-only DB role — the ADR says so in as many
words: the in-process SQL check is *"convenience, not the guarantee"*. Kubernetes has no such
thing lying around. A human's GKE credential here is mapped from `roles/owner`, and answers `yes`
to `delete pods`, `patch deployments`, `create pods/exec` and `list secrets` — on production.

An MCP built on that credential would be read-only exactly as long as its own Python was free of
bugs, and a prompt injection or a mis-scoped tool would be a production write with nothing behind
it. That is a worse posture than the thing it sits next to, so it was not built that way.

## A dedicated identity, obtained by impersonation

Every call authenticates as `k8s-triage@<project>.iam.gserviceaccount.com`, holding the upstream
`view` ClusterRole plus a generated `k8s-triage-extra`. Read-only is enforced by the **API
server**: a delete returns 403 before it is matched against an object. `scripts/k8s/bootstrap-sa.sh`
creates the identity and refuses to report success unless reads answer yes and writes answer no.

The identity is reached by **impersonation**, not a key file. A JSON key would be a long-lived
production-adjacent credential sitting on every teammate's laptop, revocable only by remembering
which laptops have it. Impersonation mints a short-lived token from the human's own credential
and is revoked by removing one IAM binding.

`view` is used verbatim rather than copied, because it is a widely-audited definition that already
excludes `secrets`, `pods/exec` and `pods/portforward`. `k8s-triage-extra` adds only what triage
genuinely needs and `view` omits — nodes, `metrics.k8s.io`, and the CRD groups — so the exclusions
survive.

CRD groups are **generated at bootstrap** from the groups that exist in that cluster. RBAC cannot
express "every group except the core one", and a `apiGroups: ["*"]` wildcard would silently hand
back the Secrets that `view` was chosen to exclude. Enumeration drifts, so `scripts/k8s/setup.sh`
reports when new groups appear and re-running the bootstrap closes the gap: a detected, fixable
condition instead of a silent hole.

## The MCP is only the only path if the shell is closed

A read-only MCP beside an open `Bash(kubectl …)` grant is decoration — the agent would simply use
the human's credential directly, and in a permissive mode a classifier's judgement would be the
only thing in the way. So `Bash(kubectl *)` and `Bash(gcloud *)` are **denied** outright, matching
what `scripts/redis/tunnel.sh` already says about `gcloud compute ssh`: *"deliberately NOT granted
to agents"*. A human still has both in their own terminal, and `!kubectl …` still works.

## Targets are derived from the cluster, not from a config or an alias

A registry of clusters in `workspace.config.yaml` would be one more thing to maintain and to
de-brand on the way upstream. Deriving from the kubeconfig context *name* was rejected too: names
are personal aliases, so the same tool would resolve differently on each teammate's machine.

Every context names its cluster as `gke_<project>_<region>_<cluster>` — written by GKE, identical
everywhere — and `<cluster>` already ends in `-prod` or `-staging`:

    gke_agent-384510_asia-southeast1_agent-staging   ->  product="agent"   env="staging"
    gke_core-287413_asia-southeast1_bluepi-prod      ->  product="bluepi"  env="prod"

That is zero configuration, identical for everyone, and multi-product for free. It also separates
two things that were being conflated: **addressing** is general (every cluster is nameable), while
**access** is deliberate (only clusters somebody bootstrapped will answer). An un-onboarded
cluster is listed and fails closed with the command that onboards it.

`product` and `env` are both required on every call, with no defaults, so an unnamed environment
can never resolve to production. Nothing is ever written to `~/.kube/config`: switching the
current context is machine-wide state, and the human's next `kubectl` in their own terminal would
silently inherit whatever the agent last selected.

## Production reuses `triage.prod`

No new key. A prod pod log carries the same player data a prod database row does, so "may this
machine touch production" stays one decision, read local-first and enforced in-process before a
token is minted. Consequently the server needs **no configuration at all** — `triage.enabled`
already governs registration and `triage.prod` already governs production.

PII provenance follows `0005` and stays production-only, applied to pod **logs**, which is where
personal data actually appears. Only shape-detectable values are vaulted (email, phone, IP, JWT,
bearer tokens); player codes, money and round ids pass through, so a ticket stays readable. Object
specs are not vaulted — a Deployment spec carries configuration, not people.
