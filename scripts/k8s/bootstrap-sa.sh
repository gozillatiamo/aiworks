#!/usr/bin/env bash
#
# bootstrap-sa.sh — create the READ-ONLY deployed-environment triage identity for one cluster.
#
# The triage MCPs never use your own kubeconfig credential. They impersonate a dedicated service
# account whose permissions come from the cluster's RBAC and from project IAM, so "read-only" is
# enforced by the API server and by Google rather than by the MCPs' own code. This script is what
# creates that identity. See docs/adr/0007 and docs/adr/0010.
#
# ONE identity serves every read-only deployed-environment surface we have — a second account
# would double this ceremony for the same trust boundary, and every role below is a viewer:
#
#   identity   k8s-triage@<project>.iam.gserviceaccount.com   (one per GCP project, by convention)
#   authn      roles/container.clusterViewer on the project   (reach the control plane, nothing more)
#              roles/monitoring.viewer on the project         (Cloud Monitoring — scripts/monitoring/)
#   authz      ClusterRoleBinding -> the upstream `view` ClusterRole
#              ClusterRoleBinding -> `k8s-triage-extra` (nodes, metrics, CRDs — generated here)
#
# `view` deliberately excludes secrets, pods/exec and pods/portforward, and this script never
# grants them back: `k8s-triage-extra` names only non-core API groups plus nodes and metrics, so
# there is no rule under which the identity can read a Secret or open a shell.
#
# RUN AS A HUMAN, ONCE PER CLUSTER. It WRITES: a service account, two project IAM bindings, and two
# ClusterRoleBindings. Everything it writes is read-only in effect and removable (see `revoke`).
# Re-running is safe and is how an already-bootstrapped project picks up a newly added role: each
# grant checks for an existing binding first and reports it rather than rewriting it.
#
# Usage:
#   scripts/k8s/bootstrap-sa.sh --context <ctx> [--grant <email>] [-n]
#   scripts/k8s/bootstrap-sa.sh status --context <ctx>
#   scripts/k8s/bootstrap-sa.sh revoke --context <ctx>          # remove the bindings again
#
#   --context <ctx>   kubeconfig context to operate on; project + cluster + env are DERIVED from
#                     its `cluster` field (gke_<project>_<region>_<cluster>), never from the
#                     context's own name, which is a personal alias and differs per machine.
#   --grant <email>   also grant this person roles/iam.serviceAccountTokenCreator on the SA, i.e.
#                     the right to impersonate it. Repeatable. Defaults to the active gcloud
#                     account on a bootstrap run.
#   --allow-prod      required before it will touch a PRODUCTION cluster. Bootstrap staging first.
#   -n, --dry-run     print every mutating command instead of running it.
#
# CRD groups drift: the extra ClusterRole is generated from the API groups that exist in THIS
# cluster right now. `scripts/k8s/setup.sh` reports when new groups appear, and re-running this
# script is how you pick them up.
set -uo pipefail

c_ok=$'\033[32m'; c_warn=$'\033[33m'; c_err=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '    %s✓ %s%s\n' "$c_ok"   "$*" "$c_off"; }
warn() { printf '    %s! %s%s\n' "$c_warn" "$*" "$c_off"; }
die()  { printf '%serror: %s%s\n' "$c_err" "$*" "$c_off" >&2; exit 1; }
dim()  { printf '    %s%s%s\n'   "$c_dim"  "$*" "$c_off"; }
say()  { printf '  %s\n' "$*"; }

SA_NAME="k8s-triage"
EXTRA_ROLE="k8s-triage-extra"
BIND_VIEW="k8s-triage-view"
BIND_EXTRA="k8s-triage-extra"

ACTION="bootstrap"; CTX=""; DRY=0; ALLOW_PROD=0; GRANTS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    bootstrap|status|revoke) ACTION="$1"; shift ;;
    --context)    CTX="${2:-}"; shift 2 ;;
    --grant)      GRANTS+=("${2:-}"); shift 2 ;;
    --allow-prod) ALLOW_PROD=1; shift ;;
    -n|--dry-run) DRY=1; shift ;;
    -h|--help)    sed -n '3,38p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            die "unknown argument: $1" ;;
  esac
done

command -v gcloud  >/dev/null 2>&1 || die "gcloud is required"
command -v kubectl >/dev/null 2>&1 || die "kubectl is required"
[[ -n "$CTX" ]] || die "--context is required (kubectl config get-contexts)"

# ── derive project / cluster / env from the context's CLUSTER, not its alias ──────
CLUSTER_REF="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"$CTX\")].context.cluster}" 2>/dev/null)"
[[ -n "$CLUSTER_REF" ]] || die "no such context: $CTX"
IFS='_' read -r _gke PROJECT REGION CLUSTER <<<"$CLUSTER_REF"
[[ "$_gke" == "gke" && -n "$PROJECT" && -n "$CLUSTER" ]] \
  || die "context '$CTX' points at '$CLUSTER_REF', which is not a GKE cluster reference (gke_<project>_<region>_<cluster>)"

case "$CLUSTER" in
  *-prod)    ENV="prod" ;;
  *-staging) ENV="staging" ;;
  *) die "cannot derive an environment from cluster '$CLUSTER' — expected it to end in -prod or -staging" ;;
esac
PRODUCT="${CLUSTER%-$ENV}"
SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

say ""
say "context   $CTX"
say "cluster   $CLUSTER   (project $PROJECT, region $REGION)"
say "target    product=$PRODUCT env=$ENV"
say "identity  $SA_EMAIL"
say ""

if [[ "$ENV" == "prod" && "$ACTION" == "bootstrap" && $ALLOW_PROD -eq 0 ]]; then
  die "refusing to bootstrap a PRODUCTION cluster without --allow-prod. Bootstrap staging first and run the acceptance checks there."
fi

# Execute, or preview under -n. Silences stdout itself so that call sites never redirect it —
# a `>/dev/null` on the call would swallow the preview line and make a dry run look like a real
# one. stderr is left alone so a failure still explains itself.
run() {
  if [[ $DRY -eq 1 ]]; then dim "would run: $*"; return 0; fi
  "$@" >/dev/null
}

# Report a mutation in the tense that actually happened.
did() { if [[ $DRY -eq 1 ]]; then dim "would: $*"; else ok "$*"; fi; }

# ── status ────────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "status" ]]; then
  if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1; then
    ok "service account exists"
  else
    dim "service account missing"
  fi
  if gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
       --filter="bindings.members:serviceAccount:$SA_EMAIL AND bindings.role:roles/container.clusterViewer" \
       --format="value(bindings.role)" 2>/dev/null | grep -q .; then
    ok "roles/container.clusterViewer granted"
  else
    dim "roles/container.clusterViewer NOT granted"
  fi
  for b in "$BIND_VIEW" "$BIND_EXTRA"; do
    if kubectl get clusterrolebinding "$b" --context="$CTX" >/dev/null 2>&1; then
      ok "clusterrolebinding/$b present"
    else
      dim "clusterrolebinding/$b missing"
    fi
  done
  say ""
  say "effective permissions (impersonating the SA):"
  for c in "get pods" "get pods/log" "list events" "get nodes" \
           "get secrets" "delete pods" "patch deployments" "create pods/exec"; do
    # shellcheck disable=SC2086
    printf '    %-24s %s\n' "$c" "$(kubectl auth can-i $c --as="$SA_EMAIL" --context="$CTX" 2>/dev/null | grep -Ex 'yes|no' | head -1)"
  done
  exit 0
fi

# ── revoke ────────────────────────────────────────────────────────────────────────
if [[ "$ACTION" == "revoke" ]]; then
  for b in "$BIND_VIEW" "$BIND_EXTRA"; do
    run kubectl delete clusterrolebinding "$b" --context="$CTX" --ignore-not-found
  done
  run kubectl delete clusterrole "$EXTRA_ROLE" --context="$CTX" --ignore-not-found
  ok "cluster bindings removed from $CLUSTER"
  dim "the service account and its project IAM binding were left in place — remove them with:"
  dim "  gcloud iam service-accounts delete $SA_EMAIL --project $PROJECT"
  exit 0
fi

# ── 1. service account ────────────────────────────────────────────────────────────
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1; then
  ok "service account already exists"
else
  run gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" \
    --display-name "Kubernetes read-only triage" \
    --description "Impersonated by the k8s_triage MCP. Read-only; see docs/adr/0007." \
    || die "could not create the service account (need roles/iam.serviceAccountAdmin or owner on $PROJECT)"
  did "service account created"
  # A freshly created SA is not immediately visible to the IAM policy API: binding a role to it
  # right away fails with "Service account ... does not exist", which reads like a permission
  # problem and is not one. Wait for it to resolve before going on.
  if [[ $DRY -eq 0 ]]; then
    for _ in $(seq 1 30); do
      gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" >/dev/null 2>&1 && break
      sleep 2
    done
  fi
fi

# ── 2. authn: reach the control plane, and read what GCP measures ────────────────
# Two project roles on the SAME identity, granted the same way. One triage identity per project
# carries every read-only deployed-environment capability we have (docs/adr/0010): a second
# service account would double this ceremony for the same trust boundary, and both roles are
# viewers — the marginal reach of holding them together is a metric read.
grant_project_role() {
  local role="$1" why="$2"
  if gcloud projects get-iam-policy "$PROJECT" --flatten="bindings[].members" \
       --filter="bindings.members:serviceAccount:$SA_EMAIL AND bindings.role:$role" \
       --format="value(bindings.role)" 2>/dev/null | grep -q .; then
    ok "$role already granted"
    return 0
  fi
  # Retried, because IAM propagation after the SA is created is eventually consistent and the
  # first attempt can fail with a "does not exist" that resolves itself seconds later.
  local granted=0 last="" attempt
  for attempt in $(seq 1 10); do
    if [[ $DRY -eq 1 ]]; then
      dim "would grant $role to $SA_EMAIL on $PROJECT"
      granted=1; break
    fi
    last="$(gcloud projects add-iam-policy-binding "$PROJECT" \
      --member "serviceAccount:$SA_EMAIL" \
      --role "$role" \
      --condition=None --quiet 2>&1 >/dev/null)"
    if [[ $? -eq 0 ]]; then granted=1; break; fi
    case "$last" in
      *"does not exist"*) dim "IAM has not caught up yet (attempt $attempt/10) — retrying"; sleep 4 ;;
      *) break ;;
    esac
  done
  if [[ $granted -eq 0 ]]; then
    case "$last" in
      *PERMISSION_DENIED*|*"setIamPolicy"*|*"Permission "*)
        die "could not grant $role — this needs resourcemanager.projects.setIamPolicy (owner). roles/editor is NOT enough; ask an owner of $PROJECT to run this script." ;;
      *) die "could not grant $role: $last" ;;
    esac
  fi
  did "$role granted  ($why)"
}

grant_project_role roles/container.clusterViewer "reach the control plane, nothing more"
grant_project_role roles/monitoring.viewer "read Cloud Monitoring time series — scripts/monitoring/"

# ── 3. authz: view + the generated extra role ─────────────────────────────────────
# Non-core API groups only. Secrets live in the core ("") group, which is never named here, so
# `resources: ["*"]` inside these groups cannot reach one.
CRD_GROUPS="$(kubectl get crd --context="$CTX" -o jsonpath='{range .items[*]}{.spec.group}{"\n"}{end}' 2>/dev/null | sort -u | grep -v '^$')"
[[ -n "$CRD_GROUPS" ]] || warn "no CRDs found in this cluster — the extra role will cover nodes and metrics only"

{
  cat <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: $EXTRA_ROLE
  annotations:
    ai-workspace/managed-by: scripts/k8s/bootstrap-sa.sh
    ai-workspace/purpose: "read-only triage: what upstream 'view' leaves out"
rules:
  - apiGroups: [""]
    resources: ["nodes", "nodes/status"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["metrics.k8s.io"]
    resources: ["pods", "nodes"]
    verbs: ["get", "list"]
  - apiGroups: ["events.k8s.io"]
    resources: ["events"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses", "csinodes", "csidrivers", "volumeattachments"]
    verbs: ["get", "list", "watch"]
YAML
  if [[ -n "$CRD_GROUPS" ]]; then
    echo "  - apiGroups:"
    while IFS= read -r g; do echo "      - \"$g\""; done <<<"$CRD_GROUPS"
    echo '    resources: ["*"]'
    echo '    verbs: ["get", "list", "watch"]'
  fi
} > /tmp/k8s-triage-extra.$$.yaml

if [[ $DRY -eq 1 ]]; then
  dim "would apply clusterrole/$EXTRA_ROLE with $(wc -l </tmp/k8s-triage-extra.$$.yaml | tr -d ' ') lines, covering $(echo "$CRD_GROUPS" | grep -c .) CRD groups:"
  sed 's/^/      /' /tmp/k8s-triage-extra.$$.yaml | head -40
else
  kubectl apply --context="$CTX" -f /tmp/k8s-triage-extra.$$.yaml >/dev/null \
    || die "could not apply clusterrole/$EXTRA_ROLE"
  ok "clusterrole/$EXTRA_ROLE applied ($(echo "$CRD_GROUPS" | grep -c .) CRD groups)"
fi
rm -f /tmp/k8s-triage-extra.$$.yaml

bind() {
  local name="$1" role="$2"
  if kubectl get clusterrolebinding "$name" --context="$CTX" >/dev/null 2>&1; then
    ok "clusterrolebinding/$name already present"
  else
    run kubectl create clusterrolebinding "$name" \
      --context="$CTX" --clusterrole="$role" --user="$SA_EMAIL" \
      || die "could not create clusterrolebinding/$name"
    did "clusterrolebinding/$name created"
  fi
}
bind "$BIND_VIEW"  view
bind "$BIND_EXTRA" "$EXTRA_ROLE"

# ── 4. who may impersonate it ─────────────────────────────────────────────────────
if [[ ${#GRANTS[@]} -eq 0 ]]; then
  me="$(gcloud config get-value account 2>/dev/null)"
  [[ -n "$me" && "$me" != "(unset)" ]] && GRANTS=("$me")
fi
for person in "${GRANTS[@]}"; do
  [[ -n "$person" ]] || continue
  run gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project "$PROJECT" \
    --member "user:$person" \
    --role roles/iam.serviceAccountTokenCreator \
    --quiet \
    && did "$person may impersonate the identity" \
    || warn "could not grant impersonation to $person"
done

# ── 5. prove it ───────────────────────────────────────────────────────────────────
if [[ $DRY -eq 1 ]]; then
  say ""
  dim "dry run — nothing was changed. Re-run without -n to apply."
  exit 0
fi

say ""
say "acceptance checks — the identity must be able to read and unable to write:"
fail=0
check() {
  local want="$1" verb="$2" res="$3" got
  # Match yes/no exactly. A cluster-scoped resource makes kubectl emit a "not namespace scoped"
  # warning AND a blank line on stderr, so filtering only the warning leaves the blank line as
  # the first line and the check silently reads as a failure.
  got="$(kubectl auth can-i "$verb" "$res" --as="$SA_EMAIL" --context="$CTX" 2>/dev/null | grep -Ex 'yes|no' | head -1)"
  [[ -n "$got" ]] || got="(no answer)"
  if [[ "$got" == "$want" ]]; then
    printf '    %s✓ %-22s %s%s\n' "$c_ok" "$verb $res" "$got" "$c_off"
  else
    printf '    %s✗ %-22s %s (expected %s)%s\n' "$c_err" "$verb $res" "$got" "$want" "$c_off"
    fail=1
  fi
}
check yes get    pods
check yes get    pods/log
check yes list   events
check yes get    nodes
check no  get    secrets
check no  delete pods
check no  patch  deployments
check no  create pods/exec
check no  create pods/portforward

say ""
if [[ $fail -eq 0 ]]; then
  ok "$CLUSTER is ready — the triage identity can read and cannot write"
else
  die "the identity does not have the expected permissions; do NOT rely on it until this is resolved"
fi
