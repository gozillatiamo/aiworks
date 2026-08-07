---
paths:
  - "agent-webservice/agent-db/**"
  - "paotung-template/packages/customization-widget/**"
globs:
  - "agent-webservice/agent-db/**"
  - "paotung-template/packages/customization-widget/**"
---

# You are inside a git submodule checkout

This path is a **read-only pointer** to a repo that is *also* cloned as its own primary
clone at the workspace root. Never create, edit, or commit here — make the change in the
primary clone and branch/commit/PR there.

| Submodule checkout | Primary clone |
|---|---|
| `agent-webservice/agent-db/` | `agent-db/` |
| `paotung-template/packages/customization-widget/` | `customization-widget/` |

**Reading is fine, and so is `git -C <sub> checkout <ref>` to PROVE something** — does the
suite go green once the pointer is bumped? The ban is on create/edit/commit, not on
inspection. Restore the ref when you are done, or use a throwaway `git worktree add`.

`pretool-submodule-guard.sh` enforces both halves: it blocks the writes and
**pre-approves** the reads, so a proof run is not denied by the permission classifier.

Full convention: [`docs/agents/submodules.md`](../../docs/agents/submodules.md).
