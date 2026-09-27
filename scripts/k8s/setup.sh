#!/usr/bin/env bash
#
# setup.sh — check that this machine can use the k8s_triage MCP, and say exactly what is missing.
#
# There is nothing to configure beyond `monitoring.targets` (docs/adr/0039): the MCP derives its
# targets from the kubeconfig, then keeps only the ones in this workspace's own GCP projects — the
# values of that block. A teammate needs only two things per IN-SCOPE cluster, neither of which
# this script can grant itself:
#
#   1. a kubeconfig entry           gcloud container clusters get-credentials ...
#   2. permission to impersonate    roles/iam.serviceAccountTokenCreator on the triage identity,
#                                   granted by an owner of that GCP project
#
# So this is a DOCTOR, not an installer: it reads, it never writes, and it prints the exact
# command that unblocks each gap — including the one somebody else has to run. It always exits 0,
# because a teammate who does not work on Kubernetes should not be told they are broken.
#
# RUN IT YOURSELF. `aiworks sync` does NOT call this (docs/adr/0009) — every check below is a
# gcloud/kubectl round-trip per cluster, and the command that closes a gap needs a GCP project
# owner, so bring-up could only ever reprint an instruction. Sync says the step is manual;
# `aiworks doctor --deep` scores the result.
#
# Usage:
#   scripts/k8s/setup.sh            # check every in-scope GKE target this kubeconfig can see
#   scripts/k8s/setup.sh --quiet    # only report problems (what `aiworks doctor --deep` calls)
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '    %s✓ %s%s\n' "$c_ok"   "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
dim()  { printf '    %s%s%s\n'   "$c_dim"  "$*" "$c_off"; }

QUIET=0
[[ "${1:-}" == "--quiet" ]] && QUIET=1
say() { [[ $QUIET -eq 1 ]] || printf '  %s\n' "$*"; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SA_NAME="k8s-triage"

if ! command -v kubectl >/dev/null 2>&1 || ! command -v gcloud >/dev/null 2>&1; then
  [[ $QUIET -eq 1 ]] || dim "kubectl or gcloud not installed — skipping Kubernetes triage checks"
  exit 0
fi

# This workspace's own GCP projects (docs/adr/0039) — the values of `monitoring.targets`. A
# context outside this set is a foreign org's cluster on the same laptop, never addressed. Empty
# means unscoped: no `monitoring.targets` declared anywhere, so every context stays in scope —
# today's behaviour.
SCOPE="$(python3 "$ROOT/scripts/lib/triage_policy.py" projects 2>/dev/null)"

# Targets, derived the same way the MCP derives them: from each context's CLUSTER reference
# (gke_<project>_<region>_<cluster>), never from the context's personal alias. The embedded Python
# appends a 6th column, `in`/`out`, from SCOPE (empty SCOPE ⇒ every row is `in`).
# Read with a while-loop, not `mapfile` — that builtin arrived in bash 4 and macOS ships 3.2
# as /bin/bash (see the interpreter note in scripts/aiworks).
ROWS=(); OUT_ROWS=(); NROWS=0; NOUT=0
while IFS= read -r _row || [[ -n "$_row" ]]; do   # `|| [[ -n ]]` keeps a last line with no trailing \n
  [[ -n "$_row" ]] || continue
  case "$_row" in
    *$'\t'in) ROWS+=("$_row"); NROWS=$((NROWS+1)) ;;
    *)        OUT_ROWS+=("$_row"); NOUT=$((NOUT+1)) ;;
  esac
done < <(kubectl config view -o json 2>/dev/null | K8S_SCOPE="$SCOPE" python3 -c '
import json, os, sys
scope = set(os.environ.get("K8S_SCOPE", "").split())
try: d = json.load(sys.stdin)
except Exception: sys.exit(0)
for c in d.get("contexts") or []:
    ref = (c.get("context") or {}).get("cluster") or ""
    p = ref.split("_")
    if len(p) != 4 or p[0] != "gke":
        continue
    _, project, _region, cluster = p
    alias = c.get("name") or ""
    for env in ("prod", "staging"):
        if cluster.endswith("-" + env):
            product = cluster[: -len(env) - 1]
            in_scope = "in" if (not scope or project in scope) else "out"
            print("\t".join([product, env, project, cluster, alias, in_scope]))
            break
' | sort -u)

if [[ $((NROWS + NOUT)) -eq 0 ]]; then
  [[ $QUIET -eq 1 ]] || dim "no GKE clusters in this kubeconfig — nothing to check"
  exit 0
fi

print_out_of_scope() {
  dim "out of scope for this workspace — not checked:"
  for row in "${OUT_ROWS[@]+"${OUT_ROWS[@]}"}"; do
    IFS=$'\t' read -r PRODUCT ENV PROJECT _CLUSTER _ALIAS _FLAG <<<"$row"
    dim "  $PRODUCT/$ENV  ($PROJECT)"
  done
}

if [[ $NROWS -eq 0 ]]; then
  if [[ $QUIET -eq 0 ]]; then
    dim "no GKE cluster in this workspace's project(s): ${SCOPE//$'\n'/, } — nothing to check for Kubernetes"
    STAGING_HINT="$(python3 -c '
import sys
sys.path.insert(0, "'"$ROOT"'/scripts/lib")
import triage_policy
staging = sorted(k for k in triage_policy.monitoring_targets() if k.endswith("/staging"))
print(staging[0] if staging else "")
' 2>/dev/null)"
    if [[ -n "$STAGING_HINT" ]]; then
      dim "check Cloud Monitoring instead:  uv run scripts/monitoring/monitoring_triage_mcp.py --verify $STAGING_HINT"
    fi
    say ""
    print_out_of_scope
  fi
  exit 0
fi

say ""
HEADER="Kubernetes triage — $NROWS target(s) in this workspace's projects"
[[ $NOUT -gt 0 ]] && HEADER="$HEADER ($NOUT out of scope, not checked)"
say "$HEADER"
[[ -n "$SCOPE" ]] || [[ $QUIET -eq 1 ]] || dim "unscoped: no monitoring.targets declared — every GKE context in this kubeconfig is checked"

problems=0
for row in "${ROWS[@]+"${ROWS[@]}"}"; do
  IFS=$'\t' read -r PRODUCT ENV PROJECT CLUSTER ALIAS _FLAG <<<"$row"
  SA="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"
  say ""
  say "  $PRODUCT/$ENV  ($CLUSTER)"

  if ! gcloud iam service-accounts describe "$SA" --project "$PROJECT" >/dev/null 2>&1; then
    warn "triage identity does not exist in $PROJECT"
    dim "an owner of $PROJECT runs:  scripts/k8s/bootstrap-sa.sh --context $ALIAS$([[ $ENV == prod ]] && echo ' --allow-prod')"
    problems=$((problems + 1))
    continue
  fi

  if ! gcloud auth print-access-token --impersonate-service-account="$SA" >/dev/null 2>&1; then
    warn "you may not impersonate $SA"
    dim "an owner of $PROJECT runs:"
    dim "  gcloud iam service-accounts add-iam-policy-binding $SA \\"
    dim "    --project $PROJECT --member user:\$(gcloud config get-value account) \\"
    dim "    --role roles/iam.serviceAccountTokenCreator"
    problems=$((problems + 1))
    continue
  fi

  reads="$(kubectl auth can-i get pods --as="$SA" --context="$ALIAS" 2>/dev/null | grep -Ex 'yes|no' | head -1)"
  writes="$(kubectl auth can-i delete pods --as="$SA" --context="$ALIAS" 2>/dev/null | grep -Ex 'yes|no' | head -1)"
  if [[ "$reads" == "yes" && "$writes" == "no" ]]; then
    ok "ready — read-only access confirmed"
  elif [[ "$writes" == "yes" ]]; then
    warn "the triage identity CAN WRITE to this cluster — it must not. Re-run bootstrap-sa.sh, and do not use this target until it reads 'no'."
    problems=$((problems + 1))
  else
    warn "identity exists but cannot read (RBAC bindings missing in this cluster)"
    dim "an owner runs:  scripts/k8s/bootstrap-sa.sh --context $ALIAS$([[ $ENV == prod ]] && echo ' --allow-prod')"
    problems=$((problems + 1))
  fi

  # The same identity also carries Cloud Monitoring (docs/adr/0010). Checked here rather than in a
  # second doctor: one identity, one place that says whether it is whole. Without this a project
  # bootstrapped before 0010 reports "ready" while every monitoring_triage read returns 403.
  if gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
       --filter="bindings.members:serviceAccount:$SA AND bindings.role:roles/monitoring.viewer" \
       --format="value(bindings.role)" 2>/dev/null | grep -q .; then
    ok "roles/monitoring.viewer granted — Cloud Monitoring triage ready"
  else
    warn "roles/monitoring.viewer is MISSING — monitoring_triage will 403 on every read"
    dim "an owner of $PROJECT re-runs:  scripts/k8s/bootstrap-sa.sh --context $ALIAS$([[ $ENV == prod ]] && echo ' --allow-prod')"
    dim "  (it skips what is already granted, so a re-run only adds the new role)"
    problems=$((problems + 1))
  fi

  # CRD groups drift: the extra ClusterRole was generated from the groups present at bootstrap.
  # Both counts are forced to a single integer: a fallback `|| echo 0` on a command that already
  # printed would make this "0\n0" and turn the comparison below into an arithmetic error.
  live="$(kubectl get crd --context="$ALIAS" -o jsonpath='{range .items[*]}{.spec.group}{"\n"}{end}' 2>/dev/null | sort -u | grep -c . | head -1)"
  granted="$(kubectl get clusterrole k8s-triage-extra --context="$ALIAS" -o json 2>/dev/null \
    | python3 -c 'import json,sys
BUILTIN = {"", "metrics.k8s.io", "events.k8s.io", "apiextensions.k8s.io", "storage.k8s.io"}
try: d = json.load(sys.stdin)
except Exception: d = {}
n = {g for r in (d.get("rules") or []) for g in (r.get("apiGroups") or []) if g not in BUILTIN}
print(len(n))' 2>/dev/null | head -1)"
  live="${live:-0}"; granted="${granted:-0}"
  if [[ "$live" -gt 0 && "$granted" -gt 0 && "$live" -gt "$granted" ]]; then
    dim "note: $live CRD groups exist, $granted are readable — re-run bootstrap-sa.sh to pick up the new ones"
  fi
done

say ""
if [[ $problems -eq 0 ]]; then
  [[ $QUIET -eq 1 ]] || ok "every target is ready"
else
  warn "$problems target(s) need attention — see the commands above"
  dim "targets that are not ready simply fail closed; the rest keep working."
fi
if [[ $NOUT -gt 0 && $QUIET -eq 0 ]]; then
  say ""
  print_out_of_scope
fi
exit 0
