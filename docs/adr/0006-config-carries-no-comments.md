# The live workspace config carries no comments

**Status:** Accepted

`workspace.config.yaml` and the personal `workspace.config.local.yaml` hold **data only**. Every
explanation — what a key does, what its options are, what a value was measured at, why a default
is what it is — lives in the `*.example.yaml` template beside it, in `docs/`, or in the owning
script's README. A comment in either live file is a defect, not a style preference.

The templates (`workspace.config.example.yaml`, `workspace.config.local.example.yaml`) are the
**opposite** case: they are almost entirely comments, and that is their whole job.

## Why

- **The shared config is injected into every session's context.** `CLAUDE.md` references it with
  `@workspace.config.yaml`, so its full text is re-read on every turn of every session, forever.
  Documentation there is paid for continuously by every teammate and every agent; documentation in
  the template is paid for once, by whoever sets the workspace up. The `voice` block alone had
  grown to ~150 comment lines — measurement tables, cost estimates, a rejected design and its
  tombstone — none of which a running session needs to resolve a value.
- **The same prose already had to exist twice.** [`aiworks config`'s drift
  guard](0001-headless-workflow-config-mirror.md) requires every live key to be documented in the
  template, because `aiworks add` bootstraps a new org by copying that template. So each key was
  explained in two files that no mechanism kept in agreement, and they diverged: the live file
  carried a heartbeat tombstone the template never mentioned, while the template carried the
  cost table the live file stated differently.
- **A config file is the wrong home for a measurement.** The numbers that mattered (voice
  sweeps, latency figures, LUFS gaps) belong where they can be tabulated, sourced and revised —
  `scripts/voice/README.md`, `docs/agents/*.md` — not squeezed into a right-hand margin.

## Enforcement (four places, because a written-down rule gets forgotten)

| where | what it does |
|---|---|
| `.claude/hooks/dev-wrapper/pretool-config-comment-guard.sh` | `PreToolUse(Write\|Edit)`: blocks an agent write that puts a comment in either live file |
| `scripts/aiworks-config.sh` (`config_comment_check`) | run by `aiworks config`/`sync`: warns about comments that arrived some other way (a hand edit in an editor), with the command that strips them |
| `scripts/aiworks-add.sh` | the bootstrap copy pipes the template through the stripper, so a new org's config is born clean |
| `scripts/lib/yaml_comments.py` | the shared scanner (`--check` / `--strip` / `--write` / `--check-stdin`) plus its own `--selftest` |

The detection is a real YAML scan, never `grep '#'`: `channel: "#dev-acme"` is a value, and
so is `url: git@host:org/repo#tag`. A guard that mistook those would block the most ordinary edit
there is, and a stripper that ate them would silently change where notifications go.

## Consequences

- Reading the live config tells you **what** the workspace is set to, never **why**. The template
  beside it is the answer to "why", and the drift guard is what keeps it honest — that check moves
  from advisory-nice-to-have to load-bearing.
- Stripping is value-preserving: the 142 comment lines removed from `workspace.config.yaml` and
  13 from `workspace.config.local.yaml` left both files parsing to structures identical to the
  originals, and `aiworks config` regenerated a byte-identical `dev-cycle.js` mirror from the
  stripped file (22 repos).
- A **tombstone** for a removed key (e.g. the pre-0005 `prod_triage.enabled`, or the deleted
  `voice.autoplay.heartbeat`) can no longer sit in the config. It goes in the template, the ADR,
  or the feature's README — which is where someone looking for a key they remember will search
  anyway, since it is no longer in the file at all.
- The `*.example.yaml` templates get longer over time, and that is fine: nothing reads them at
  runtime.

## Rejected alternatives

- **Keep the comments** — the status quo, and the thing being paid for on every turn. It also
  keeps two divergent copies of the same explanation.
- **Ban comments in the templates too, and document keys only in `docs/`** — then the file a new
  org copies explains nothing, and the drift guard has nothing to check against. The template is
  the one place where an explanation sits directly beside the key it explains, at zero runtime
  cost.
- **State the rule in `CLAUDE.md` and leave it there** — the language policy proved twice that a
  prose-only instruction is missed in a long session ([0002](0002-workspace-output-localization.md)).
  Editing a config is exactly when a model wants to annotate its work, so the rule needs a hook.
- **Strip comments automatically on write (a formatter)** — silently rewriting the human's file
  hides the rule instead of teaching it, and a stripper that runs unattended is one bug away from
  eating a value.
