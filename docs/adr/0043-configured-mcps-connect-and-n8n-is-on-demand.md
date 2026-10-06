# Configured MCP servers connect on session start; n8n is on demand

**Status:** Accepted. Extends [ADR 0005](0005-deployed-env-triage-and-the-prod-gate.md) and [ADR 0038](0038-triage-mcp-registration-is-project-scope.md) for one non-triage server.

## Context

In a fresh linked worktree a session could start with every secret-backed MCP server failed even
though the person had configured all of them:

- The stdio wrappers loaded the worktree's own `.env`, which does not exist until setup copies it —
  and the session usually starts before that.
- `sonarqube` was an http entry whose `Authorization` header expanded `${SONARQUBE_TOKEN}` from
  the client's process env, which is only set when direnv ran in the launching shell.
- A shared, committed "disabled" entry decided per-person opt-in for everyone.
- `n8n` was a shared, always-on server: every session paid its start-up and its failures, though
  it is a remote, write-capable tool used only sometimes.

## Decision

1. A shared `.mcp.json` server that needs a secret is a **stdio wrapper that loads the secret
   itself** — from the workspace `.env`, falling back to the main checkout's — never `${VAR}` in an
   http header.
2. Approval for such a server is **per person**, written by `aiworks sync` when its config flag is
   on AND its key is present (presence only, never the value). No shared disabled entry.
3. A remote MCP used only sometimes **registers like triage** (`scripts/triage-mcp.sh`, Claude
   local scope, Cursor/Codex project scope): `n8n` is wanted iff both `N8N_MCP_URL` and
   `N8N_MCP_ACCESS_TOKEN` are set, opens no connection at start, connects per call
   (`n8n_tools`, `n8n_call`) and exposes `disconnect` as the teardown.

## Consequences

- A configured server connects in a brand-new worktree without `direnv allow`.
- `sonarqube` pays an `npx mcp-remote` start cost.
- n8n's remote tools are reached through `n8n_call`, not as first-class tools; a session that never
  uses n8n never contacts it.
