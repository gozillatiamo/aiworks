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
# A local Harness outside the shared set is not an error: the local file is the highest-priority
# source and drives sync, doctor and the machine-local surfaces alike. It must come back
# verbatim, not intersected away.
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

# Registry dispatch: sync projects the ACTIVE set (local wins) and NEVER removes — a Harness
# absent from the set keeps whatever is on disk. `remove` is the only path that deletes: it runs
# the projector's --remove, drops the id from both config files, and clears the shared AGENTS.md
# only once no remaining active Harness consumes agents-md guidance.
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
# Local names only claude: nothing is projected, and NOTHING is removed — not codex (shared-only),
# not cursor (in neither file), not the AGENTS.md link.
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
test ! -s "$FIXTURE/calls"
test -L "$FIXTURE/AGENTS.md"
# Local names codex too (a local-only entry is a projection this machine maintains): projected.
printf 'harnesses:\n  - claude\n  - codex\n' > "$FIXTURE/workspace.config.local.yaml"
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
test "$(cat "$FIXTURE/calls")" = "codex "
: > "$FIXTURE/calls"
# Dropping codex from the SHARED file changes nothing on disk while the local file still has it…
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses claude >/dev/null
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
test "$(cat "$FIXTURE/calls")" = "codex "
: > "$FIXTURE/calls"
# …and dropping it from the LOCAL file too still deletes nothing: sync only adds and updates.
printf 'harnesses:\n  - claude\n' > "$FIXTURE/workspace.config.local.yaml"
"$FIXTURE/scripts/aiworks-harnesses.sh" sync
test ! -s "$FIXTURE/calls"
test -L "$FIXTURE/AGENTS.md"
# `remove` is the explicit path: -n previews without touching config, the real run calls the
# projector's --remove, drops the id from both files, and clears AGENTS.md once nothing reads it.
python3 "$HELPER" set --config "$FIXTURE/workspace.config.yaml" --registry "$REGISTRY" --harnesses claude,codex >/dev/null
printf 'harnesses:\n  - claude\n  - codex\n' > "$FIXTURE/workspace.config.local.yaml"
preview="$("$FIXTURE/scripts/aiworks-harnesses.sh" remove codex -n)"
printf '%s\n' "$preview" | grep -q 'would drop codex'
grep -q '^codex --remove --dry-run$' "$FIXTURE/calls"
grep -q '^  - codex$' "$FIXTURE/workspace.config.yaml"
test -L "$FIXTURE/AGENTS.md"
: > "$FIXTURE/calls"
"$FIXTURE/scripts/aiworks-harnesses.sh" remove codex
grep -q '^codex --remove$' "$FIXTURE/calls"
! grep -q 'codex' "$FIXTURE/workspace.config.yaml"
! grep -q 'codex' "$FIXTURE/workspace.config.local.yaml"
test ! -e "$FIXTURE/AGENTS.md"
: > "$FIXTURE/calls"
# Removing the last Harness is refused — config untouched, projector not called.
if "$FIXTURE/scripts/aiworks-harnesses.sh" remove claude 2>/dev/null; then
  echo "removing the last Harness should fail" >&2
  exit 1
fi
grep -q '^  - claude$' "$FIXTURE/workspace.config.yaml"
test ! -s "$FIXTURE/calls"
if "$FIXTURE/scripts/aiworks-harnesses.sh" remove hermes 2>/dev/null; then
  echo "removing an unregistered Harness should fail" >&2
  exit 1
fi

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

# ── Triage MCP registration is PROJECT scope for Cursor and Codex (docs/adr/0038) ────────────
# Each Harness gets a generated, git-ignored overlay AT THIS ROOT (`.cursor/mcp.json`,
# `.codex/config.toml`) rather than one shared machine-global file, so two checkouts on one
# machine never contend for the same entry. `scripts/triage-mcp.sh` (via this script) is the
# only writer; projectors only ever PRESERVE (ADR 0009), which is exercised in
# scripts/codex/selftest.sh and via aiworks-cursor.sh directly, not here.
git init -q "$FIXTURE"
cat > "$FIXTURE/.gitignore" <<'EOF'
/.cursor/mcp.json
/.codex/config.toml
EOF
printf '{"mcpServers":{"docs":{"command":"docs-mcp"}}}\n' > "$FIXTURE/.mcp.json"
cat > "$FIXTURE/workspace.config.yaml" <<'EOF'
harnesses:
  - cursor
  - codex
products: []
EOF
rm -f "$FIXTURE/workspace.config.local.yaml"
for rel in scripts/db/pg_triage_mcp.py scripts/redis/redis_triage_mcp.py \
           scripts/k8s/k8s_triage_mcp.py scripts/monitoring/monitoring_triage_mcp.py; do
  mkdir -p "$FIXTURE/$(dirname "$rel")"
  printf '#!/usr/bin/env python3\n' > "$FIXTURE/$rel"
done
rm -rf "$FIXTURE/scripts/codex"; cp -r "$ROOT/scripts/codex" "$FIXTURE/scripts/codex"
rm -rf "$FIXTURE/.cursor" "$FIXTURE/.codex"

GCURSOR="$FIXTURE/global-cursor.json"
CODEXHOME="$FIXTURE/codex-home"; mkdir -p "$CODEXHOME"
STUBBIN="$FIXTURE/bin"; mkdir -p "$STUBBIN"
cat > "$STUBBIN/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIXTURE/codex-calls"
EOF
chmod +x "$STUBBIN/codex"
: > "$FIXTURE/codex-calls"
R="$(cd "$FIXTURE" && pwd -P)"

trg() { AIWORKS_CURSOR_MCP_CONFIG="$GCURSOR" CODEX_HOME="$CODEXHOME" PATH="$STUBBIN:$PATH" \
        python3 "$FIXTURE/scripts/harnesses/triage_mcp.py" --root "$FIXTURE" "$@"; }
rndr() { python3 "$FIXTURE/scripts/harnesses/triage_mcp.py" --root "$FIXTURE" --render cursor; }

# 1. The legacy symlink, then `sync --want 1` → a real file with 5 servers (docs + 4 triage),
#    pg_triage pointed at THIS root. The global file's unrelated "mine" survives untouched.
printf '{"mcpServers":{"mine":{"command":"mine"}}}\n' > "$GCURSOR"
mkdir -p "$FIXTURE/.cursor"; ln -sf ../.mcp.json "$FIXTURE/.cursor/mcp.json"
trg --action sync --want 1 >/dev/null
test "$(jq '.mcpServers | length' "$FIXTURE/.cursor/mcp.json")" -eq 5
test "$(jq -r '.mcpServers.pg_triage.args[2]' "$FIXTURE/.cursor/mcp.json")" = "$R/scripts/db/pg_triage_mcp.py"
test "$(jq -r '.mcpServers | keys | join(",")' "$GCURSOR")" = mine

# 2. `--render cursor` (the projector's preserve-mode read) agrees byte-for-byte with the file
#    `sync` just wrote — the same render function backs both writers (docs/adr/0038 §2 Cursor).
diff <(rndr) "$FIXTURE/.cursor/mcp.json"

# 3. `sync --want 0` → the project file drops to `docs` only.
trg --action sync --want 0 >/dev/null
test "$(jq -r '.mcpServers | keys | join(",")' "$FIXTURE/.cursor/mcp.json")" = docs

# 4. Preserve: re-register, then widen `.mcp.json` with "other" → `--render` carries both plus
#    all four triage. Hand-edit one triage path off this root → `--render` drops only that one.
trg --action sync --want 1 >/dev/null
printf '{"mcpServers":{"docs":{"command":"docs-mcp"},"other":{"command":"other-mcp"}}}\n' > "$FIXTURE/.mcp.json"
test "$(rndr | jq -r '.mcpServers | keys | join(",")')" = "docs,k8s_triage,monitoring_triage,other,pg_triage,redis_triage"
tmp="$(mktemp)"; jq '.mcpServers.pg_triage.args[2] = "/elsewhere/scripts/db/pg_triage_mcp.py"' \
  "$FIXTURE/.cursor/mcp.json" > "$tmp"; mv "$tmp" "$FIXTURE/.cursor/mcp.json"
! rndr | jq -e '.mcpServers.pg_triage' >/dev/null
printf '{"mcpServers":{"docs":{"command":"docs-mcp"}}}\n' > "$FIXTURE/.mcp.json"   # reset for the rest

# 5. Migration classification: own leftover + dead leftover are removed; a live sibling and a
#    hand-made foreign command are both left exactly alone.
sib="$FIXTURE/sibling"; mkdir -p "$sib/scripts/k8s"
printf '#!/usr/bin/env python3\n' > "$sib/scripts/k8s/k8s_triage_mcp.py"
sib_live="$(cd "$sib" && pwd -P)/scripts/k8s/k8s_triage_mcp.py"
cat > "$GCURSOR" <<EOF
{"mcpServers":{
  "pg_triage": {"command":"uv","args":["run","--quiet","$R/scripts/db/pg_triage_mcp.py"]},
  "redis_triage": {"command":"uv","args":["run","--quiet","$FIXTURE/gone/scripts/redis/redis_triage_mcp.py"]},
  "k8s_triage": {"command":"uv","args":["run","--quiet","$sib_live"]},
  "monitoring_triage": {"command":"python3","args":["/x/monitoring_triage_mcp.py"]},
  "mine": {"command":"mine"}
}}
EOF
trg --action sync --want 1 >/dev/null
test "$(jq -r '.mcpServers | keys | join(",")' "$GCURSOR")" = "k8s_triage,mine,monitoring_triage"

# 6. `status` greps: before the sync above, each class reads distinctly; after it, the project
#    scope reads registered. (Re-seeded here so this case stands on its own.)
cat > "$GCURSOR" <<EOF
{"mcpServers":{
  "pg_triage": {"command":"uv","args":["run","--quiet","$R/scripts/db/pg_triage_mcp.py"]},
  "redis_triage": {"command":"uv","args":["run","--quiet","$FIXTURE/gone/scripts/redis/redis_triage_mcp.py"]},
  "k8s_triage": {"command":"uv","args":["run","--quiet","$sib_live"]}
}}
EOF
rm -f "$FIXTURE/.cursor/mcp.json"
out="$(trg --action status --want 1)"
printf '%s\n' "$out" | grep -q 'cursor/pg_triage — GLOBAL leftover from this workspace'
printf '%s\n' "$out" | grep -q 'cursor/redis_triage — GLOBAL leftover (path gone)'
printf '%s\n' "$out" | grep -q 'cursor/k8s_triage — GLOBAL entry owned elsewhere'
trg --action sync --want 1 >/dev/null
printf '%s\n' "$(trg --action status --want 1)" | grep -q 'cursor/pg_triage — registered (project scope)'

# 7. `--want 0` with a sibling global entry present → warns it is ACTIVE while triage is off, and
#    never touches it (Cursor has no mask; only Codex does, case 12).
printf '{"mcpServers":{"k8s_triage": {"command":"uv","args":["run","--quiet","%s"]}}}\n' "$sib_live" > "$GCURSOR"
printf '%s\n' "$(trg --action sync --want 0)" | grep -q 'ACTIVE here while triage is off'
test "$(jq -r '.mcpServers.k8s_triage.args[2]' "$GCURSOR")" = "$sib_live"

# 8. Guard: triage is refused into a tracked or un-ignored project file (docs/adr/0005's trust
#    boundary), and the file is left carrying no triage either way.
printf '{"mcpServers":{"docs":{"command":"docs-mcp"}}}\n' > "$FIXTURE/.cursor/mcp.json"
(cd "$FIXTURE" && git add -f .cursor/mcp.json) >/dev/null
rc=0; out="$(trg --action sync --want 1 2>&1)" || rc=$?
test "$rc" -eq 1
printf '%s\n' "$out" | grep -q 'is tracked by git'
! jq -e '.mcpServers.pg_triage' "$FIXTURE/.cursor/mcp.json" >/dev/null
(cd "$FIXTURE" && git rm --cached -q .cursor/mcp.json) >/dev/null
printf '/.codex/config.toml\n' > "$FIXTURE/.gitignore"   # drop the cursor line only
rc=0; out="$(trg --action sync --want 1 2>&1)" || rc=$?
test "$rc" -eq 1
printf '%s\n' "$out" | grep -q 'is not git-ignored'
cat > "$FIXTURE/.gitignore" <<'EOF'
/.cursor/mcp.json
/.codex/config.toml
EOF

# 9. An extra flag makes it somebody's own command even under this root's own path — left alone
#    (the shape test needs exactly 3 args; a hand-added flag is not this script's shape).
printf '{"mcpServers":{"pg_triage":{"command":"uv","args":["run","--quiet","--with","psycopg[binary]","%s"]}}}\n' \
  "$R/scripts/db/pg_triage_mcp.py" > "$GCURSOR"
trg --action sync --want 0 >/dev/null
test "$(jq -r '.mcpServers.pg_triage.args | length' "$GCURSOR")" -eq 5

# Codex — drives `generate.py` as a subprocess (scripts/codex/* copied into the fixture above).
printf '{"mcpServers":{}}\n' > "$GCURSOR"
rm -f "$CODEXHOME/config.toml"; : > "$FIXTURE/codex-calls"

# 10. `sync --want 1` → `.codex/config.toml` carries `[mcp_servers.pg_triage]` at THIS root's
#     path. Nothing in codex-calls names `add` — Codex is never told to register anything.
trg --action sync --want 1 >/dev/null
grep -q '^\[mcp_servers.pg_triage\]' "$FIXTURE/.codex/config.toml"
grep -q "$R/scripts/db/pg_triage_mcp.py" "$FIXTURE/.codex/config.toml"
! grep -q add "$FIXTURE/codex-calls"

# 11. The Codex GLOBAL config carries this root's own entry (own leftover) and a sibling's
#     (sibling) → only the own one is removed, via `codex mcp remove`.
cat > "$CODEXHOME/config.toml" <<EOF
[mcp_servers.pg_triage]
command = "uv"
args = ["run", "--quiet", "$R/scripts/db/pg_triage_mcp.py"]

[mcp_servers.k8s_triage]
command = "uv"
args = ["run", "--quiet", "$sib_live"]
EOF
: > "$FIXTURE/codex-calls"
trg --action sync --want 1 >/dev/null
grep -q 'mcp remove pg_triage' "$FIXTURE/codex-calls"
! grep -q k8s_triage "$FIXTURE/codex-calls"

# 12. `sync --want 0` → the project tables carry `enabled = false` — the MASK Codex needs since
#     its project layer merges into a same-named global entry field by field (unlike Cursor).
trg --action sync --want 0 >/dev/null
grep -A3 '^\[mcp_servers.pg_triage\]' "$FIXTURE/.codex/config.toml" | grep -q 'enabled = false'

printf 'Harness registry selftest: ok\n'
