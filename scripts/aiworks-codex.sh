#!/usr/bin/env bash
# aiworks-codex.sh — project the canonical Claude configuration onto Codex.
#
# Usage:
#   aiworks codex [<repo> ...] [--check|-n|--remove]
#
# With no repo, projects the workspace root and every cloned repo declared in
# workspace.config.yaml. --remove deletes only generator-owned Codex artifacts and the
# canonical skill symlink.
#
# Exit codes — --check is the gate, and only --check (same rule as aiworks-cursor.sh):
#   0  in sync — and what a reconcile or a --dry-run preview always returns, since it did
#      everything it was allowed to do. Whatever it could not do it prints as
#      `needs a person: <target>: <message>`.
#   1  --check only: drift a reconcile WILL close. Run `aiworks codex`.
#   2  --check only: drift it will not — a real path where the canonical link belongs, a
#      generated file somebody edited, a rules file with no frontmatter, a source defect only
#      its author can settle. A repair pass must hand these to a person, not to a command.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
GEN="$DIR/codex/generate.py"

[[ -f "$GEN" ]] || { printf 'aiworks codex: missing %s\n' "$GEN" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf 'aiworks codex: python3 is required\n' >&2; exit 1; }

exec python3 "$GEN" --root "$ROOT" "$@"
