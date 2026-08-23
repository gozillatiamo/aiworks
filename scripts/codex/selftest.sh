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

# A REAL `.agents/skills` directory is refused and SURVIVES, and `--check` says so with exit 2.
#
# The shape below is the one that matters, and it is the reason this is not "reconciled" by
# comparing the two trees: the canonical skills live in `.agents/skills`, and `.claude/skills/*`
# symlinks INTO it. Compare the trees file by file and every file equals ITSELF, so a
# content-based rule declares the directory a redundant copy and deleting it destroys the only
# copy on disk. It happened, across 14 repos. The tree must survive this run untouched.
rm "$FIXTURE/.agents/skills"
mkdir -p "$FIXTURE/.agents/skills/legacy-skill"
printf 'the only copy of this file\n' > "$FIXTURE/.agents/skills/legacy-skill/SKILL.md"
ln -s ../../.agents/skills/legacy-skill "$FIXTURE/.claude/skills/legacy-skill"
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >"$FIXTURE/refuse.log" 2>&1
grep -q 'needs a person: workspace root: .agents/skills' "$FIXTURE/refuse.log"
test -f "$FIXTURE/.agents/skills/legacy-skill/SKILL.md"
grep -q 'the only copy' "$FIXTURE/.agents/skills/legacy-skill/SKILL.md"

# EXIT CODES. --check is the gate, and only --check — the same rule aiworks-cursor.sh:875 keeps,
# and the documented projector interface (docs/agents/harnesses.md) promises a --dry-run that
# previews "without writing or failing on expected drift". A reconcile did everything it was
# allowed to do, so it exits 0 and prints its `needs a person:` lines; failing it instead made
# `aiworks sync` warn "could not reconcile Harness projections" forever on a workspace holding
# one hand-written AGENTS.md, and made doctor --fix print `✗ failed` for a pass that had written
# every surface it was permitted to write.
#   2 = drift a reconcile will NOT close, so whoever is repairing must hand it to a person
set +e
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --check >/dev/null 2>&1; check_rc=$?
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null 2>&1;         write_rc=$?
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" -n >/dev/null 2>&1;      dry_rc=$?
set -e
test "$check_rc" -eq 2
test "$write_rc" -eq 0
test "$dry_rc" -eq 0

rm "$FIXTURE/.claude/skills/legacy-skill"
rm -rf "$FIXTURE/.agents/skills"
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null
test "$(readlink "$FIXTURE/.agents/skills")" = ../.claude/skills

#   1 = ordinary drift, which a reconcile really does close
rm "$FIXTURE/.codex/generated/rules.json"
set +e
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --check >/dev/null 2>&1; check_rc=$?
set -e
test "$check_rc" -eq 1
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --check >/dev/null

# A real user file is never overwritten or removed, and --check reports it as a person's call.
rm "$FIXTURE/.codex/hooks.json"
printf '{"hooks":{}}\n' > "$FIXTURE/.codex/hooks.json"
set +e
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --check >/dev/null 2>&1; check_rc=$?
set -e
test "$check_rc" -eq 2
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" >/dev/null
grep -q '^{"hooks":{}}$' "$FIXTURE/.codex/hooks.json"
python3 "$ROOT/scripts/codex/generate.py" --root "$FIXTURE" --remove >/dev/null
test -f "$FIXTURE/.codex/hooks.json"
test ! -e "$FIXTURE/.agents/skills"

printf 'codex projection selftest: ok\n'
