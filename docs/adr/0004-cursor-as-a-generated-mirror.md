# Cursor gets a generated mirror of the Claude config, built from symlinks

**Status:** Accepted

The workspace is authored for Claude Code. Cursor reads a different set of paths for the same
concepts: `AGENTS.md` instead of `CLAUDE.md`, `.cursor/rules/*.mdc` instead of `.claude/rules/*.md`,
`.cursor/hooks.json` instead of the `hooks` block of `.claude/settings.json`, `.cursor/cli.json`
instead of `permissions`, `.cursor/mcp.json` instead of `.mcp.json`. Skills and subagents are the
lucky pair: `.cursor/skills/` and `.cursor/agents/` take exactly the same on-disk shape as their
`.claude/` counterparts.

`scripts/aiworks-cursor.sh` (`aiworks cursor`) builds that second face for the workspace root and
every product repo. Three decisions shaped it.

## Mirror rather than rely on Cursor's third-party import

Cursor can read `.claude/skills/`, `.claude/agents/`, and the hooks in `.claude/settings.json`
directly, behind Settings → Rules, Skills, Subagents → *Include third-party Plugins, Skills, and
other configs*. Tempting, and it would have removed most of this script.

We do not depend on it. That toggle is **per account**, cannot be committed, and the docs gate it
further ("the feature must be enabled for your account"). A teammate who has not flipped it gets no
skills, no subagents, and — worse — none of the guard hooks, silently and with no error. Everything
`aiworks cursor` writes is committed into the repo instead, so a fresh clone works with no
account-level setup. `.claude/rules/` is not covered by the toggle at all, so a mirror was required
for rules regardless.

## Symlinks, not copies — the frontmatter carries both vocabularies

Every mirrored artefact is a **symlink back to the Claude-side file**, so there is one copy of each
rule, skill, and agent on disk and drift is impossible by construction.

Rules are the interesting case: the file has to answer to `paths:` (Claude) and `globs:` (Cursor),
and to end in `.mdc` (Cursor ignores a plain `.md` under `.cursor/rules`). The extension is free —
that is just the name of the symlink. The frontmatter is solved by carrying **both keys** in the one
source file; each tool ignores the key it does not know. `aiworks cursor` maintains that invariant,
so a rule added later cannot silently lose its Cursor scoping.

Exactly three files are generated rather than linked, because their formats have no shared shape:
`.cursor/hooks.json`, `.cursor/cli.json`, and `.cursor/hooks/hook-shim.sh`.

## The hook shim is the one deliberate copy

Cursor and Claude Code speak nearly the same hook protocol — `tool_name`, `tool_input.file_path`,
`tool_input.command`, and `session_id` are identical, and exit code 2 blocks in both. They differ in
four small ways: the event names are camelCase, the shell tool is `Shell` and the subagent tool is
`Task`, context is returned as `additional_context` rather than
`hookSpecificOutput.additionalContext`, and a block carries its reason in `agent_message` rather
than on stderr.

`scripts/cursor/hook-shim.template.sh` translates those in both directions and execs the real hook
unchanged. That keeps every hook single-source and Claude-shaped, and it is the only way the
third-party hooks (`rtk hook claude`, `sonar hook claude-pre-tool-use`) work under Cursor at all,
since those binaries only speak Claude.

The shim is **copied** into each repo rather than symlinked. `.cursor/` is committed so that a
standalone clone of one repo still works; a symlink from inside a repo up to the workspace root
would dangle in exactly that clone. `aiworks cursor --check` hashes each copy against the template,
so the copy cannot drift unnoticed. See `docs/agents/cursor.md` for the operational detail and for
what does not survive the crossing.
