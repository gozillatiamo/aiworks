# The local Harness set drives sync, and sync never removes a projection

## Context

`harnesses:` can be declared in two files: the shared `workspace.config.yaml` and the git-ignored
`workspace.config.local.yaml`. Until now the two had different jobs. The local file drove only
machine-local surfaces — CLI install, plugins, status line, this machine's MCP registrations —
while every writer of a tracked file read the **shared** set. `aiworks harnesses sync` projected
what the shared file named and ran `<projector> --remove` for every registered Harness it did not.

That contract was built for one guarantee: a personal preference can never dirty a shared
checkout. It failed the case it met first. A person enabled Cursor and Codex locally, committed
the generated projections to share them, and the next `aiworks sync -y` deleted every one of them
because the shared file did not list those Harnesses. Adding them to the shared file and then
removing them again deleted them a second time. Removal was a side effect of an absence, so the
same command a teammate runs to *get* the workspace could silently take a committed projection
away from them.

## Decision

1. **The local file wins.** When `workspace.config.local.yaml` names a non-empty `harnesses:`,
   that is the effective set for every consumer — `aiworks sync`, `aiworks doctor`, and the
   machine-local surfaces alike. `list --active` is the set that matters; `list` is only the
   shared default for machines that have no local file.
2. **Sync only adds and updates.** A Harness absent from the effective set is left exactly as it
   is on disk. Dropping an id from either config file deletes nothing.
3. **Removal is explicit.** `aiworks remove --harnesses <id>[,<id>]` (also
   `aiworks harnesses remove`) is the only path that deletes a projection. It runs the projector's
   `--remove` — generator-owned artifacts only, its existing contract — drops the id from **both**
   config files so the next sync does not project it straight back, and clears the generator-owned
   `AGENTS.md` once no remaining active Harness reads it. Removing the last Harness is refused.

## Consequences

- A projection generated from a local-only Harness is a first-class thing to commit. Teammates
  whose local file omits that Harness keep it: their sync neither refreshes nor removes it, and
  `aiworks doctor` says so as `shared-only Harness` at the advisory tier rather than as a finding.
- Doctor's projection checks (`cursor projection`, `codex projection`) key on the active set. A
  Harness the shared file names but the local file omits is no longer checked on that machine —
  it is not that machine's to maintain.
- The old "local-only Harness gets no projection" advisory is gone; it described a rule that no
  longer exists.
- A stale projection can now outlive its config entry on a machine whose owner never runs
  `aiworks remove --harnesses`. That is the intended trade: a stray directory nobody reads costs
  nothing, a deleted committed projection costs a teammate their tooling.

## Rejected

- **Union of shared and local.** A person who wants *fewer* Harnesses than the team could never
  express it; the override would only ever add.
- **Sync removes, but only what is untracked.** Whether a file is committed says nothing about
  whether its owner wants it gone, and the check would race every uncommitted regeneration.
- **A `--prune` flag on sync.** Deletion hidden behind a flag on the command everybody runs is the
  shape that caused this; a verb of its own is harder to reach by accident.
