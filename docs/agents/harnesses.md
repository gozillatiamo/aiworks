# Agent harnesses

An **Agent harness** is the execution environment through which the agent team works: Claude Code,
Cursor, Codex, and later Hermes. It is not a Provider; Provider remains the concrete backend behind
the VCS, tracker, and notification adapters.

The organization-wide Harness set lives in `workspace.config.yaml`:

```yaml
harnesses:
  - claude
  - cursor
  - codex
```

`aiworks setup` owns the first-run picker. `aiworks sync` reconciles the selected set at the
workspace root and in every declared repo. A deselected Harness loses only artifacts carrying a
generator ownership proof; user-authored files are reported and preserved.

## One canonical source

The agent configuration is authored under `.claude/`. The shared MCP registry remains `.mcp.json`.
Every other Harness is a projection:

| Capability | Canonical source | Cursor projection | Codex projection |
|---|---|---|---|
| Project guidance | `CLAUDE.md` | `AGENTS.md` symlink | same `AGENTS.md` symlink |
| Skills | `.claude/skills/` | `.cursor/skills` symlink | `.agents/skills` symlink |
| Agents | `.claude/agents/*.md` | `.cursor/agents` symlink | generated `.codex/agents/*.toml` |
| Instruction rules | `.claude/rules/*.md` | `.cursor/rules/*.mdc` links/slices | generated scope index + direct-read hook |
| Hooks | `.claude/settings.json` + `.claude/hooks/` | generated wiring + shim | generated wiring + shim |
| MCP | `.mcp.json` | `.cursor/mcp.json` symlink | generated `.codex/config.toml` tables |
| Workflows | `.claude/workflows/*.js` | shared runtime, Cursor adapter | shared runtime, Codex adapter |
| Status line | Harness-native | command-driven Cursor form | native Codex footer items |

Compatible formats use relative symlinks. Incompatible formats are generated and checked. A
generated copy is never an authored source.

Codex writes `.codex/generated/compatibility.json` beside its rule index. It names every source
hook event mapping/fold plus the verified native-agent, status-line, and SSE-bridge boundaries;
an unknown source event fails `aiworks codex --check`.

## Commands

```sh
aiworks harnesses list
aiworks harnesses configure --reconfigure
aiworks harnesses configure --harnesses claude,cursor,codex
aiworks harnesses sync
aiworks harnesses check

aiworks cursor --check
aiworks codex --check
aiworks workflow dev-cycle --harness cursor FM-123
aiworks workflow dev-cycle --harness codex FM-123
```

In chat, invoke `$dev-cycle` / `$prd` / `$brd` in Codex and `/dev-cycle` / `/prd` / `/brd` in
Cursor. The skills launch the deterministic runtime; they do not ask the outer model to reproduce
the workflow from prose.

## Harness registry contract

`scripts/harnesses/registry.json` is the dispatch source. A Harness entry contains:

| Field | Contract |
|---|---|
| `id` | Stable lowercase config/CLI identifier |
| `display_name` | Picker and diagnostic label |
| `default_selected` | Legacy fallback only; never silently enables a new Harness |
| `cli` | Binary `setup`, `update`, and `doctor` verify |
| `projector` | Repo-relative projection command, or `null` for the canonical Harness |
| `workflow_adapter` | Module name under `scripts/workflows/adapters/`, or `native` |
| `project_guidance` | `claude` or `agents-md`; lets deselection clean a shared `AGENTS.md` safely |

Do not add a Harness-specific branch to `aiworks sync`. Register the adapter, then let
`aiworks-harnesses.sh` dispatch it.

### Projector interface

Every non-canonical projector must accept:

```text
<projector> [<repo> ...]           reconcile selected projection
<projector> --check [<repo> ...]   write nothing; nonzero on drift
<projector> --remove [<repo> ...]  remove only generator-owned artifacts
<projector> --dry-run              preview without writing or failing on expected drift
```

`--check` is the only form that verdicts. A reconcile and a `--dry-run` exit 0 — they did
everything they were allowed to do — and print what they could not do instead. A projector may
split `--check`'s nonzero further, as `aiworks codex` does: **1** for drift a reconcile will
close, **2** for drift it will not (a real path where the canonical link belongs, a generated
file somebody edited, a source defect only its author can settle). The distinction is what lets
`doctor --fix` hand the second kind to a person rather than register a command that will refuse
identically on every run.

Requirements:

- With no repo, process the root and every cloned repo declared by `workspace.config.yaml`.
- Use relative symlinks when the target format is compatible.
- Put an ownership marker in every generated regular file.
- Refuse to overwrite a real file, a differently-targeted link, or an unmarked directory.
- Prune stale generated children when a canonical source disappears.
- Keep project-root and standalone-repo operation equivalent.
- Provide a self-test that exercises idempotence, drift, conflict preservation, and removal.

### Workflow adapter interface

`scripts/workflows/run.mjs` loads `scripts/workflows/adapters/<workflow_adapter>.mjs` dynamically.
The module exports:

```js
export async function run({ root, role, definition, prompt, schema, options }) {
  return { value, spent, accounting };
}
```

The adapter must:

- execute the role through its Harness rather than impersonating it in the outer session;
- preserve or intentionally map model/effort policy;
- enforce the least filesystem/tool permissions the canonical role allows;
- return a value conforming to the existing workflow JSON Schema;
- retry malformed output only within a documented bound, then fail closed;
- report output-token usage, or a conservative estimate explicitly labelled as such;
- support parallel invocations without sharing mutable session state;
- surface a Harness failure as a failed phase, never as permission to continue manually.

## Agent compatibility contract

A generated agent is available only when safety-relevant fields are mapped:

- `name`, `description`, prompt body, model, and supported effort map directly.
- `skills:` becomes a mandatory startup-skill instruction; every named canonical skill must exist.
- Workflow-spawned Codex roles pass their identity to a project-global default-deny tool guard.
  Generated native custom agents also carry a conservative read-only default when their canonical
  role lacks `Write`/`Edit`, but Codex re-applies the parent turn's live permission override when it
  spawns them. Native role TOML therefore preserves role/model/instructions, not a hard per-role
  permission boundary. Run permission-sensitive role work through the Workflow runtime; never use
  a native custom-agent result as proof that its Claude tool allowlist was enforced.
- Plan-only roles use the Harness's read-only mode.
- `maxTurns` is preserved as a role handoff ceiling and bounded by the workflow runtime where the
  Harness has no native equivalent.

Harness-specific presentation can differ. Exact status-line layout is not functional parity, but
missing agents, rules, hooks, skills, MCP tools, or workflow validation are.

## Setup, update, and doctor

A registered Harness is incomplete until all three lifecycle owners know it:

1. `aiworks setup` installs the selected CLI, checks authentication quietly, launches login only
   in the main interactive workspace, and reconciles native/projected plugin components.
2. `aiworks update` upgrades the CLI through its owning installer and refreshes native plugin
   marketplaces without replacing an installation from another owner.
3. `aiworks doctor` checks binary/auth readiness, cheap projection presence, and the full projector
   under `--deep`.

Worktree setup never opens installers, login flows, or the first-run picker. It inherits the main
workspace's shared Harness set and machine-global login state.

## Verification gate

A Harness is not supported because files were generated. Before its PR can claim support:

- generator fixture: create, second-run idempotence, source drift, safe removal, user conflict;
- skill discovery in a fresh real Harness session;
- every agent definition parses, with live samples across its model tiers;
- a workflow-role forbidden write is denied; generated native non-write roles declare a read-only
  default, and the parent-permission inheritance limitation is named rather than treated as proof;
- path-scoped rule context appears only for a matching path;
- representative hook context and blocking responses survive protocol translation;
- shared and local MCP registrations list the expected servers without exposing secret values;
- serial and parallel workflow probes satisfy their schemas;
- BRD, PRD, and dev-cycle execute through deterministic stub agents;
- a fresh terminal renders the richest supported native status line;
- no verification run writes a real ticket, PR, or team notification.

## Adding Hermes

Hermes is the planned next Harness. Add it without changing the canonical tree:

1. Add `hermes` to `scripts/harnesses/registry.json` with `default_selected: false`.
2. Implement `scripts/aiworks-hermes.sh` with the Projector interface above.
3. Add `scripts/workflows/adapters/hermes.mjs` implementing the runtime interface.
4. Add install, quiet auth check, login, and owner-aware update commands to the lifecycle helpers.
5. Translate canonical agents, rules, hooks, MCP, plugins, and status presentation. Link; do not
   copy, whenever Hermes accepts the canonical format.
6. Add `aiworks hermes` as a direct diagnostic command, while normal sync stays registry-driven.
7. Extend `aiworks doctor` with cheap presence and deep drift checks.
8. Run the full Verification gate and document only genuine, non-functional presentation
   exceptions.

If adding Hermes requires editing existing workflow scripts, duplicating skills, or adding a
Hermes branch to `aiworks sync`, the adapter boundary is incomplete—fix the boundary first.

Architecture rationale: [ADR 0023](../adr/0023-agent-harnesses-project-from-claude-canonical-source.md).
