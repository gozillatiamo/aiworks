# One workflow, one slash entry — authored scripts live under `.claude/workflows/src/`

## Context

Every canonical workflow in this workspace is reachable two ways at once, and until now both
ways were registered under the same name.

The skill is the intended door. `.claude/skills/{brd,prd,dev-cycle}/SKILL.md` exists because a
workflow has to start differently on each Harness: under Claude Code it is built first and handed
to the native Workflow tool as a `scriptPath`, under Codex and Cursor it goes through
`./aiworks workflow <name> --harness <id>` and the shared runtime in `scripts/workflows/run.mjs`.
The skill is also what makes the name portable — `$dev-cycle` in Codex, `/dev-cycle` in Cursor and
in Claude Code all reach the same deterministic script.

The second door was never chosen. Claude Code auto-loads `.claude/workflows/` and registers every
`.js` it finds there as **both** a `/<name>` slash command and a `Workflow({name})` target — the
save dialog says so outright: *"Invoke as `/<name>` or `Workflow({name})` in future sessions."*
Because the authored scripts sat in exactly that directory, the `/` menu carried two entries
called `prd`, two called `brd`, and two called `dev-cycle`: one a skill, one a *(dynamic
workflow)*. A person picking from that menu had no way to tell which was which, and this is a
framework other people clone.

The native entry is not merely redundant, it is the wrong half:

- It hands the Workflow tool the **authored** file. `docs/agents/harnesses.md` records why that
  cannot be allowed: the tool weighs the script file before parsing it, the cap is 524,288 bytes,
  and `dev-cycle.js` is 523,864 authored against 347,134 built. The margin on the authored file is
  424 bytes, against measured growth of +5,189 bytes per fix. The native `/dev-cycle` is one
  commit away from a run that cannot start.
- It knows nothing about Harness dispatch, so it is a Claude-Code-only door onto something the
  other two Harnesses must reach identically.
- It bypasses `scripts/workflows/build.mjs`, which is the only thing that verifies a stripped
  script still parses and still says what the authored one said.

Nothing in the Claude Code configuration surface turns a single workflow off.
`settings.enableWorkflows: false` and `CLAUDE_CODE_WORKFLOWS=false` disable the Workflow **tool**,
which the skills depend on; the per-workflow `workflows:` key belongs to a plugin manifest and is
relative to a plugin root; and nothing in a script's `meta` hides its command.

What does hold is the shape of the loader. Measured against the live CLI with a fixture carrying
`alpha.js`, `sub/beta.js`, `.build/gamma.js` and `_src/delta.js`, an unresolvable
`Workflow({name})` reported `Available: deep-research, alpha`. **Only `*.js` directly inside
`.claude/workflows/` is registered; the loader does not recurse.** `.build/` had already been
invisible on those terms for as long as it has existed.

## Decision

The authored workflow scripts move one directory down, to `.claude/workflows/src/`. The built,
comment-stripped copies stay at `.claude/workflows/.build/`. The directory Claude Code scans is
left empty, so the skill is the only `/<name>` in the menu — on every Harness, spelled the same
way.

1. **The skill is the single entry point.** `/prd`, `/brd`, `/dev-cycle` resolve to a skill and
   nothing else. Each one now says the same thing on Claude Code: run
   `node scripts/workflows/build.mjs <name>`, then invoke the Workflow tool with `scriptPath` set
   to the path it prints, and add `resumeFromRunId` to that same call to resume. `prd` and `brd`
   previously said "invoke the native `<name>` Workflow"; that instruction is gone, because the
   thing it named is gone.

2. **`name:` is not a fallback.** There is no registered name to resolve, so the failure mode is a
   clear "not found" rather than a silent run of the unbuilt file.

3. **The invariant is checked, not just written down.** `build.mjs` (and therefore
   `build.mjs --check`) reports each stray `*.js` at the top of `.claude/workflows/` as
   `stray <name>` and exits non-zero. `scripts/workflows/selftest.mjs` asserts the directory holds
   no `.js` at all. `aiworks doctor` renders the stray line as a failure naming the `git mv` that
   closes it, rather than folding it into the byte-budget warning it sits beside.

4. **Moving a stray file is a person's call.** The doctor entry is a `see:` advisory, not a
   registered fix command: a `.js` someone dropped there may be their own private workflow rather
   than drift, and a tool that silently relocates a file somebody wrote is worse than one that
   names it.

## Consequences

- Every path that named `.claude/workflows/<name>.js` now names `.claude/workflows/src/<name>.js`:
  the build and runtime (`build.mjs`, `run.mjs`, `selftest.mjs`), the CONFIG generator and its
  selftest, the doctor, the workflow selftests, the compile hook, the chat-dispatch catalog, and
  the docs. `.build/` is unchanged, so `.gitignore` is unchanged.
- A workflow added in future belongs in `src/`. Dropping one at the old location still works as a
  Claude Code workflow — which is exactly why the check exists to say it should not.
- Nothing changes for Codex or Cursor beyond the source path: they never read
  `.claude/workflows/` as a registry, only as a file location, and they reach workflows through
  the same skills over the same `.claude/skills` symlink.
- The build/deliver rule is unchanged and now has no competing door. A run that starts from a `/`
  entry is a run that was built first.
