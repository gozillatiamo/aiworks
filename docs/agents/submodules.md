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

### Inside a dev-cycle run, a pointer move is the ONE sanctioned write — and it does not wait for a merge

A pointer move is a commit in the **superproject**, so it is not a write inside the checkout and the
guard does not touch it. When a `dev-cycle` run touches both a repo and something that vendors it,
the vendoring repo is built in a **later wave** and pins to the upstream's *pushed* branch tip —
unmerged, on purpose. A submodule pointer needs a commit that exists on the remote, not a merged
one, and waiting for the merge is what used to cost the ticket a whole extra round. The pointer is
re-aimed at the merged sha by the run's `submodule-bump` ship step, after the upstream lands and
before the downstream does. → [ADR 0031](../adr/0031-a-submodule-pin-needs-a-pushed-commit-not-a-merge.md)

### …but READING one is fine, and so is a checkout that proves something

The prohibition is on **create / edit / commit**, and on nothing else. Inspecting a
submodule, and moving its ref to answer a question, are ordinary work:

```sh
git -C <sub> status                 # fine
git -C <sub> show <ref>:<path>      # fine
git -C <sub> diff / log / fetch     # fine
git -C <sub> checkout <ref>         # fine — a BARE ref checkout, to prove something
```

That last one matters for review. "Does this suite go green once the pointer is bumped?"
is answerable only by moving the ref and running the suite, and the difference between a
finding that says *"I reasoned it will fail"* and one that says *"I ran it and it failed"*
is the difference between an unverified claim handed back to a human and a settled one.
Restore the original ref when you are done, or work in a throwaway `git worktree add`.

What stays blocked is anything that writes: `add` · `commit` · `push` · `merge` · `rebase` ·
`cherry-pick` · `apply` · `reset` · `restore` · `stash push` · `checkout -b` / `switch -c`
(branch creation) — plus a plain filesystem write into the checkout (`cp`, `mv`, `rm`,
`sed -i`, a `>` redirect, or a `Write`/`Edit` tool call).

### It is enforced, not remembered

`.claude/hooks/dev-wrapper/pretool-submodule-guard.sh` (`PreToolUse` on `Bash` and on
`Write|Edit|NotebookEdit`) blocks the write half and **pre-approves** the read half.

The pre-approval is the part worth knowing about. Added 2026-07-27 after the OFB-2179
review, where this rule was prose-only and the outcome was exactly inverted: nothing
mechanically stopped a write, while a read-only proof got denied anyway — by Claude Code's
auto-mode permission classifier, which silently refused 8 commands that run in that
session, among them

```sh
git -C agent-db checkout --detach origin/feature/OFB-2179 2>&1 | tail -2 && ls … && ./scripts/dev.sh test …
git -C … status --porcelain | head -30
git show <ref>:src/routes/reconcile_transaction_route.rs | sed -n '236,300p'
```

All 8 were **compound** commands. A static allow rule (`Bash(git *)`) is prefix-matched
against the WHOLE command string, so anything wrapped in `cd … && …`, a pipe, or a heredoc
matches no allow rule and falls through to the classifier. The guard closes that by
emitting `permissionDecision: allow` itself.

Two properties keep that narrow, and both are pinned by cases in
`.claude/hooks/dev-wrapper/guards-selftest.sh`:

- **Whole-command, so all-or-nothing.** `permissionDecision: allow` approves the entire
  command, not the segment that earned it — so the guard pre-approves only when *every*
  segment is in its recognized read-only set. `git -C <sub> status && curl http://evil/`
  gets no pre-approval.
- **Secrets are somebody else's job.** `git show <ref>:.env` is read-only and still a leak,
  so the guard stands aside (no verdict) on anything secrets-shaped and lets
  `pretool-env-guard.sh` block it.

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
