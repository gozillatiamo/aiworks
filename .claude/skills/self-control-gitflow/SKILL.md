---
name: self-control-gitflow
description: Git branch + PR/MR lifecycle around a coding task. START — branch a fresh `feature/<KEY>` branch off the latest default branch before any coding. FINISH (only after all tests pass) — commit, push, open a PR/MR to the parent/default branch, and squash-merge it yourself via the VCS adapter. Use right before implementation begins, and again once the suite is green (pairs with coding-automate).
argument-hint: "[start|finish] [ticket]"
allowed-tools:
  - Bash(git *)
  - Bash(scripts/vcs/*)
---

# self-control-gitflow

Two-phase git flow around a coding task: branch before coding, PR/MR + self squash-merge
after the suite passes. Host operations go through the **VCS adapter** (`scripts/vcs/`,
`github`|`gitlab`) — never call `gh`/`glab` directly.

**Confirm the repo FIRST — every time.** This is a multi-repo workspace, so before any
`git`/adapter command run `git rev-parse --show-toplevel` and make sure it's the repo you
mean to change. Run all commands from that root.

**And confirm it's not a submodule.** `--show-toplevel` returns a *submodule's* own dir too,
so it can't tell a primary clone from a submodule checkout. Also run `git rev-parse
--show-superproject-working-tree` — if it's **non-empty** you're inside a submodule; never
branch/commit/push here. Switch to the repo's primary clone at the workspace root and run
the lifecycle there instead. See the workspace-root `docs/agents/submodules.md`.

**Pick the phase** from the argument (`start` / `finish`); if none given, auto-detect: on
the default branch → **START**; on a feature branch → **FINISH**.

Detect the default (parent) branch once and reuse it:
```sh
base="$(scripts/vcs/default-branch.sh)"
```

## START — branch before coding

Goal: a clean feature branch off the newest default branch, so coding never happens on the base.

1. Confirm the repo root. If the working tree has changes you don't intend to carry onto the new branch, stop and have them committed/stashed/cleaned first.
2. Sync the base: `git fetch origin && git switch "$base" && git pull --ff-only origin "$base"`.
3. Create the branch named for the ticket: `git switch -c "feature/<KEY>"`.
   - The branch name is **`feature/` + the ticket key** — e.g. `feature/FM-9`, `feature/APP-123`. Normalize the key to uppercase; no slug, no description.
4. Report the new branch and its base, then hand back so coding can start.

## FINISH — PR/MR + self squash-merge (only after ALL tests pass)

**Precondition: the suite is green.** Never run FINISH on a red suite, and never from the default branch.

1. `head="$(git rev-parse --abbrev-ref HEAD)"`; refuse if `head` == `base` (you're on the default branch — nothing to PR).
2. Commit the work if the tree is dirty: `git add -A && git commit -m "<concise change summary>"`. End the commit message with:
   ```
   Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
   ```
   If there are no commits ahead of `base` (`git rev-list --count "$base..$head"` is 0), there's nothing to merge — stop and say so.
3. Open the PR/MR to the parent/default branch (the adapter pushes the branch for you). Title it per **Conventional Commits**, deriving the type from the branch prefix — `feature/<KEY>` → `feat(<KEY>): <title>`, `fix/<KEY>` → `fix(<KEY>): <title>`:
   ```sh
   scripts/vcs/open-pr.sh --base "$base" --head "$head" --title "<type>(<KEY>): <title>" --body "<summary>"
   ```
   End the PR/MR body with:
   ```
   🤖 Generated with [Claude Code](https://claude.com/claude-code)
   ```
   The adapter prints the URL and `number=<n>`.
4. **Auto-merge gate.** Read `vcs.auto_merge` from `workspace.config.yaml` (and this repo's
   `products[].repos[].auto_merge` override if it has one — the per-repo value wins). If the
   effective value is **false**, STOP here: leave the PR/MR **open**, report its URL + number and
   that it is awaiting a human merge (auto-merge is off), then skip steps 5–6 — do **not** merge.
   If it is **true** (the default), continue.
5. Squash-merge it yourself (server-side, so the web PR/MR shows Merged). Use the same Conventional Commits subject as the PR/MR title so the squashed commit lands on the base as a conventional commit:
   ```sh
   scripts/vcs/merge-pr.sh <number> --subject "<type>(<KEY>): <title>"
   ```
   It prints `state=` + `merge_sha=`; confirm `state=MERGED` before reporting.
6. Return to base: `git switch "$base" && git pull --ff-only origin "$base"`. Report the merged PR/MR URL.

## Notes
- The adapter picks `gh`/`glab` from the `origin` remote (override with `scripts/vcs/.env`). If branch protection blocks a self-merge, add `--admin` inside `scripts/vcs/github.sh` (GitHub).
- This skill is the one place that commits/pushes/merges for the task — that's its explicit job. Outside it, don't push or merge unasked.
