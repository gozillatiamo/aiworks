# Kubernetes triage targets are scoped to the workspace's declared projects

**Status:** Accepted. Amends `docs/adr/0007` §"Targets are derived from the cluster, not from a
config or an alias".

## The gap

`docs/adr/0007` derives every k8s-triage target from the kubeconfig, by design, so onboarding a
cluster costs zero configuration. That assumed one organization per kubeconfig. On a laptop that
also holds a second org's clusters — a contractor, a side project, a previous employer — every one
of that org's GKE contexts is derived too: `scripts/k8s/setup.sh` prints a `bootstrap-sa.sh`
command for it, `aiworks doctor --deep` scores it, and the `k8s_triage` MCP lists it as something
this session can address.

Concrete failure: a laptop whose kubeconfig also holds another employer's clusters sees
`setup.sh` derive e.g. `other/{prod,staging}` and print a `bootstrap-sa.sh --context …` command
for each, even though this workspace's only declared GCP project is under `monitoring.targets`
and its product may run on Cloud Run plus a VM with **no** GKE cluster at all. Root cause:
`scripts/k8s/setup.sh` and `k8s_triage_mcp.py` derive targets from **every** GKE context in the
kubeconfig, with no notion of which project is this workspace's own.

## Decision

**The allowlist is the set of project ids that are the values of `monitoring.targets`**
(local-first merge of `workspace.config.local.yaml` over `workspace.config.yaml`, same precedence
as every other key `scripts/lib/triage_policy.py` resolves). No new config key.

| option | verdict |
|---|---|
| values of `monitoring.targets` | **chosen** |
| new `triage.gcp_projects: [..]` | rejected |
| per-repo `products[].repos[].gcp_project` | rejected |
| derive from `gcloud config get-value project` | rejected |

Why reuse wins: `docs/adr/0010` already made one read-only identity per project serve both k8s and
Cloud Monitoring, and `setup.sh` already checks `roles/monitoring.viewer` on every GKE project. A
GKE project that is not in `monitoring.targets` is a half-declared workspace already; requiring it
there costs nothing new and removes a drift source. It is also org data every monitoring-triage
workspace already has, including this one — zero migration.

Why not the others: a second project list (`triage.gcp_projects`) would drift from
`monitoring.targets`, and the `triage:` section is a flat two-boolean block `scripts/triage-mcp.sh`
scans in awk and `triage_policy.py` promises to keep in parity with — a list there breaks that
contract. `products[].repos[]` is a schema change across the product model for a triage-only
concern. A `gcloud config` project is per-machine state, the same drift `docs/adr/0007` rejected
for kubeconfig aliases.

**Empty allowlist ⇒ unscoped (today's behaviour), not locked out.** Fail-closed-on-empty would
silently remove every k8s target from every aiworks workspace that never declared monitoring.
Scoping is about *addressing*; *access* stays fail-closed at the IAM/API-server layer regardless
(`docs/adr/0007`), so the unscoped fallback grants nothing new — it is exactly today's behaviour,
now labelled `"scope": "unscoped"` in `list_targets()` and a dim line in `setup.sh`.

## What changed

- `scripts/lib/triage_policy.py` gained `monitoring_targets()` / `workspace_projects()` — the one
  parser for `monitoring.targets`, moved here from `monitoring_triage_mcp.py` so `k8s_triage_mcp.py`
  can read the same allowlist without a second implementation to drift from it. `projects` on the
  CLI prints the allowlist, one project id per line, for `setup.sh` to consume with plain `python3`.
- `k8s_triage_mcp.py` filters every derived target through `_in_scope()` before it reaches
  `list_targets()`, `_resolve()` or `_verify()`. An out-of-scope cluster is invisible to the
  payload — the agent never learns a foreign org's coordinates — and `_resolve()` for one names
  the project and `monitoring.targets` in its error rather than saying "unknown".
- `setup.sh` splits derived rows into in-scope and out-of-scope before the check loop. Out-of-scope
  rows get no gcloud/kubectl round-trip, no owner command, and do not count toward `problems`; they
  are named once in a dim "out of scope for this workspace" block so the fix (add the project under
  `monitoring.targets`) is visible, never silently swallowed.
- `bootstrap-sa.sh` refuses bootstrap / status / revoke when the context's GKE project is not in
  that allowlist (empty allowlist stays unscoped). An explicit `--context` is therefore not a
  bypass of the workspace boundary.
- `aiworks-doctor.sh --deep` reports **skip** (not warn) when this workspace has monitoring.targets
  but zero in-scope GKE clusters — that is a Cloud-Run-only product working as intended, not a gap.

## Consequences

- **Lock-out via partial declaration.** A workspace that declares `monitoring.targets` for its
  Cloud-Run project but also has a GKE project it never listed loses that k8s target after
  upgrading. Mitigated by `setup.sh` naming it under "out of scope" with its project id — the fix
  is visible, not silent.
- **Unscoped is still today's exposure, not a new one.** With no `monitoring.targets` declared, an
  agent session can still address a foreign org's cluster the human happens to hold impersonation
  on. Access stays IAM-gated and prod stays `triage.prod`-gated regardless; scoping only removes
  the exposure where a workspace has declared its projects. This is not full isolation, and is not
  claimed to be.
- **The non-GKE bootstrap gap is closed.** See `docs/adr/0010` §Projects with no GKE cluster —
  `bootstrap-sa.sh --project <id> --monitoring-only` creates the shared identity without RBAC.
