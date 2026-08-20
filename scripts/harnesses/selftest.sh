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
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses codex >/dev/null
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

# Cursor statusline setup writes the command only when absent and preserves a user's command.
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses cursor >/dev/null
AIWORKS_CURSOR_CONFIG="$FIXTURE/cursor-cli.json" bash -c "cd '$FIXTURE'; . '$ROOT/.superset/lib.sh'; ensure_harness_statuslines" >/dev/null
jq -e '.statusLine.command | contains("caveman-statusline/statusline.sh")' "$FIXTURE/cursor-cli.json" >/dev/null
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

printf 'Harness registry selftest: ok\n'
