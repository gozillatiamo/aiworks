# /// script
# requires-python = ">=3.10"
# dependencies = [
#   "mcp>=1.8,<2",
# ]
# ///
# # The <2 bound is load-bearing: mcp 2.0 removed `mcp.server.fastmcp` (see pg_triage_mcp.py).
"""n8n — on-demand stdio MCP that proxies a remote n8n MCP endpoint (docs/adr/0043).

Registered like the triage servers (`scripts/triage-mcp.sh sync`), but wanted iff the workspace
`.env` (or the main checkout's, from a fresh linked worktree) sets BOTH `N8N_MCP_URL` and
`N8N_MCP_ACCESS_TOKEN`. Starting it opens no connection: the remote is only reached when a tool
is called, so a session that never touches n8n pays nothing and never blocks on it.

The token is read by THIS process and never passes through the agent, the MCP config or the
transcript; any error text is scrubbed of it before it is returned.

  n8n_tools()                 list the remote tools (name + description + input schema)
  n8n_call(tool, arguments)   call one remote tool, return its text content
  disconnect()                no-op teardown; sessions are per call

  uv run scripts/n8n/n8n_mcp.py --selftest   hermetic checks, no network
  uv run scripts/n8n/n8n_mcp.py --verify     live: list remote tools, print the count only
"""
from __future__ import annotations

import asyncio
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KEYS = ("N8N_MCP_URL", "N8N_MCP_ACCESS_TOKEN")


def env_file(root: Path = ROOT) -> Path:
    own = root / ".env"
    if own.is_file():
        return own
    try:
        out = subprocess.run(["git", "-C", str(root), "worktree", "list", "--porcelain"],
                             capture_output=True, text=True).stdout
    except OSError:
        return own
    first = out.splitlines()[0] if out else ""
    return Path(first[len("worktree "):]) / ".env" if first.startswith("worktree ") else own


def load(path: Path) -> tuple[str, str]:
    text = path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""
    vals = {}
    for k in KEYS:
        m = re.search(rf"^{k}=(.+)$", text, re.M)
        vals[k] = m.group(1).strip().strip("'\"") if m else ""
    missing = [k for k in KEYS if not vals[k]]
    if missing:
        raise RuntimeError(f"n8n MCP not configured: set {', '.join(missing)} in .env")
    return vals["N8N_MCP_URL"], vals["N8N_MCP_ACCESS_TOKEN"]


def scrub(text: str, token: str) -> str:
    return text.replace(token, "<redacted>") if token else text


async def _with_session(fn):
    from mcp import ClientSession
    from mcp.client.streamable_http import streamablehttp_client

    url, token = load(env_file())
    try:
        # ponytail: one HTTP session per call; keep a pooled session if call volume ever matters.
        async with streamablehttp_client(url, headers={"Authorization": f"Bearer {token}"}) as (r, w, _):
            async with ClientSession(r, w) as session:
                await session.initialize()
                return await fn(session)
    except Exception as exc:  # surface the reason, never the token
        raise RuntimeError(scrub(f"{type(exc).__name__}: {exc}", token)) from None


async def _tools(session):
    res = await session.list_tools()
    return [{"name": t.name, "description": t.description or "", "input_schema": t.inputSchema}
            for t in res.tools]


def selftest() -> None:
    import tempfile
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / ".env"
        p.write_text("N8N_MCP_URL=https://n8n.example.com/mcp\nN8N_MCP_ACCESS_TOKEN=\n")
        try:
            load(p)
            raise AssertionError("missing token accepted")
        except RuntimeError as e:
            assert "N8N_MCP_ACCESS_TOKEN" in str(e) and "example" not in str(e)
        p.write_text("N8N_MCP_URL=https://n8n.example.com/mcp\nN8N_MCP_ACCESS_TOKEN='tok-123'\n")
        assert load(p) == ("https://n8n.example.com/mcp", "tok-123")
        assert scrub("401 for Bearer tok-123", "tok-123") == "401 for Bearer <redacted>"
        assert env_file(Path(d)) == p
    print("n8n_mcp selftest: ok")


def main() -> None:
    if "--selftest" in sys.argv:
        return selftest()
    if "--verify" in sys.argv:
        print(f"n8n remote tools: {len(asyncio.run(_with_session(_tools)))}")
        return
    from mcp.server.fastmcp import FastMCP

    mcp = FastMCP("n8n")

    @mcp.tool()
    async def n8n_tools() -> list[dict]:
        """List the tools the remote n8n MCP exposes (name, description, input schema)."""
        return await _with_session(_tools)

    @mcp.tool()
    async def n8n_call(tool: str, arguments: dict | None = None) -> str:
        """Call one remote n8n MCP tool by name; returns its text content."""
        async def call(session):
            res = await session.call_tool(tool, arguments or {})
            text = "\n".join(getattr(c, "text", "") for c in res.content)
            return f"ERROR: {text}" if res.isError else text
        return await _with_session(call)

    @mcp.tool()
    def disconnect() -> dict:
        """Teardown. Sessions are opened per call, so nothing is ever left open."""
        return {"open_sessions": 0}

    mcp.run()


if __name__ == "__main__":
    main()
