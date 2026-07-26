# Working this workspace from Cursor

Everything the agents rely on — the project instruction, the rules, the skills, the subagents, the
guard hooks, the permission model, MCP, and every `scripts/` adapter — works in Cursor as well as in
Claude Code. One thing does not cross: **workflows**.

The Cursor layer is *generated*, never hand-edited. Author on the Claude side; run `aiworks cursor`.

```bash
aiworks cursor                 # root + every repo (add / sync already do this)
aiworks cursor backoffice      # one repo
aiworks cursor --check         # verify only; exit 1 on drift — use it in CI
aiworks cursor --user          # link the Claude plugin skills into ~/.agents/skills
```

## What lives where

| Concept | Claude Code (authored here) | Cursor (generated) |
|---|---|---|
| Project instruction | `CLAUDE.md` | `AGENTS.md` → symlink |
| Rules | `.claude/rules/*.md` | `.cursor/rules/*.mdc` → symlink per file |
| Skills | `.claude/skills/` | `.cursor/skills` → symlink (dir) |
| Subagents | `.claude/agents/` | `.cursor/agents` → symlink (dir) |
| MCP | `.mcp.json` (root) | `.cursor/mcp.json` → symlink (root only) |
| Hooks | `hooks` in `.claude/settings.json` | `.cursor/hooks.json` — **generated** |
| Permissions | `permissions` in `.claude/settings.json` | `.cursor/cli.json` — **generated** |
| — | `scripts/cursor/hook-shim.template.sh` | `.cursor/hooks/hook-shim.sh` — **copied** |
| Each repo's instruction + rules, for a **root** session | `<repo>/CLAUDE.md`, `<repo>/.claude/rules/` | `.cursor/rules/repos/<repo>/*.mdc` — **generated** |

Only those last four are not symlinks; the rest is one file read by both tools. Rule frontmatter
therefore carries `paths:` (Claude) **and** `globs:` (Cursor) — `aiworks cursor` keeps them in step,
so never hand-add one without the other. Why it is built this way:
[ADR 0004](../adr/0004-cursor-as-a-generated-mirror.md).

## Working from the workspace root

Cursor does not read configuration from subdirectories the way Claude Code does. A root session
gets the root's own config and, natively, **nothing** from any repo — measured, not assumed:

- `cursor-agent` at the workspace root sees no nested `AGENTS.md`, no nested rules and no nested
  skills, even after reading a file inside that subtree.
- The **multi-root `ai-workspace.code-workspace` does not fix it.** Asked in the IDE what
  `paotung-template`'s `data-cy` convention is without reading files, the agent could not answer.
  Registering a repo as a folder root is not the same as Cursor loading that root's `.cursor/`.

What Cursor *does* honour from the root is a rule whose glob is **path-prefixed**. A root rule
globbed `game/src/**` fires on `game/src/adapter.rs` and stays silent everywhere else. So
`aiworks cursor` generates one slice per repo under `.cursor/rules/repos/<repo>/`: the repo's
`CLAUDE.md` as an always-in-repo rule (`<repo>/**`), plus every one of its rules with each glob
re-scoped — `src/**` becomes `<repo>/src/**`. A rule with no glob at all is repo-wide on the Claude
side, so its root form is `<repo>/**`.

Verified end to end from the root: reading `game/src/adapter.rs` pulls in `game/CLAUDE.md` and the
four `game` rules whose globs match — and reading `backoffice/src/svg-icons/index.tsx` pulls in
`backoffice`'s and nothing of `game`'s. Prefixing is what makes that true: `src/**` is the identical
glob in 20 of 20 repos here, so plain copies would put twenty contradictory coding standards on every
file.

### Two kinds of slice, because Cursor has two triggers

Cursor picks a rule's type from its frontmatter, and the type decides when the body reaches the model:

| Type | Frontmatter | Body enters context |
|---|---|---|
| Always | `alwaysApply: true` | every turn |
| Auto Attached | `globs:` | when a matching file is in context |
| Agent Requested | `description:`, **no** `globs:` | the agent sees the description and fetches the body |

The per-rule slices are **Auto Attached** — right for the case that matters while working, and inert
otherwise. Ask at the workspace root *"what is the data-cy convention in paotung-template?"* with no
file open and they correctly do nothing; that is the definition, not a fault.

So each repo also gets `about.mdc`, description-only and deliberately **without** globs, which makes
it **Agent Requested**: Cursor lists it, and the agent pulls it in when the question is about that
repo. Measured — the question above then answers from the real rule with no file of the repo opened.

The card carries the repo's `CLAUDE.md` inline (a few kB; it answers most repo-level questions in one
hop) plus an **index** of the repo's rules — name, description, path — rather than their text.
Concatenating them would drop 54 kB of `agent-webservice` into context on any mention of the name.

**One limit worth knowing.** An Agent Requested body is *fetched*, which is a read. Under a literal
"answer without reading anything" constraint no repo's conventions can reach a root session, and the
only configuration that would is `alwaysApply: true` on all 21 — 262 kB every turn. Not a trade worth
making; open the repo instead when you want it all resident.

**Still missing from a root session: a repo's own skills** (each repo carries 6–7). If you need
those, or you are doing sustained work in one repo, **`cd <repo> && cursor .`** remains the better
arrangement. The `.code-workspace` file is worth opening for the Source Control panels either way.

### Ignore the files, never the directory

The slices are gitignored — they are derived from twenty-one other repositories and `aiworks sync`
rebuilds them. **How** they are ignored decides whether the feature works at all:

| `.gitignore` entry | Effect |
|---|---|
| `.cursor/rules/repos/**/*.mdc` | ignores the **files** — Cursor still reads them ✅ |
| `.cursor/rules/repos/` | ignores the **directory** — Cursor reads nothing ❌ |

Cursor prunes an ignored directory rather than descending into it, so rules inside one are never
discovered. Measured in a single run with four rules and a tracked control: every file-level-ignored
rule fired — including one with no negation anywhere — and the directory-level ones stayed silent.
Nothing recovers a pruned directory afterwards: negating in `.cursorindexingignore` or
`.cursorignore` does not bring it back (also measured, and Cursor's docs note that a negation cannot
re-include through an excluded parent). Cursor's rules documentation says nothing about ignore files
in either direction, so this is measurement, not spec.

**The same trap arrives from the other direction: repo-clone patterns must be anchored.** A bare
`game/` matches at every depth, so it excludes `.cursor/rules/repos/game/` as well and silently
deletes that repo's whole slice. `aiworks add` writes `/game/`; `aiworks cursor` reports any bare
pattern it finds, naming it. Applies to `.git/info/exclude` too.

Drift is caught separately: `aiworks cursor --check` diffs every slice against what it would write,
so a stale one fails CI rather than quietly serving an out-of-date convention.

### The injector — the Claude Code half of the same problem

`.claude/hooks/dev-wrapper/pretool-repo-context.sh` solves this for Claude Code, which has the
mirror-image gap: it picks up a nested `CLAUDE.md` but not a nested `.claude/rules`. When a tool
touches a path under `<repo>/`, the hook injects that repo's instruction plus the rules whose globs
match, once per repo per session. Verified: reading `game/src/adapter.rs` from the root pulls in
`game/CLAUDE.md` and its `src/**` rules.

Under Cursor the same hook **emits but does not land** — traced live, it produces ~3.8 kB of valid
`additional_context` on `preToolUse` and the model reports receiving nothing. Every isolated
reproduction delivers (shim or no shim, one hook or ten, 4 kB payload, alongside `sessionStart`
context, inside a nested gitignored repo), so the cause is something about the real root that the
reproductions do not capture. It is not worth chasing: the generated slices cover Cursor by a
different mechanism, and the hook still earns its place on the Claude Code side.

## Set your model to `auto`

Subagent files carry `model: opus` / `sonnet` / `haiku` — Claude Code's vocabulary, which Cursor
does not share (its ids look like `claude-opus-5-high`, `composer-2.5`, `auto`). Cursor ignores a
model value it cannot resolve rather than failing, so the files are left alone and Cursor falls back
to your session model. Set that to **`auto`** — `cursor-agent --model auto`, or the model picker in
the IDE. Note that every Claude model Cursor offers is a 1M-context variant, which is not what this
workspace wants pinned; `auto` sidesteps that too.

## What does not cross

**Workflows.** `.claude/workflows/{dev-cycle,prd,brd}.js` run on Claude Code's Workflow engine —
deterministic waves, pipelines, schema-validated subagent output, resume. Cursor has no equivalent
and none is emulated. Run those from Claude Code. Everything the workflows *call* (the agents, the
skills, the adapters) works in Cursor when you drive it yourself.

**Per-agent tool grants.** The `tools:` allowlist in an agent file is inert in Cursor — every
subagent gets the full tool set. Cursor's `readonly: true` is not a substitute: it blocks shell and
MCP writes as well as file writes, which would break every one of our read-only agents, since they
all act through the tracker/vcs/notify adapters or through MCP rather than through file edits. The
guard hooks are the enforcement layer that does carry over.

**Plugin skills**, unless you run `aiworks cursor --user`. Claude plugin skills live under
`~/.claude/plugins/marketplaces/…`, which Cursor does not scan; `--user` links them into
`~/.agents/skills`, which it does. Personal machine state — nothing committed. The `plugin:skill`
form (`caveman:caveman`) does not resolve in Cursor either way; a skill referenced that way is
simply not found.

**`tool_response` on postToolUse.** Cursor does not send it, so `posttool-output-warden.sh`
degrades to a no-op there. Nothing to translate — the field does not exist.

**The text of a blocked action.** A guard's reason reaches Cursor (the shim sends it as
`agent_message`, both spellings; `scripts/cursor/hook-shim-selftest.sh` asserts it), but Cursor
currently renders the block as a bare `Rejected:`. The block itself is enforced — only the
explanation is lost.

**`.cursor/cli.json` covers the CLI only.** The IDE has its own permission surface. The deny list
still matters — it is defence in depth behind the hooks, which run in both.

## Hooks: how the two protocols meet

`.cursor/hooks.json` wires every command through `.cursor/hooks/hook-shim.sh`, which translates and
then execs the real hook under `.claude/hooks/` unchanged. The differences it absorbs:

| | Claude Code | Cursor |
|---|---|---|
| event name | `PreToolUse` | `preToolUse` |
| shell tool | `Bash` | `Shell` |
| subagent tool | `Agent` | `Task` |
| inject context | `{"hookSpecificOutput":{"additionalContext":…}}` | `{"additional_context":…}` |
| block | exit 2, reason on stderr | exit 2, or `{"permission":"deny","agent_message":…}` |

Everything else already matches, including `tool_input.file_path`, `tool_input.command`, the `Task`
tool's `description`/`prompt`/`subagent_type`, and `session_id`. Cursor also exports
`CLAUDE_PROJECT_DIR` as an alias, so the ~80 hook references to it resolve.

`subagentStart` and `subagentStop` never fired in testing — do not build on them.

Change a hook by editing it under `.claude/hooks/`. Change the *translation* by editing
`scripts/cursor/hook-shim.template.sh`, then `aiworks cursor` to redistribute and
`scripts/cursor/hook-shim-selftest.sh` to prove it still holds.

## Onboarding a teammate

1. `aiworks sync` — clones the repos and projects the Cursor layer as part of the run.
2. `aiworks cursor --user` — makes the Claude plugin skills visible to Cursor.
3. Set the Cursor model to `auto`.
4. Open `ai-workspace.code-workspace`, or open one repo at a time. Not the meta-repo folder.

MCP servers need a one-time per-server approval in Cursor (`cursor-agent mcp list` shows them as
`not loaded (needs approval)` until then).

## The one commit that fails: prettier refuses a symlink

In a repo whose `lint-staged` runs `prettier --write` over `*.md`, the commit that first
introduces `AGENTS.md` fails:

```
[error] Explicitly specified pattern "AGENTS.md" is a symbolic link.
```

Prettier rejects an explicitly named symlink outright — `.prettierignore` does not suppress it,
because the refusal happens before ignore handling. Commit that one change with `--no-verify`
(there is nothing for prettier to do: the rest of the commit is symlinks and generated JSON).

It bites exactly once per repo. A symlink is only staged when it is created; afterwards an edit to
the project instruction stages `CLAUDE.md`, which is a regular file, and the hook is happy.
`front-end` hit this; `backoffice` did not, because its `lint-staged` glob is narrower.

## If something looks unconfigured

- `aiworks cursor --check` — reports every missing link, stale generated file, drifted shim copy,
  and any rule whose frontmatter lost its `globs:`.
- `scripts/cursor/hook-shim-selftest.sh` — proves the translation layer end to end against the real
  guard hooks.
- Check what you opened. See the section above; it is usually that.
