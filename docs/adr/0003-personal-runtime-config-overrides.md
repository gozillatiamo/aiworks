# Personal config overrides apply at runtime only, never in the committed mirror

**Status:** Accepted
**Revised:** 2026-08-07 — `planning.auto_approve` moved from the never-override group into the
override group. The original wording drew the line at *output preference vs control flow*; this
revision draws it at **reversibility** instead. See "Rejected alternatives" for why the first line
was wrong.

Some config is a personal preference, not a team default — most obviously `language`, where one
teammate may want `th` without switching it on for everyone. We support this with a git-ignored
**`workspace.config.local.yaml`** (the analogue of `.claude/settings.local.json`): it overrides
`workspace.config.yaml` for everything read **at runtime** — this chat, the Agent-tool agents,
and interactive skills. The one lifecycle exception is a local `harnesses` value: it activates a
non-empty subset of the shared supported Harnesses for this machine only.

The hard constraint comes from [0001](0001-headless-workflow-config-mirror.md): the workflow
`AIWORKS:CONFIG` mirror is a **committed, tracked** file. So the local override must never reach
it — `scripts/aiworks-config.sh` regenerates the mirror from the **shared** `workspace.config.yaml`
only, and merely warns when a local file is present. A personal `language` still reaches a
headless workflow run, because the spawned agents read `language` at runtime through their
per-agent pointer, not the baked `const LANGUAGE`.

The line we draw for *which* keys may be overridden this way is **reversibility** — can a wrong
personal setting still be caught before anything leaves the runner's machine?

- **Output preferences** decide what a human ends up reading: `language`, and `planning.to_html`
  (does a plan also get an interactive HTML render beside its markdown?). Overridable.
- **Reversible control flow** decides what the pipeline does, but leaves every downstream gate
  standing. `planning.auto_approve` is the only member: skipping the plan gate changes how the
  runner spends their own time, and review, the cross-repo test-suite gate and the merge all still
  sit between that plan and anything shipping. Overridable.
- **Machine-local activation** selects already-supported Harness CLIs, plugins, status lines, and
  local MCP registrations. `harnesses` is overridable only as a non-empty subset of the shared
  supported set; shared projection generation remains shared-only, so a local preference cannot
  create, remove, or dirty tracked artifacts.
- **Irreversible control flow** may never be overridden. `vcs.auto_merge` *publishes*; the status
  lifecycle and `REPOS` rewrite artifacts the whole team reads. A personal, git-ignored file must
  not be able to reach those.

So `dev-cycle.js` resolves `language`, `planning.to_html` **and** `planning.auto_approve`
local-first in one `resolve-runtime-config` sub-agent Read, and treats the baked `const LANGUAGE` /
`const PLAN_TO_HTML` / `const AUTO_APPROVE_PLAN` as fallback defaults; it then states the resolved
`to_html` **explicitly** in each planner prompt (ON *and* OFF), so a planner that would otherwise
self-resolve from disk can never diverge from the run.

## Consequences

- Precedence, everywhere read at runtime: `workspace.config.local.yaml` → else
  `workspace.config.yaml`.
- The merge is **shallow per top-level key**: a local `planning:` block replaces the shared one
  whole, so a key omitted from it falls to its own default rather than inheriting the shared value.
  Every reader (agent files included) must resolve it that way.
- `planning.auto_approve` resolution is **fail-closed**. The resolver reports the key *only* when a
  local `planning:` block exists, and an `auto_approve` absent from that block reads as `false` —
  never the shared file's value, never the framework default (`true`). A resolver that throws, omits
  the key, or returns junk therefore leaves the committed `AUTO_APPROVE_PLAN` standing and the gate
  ON. The gate can be loosened by writing `auto_approve: true` on purpose, and by nothing else.
- Your personal preference can **never** land in git via the generator — the committed mirror
  stays shared-only by construction.
- The shared Harness set is the projection contract; the local active subset is the machine
  lifecycle contract. `aiworks harnesses list` reports the former and `list --active` the latter.
- `.superset/setup.sh` symlinks `workspace.config.local.yaml` (and `.claude/settings.local.json`)
  into each per-ticket worktree, so personal prefs follow you into a superset run (opt out with
  `SUPERSET_LOCAL=skip`).

## Rejected alternatives

- **Bake the local override into the mirror.** Rejected: the mirror is tracked, so a personal
  preference would leak into git and reach the whole team on the next commit.
- **No local override for headless workflows.** Rejected: a personal `language: th` would then
  be silently ignored by `dev-cycle`/`prd`; routing it through the runtime per-agent pointer
  keeps the override honest without touching the committed mirror.
- **Keep every control-flow key shared-only** — the original 2026-07 line. Rejected on revision
  (2026-08-07): it grouped the reversible plan gate with irreversible publishing, which cost more
  than it protected. A ticket only one person touches could not run headless end to end — the
  runner stopped at the gate and re-invoked with `--approve-plan` to approve their own plan, which
  is ceremony, not review. Worse, the key was already settable in `workspace.config.local.yaml` and
  silently did nothing there, which reads as a bug every time someone tries it. The safety the
  original wording protected is real, but it lives in `vcs.auto_merge` and the status/`REPOS` keys —
  and those stay shared-only.
