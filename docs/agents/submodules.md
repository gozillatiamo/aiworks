# Git submodule conventions

The single reference for how agents work with **git submodules** in this workspace. The
coding-lifecycle skills (`ticket-kickoff`, `coding-feature`, `self-control-gitflow`)
consult this file so a change to submodule'd code always lands in the right repo.

## The rule: never develop inside a submodule checkout

Some primary clones at the workspace root embed **another** of the workspace's repos as a
git **submodule** — and that same repo is *also* cloned as its own primary clone at the
root. A submodule checkout is a **read-only pointer**: a detached-HEAD snapshot the
superproject pins to one commit, not a place to develop.

**Never edit, add, or commit inside a submodule checkout.** Make the change in the repo's
**primary clone at the workspace root** (the one `mani` cloned) — branch, commit, and open
the PR/MR there. Bumping the superproject's pointer to the merged commit is a separate,
deliberate step, not this skill's job.

Current instances in this workspace (illustrative — detect from git, don't trust the list to stay current):

| Submodule checkout — do NOT touch | Is really the repo | Develop here instead (primary clone at root) |
|---|---|---|
| `agent-webservice/agent-db/` | `agent-db` | `agent-db/` |
| `commission-batch/agent-db/` | `agent-db` | `agent-db/` |
| `paotung-template/packages/customization-widget/` | `customization-widget` | `customization-widget/` |

## Detect it before you edit — two angles, check both

**Are you standing inside a submodule?** Inside one, `git rev-parse --show-toplevel`
happily returns the *submodule's* own dir (it is a real repo), so that check alone won't
save you. The tell is the superproject:

```sh
git rev-parse --show-superproject-working-tree   # NON-EMPTY ⇒ you are inside a submodule — STOP
```

**Is the file you're about to touch under a submodule?** Any `path` in the current repo's
`.gitmodules` is a submodule mount:

```sh
git config -f .gitmodules --get-regexp '\.path$'   # e.g. "submodule.agent-db.path agent-db"
```

A target under one of those paths must be redirected before you write.

## Redirect to the primary clone

Map the submodule to its primary clone at the workspace root by repo name:

```sh
url="$(git -C <submodule-path> config --get remote.origin.url)"   # …/agent-db.git
repo="$(basename "$url" .git)"                                    # agent-db
# primary clone = <workspace-root>/$repo   (what `mani` cloned; confirm with `mani list projects`)
```

`cd` to that primary clone and run `git rev-parse --show-superproject-working-tree` there
to confirm it comes back **empty** (a true primary clone, not yet another submodule), then
do the branch → edit → commit → PR work there.
