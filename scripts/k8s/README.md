# Kubernetes triage adapter

Read-only access to the deployed GKE clusters, for grounding an investigation in what the running
system actually holds instead of what the manifests say it should.

| file | what it is |
|---|---|
| `k8s_triage_mcp.py` | the MCP server — read-only, staging + prod |
| `bootstrap-sa.sh` | **admin**, once per cluster: creates the read-only identity and proves it |
| `setup.sh` | **everyone**, a doctor: says what is missing and the command that fixes it |

## Why there is a separate identity

The kubeconfig credential a human carries on these clusters can `delete pods`, `patch
deployments`, `create pods/exec` and `list secrets` — on production. An MCP that used it would be
read-only only for as long as its own Python was free of bugs.

So it does not use it. Every call authenticates as `k8s-triage@<project>.iam.gserviceaccount.com`,
obtained by **impersonation** (no key file exists anywhere), and that identity holds the upstream
`view` ClusterRole plus a small generated `k8s-triage-extra`. Read-only is enforced by the **API
server**: a delete comes back `403` from Kubernetes before it is matched against an object.

`view` excludes `secrets`, `pods/exec` and `pods/portforward`, and `k8s-triage-extra` only adds
nodes, metrics and non-core API groups — so no rule anywhere grants a Secret read or a shell.

The agent also has no `Bash(kubectl *)` / `Bash(gcloud *)` grant, so this server is the only path
from a session to a cluster. A human still has their own credential in their own terminal.

## Targets are derived, never configured

Each kubeconfig context names its cluster as `gke_<project>_<region>_<cluster>` — a string GKE
writes, so it reads the same on every machine. The context's own name is a personal alias and is
ignored.

```
gke_agent-384510_asia-southeast1_agent-staging  ->  product="agent"   env="staging"
gke_core-287413_asia-southeast1_bluepi-prod     ->  product="bluepi"  env="prod"
```

`product` and `env` are required on every call and neither is defaulted, so an unnamed
environment can never resolve to production. Nothing is written to `~/.kube/config`: switching the
current context would leak into the human's own next `kubectl`.

A cluster nobody has bootstrapped is still *listed* but not *readable* — it fails closed with the
command that onboards it.

## Admin runbook — one cluster at a time

Needs **owner** on the GCP project (`roles/editor` is not enough: granting the identity a role
requires `resourcemanager.projects.setIamPolicy`).

```bash
# 1. see what this machine can address, and pick a context
kubectl config get-contexts

# 2. preview — writes nothing
scripts/k8s/bootstrap-sa.sh --context ofb-staging -n

# 3. apply. STAGING FIRST: the script refuses production without --allow-prod.
scripts/k8s/bootstrap-sa.sh --context ofb-staging

# 4. only once staging passes its checks
scripts/k8s/bootstrap-sa.sh --context ofb-prod --allow-prod

# 5. let a teammate use it
scripts/k8s/bootstrap-sa.sh --context ofb-staging --grant someone@example.com
```

Step 3 ends by asserting the property rather than assuming it — `get pods` / `pods/log` / `events`
/ `nodes` must answer **yes**, and `secrets` / `delete pods` / `patch deployments` / `pods/exec` /
`pods/portforward` must answer **no**. It refuses to report success otherwise.

`bootstrap-sa.sh status --context <ctx>` re-prints that table any time.
`bootstrap-sa.sh revoke --context <ctx>` removes the bindings again.

### What it creates

| object | scope | why |
|---|---|---|
| service account `k8s-triage` | GCP project | the identity; no key is ever generated |
| `roles/container.clusterViewer` | GCP project | reach the control plane — grants no object access |
| `clusterrole/k8s-triage-extra` | cluster | nodes, metrics, and the CRD groups present at bootstrap |
| `clusterrolebinding/k8s-triage-view` | cluster | the upstream `view` role |
| `clusterrolebinding/k8s-triage-extra` | cluster | the role above |
| `roles/iam.serviceAccountTokenCreator` | the SA | who may impersonate it |

## Teammate setup

Nothing to configure.

```bash
scripts/k8s/setup.sh
```

`aiworks sync` runs it automatically. It only reads, always exits 0, and prints the exact command
for each gap — including the ones an owner has to run for you.

## Production

Gated by `triage.prod` (default off, per machine, in the git-ignored
`workspace.config.local.yaml`) — the same switch as `pg_triage` and `redis_triage`, because a prod
pod log carries the same player data a prod database row does. Checked in-process before a token
is minted. Staging needs no opt-in.

Prod pod logs are fingerprinted for egress redaction (`scripts/lib/pii_provenance.py`) so a token,
email or IP read here is masked if it later reaches a ticket or Slack. Only shape-detectable
values are vaulted — player codes, money and round ids pass through untouched. Staging is never
vaulted.

## CRD drift

`k8s-triage-extra` is generated from the API groups that exist at bootstrap time, because RBAC has
no way to say "every group except the core one" and a wildcard would hand back `secrets`. When new
CRDs are installed, `setup.sh` notices the gap and re-running `bootstrap-sa.sh` closes it.

## Checks

```bash
uv run scripts/k8s/k8s_triage_mcp.py --selftest         # deps, derivation, policy — no cluster access
uv run scripts/k8s/k8s_triage_mcp.py --verify staging   # live: reads work, Secrets are refused
uv run scripts/k8s/k8s_triage_mcp.py --targets          # what would be derived, as JSON
```
