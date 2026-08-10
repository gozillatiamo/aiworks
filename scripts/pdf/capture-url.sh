#!/usr/bin/env bash
# scripts/pdf/capture-url.sh — screenshot a LIVE remote URL to PNG via headless Chrome.
#
#   printf '%s' "$url" | ./capture-url.sh <output.png> [--width 1280] [--height 800] \
#                                         [--wait-ms 3000] [--timeout 30000] [--full-page]
#
# The URL comes in on STDIN, not as an argument, and that is not a style choice: the pages this
# exists for (a provider's game-replay screen) carry a single-use token in the query string, and
# argv is readable by any process on the box through `ps`. Nothing here logs the query string.
#
# For rendering a LOCAL html/md document instead, use render.sh — same browser, different job.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=resolve-browser.sh
source "$DIR/resolve-browser.sh"
pdf_ensure_node_deps
pdf_resolve_browser

exec node "$DIR/capture-url.mjs" "$@"
