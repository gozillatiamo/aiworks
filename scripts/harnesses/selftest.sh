#!/usr/bin/env bash
# Offline fixture tests for Harness selection and registry-driven configuration.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d -t aiworks-harness-selftest)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

cat > "$FIXTURE/workspace.config.yaml" <<'EOF'
org:
  name: Fixture
products: []
EOF

HELPER="$ROOT/scripts/harnesses/config.py"
REGISTRY="$ROOT/scripts/harnesses/registry.json"
fallback="$(python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --fallback | tr '\n' ' ')"
test "$fallback" = "claude cursor "
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses codex,claude >/dev/null
selected="$(python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" | tr '\n' ' ')"
test "$selected" = "codex claude "
test "$(grep -c '^harnesses:$' "$FIXTURE/workspace.config.yaml")" -eq 1
cat > "$FIXTURE/workspace.config.local.yaml" <<'EOF'
harnesses:
  - codex
EOF
active="$(python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --config-local "$FIXTURE/workspace.config.local.yaml" --registry "$REGISTRY" | tr '\n' ' ')"
test "$active" = "codex "
# A local Harness outside the shared set is a machine-local activation, not an error: the
# active set drives only CLI/plugins/status line/local MCP, while every tracked projection is
# written from the SHARED set. It must come back verbatim, not intersected away.
printf 'harnesses:\n  - cursor\n' > "$FIXTURE/local-outside.yaml"
outside="$(python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --config-local "$FIXTURE/local-outside.yaml" --registry "$REGISTRY" | tr '\n' ' ')"
test "$outside" = "cursor "
printf 'harnesses: []\n' > "$FIXTURE/local-empty.yaml"
if python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --config-local "$FIXTURE/local-empty.yaml" --registry "$REGISTRY" >/dev/null 2>&1; then
  echo "an empty local Harness set should fail" >&2
  exit 1
fi
printf 'harnesses:\n  - hermes\n' > "$FIXTURE/local-unknown.yaml"
if python3 "$HELPER" list --config "$FIXTURE/workspace.config.yaml" --config-local "$FIXTURE/local-unknown.yaml" --registry "$REGISTRY" >/dev/null 2>&1; then
  echo "an unknown local Harness should fail" >&2
  exit 1
fi
if python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses hermes >/dev/null 2>&1; then
  echo "unregistered Hermes should fail until its adapter entry exists" >&2
  exit 1
fi
python3 "$HELPER" catalog --registry "$REGISTRY" | grep -q '^codex|Codex|'

# Registry dispatch: selected projector updates; deselected projector removes; shared AGENTS.md
# disappears only when no selected Harness consumes agents-md guidance.
mkdir -p "$FIXTURE/scripts/harnesses" "$FIXTURE/.claude/skills"
cp "$ROOT/scripts/aiworks-harnesses.sh" "$FIXTURE/scripts/"
cp "$HELPER" "$REGISTRY" "$FIXTURE/scripts/harnesses/"
cp "$ROOT/scripts/harnesses/triage_mcp.py" "$FIXTURE/scripts/harnesses/"
for projector in cursor codex; do
  cat > "$FIXTURE/scripts/aiworks-$projector.sh" <<EOF
#!/usr/bin/env bash
printf '$projector %s\n' "\$*" >> "$FIXTURE/calls"
EOF
  chmod +x "$FIXTURE/scripts/aiworks-$projector.sh"
done
printf '# Fixture\n' > "$FIXTURE/CLAUDE.md"
ln -s CLAUDE.md "$FIXTURE/AGENTS.md"
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses codex,claude >/dev/null
cat > "$FIXTURE/workspace.config.local.yaml" <<'EOF'
harnesses:
  - claude
EOF
shared="$("$FIXTURE/scripts/aiworks-harnesses.sh" list | tr '\n' ' ')"
test "$shared" = "codex claude "
active="$("$FIXTURE/scripts/aiworks-harnesses.sh" list --active | tr '\n' ' ')"
test "$active" = "claude "
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
grep -q '^cursor --remove$' "$FIXTURE/calls"
grep -q '^codex $' "$FIXTURE/calls"
test -L "$FIXTURE/AGENTS.md"
: > "$FIXTURE/calls"
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses claude >/dev/null
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
grep -q '^cursor --remove$' "$FIXTURE/calls"
grep -q '^codex --remove$' "$FIXTURE/calls"
test ! -e "$FIXTURE/AGENTS.md"

# Cursor statusline setup follows the active subset, not every shared projection.
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses cursor,codex >/dev/null
printf 'harnesses:\n  - codex\n' > "$FIXTURE/workspace.config.local.yaml"
AIWORKS_CURSOR_CONFIG="$FIXTURE/cursor-cli.json" bash -c "cd '$FIXTURE'; . '$ROOT/.superset/lib.sh'; ensure_harness_statuslines" >/dev/null
test ! -e "$FIXTURE/cursor-cli.json"
printf 'harnesses:\n  - cursor\n' > "$FIXTURE/workspace.config.local.yaml"
AIWORKS_CURSOR_CONFIG="$FIXTURE/cursor-cli.json" bash -c "cd '$FIXTURE'; . '$ROOT/.superset/lib.sh'; ensure_harness_statuslines" >/dev/null
jq -e '.statusLine.command | contains("caveman-statusline/statusline.sh")' "$FIXTURE/cursor-cli.json" >/dev/null
mcp_selected="$(PYTHONPATH="$FIXTURE/scripts/harnesses" python3 -c 'from pathlib import Path; from triage_mcp import selected; print(" ".join(sorted(selected(Path(__import__("sys").argv[1])))))' "$FIXTURE")"
test "$mcp_selected" = "cursor"
jq '.statusLine.command = "my-status"' "$FIXTURE/cursor-cli.json" > "$FIXTURE/cursor-user.json"
mv "$FIXTURE/cursor-user.json" "$FIXTURE/cursor-cli.json"
AIWORKS_CURSOR_CONFIG="$FIXTURE/cursor-cli.json" bash -c "cd '$FIXTURE'; . '$ROOT/.superset/lib.sh'; ensure_harness_statuslines" >/dev/null
test "$(jq -r '.statusLine.command' "$FIXTURE/cursor-cli.json")" = my-status

# Machine-local Cursor MCP registration preserves unrelated user servers and reconciles both ways.
printf '{"mcpServers":{"mine":{"command":"mine"}}}\n' > "$FIXTURE/cursor-mcp.json"
AIWORKS_CURSOR_MCP_CONFIG="$FIXTURE/cursor-mcp.json" python3 "$FIXTURE/scripts/harnesses/triage_mcp.py" \
  --root "$FIXTURE" --action sync --want 1 >/dev/null
test "$(jq '.mcpServers | length' "$FIXTURE/cursor-mcp.json")" -eq 5
AIWORKS_CURSOR_MCP_CONFIG="$FIXTURE/cursor-mcp.json" python3 "$FIXTURE/scripts/harnesses/triage_mcp.py" \
  --root "$FIXTURE" --action sync --want 0 >/dev/null
test "$(jq -r '.mcpServers | keys | join(",")' "$FIXTURE/cursor-mcp.json")" = mine

# A DEAD registration this script wrote from a workspace root that is gone — the shape a deleted
# worktree leaves behind. It used to be read as a foreign command and left alone forever, so
# `sync` no-opped and still exited 0. It is repointed; a genuinely foreign command under the same
# name is still not touched.
mcp() { AIWORKS_CURSOR_MCP_CONFIG="$FIXTURE/cursor-mcp.json" \
        python3 "$FIXTURE/scripts/harnesses/triage_mcp.py" --root "$FIXTURE" "$@"; }
printf '{"mcpServers":{"pg_triage":{"command":"uv","args":["run","--quiet","/gone/worktree/scripts/db/pg_triage_mcp.py"]},"k8s_triage":{"command":"python3","args":["/somebody/elses/k8s_triage_mcp.py"]}}}\n' \
  > "$FIXTURE/cursor-mcp.json"
mcp --action sync --want 1 >/dev/null
test "$(jq -r '.mcpServers.pg_triage.args[2]' "$FIXTURE/cursor-mcp.json")" \
   = "$(cd "$FIXTURE" && pwd -P)/scripts/db/pg_triage_mcp.py"
test "$(jq -r '.mcpServers.k8s_triage.command' "$FIXTURE/cursor-mcp.json")" = python3
# …and `status` says which of the two it is, in words the doctor can tell apart.
printf '{"mcpServers":{"pg_triage":{"command":"uv","args":["run","--quiet","/gone/worktree/scripts/db/pg_triage_mcp.py"]}}}\n' \
  > "$FIXTURE/cursor-mcp.json"
mcp --action status --want 1 | grep -q 'cursor/pg_triage — STALE path'

# THE SIBLING. Cursor's config is one machine-GLOBAL file and `codex mcp` has no scope, so a
# second checkout on the same machine sees the identical shape pointing at a LIVE script. Shape
# alone must therefore never mean "stale": repointing that takes a working server away from the
# other root, and with `triage.enabled: false` here the deregister branch would delete it
# outright — an entry this script never wrote from this root. Both must be no-ops.
sib="$FIXTURE/sibling"; mkdir -p "$sib/scripts/db"
printf '#!/usr/bin/env python3\n' > "$sib/scripts/db/pg_triage_mcp.py"
live="$(cd "$sib" && pwd -P)/scripts/db/pg_triage_mcp.py"
printf '{"mcpServers":{"pg_triage":{"command":"uv","args":["run","--quiet","%s"]}}}\n' "$live" \
  > "$FIXTURE/cursor-mcp.json"
mcp --action status --want 1 | grep -q 'cursor/pg_triage — not registered'
mcp --action sync --want 1 >/dev/null
test "$(jq -r '.mcpServers.pg_triage.args[2]' "$FIXTURE/cursor-mcp.json")" = "$live"
mcp --action sync --want 0 >/dev/null
test "$(jq -r '.mcpServers.pg_triage.args[2]' "$FIXTURE/cursor-mcp.json")" = "$live"

# An extra flag makes it somebody's own command even when the path is this root's — the bash twin
# globbed across spaces and would have stripped the flag on the way back.
printf '{"mcpServers":{"pg_triage":{"command":"uv","args":["run","--quiet","--with","psycopg[binary]","%s"]}}}\n' \
  "$(cd "$FIXTURE" && pwd -P)/scripts/db/pg_triage_mcp.py" > "$FIXTURE/cursor-mcp.json"
mcp --action sync --want 0 >/dev/null
test "$(jq -r '.mcpServers.pg_triage.args | length' "$FIXTURE/cursor-mcp.json")" -eq 5

printf 'Harness registry selftest: ok\n'
