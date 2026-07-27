#!/usr/bin/env bash
# Fetch one trace's span waterfall from the configured observability backend.
#
#   ./get-trace.sh e1e2759e9ebb7852db237d93a52747b1
#   ./get-trace.sh e1e2759e9ebb7852db237d93a52747b1 --span 7e3cb99845dcf795
#   ./get-trace.sh e1e2759e9ebb7852db237d93a52747b1 --raw     # unparsed JSON
#
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF'
Usage: get-trace.sh <trace_id> [--span <span_id>] [--raw]

Print a trace's span waterfall (name, service, duration, status), indented by call
depth, from the backend selected by OBSERVABILITY_PROVIDER (signoz).

Arguments:
  <trace_id>          Trace id (from a SigNoz trace URL: /trace/<trace_id>).

Options:
  --span <span_id>    Mark this span in the output (from ?spanId=<span_id>).
  --env <name>        Which environment this trace belongs to (local | dev | staging | prod).
                      A trace id does not say where it came from, so this is the only way the
                      PII provenance vault can know a span payload is production-derived.
                      Pass --env prod when triaging prod; nothing is recorded otherwise.
  --raw               Print the raw JSON response instead of the parsed waterfall.
  -h, --help          Show this help and exit.

Environment:
  OBSERVABILITY_PROVIDER  signoz (default). Provider creds live in .env.
EOF
}

trace_id="" span_id="" env="" raw=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --span) span_id="${2:-}"; shift 2 ;;
    --env) env="${2:-}"; shift 2 ;;
    --raw) raw=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage; exit 1 ;;
    *) trace_id="$1"; shift ;;
  esac
done

[[ -n "$trace_id" ]] || { usage; exit 1; }

# shellcheck source=lib.sh
. "$DIR/lib.sh"

if [[ "$raw" -eq 1 ]]; then
  out="$(curl -sS -H "${SIGNOZ_AUTH_HEADER}: ${SIGNOZ_API_KEY}" "${SIGNOZ_BASE_URL}/api/v1/traces/${trace_id}" | jq '.')"
else
  out="$(obs_get_trace "$trace_id" "$span_id")"
fi
printf '%s\n' "$out"

# Only a caller-declared prod trace feeds the PII provenance vault (a trace id itself says
# nothing about its environment). Keyed hashes only — see docs/agents/pii-provenance.md.
case "$(printf '%s' "$env" | tr '[:upper:]' '[:lower:]')" in
  prod|production)
    printf '%s' "$out" | python3 "$DIR/../lib/pii_provenance.py" record - >/dev/null 2>&1 || true
    ;;
esac
