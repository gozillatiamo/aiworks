#!/usr/bin/env bash
# Offline fixture tests for the Codex Harness projection.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d -t aiworks-codex-selftest)"
cleanup() { rm -rf "$FIXTURE"; }
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/agents" "$FIXTURE/.claude/skills/review" "$FIXTURE/.claude/rules" "$FIXTURE/.git"
cat > "$FIXTURE/CLAUDE.md" <<'EOF'
# Fixture
EOF
cat > "$FIXTURE/.claude/skills/review/SKILL.md" <<'EOF'
---
name: review
description: Fixture review skill.
---
Review carefully.
EOF
cat > "$FIXTURE/.claude/agents/reviewer.md" <<'EOF'
---
name: reviewer
description: Fixture reviewer.
model: sonnet
effort: high
permissionMode: plan
maxTurns: 7
skills:
  - review
tools:
  - Read
  - Grep
---
Stay read-only and return evidence.
EOF
cat > "$FIXTURE/.claude/rules/src.md" <<'EOF'
---
paths:
  - "src/**"
---
# Fixture scoped rule
SCOPED_RULE_MARKER
EOF
cat > "$FIXTURE/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write|Edit",
        "hooks": [
          {"type":"command","command":"test -n \"$CLAUDE_PROJECT_DIR\"","timeout":10}
        ]
      }
    ]
  }
}
EOF
cat > "$FIXTURE/.mcp.json" <<'EOF'
{"mcpServers":{"docs":{"type":"stdio","command":"docs-mcp","args":["serve"]}}}
EOF
cat > "$FIXTURE/workspace.config.yaml" <<'EOF'
harnesses:
  - codex
products: []
EOF

python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null
test "$(readlink "$FIXTURE/AGENTS.md")" = CLAUDE.md
test "$(readlink "$FIXTURE/.agents/skills")" = ../.claude/skills
grep -q 'model = "gpt-5.6-terra"' "$FIXTURE/.codex/agents/reviewer.toml"
grep -q 'model_reasoning_effort = "high"' "$FIXTURE/.codex/agents/reviewer.toml"
grep -q 'sandbox_mode = "read-only"' "$FIXTURE/.codex/agents/reviewer.toml"
grep -q 'canonical role ceiling is 7' "$FIXTURE/.codex/agents/reviewer.toml"
grep -q '^\[mcp_servers.docs\]' "$FIXTURE/.codex/config.toml"
jq -e '.hooks.PreToolUse | length > 0' "$FIXTURE/.codex/hooks.json" >/dev/null
jq -e '.native_agent_permissions.status == "conservative"' "$FIXTURE/.codex/generated/compatibility.json" >/dev/null

second="$(python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE")"
printf '%s' "$second" | grep -q 'changed=0 drift=0'
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --check >/dev/null

allowed='{"cwd":"FIXTURE","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"rg marker src"}}'
allowed="${allowed/FIXTURE/$FIXTURE}"
test -z "$(printf '%s' "$allowed" | PYTHONPATH="$ROOT/scripts/codex" python3 "$ROOT/scripts/codex/tool_guard.py" reviewer)"
denied='{"cwd":"FIXTURE","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch"}}'
denied="${denied/FIXTURE/$FIXTURE}"
printf '%s' "$denied" | PYTHONPATH="$ROOT/scripts/codex" python3 "$ROOT/scripts/codex/tool_guard.py" reviewer \
  | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

session="fixture-$$-$RANDOM"
payload='{"cwd":"FIXTURE","session_id":"SESSION","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: src/a.js\n*** End Patch"}}'
payload="${payload/FIXTURE/$FIXTURE}"
payload="${payload/SESSION/$session}"
printf '%s' "$payload" | python3 "$FIXTURE/.codex/hooks/rule_context.py" | grep -q SCOPED_RULE_MARKER
test -z "$(printf '%s' "$payload" | python3 "$FIXTURE/.codex/hooks/rule_context.py")"

# A real user file is never overwritten or removed.
rm "$FIXTURE/.codex/hooks.json"
printf '{"hooks":{}}\n' > "$FIXTURE/.codex/hooks.json"
if python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null 2>&1; then
  echo "expected unmanaged hooks.json conflict" >&2
  exit 1
fi
grep -q '^{"hooks":{}}$' "$FIXTURE/.codex/hooks.json"
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --remove >/dev/null
test -f "$FIXTURE/.codex/hooks.json"
test ! -e "$FIXTURE/.agents/skills"

printf 'codex projection selftest: ok\n'
