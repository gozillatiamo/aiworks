# Declared plugins install at project scope, and every copy is kept current

## Context

The workspace declares the plugins it needs in a committed `.claude/settings.json`
(`enabledPlugins` + `extraKnownMarketplaces`), and `ensure_claude_plugins` in `.superset/lib.sh`
installed them at **user** scope. The reasoning was reach: one install covered the workspace root,
every clone beside it and any other project on the machine, so a repo-only session still got the
hooks that carry the output and code rulesets into a session and its subagents.

Reach was real; currency was not. Three commands wrote to the same registry with different
defaults:

- `.superset/lib.sh` installed at **user** scope.
- `aiworks add` installs its per-repo plugin at **project** scope, and the Claude CLI itself
  registers a **project** entry for a project it is run in.
- `aiworks update` ran `claude plugin update <key>`, whose default scope is **user**.

So a project-scope entry existed that nothing ever refreshed. It stayed pinned to whatever
marketplace commit was cached the day it appeared while the user entry moved on: measured
2026-09-04, this workspace's root carried an output-ruleset plugin 19 days behind the machine's
user-scope copy — with the older ruleset missing rules the newer one had.

`aiworks doctor` reported that divergence, and prescribed the only fix that matched a user-scope
policy: uninstall the project copy. That fix could not hold. The uninstall also deletes the
plugin's line from the committed `settings.json` — the very declaration the workspace installs
from — and the next `aiworks setup`/`update`, or simply the next session opened in the project,
put the entry straight back. The person ran `aiworks update`, then `aiworks doctor --deep --fix`,
and got the same warning every time: a finding that survived its own owner command, which is the
one thing this doctor is not allowed to have.

## Decision

1. **Project scope is where a declared dependency is installed.** A workspace declares its
   plugins in a committed file, so the install that satisfies the declaration belongs to the same
   project — not to the machine of whoever cloned it. `ensure_claude_plugins` installs with
   `-s project`, run **in** the project, because the CLI resolves the project from the working
   directory.

2. **Reach is bought by walking, not by scope.** `ensure_claude_plugins` reconciles the workspace
   root *and* every clone beside it that declares plugins of its own, so a repo-only session is
   served by its own project's copy. One install per project is the price; it is paid by a loop,
   not by a machine-wide install nothing keeps in step.

3. **`aiworks update` refreshes every copy that exists.** For each declared plugin: each
   project copy under this workspace, updated in the project that owns it, plus a leftover
   user-scope copy if the machine has one. A copy nothing refreshes is the defect this ADR
   exists for, and that is true of a user-scope leftover too.

4. **A user-scope copy is never removed.** It serves the person's other projects. It is not a
   finding on its own — this project is served by its own copy — and deleting it would reach
   outside the workspace to fix something the workspace already fixed for itself.

5. **The doctor reports the two states that remain.** A declared plugin with no copy in *this*
   project is `declared plugin(s) not installed in this project`, owned by
   `ensure_claude_plugins` — the state `aiworks sync` leaves, since sync converges the
   declaration everywhere and installs nothing. Two copies that have parted are
   `project-scope plugin copy is out of step with the machine's user-scope copy`, owned by
   `aiworks update --only plugins`, which moves both forward. Every finding here is closed by
   the command that owns it.

## Consequences

- A fresh machine performs one install per project rather than one per machine. Setup is longer
  by that walk; nothing else changes for a person cloning the workspace.
- The registry now carries one entry per project for a declared plugin. That is intended: each
  entry is refreshed by the update path that created it.
- The restart check (`plugin updated since the last activation`) compares this project's copy,
  falling back to a user-scope one where that is all a machine has.
- A machine that used the workspace before this change keeps its user-scope copies. They are
  updated, not uninstalled, and the project copies become what its sessions serve.
