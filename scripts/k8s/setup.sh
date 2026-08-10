#!/usr/bin/env bash
#
# setup.sh — check that this machine can use the k8s_triage MCP, and say exactly what is missing.
#
# There is nothing to configure. The MCP derives its targets from the kubeconfig, so a teammate
# needs only two things per cluster, neither of which this script can grant itself:
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
#   scripts/k8s/setup.sh            # check every GKE target this kubeconfig can see
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

# Targets, derived the same way the MCP derives them: from each context's CLUSTER reference
# (gke_<project>_<region>_<cluster>), never from the context's personal alias.
# Read with a while-loop, not `mapfile` — that builtin arrived in bash 4 and macOS ships 3.2
# as /bin/bash (see the interpreter note in scripts/aiworks).
ROWS=(); NROWS=0
while IFS= read -r _row || [[ -n "$_row" ]]; do   # `|| [[ -n ]]` keeps a last line with no trailing \n
  [[ -n "$_row" ]] || continue
  ROWS+=("$_row"); NROWS=$((NROWS+1))
done < <(kubectl config view -o json 2>/dev/null | python3 -c '
import json, sys
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
            print("\t".join([product, env, project, cluster, alias]))
            break
' | sort -u)

if [[ $NROWS -eq 0 ]]; then
  [[ $QUIET -eq 1 ]] || dim "no GKE clusters in this kubeconfig — nothing to check"
  exit 0
fi

say ""
say "Kubernetes triage — $NROWS target(s) derived from kubeconfig"

problems=0
for row in "${ROWS[@]+"${ROWS[@]}"}"; do
  IFS=$'\t' read -r PRODUCT ENV PROJECT CLUSTER ALIAS <<<"$row"
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
exit 0
