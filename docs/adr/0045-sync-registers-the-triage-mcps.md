# `aiworks sync` registers the read-only triage MCPs

**Status:** Accepted. Amends [ADR 0009](0009-bring-up-never-bootstraps-deployed-access.md): the
MCP half returns to sync; the Kubernetes-identity half stands.

## Context

ADR 0009 took `scripts/triage-mcp.sh sync` out of `aiworks sync` so that a repo-onboarding sweep
would not "write something nobody asked for". The cost showed up on every fresh clone: after
`aiworks sync`, a teammate had no triage server in any Harness, the summary told them to run a
second command, and when they did, `triage-mcp.sh` refused on the two project-scope files that
ADR 0038 had declared git-ignored but `.gitignore` never listed:

```
! codex triage not written: .codex/config.toml is not git-ignored — add /.codex/config.toml to .gitignore first
! cursor triage not written: .cursor/mcp.json is not git-ignored — add /.cursor/mcp.json to .gitignore first
```

The tempting fix — commit the generated `.cursor/mcp.json` and `.codex/config.toml` so everyone
inherits them — was rejected again, for the reasons ADR 0038 already gave: every triage entry
carries the writing checkout's absolute path, the file's content depends on the personal
`triage.prod` toggle, and `triage_mcp.holds_triage_safely` refuses a tracked file by design.

## Decision

1. **`aiworks sync` runs `scripts/triage-mcp.sh sync` at the end of every run**, in every summary
   branch (0-repo, `--dry-run`, normal), after the projectors have written the files it fills.
   Under `--dry-run` it runs `sync -n`, which previews and changes nothing.
2. **It never changes sync's exit code.** `triage-mcp.sh` already warns and exits 0 when a
   Harness file refuses triage; a hard failure (no `jq`, invalid Harness config) is downgraded to
   a sync warning that names the command to re-run on its own.
3. **The opt-outs are unchanged.** `triage.enabled: false` skips the step and the stanza
   entirely. Production targets are still a separate, per-machine opt-in (`triage.prod` in
   `workspace.config.local.yaml`), read by `triage-mcp.sh` itself — sync widens nothing.
4. **The two project-scope files are git-ignored by the committed `.gitignore`**
   (`/.cursor/mcp.json`, `/.codex/config.toml`, anchored so a product clone's own `.cursor/mcp.json`
   is untouched), which is what ADR 0038 assumed all along.

## Why ADR 0009's first reason no longer holds

"Nobody asked for it" was true when registration was the surprise. Three things changed since:
the servers are read-only by construction (ADR 0005), the production targets are behind their own
local opt-in, and the Cursor/Codex registrations are project-scope files inside this checkout
(ADR 0038), not a global client config. What sync writes now is the workspace's own generated
overlays plus one machine-local Claude registration, all of which `triage.enabled: false` keeps
out. The remaining surprise — a teammate who did not expect triage at all — is the same
teammate who did not read `workspace.config.yaml`, and the summary still shows every line the
script printed.

ADR 0009's other two reasons were about the Kubernetes identity probe, and they are untouched:
sync still probes no cluster and still cannot run `bootstrap-sa.sh`.

## Consequences

- A fresh clone has triage after `aiworks sync` alone. `aiworks doctor` keeps its `triage` group
  as the independent check, with `scripts/triage-mcp.sh sync` as the owner command.
- `aiworks sync` now takes the time `triage-mcp.sh sync` takes: a few `claude mcp` reads and two
  file rewrites, no network.
- The summary's `Triage:` stanza shows the script's own `✓`/`!` lines instead of a one-line count.
