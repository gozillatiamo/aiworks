---
name: ultra-review
description: Run a ticket's open MR/PR through two specialist review gates at once — code-reviewer (clean-code + spec), performance-engineer (profiling) — spawned in parallel, then aggregated into one combined verdict where a blocking finding at any gate caps the result. Honors the workspace output language and review.level. Use when the user wants a deep / full / ultra review, a multi-gate review, or a combined code + performance review of a <KEY> ticket — distinct from /review, the single spec+standards pass.
disable-model-invocation: true
---

# Ultra-review

Runs one ticket's open MR/PR through **two specialist gates in parallel** — Daniel
(code-reviewer), Liam (performance-engineer) — then aggregates their verdicts into one. A
**blocking finding at ANY gate caps the combined verdict**, no matter how clean the other is.

Distinct from `/review` (the single 2-axis spec+standards pass by two `general-purpose`
sub-agents): ultra-review fans out the two *acting* specialist agents, which comment
inline on the live MR/PR and render their own verdicts. The verdict grounding is shared —
[`.claude/skills/review/basis.md`](../review/basis.md) — and every gate reads it first.

**Scope — review, never merge.** The gates review, comment findings inline, and render a
verdict/approval; they must **NOT merge** (even where `auto_merge` is on). Ultra-review is a
review pass — merge stays a separate, later decision.

## 0. Resolve language + review level BEFORE spawning (do this FIRST)

These two values are resolved **once here** and pasted **verbatim** into both gate
briefs. The gates are real sub-agents that would otherwise each re-resolve from disk and can
drift; passing the resolved directive is the proven fix (mirrors `/review` step 4). Both
agent definitions honor an in-prompt directive over any self-resolution.

- **Output language.** If a `LANGUAGE_DIRECTIVE` / `OUTPUT LANGUAGE = …` line is already in
  your prompt, that value is authoritative — do NOT re-resolve. Otherwise read
  `workspace.config.local.yaml` (git-ignored personal override) if it exists and has a
  `language:` line, else `workspace.config.yaml` — never from memory.
- **Review level.** Read `review.level` from `workspace.config.yaml` (default **strict** if
  absent).

State both resolved values + their source in one line before spawning. Hold this block to
paste into **every** gate brief (substitute the resolved values, never the literal `<…>`):

```
OUTPUT LANGUAGE = <en|th> (authoritative — do NOT re-resolve). Write every finding's prose
in this language; under th the finding SENTENCES are Thai with an English spine — headings/
labels, ALL code + identifiers + file paths, and technical/domain/proper-noun terms stay
English (Arabic numerals always); under en write English.
Review level = <strict|thorough> (passed in — do NOT re-read the config). At strict report
blocking must-fixes only; at thorough also triage the nice-to-have tier.
```

## Process

### 1. Pin the ticket + its open MR/PR

Resolve the `<KEY>` ticket (id format + fetch via `docs/agents/issue-tracker.md`, through
`scripts/tracker/`). Find its **open MR/PR(s)** via the VCS adapter (`scripts/vcs/`) — for
each, capture the branch, the target branch, and the MR/PR number/ref.

**Completion:** you hold the ticket plus at least one open MR/PR (branch → target). If the
ticket has **no open MR/PR**, STOP and say so: these gates comment on a live MR/PR — open one
first (`/open-pr`), or use `/review` for a branch-only pass. Do not fabricate a diff.

*(Multi-repo ticket: collect every repo's open MR/PR and hand each gate the full list — the
gates review each. No wave engine here; that is dev-cycle's job.)*

### 2. Spawn the two gates in parallel

Send **one message with two `Agent` tool calls** — `code-reviewer`, `performance-engineer` —
so they run concurrently and don't pollute each other's context. Into **each** brief put:

- The shared directive block from §0 (language + review level), verbatim.
- The ticket `<KEY>` and the open MR/PR ref(s) + branch + target.
- `"This is an ultra-review pass — review, comment findings inline on the MR/PR, and render
  your verdict. Do NOT merge, even if auto_merge is on; merge is a separate decision."`
- **A force-shell first line** (proven fix for the perf "no Bash" give-up — see §3):
  `"Your FIRST action is a real Bash call — run `scripts/vcs/pr-view.sh <num>` (or `git
  rev-parse --show-toplevel`) from inside the target repo BEFORE any analysis or prose. Do NOT
  reason about whether Bash/tools are available — you HAVE a scoped Bash grant (the code-reviewer
  uses the identical mechanism). Never self-report 'no Bash / no shell' without an actual failed
  attempt; a real denial comes with a real error you must quote."`

Each gate then runs its own instrument (Daniel: `/review` + codegraph blast radius; Liam:
profiling) per its own definition — no extra tool grant needed. **Completion:** both gates
have returned a verdict.

### 3. Aggregate

**Backstop — verify every finding actually landed inline, IN THE RIGHT LANGUAGE (do this
FIRST, before presenting).** A gate can return a verdict yet fail to post its findings — most
often it wrongly concludes it "has no shell / no Bash" and leaves them only in its return text
(a genuine denial is different: it comes with a real error). A gate can also post for real but
in the wrong language — a gate's own language self-resolution can drift even with the §0
directive pasted verbatim (root-caused 2026-07-22, ticket OFB-1803: code-reviewer posted two
must-fix comments in English on a `th`-resolved run). So for each repo's MR/PR, list the posted
review threads (`scripts/vcs/pr-threads.sh <num>`, run from inside that repo) and reconcile them
against the must-fixes each gate reported, checking BOTH:
1. **Presence** — is the finding on the MR/PR at all?
2. **Language** — under `th`, does the posted body actually contain Thai prose (not just an
   English body with technical terms)? Under `en`, is it English?

**MR/PR numbers collide across repos — verify cwd before every post.** `pr-comment.sh`
resolves its target repo from cwd, not from the number you pass. A multi-repo ticket
routinely has the SAME number in two different repos (e.g. OFB-1803: `backoffice` !806 AND
`agent-webservice` !806 — unrelated MRs, same number). Run `git remote get-url origin`
immediately before every `pr-comment.sh`/`pr-threads.sh` call and confirm it matches the repo
you intend — do not trust a `cd` from a prior step to have stuck (root-caused 2026-07-22,
OFB-1803: a stale cwd sent a backoffice-repo finding to an unrelated, already-merged MR in
agent-webservice that happened to share the number).

For any finding that fails either check — missing, or present but in the wrong language — post
(or re-post) it yourself via `scripts/vcs/pr-comment.sh --path <file> --line <n> --body …` —
anchored + quoting the code, in the resolved OUTPUT LANGUAGE, attributed to the gate (e.g.
`[Performance gate (Liam)]`). For a wrong-language repost, prefix the body with a short marker
in the resolved language noting it supersedes the earlier wrong-language comment (the adapter
has no edit-in-place; the old comment stays visible, the new one is authoritative — do not rely
on the gate or a later pass to notice the mismatch on its own). The gate definitions now require
them to post their own, in the resolved language; this is the safety net for when one still
doesn't. Note in your summary which findings you posted or reposted, and why.

**Known gate failure the backstop MUST expect (root-caused 2026-07-17):**
- **`performance-engineer` returns "no Bash" — BEHAVIORAL, not a missing grant.** Ground-truth
  probe: forced with a prompt whose only allowed first action was a Bash call,
  `performance-engineer` executed `echo` fine (real `tool_use`, stdout returned, 0 errors).
  So the Bash grant WORKS; the agent just talks itself into "no Bash / no shell" and emits
  `tool_uses: 0` whenever the task lets it reason first (its `tool_uses:0` "not in toolset"
  self-reports are unreliable model introspection, NOT schema truth — they even contradicted each
  other across probes). `code-reviewer` doesn't do this (34 real Bash calls same spawn). The fix is
  the **force-shell first line in every gate brief (§2)** — make a real Bash call the gate's
  literal first action, before any reasoning. This is the prevention; the backstop above is the
  guaranteed net: for any gate finding not on the MR/PR, post it yourself via `pr-comment.sh`.
- **A gate posts for real but drifts to the wrong language** (root-caused 2026-07-22, OFB-1803).
  Pasting the §0 directive verbatim into the brief is the prevention but is not itself a
  guarantee — treat it the same as the Bash case: prevention in §2, guaranteed net in the
  backstop above (the language check on every posted thread, every run, not just when something
  looks off).
- **A repost lands on the wrong repo's MR/PR because two repos share the same number**
  (root-caused 2026-07-22, OFB-1803, discovered on a re-visit of this same ticket). The
  backstop's own remediation step is itself at risk here — verify cwd (`git remote get-url
  origin`) immediately before every `pr-comment.sh` call, per the guard above; when it still
  happens, the adapter has no delete, so post a short retraction/disregard note on the
  wrong MR pointing at the correct one, and post the real finding on the correct repo.

Present the two results under `## Code (Daniel)` and `## Performance (Liam)` — verbatim or
lightly cleaned, **not merged or reranked**: the gates are deliberately independent so the user
sees each. **Language check:** the backstop above already caught and fixed any wrong-language
finding on the MR/PR itself; separately, rewrite any wrong-language prose in what you present
here into the resolved OUTPUT LANGUAGE before presenting — never show the user a finding in the
wrong language even if the MR/PR copy has since been corrected.

End with **one combined verdict** line: requirements genuinely **met / partially met / not
met**, then the review level and the worst single issue per gate. The combined verdict is
**capped by any blocking finding at any gate** — a critical perf regression caps the verdict at
"partially met" even when the code-quality gate is clean.

### 4. Notify — orchestrator-owned, deterministic (ALWAYS runs when `notify.enabled`)

Do **NOT** leave notify to the gates. A gate that lost its shell (perf hallucinating "no Bash")
posts nothing — so gate-owned notify is non-deterministic and silently drops. After aggregating,
the **orchestrator itself** posts the **one combined verdict** as a threaded reply under the
ticket's review-request:

```
scripts/notify/send.sh --reply <KEY>   # threads under the "please review" msg; top-level fallback if none
```

Pipe the combined verdict (met / partially met / not met + review level + the worst finding per
gate) on stdin, in the resolved OUTPUT LANGUAGE. This is per `workspace.config.yaml`
`notify.enabled` + channel and is **not optional — never ask first**. This orchestrator post is
the guaranteed one; gates MAY still thread their own per-gate verdict per their definition, but
the run's notify does not depend on them. Report the returned `permalink`.
