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

Only those last three are not symlinks; the rest is one file read by both tools. Rule frontmatter
therefore carries `paths:` (Claude) **and** `globs:` (Cursor) — `aiworks cursor` keeps them in step,
so never hand-add one without the other. Why it is built this way:
[ADR 0004](../adr/0004-cursor-as-a-generated-mirror.md).

## Open Cursor at the repo you are working in

**This is the one thing that will bite you.** Cursor does not pick up configuration from
subdirectories the way Claude Code does. Working from the workspace root gives you the root's rules,
skills, and subagents — and **none** of any repo's.

Measured, not assumed, in both surfaces:

- `cursor-agent` run from the workspace root sees no nested `AGENTS.md`, no nested rules and no
  nested skills — even after it has read a file inside that subtree.
- The **multi-root `ai-workspace.code-workspace` does not fix it either.** Asked in the IDE what
  `paotung-template`'s `data-cy` convention is without reading files, the agent could not answer:
  it knew the answer lived in a repo rule and offered to go read it. Registering a repo as its own
  folder root is not the same as Cursor loading that root's `.cursor/` config.

So: **`cd <repo> && cursor .`**, or run `cursor-agent` from inside the repo. That is the only
arrangement measured to give an agent the repo's own instruction, rules and skills.

The `.code-workspace` file is still worth opening for the Source Control panels — just do not expect
it to configure the agent.

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
