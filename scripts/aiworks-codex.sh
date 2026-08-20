#!/usr/bin/env bash
# aiworks-codex.sh — project the canonical Claude configuration onto Codex.
#
# Usage:
#   aiworks codex [<repo> ...] [--check|-n|--remove]
#
# With no repo, projects the workspace root and every cloned repo declared in
# workspace.config.yaml. --check writes nothing and exits 1 on drift. --remove
# deletes only generator-owned Codex artifacts and the canonical skill symlink.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GEN="$DIR/codex/generate.py"

[[ -f "$GEN" ]] || { printf 'aiworks codex: missing %s\n' "$GEN" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'aiworks codex: python3 is required\n' >&2; exit 1; }

exec python3 "$GEN" --root "$ROOT" "$@"
