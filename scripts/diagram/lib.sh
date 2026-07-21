#!/usr/bin/env bash
# Diagram adapter — shared dispatch for the diagram scripts.
# Sourced by the entry scripts (render.sh, live-link.sh); not meant to run alone.
#
# Selects a provider implementation by DIAGRAM_PROVIDER (mermaid-ink) and sources
# scripts/diagram/<provider>/impl.sh, which defines the provider interface:
#
#   diagram_render     SOURCE_FILE OUT_FILE FORMAT THEME  — render Mermaid source to a
#                                                            local PNG/SVG at OUT_FILE
#   diagram_live_link  SOURCE_FILE THEME                  — print an edit-in-browser URL
#                                                            for the same Mermaid source
#
# SOURCE_FILE is a path to a file holding raw Mermaid text, or "-" for stdin.
#
# Like the notify adapter, the "should a diagram be generated at all" DECISION lives
# upstream — in workspace.config.yaml (diagrams.enabled) and the calling skill
# (/diagram-ticket). These scripts are low-level primitives and always render/link
# when invoked; they never re-check the config gate themselves.
#
# No secrets are needed today (mermaid.ink/mermaid.live are public, unauthenticated
# endpoints) — the .env load below is here only so a future self-hosted provider
# (e.g. an internal Kroki instance) can drop in an URL/token without touching callers.

set -euo pipefail

DIAGRAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load a .env sitting next to these scripts, if present (git-ignored local config).
if [[ -f "$DIAGRAM_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  . "$DIAGRAM_DIR/.env"
  set +a
fi

die() { echo "error: $*" >&2; exit 1; }
command -v curl   >/dev/null || die "curl is required"
command -v python3 >/dev/null || die "python3 is required (used to pako-encode the Mermaid source)"

# Which renderer backs this workspace. Defaults to mermaid-ink (the only provider today).
DIAGRAM_PROVIDER="${DIAGRAM_PROVIDER:-mermaid-ink}"
IMPL="$DIAGRAM_DIR/$DIAGRAM_PROVIDER/impl.sh"
[[ -f "$IMPL" ]] || die "unknown DIAGRAM_PROVIDER '$DIAGRAM_PROVIDER' (no $IMPL) — use 'mermaid-ink', or add an impl.sh under scripts/diagram/$DIAGRAM_PROVIDER/"
# shellcheck disable=SC1090
. "$IMPL"

# Read Mermaid source from a file path or "-" for stdin. Shared by both entry scripts.
diagram_read_source() {
  local src="$1"
  if [[ "$src" == "-" ]]; then
    cat
  else
    [[ -f "$src" ]] || die "no such file: $src"
    cat "$src"
  fi
}
