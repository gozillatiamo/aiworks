---
paths:
  - "workspace.config.yaml"
  - "workspace.config.local.yaml"
  - "workspace.config.example.yaml"
  - "workspace.config.local.example.yaml"
globs:
  - "workspace.config.yaml"
  - "workspace.config.local.yaml"
  - "workspace.config.example.yaml"
  - "workspace.config.local.example.yaml"
---

# The workspace config files

`workspace.config.yaml` is the source of truth for this workspace — providers, ticket
prefix, status lifecycle, branch model, output language, feature gates, and the
`products[].repos[]` registry. `scripts/aiworks sync` sets everything up from it.

**Every key is documented in `workspace.config.example.yaml`**, not here and not in the
live file. The drift guard already requires every live key to appear in the template, so
the template is the one place to look up what a key does and what its options are.

Personal, non-shared overrides go in the git-ignored `workspace.config.local.yaml` — the
analogue of `.claude/settings.local.json`, templated by
`workspace.config.local.example.yaml`. It overrides the shared file for everything read at
**runtime** (chat, agents, interactive skills); the committed workflow mirror stays
shared-only. Rationale: [ADR 0003](../../docs/adr/0003-personal-runtime-config-overrides.md).

## Neither live file carries a comment

Not a header, not a section divider, not a trailing note, not a tombstone for a key you
removed. Both are **data**.

Every explanation — what a key does, its options, a measurement, why a key went away —
belongs in the `*.example.yaml` template beside it, in `docs/`, or in the owning script's
README. The rule holds when you ADD a key: add it to the template in the same change, with
the comment there.

The reason is cost, not tidiness. `workspace.config.yaml` is `@`-imported by the root
`CLAUDE.md`, so it enters context **in full, every session** — a comment in it is re-read
on every turn forever.

Enforced by `pretool-config-comment-guard.sh` (`Write`/`Edit`) plus an advisory check in
`aiworks config`. Clean a file with `python3 scripts/lib/yaml_comments.py --write <file>`.
Rationale: [ADR 0006](../../docs/adr/0006-config-carries-no-comments.md).
