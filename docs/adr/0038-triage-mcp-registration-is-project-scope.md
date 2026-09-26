# Triage MCP registration is project scope for Cursor and Codex

## Context

`scripts/triage-mcp.sh sync` registers the four read-only deployed-environment triage MCPs
(`pg_triage`, `redis_triage`, `k8s_triage`, `monitoring_triage`, `docs/adr/0005`) for every selected
Harness. Claude registers them at `~/.claude.json`, which is genuinely machine-local: Claude Code has
no project-scope MCP file to write instead. Cursor and Codex do — a project's own `.cursor/mcp.json`
and `.codex/config.toml` — but the reconciler wrote both of them at **machine-global** scope too:
`~/.cursor/mcp.json` and `${CODEX_HOME:-~/.codex}/config.toml`.

That collides the moment a person keeps two checkouts of this workspace on one machine (a second
clone, or a worktree for a long-lived branch, exactly like the one this ADR was written in). Both
checkouts' `sync` write the **same** global key with **different** absolute script paths — whichever
ran last wins, and the other checkout's triage servers silently point at the wrong tree. The
existing "own vs. foreign" guard (a hand-edited command is left alone) cannot tell the two checkouts
apart, because both entries have the identical, machine-generated shape; it can only ever converge
on one winner, never on "both, correctly."

## Decision

1. **Cursor and Codex register in this root's own project scope.** `<root>/.cursor/mcp.json` and
   `<root>/.codex/config.toml` carry the four triage tables, each pointing at `<root>/scripts/...`.
   Two checkouts now each own their own file; there is nothing left to contend for. Claude is
   unchanged — it stays machine-local, because it has no project-scope alternative to move to.

2. **Both project files are generated and git-ignored, never committed.** `.cursor/mcp.json` is
   `.mcp.json`'s servers plus this root's triage entries (docs/adr/0004 — a fourth file joins the
   three already generated rather than symlinked); `.codex/config.toml` gains the same tables from
   `scripts/codex/generate.py`, the file's one writer. Neither file may ever hold triage unless it
   is tracked-clean and git-ignored first (`triage_mcp.holds_triage_safely`) — the same trust
   boundary `docs/adr/0005` already draws around registration, now enforced at write time instead of
   assumed.

3. **The projectors preserve; only `scripts/triage-mcp.sh sync` adds or removes.** `aiworks cursor`
   and `scripts/codex/generate.py` carry forward a triage entry only if it already matches exactly
   what this root would register — they never add one bring-up never asked for (`docs/adr/0009`). A
   plain projector run is therefore silent about triage either way: on if it was on, off if it
   was off.

4. **Codex gets a real off-switch; Cursor gets a warning instead.** Codex has no per-project
   "disabled" flag, so `off` writes a full table with `enabled = false` — a **mask** that overrides
   a same-named entry the user layer would otherwise merge in from a sibling workspace's global
   registration. Cursor has no equivalent mechanism: turning triage off here cannot hide a sibling's
   live global entry, so `sync` prints a warning instead of silently leaving stale access active.

5. **A leftover global registration is migrated, never a sibling's.** Every triage name found in
   the global file is classified before `sync` touches it:

   | Class | Test | Action |
   |---|---|---|
   | own leftover | shape matches this root's expected entry exactly | removed |
   | dead leftover | triage shape, but the script path no longer exists | removed |
   | sibling | triage shape, script path exists, belongs elsewhere | left alone |
   | foreign | anything else (a hand-made command) | left alone |

   Only this root's own or dead leftovers are ever removed from a global file; a live sibling keeps
   working until its own upgraded `sync` claims its entry as "own."

## Consequences

- A fresh clone has neither `<root>/.cursor/mcp.json` nor `<root>/.codex/config.toml` until
  `aiworks sync` runs the projectors once, and no triage until `scripts/triage-mcp.sh sync` runs.
  Both are one-time, explicit, and named by the tool that reports the gap.
- Upgrading past this change deletes both files' tracked history in one commit
  (`git rm --cached`). Existing machines keep their *own* global registrations until the next
  `scripts/triage-mcp.sh sync`, so there is no outage window: the old global entry keeps serving
  until the new project-scope one replaces it.
- Cursor cannot mask a sibling's still-active global entry while triage is off in this workspace.
  That is a known, accepted gap (not this ADR's to close) — the warning names it, and a person
  clears it by hand or by upgrading the sibling workspace.
- Codex only honours a project's `.codex/config.toml` for a **trusted** project. An untrusted root
  silently keeps whatever the user layer already provided — out of scope here, same as every other
  hook that already depends on Codex trust.
- `triage_mcp.py` is the single place that knows the expected shape and the classification rules for
  both Harnesses, so `scripts/codex/generate.py` and `scripts/aiworks-cursor.sh` each call into it
  rather than re-deriving "is this ours" independently.

## Alternatives rejected

- **`${workspaceFolder}` in a committed sidecar file.** Cursor supports the variable in
  `.cursor/mcp.json`, which would let a *committed* file resolve per-clone. Codex has no equivalent
  substitution, so the two Harnesses would still need different mechanisms, and a committed file
  reintroduces exactly the shared-file trust boundary `docs/adr/0005` requires local scope to avoid.
- **Org- or repo-prefixed global names** (`myorg_pg_triage`). Solves the collision without moving
  scope, but every existing global entry across every machine would need a one-time rename, and a
  third checkout still collides with a fourth under the same prefix — it only raises the number of
  checkouts before the same problem returns.
- **Keeping the machine-global entries and improving the "own vs. foreign" guard.** Rejected in
  §Context: two generated entries of identical shape are indistinguishable by construction; no
  smarter guard can tell them apart without the path already being part of the key, which is
  project scope by another name.
- **Committing the generated overlays.** Would put a real filesystem path — this machine's, this
  checkout's — into a file every clone reads, which is the shared-file boundary `docs/adr/0005`
  exists to keep triage out of.
