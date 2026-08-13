# graphify — operating the doc graph

[ADR 0013](../adr/0013-codegraph-keeps-the-code-graphify-maps-the-prose.md) says *why* this
workspace runs two indexes. This is how to keep the prose one working.

## It is TWO installs, and the second is the one people miss

| command | lands | scope |
|---|---|---|
| `graphify hook install` | post-commit auto-rebuild · the union **merge driver** · `.gitattributes` | `.git/` (per-clone) + one committed file |
| `graphify install --platform claude` | the **`/graphify` skill** | `.claude/skills/graphify/` |

Both are needed. Having only the first is the failure mode this doc exists for, because the
symptom does not look like a missing install — it looks like graphify demanding an API key.

## ⚠️ graphify needs no API key. The skill IS the LLM.

Upstream's team-setup guide never mentions a key, and that is not an omission: the pipeline routes
**semantic extraction and community naming through the host assistant**. The skill's own words:

> graphify needs no API key. Never ask the user for one, and never block on one. … otherwise the
> host agent itself is the LLM.

Community names are written by the agent in the skill's Step 5, read straight out of
`.graphify_analysis.json`. No call leaves the machine.

The CLI's `graphify label --backend=<name>` is the **headless/CI** path, and only that path wants
`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` (and `--backend=gemini` additionally needs the `openai`
package). With the skill installed you never need it. If a `GEMINI_API_KEY` happens to be set for
some other tool, **unset it for the run** so a personal credential is not spent:

```bash
env -u GEMINI_API_KEY -u GOOGLE_API_KEY   # then drive the pipeline through /graphify --update
```

## ⚠️ Remove the post-checkout hook

`graphify hook install` lands **two** hooks. Upstream's team setup prescribes only the
post-**commit** rebuild; the post-**checkout** one runs the same rebuild on every branch switch.

That matters because **every rebuild re-partitions the graph**, and clustering is not stable run to
run (49 → 53 → 52 → 53 → 54 communities observed on an unchanged corpus). Measured: switching
branches took 15 of 49 curated community names back to raw hub names — `Voice and Notification
Adapters` → `speak.sh`. There is no no-cluster knob; `GRAPHIFY_SKIP_HOOK` is all-or-nothing.

```bash
rm .git/hooks/post-checkout      # keep post-commit
```

It lives under `.git/`, so **no commit can carry this** — every clone does it by hand, and a
workspace that skips it will watch its labels rot on the next branch switch.

## ⚠️ Labels are positional — regenerate the `.sig`

`.graphify_labels.json` is keyed by **community id**, which is an index, not an identity. Any
re-partition invalidates it. `.graphify_labels.json.sig` is the guard: a per-community
`sha256(sorted member ids)[:16]` (`graphify.cluster.community_member_sigs`) that graphify compares
before reusing a curated name.

**After relabeling, regenerate the sig**, or the next rebuild declares every label stale and renames
by hub — reproducing exactly the damage you just repaired:

```python
from graphify.cluster import community_member_sigs
# comms = {cid: [node ids]}  →  write {str(cid): sig} to .graphify_labels.json.sig
```

A mismatch is silent. Nothing errors; the names simply degrade.

## What is committed, and what is not

`graph.json`, `manifest.json`, `GRAPH_REPORT.md` and the label pair **are** committed — a teammate's
first pull gets the map without re-spending the semantic pass. Not committed: `cache/`, `cost.json`,
`graph.html`, the dated backup dirs, and any `.graphify_*` file holding an absolute path or a
per-machine tally.

`.graphify_analysis.json` is **intra-run scratch** — the skill's Step 5 reads it and Step 9 deletes
it. Committing it guarantees a permanently dirty tree.

`.gitattributes` binding `graph.json` to the union merge driver is the one shareable artifact of
`hook install`. Without it the driver is dead config and a `graph.json` conflict lands as tens of
thousands of unresolvable lines.

## `graphify install` overreaches — review before committing

It does more than drop the skill. Observed: a block appended to the root `CLAUDE.md` (which is
line-budgeted), a duplicate `.claude/CLAUDE.md`, and two `PreToolUse` hooks hardcoded to the
**absolute path of the installing machine's** `graphify` binary — broken for every other clone — one
of which mandates `graphify query` before any `grep`, contradicting ADR 0013's split.

Keep `.claude/skills/graphify/`. Revert the rest.

## Adding docs to the graph

```
/graphify --update
```

The incremental path re-extracts only changed files. Drive it through the skill, not
`graphify update` alone — the CLI covers code but tells you to use the assistant for prose:
*"For doc/paper/image changes run /graphify --update in your AI assistant."*
