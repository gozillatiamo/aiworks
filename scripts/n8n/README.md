# n8n MCP (on demand)

`n8n_mcp.py` is a stdio MCP that proxies a remote n8n MCP endpoint. It is registered by
`scripts/triage-mcp.sh sync` (Claude local scope, Cursor/Codex project scope) only when the
workspace `.env` sets both `N8N_MCP_URL` and `N8N_MCP_ACCESS_TOKEN`; it opens no connection until
a tool is called. Tools: `n8n_tools`, `n8n_call`, `disconnect`. See `docs/adr/0043`.

```bash
uv run scripts/n8n/n8n_mcp.py --selftest   # hermetic
uv run scripts/n8n/n8n_mcp.py --verify     # live: prints the remote tool count only
```
