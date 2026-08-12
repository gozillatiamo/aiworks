# Cursor gets a generated mirror of the Claude config, built from symlinks

**Status:** Accepted

The workspace is authored for Claude Code. Cursor reads a different set of paths for the same
concepts: `AGENTS.md` instead of `CLAUDE.md`, `.cursor/rules/*.mdc` instead of `.claude/rules/*.md`,
`.cursor/hooks.json` instead of the `hooks` block of `.claude/settings.json`, `.cursor/cli.json`
instead of `permissions`, `.cursor/mcp.json` instead of `.mcp.json`. Skills and subagents are the
lucky pair: `.cursor/skills/` and `.cursor/agents/` take exactly the same on-disk shape as their
`.claude/` counterparts.

`scripts/aiworks-cursor.sh` (`aiworks cursor`) builds that second face for the workspace root and
every product repo. Four decisions shaped it.

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
unchanged. That keeps every hook single-source and Claude-shaped, and it is the only way a
third-party hook (`sonar hook claude-pre-tool-use`) works under Cursor at all, since that binary
only speaks Claude.

The shim is **copied** into each repo rather than symlinked. `.cursor/` is committed so that a
standalone clone of one repo still works; a symlink from inside a repo up to the workspace root
would dangle in exactly that clone. `aiworks cursor --check` hashes each copy against the template,
so the copy cannot drift unnoticed. See `docs/agents/cursor.md` for the operational detail and for
what does not survive the crossing.

## A root session gets each repo re-globbed

Everything above serves a session opened *inside* a repo. A session opened at the **workspace root**
gets none of it — Cursor reads no configuration from subdirectories, and the multi-root
`.code-workspace` does not change that (both measured).

What Cursor does honour from the root is a **path-prefixed glob**: a root rule globbed
`game/src/**` fires on `game/src/adapter.rs` and stays silent for every other path. Measured with
seven probe rules over three `cursor-agent` runs — including negative controls (a glob naming a
different repo stayed silent) and a reciprocal run — because the positive result alone is also
consistent with "Cursor ignores globs and attaches every rule", which would have been worthless.

So `aiworks cursor` generates `.cursor/rules/repos/<repo>/`: the repo's `CLAUDE.md` scoped to
`<repo>/**`, plus every rule with each glob prefixed (`src/**` → `<repo>/src/**`). A rule carrying
no glob is repo-wide on the Claude side, so its root form is `<repo>/**`. The prefixing is the whole
point — `src/**` is the identical glob in 20 of 20 repos here, so unprefixed copies would fire
twenty contradictory coding standards on every file.

This breaks the symlink rule above, and cannot avoid doing so: the frontmatter has to change, so the
root form is a different file by construction. The slices are gitignored, since they are derived
from twenty-one other repositories — but the *shape* of that ignore turned out to matter more than
the decision to ignore:

- **Ignore the files, never the directory.** `.cursor/rules/repos/**/*.mdc` works; the obvious
  `.cursor/rules/repos/` does not, because Cursor prunes an ignored directory instead of descending
  into it and never discovers the rules inside. One run, four rules, distinct tokens, tracked
  control: every file-level-ignored rule fired — including one with no negation anywhere — and the
  directory-level ones stayed silent. Nothing recovers a pruned directory: negations in
  `.cursorignore` and `.cursorindexingignore` were both measured and neither works, consistent with
  Cursor's documented rule that a negation cannot re-include through an excluded parent. The rules
  documentation says nothing about ignore files, so this is measurement rather than spec, and worth
  re-checking if a Cursor upgrade ever makes root rules go quiet.
- **Repo-clone ignore patterns are anchored** (`/game/`, not `game/`) — the same trap from the other
  side. A bare directory pattern matches at every depth and would exclude
  `.cursor/rules/repos/game/` along with the clone, deleting that repo's slice with no error
  anywhere. `aiworks add` writes the anchored form; `aiworks cursor` names any bare pattern it finds.

Drift is handled independently: `aiworks cursor --check` diffs every slice against what it would
write, so a stale slice is a CI failure rather than a rule that quietly lies.

`scripts/cursor/root-rule.awk` holds the transform, separately from the generator, so
`scripts/cursor/root-rules-selftest.sh` can exercise it against throwaway fixtures: a wrong prefix
fails silently in both directions (rule never fires, or fires everywhere) and the generated file
looks plausible either way.
