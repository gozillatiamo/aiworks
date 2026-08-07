# Output compression (caveman)

Every session and **every agent** in this workspace writes ultra-compressed prose — the
`caveman:caveman` plugin skill. This is the home of *how it reaches each spawn path* and
*where the compression boundary sits*. The operative one-liner lives in the root
`CLAUDE.md`.

## How it reaches each spawn path

Three paths, three mechanisms, all mechanical rather than remembered:

| Spawn path | Mechanism |
|---|---|
| **Main session** | the plugin's own `SessionStart` / `UserPromptSubmit` hooks |
| **Named agent** (`developer`, `qa-runner`, …) | `skills: - caveman:caveman` in its `.claude/agents/<name>.md` frontmatter |
| **Def-less agent type** (`general-purpose`, `Explore`, `Plan`) | a `CAVEMAN_DIRECTIVE` string |

The named-agent path is measured, not assumed: the skill's text was present in 5/5 probe
transcripts.

A def-less type has no frontmatter to preload from, so the directive is injected instead —
by `pretool-agent-context.sh` for a direct `Agent` spawn, and by a constant in each
workflow for a workflow spawn. If you add a workflow call site, `grep agentType` to find
the ones already wired.

A **repo-only session** (`cd <repo> && claude`) is covered too: each repo's
`.claude/settings.json` enables the plugin, and `.superset/setup.sh` installs it once at
**user** scope. Declaring alone is not installing — also measured.

## The boundary: compression is an OUTPUT rule

⚠️ **The FIRST brief is INPUT and goes in FULL** — never compressed, summarized, or
trimmed to save tokens. That one message is the agent's whole world: it cannot recover
context you dropped and has no way to know something is missing, so a starved brief reads
as a bad agent rather than a starved one.

**Every message after that is caveman** — a follow-up, a re-review ping, a next-slice
nudge, a `SendMessage` to a live agent. The context already landed, so the follow-up is a
pointer, not a context transfer.

Compression there is style, never content. Any NEW fact a follow-up carries — a QA bug
report, a failing line, a changed requirement — still goes in complete. Drop the filler,
never the facts.

The same boundary applies *inside* an agent: caveman governs how it **writes**, never what
it **does**. It must never skip a tool call, skip a tool-availability check, or claim a
tool or shell is unavailable without actually running it first.

## In Cursor the skill is `/caveman`

Cursor cannot resolve the `plugin:skill` form at all. `aiworks cursor` links each enabled
plugin's skills to `.claude/skills/<name>` (git-ignored), which Cursor reads through
`.cursor/skills`, so both names resolve to the same file. Every agent file names both
forms. See [`cursor.md`](cursor.md).
