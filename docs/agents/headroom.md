# Headroom — input-side context compression

`caveman` compresses what an agent **writes**. Headroom compresses what an agent **reads**, and
it is the cheaper half: an output token you never emit saves one token, while a 40 KB file you
never ingest saves ~16,000 — and keeps saving them on every subsequent turn, because everything
already in the window is re-sent with each request.

That last clause has a third consequence, and it is the largest of the three: **a turn you never
take saves the entire window.** Not the bytes of one result — all of it, re-sent. Which is why the
most expensive call in a transcript is routinely one whose result is four characters long
(*The poll loop*, below).

Two pieces, and it matters which is which:

| Piece | What it is | Where it comes from |
|---|---|---|
| **engine** | the `headroom` binary — the compression pipeline everything shells out to | `uv tool install --python 3.13 'headroom-ai[mcp]'`, via `.superset/setup.sh` |
| **plugin** | `headroom-usage-indicator@headroom-tools` — hooks, `hcat`, the savings badge | `.claude/settings.json` `enabledPlugins` → `ensure_claude_plugins` |

The plugin is a **gauge and a set of hooks**; it contains no compressor. Both halves fail OPEN —
without the engine there is no compression, no badge and **no error** — which is why
`aiworks doctor --only headroom` exists.

## The one thing to actually do

When you are about to pull a large structured file into context, run it through `hcat` instead of
`Read` or `cat`:

```bash
hcat graphify-out/manifest.json
```

It prints a compressed rendering plus a receipt line, and the raw bytes never enter the window:

```
── hcat: …/manifest.json · 992 lines · 37.7 KB · ~16217 tok → ~992 tok (93.9% saved)
```

The **original on disk stays the source of truth**. When you need an exact value, `Read` that same
path with `offset`/`limit` — a compressed rendering is for orienting, never for quoting.

`hcat` takes exactly one file argument. No pipes, no globs, no flags.

## The guard that makes this happen, because advice did not

`hcat` was on `PATH` and documented for months and still went unused, because nothing stopped the
cheaper habit. **Measured over one real session** (~290k tokens
of messages): `posttool-output-warden.sh` fired **13 times** and changed nothing — it speaks after
the bytes have landed, and says so itself: *"PostToolUse can't shrink output already received."*
Over the same session the *blocking* guards fired 3 times and were obeyed 3 times. Same
information, opposite timing, opposite outcome.

**A spawned agent gets the hooks but not the whole habit, and it is the one that dies of this.**
A hook can block an oversized `Read`; nothing can block a test run's output, which is where a
workflow agent's context actually goes. Measured across 235 `dev-cycle` agents: 90 were killed
mid-work, 84 of them past 160k input tokens, while the 145 that finished averaged 71k — and step
count told the two apart almost not at all (killed 22–411 steps, finished 4–527). Of the 3,891
results the killed agents pulled in, the median was ~1 KB and the **9% over 8 KB were 56% of
everything they spent**. So this page's rule rides every agent brief (`CONTEXT_DISCIPLINE` in
`.claude/workflows/src/dev-cycle.js`), and the ceiling is re-measured rather than assumed —
`scripts/agent-context-ceiling.sh` derives it from the local transcripts, because the wall is the
runtime's and moves with the window a session was given.

So the enforcement is a **PreToolUse** hook, `pretool-bash-context-guard.sh`, with two rules:

1. **An unbounded read of a file ≥ 8 KiB is blocked** (`BASH_READ_MAX_BYTES`). `cat`, `nl`,
   `less`, `more`, `bat` — but only when nothing consumes the output. `… | head`, `… | grep`,
   `… > file`, `sed -n '10,40p'`, and `grep` itself are all allowed, because they are what the
   block message recommends and blocking them would push you straight back to the bare `cat`.
   The rule judges only what is **statically knowable**: the file exists, `wc -c` says how big it
   is, and the command asked for all of it. It deliberately does not try to predict `grep` output.
   That session's single largest block was one `cat` of a 25 KB `SKILL.md` — ~7,000 tokens, to
   answer a question that needed about 30 lines.

2. **A read-modify-write patch through a heredoc is blocked** (`BASH_PATCH_GUARD=0` disables just
   this rule). `python3 - <<'PY' … .read() … open(p,'w').write(…) … PY` pays for the same text
   twice: the command carries the old block *you already read* plus the new one, and because the
   write happens outside the tracked `Edit` path the harness then echoes an `edited_text_file`
   diff back (16.2k tokens over 7 echoes that session, on top of ~50k of command payloads).
   `Edit` sends `old_string`/`new_string` only and triggers no echo. A **write-only** script —
   a new file, a computed file — is not a patch and is allowed; requiring a real read *call*
   (not a bare `open(`) is what separates the two, and is the guard's one measured false positive,
   now a selftest case.

   ⚠️ Rule 2 knowingly overrides the auto-mode preference for editing files with "sed, heredocs,
   or short scripts, rather than the dedicated Read, Edit, or Write tools". That preference is
   about permission friction; this is about context cost, and for this one shape the cost is
   measured and large. Every other Bash edit still works.

3. **The poll loop — the same file probe blocked on the 7th run** (`BASH_POLL_MAX`,
   `BASH_POLL_WINDOW`, `BASH_POLL_GUARD=0`). Rules 1 and 2 both price a single call by its
   bytes. This one prices the call that has almost no bytes and is still the most expensive
   thing in the transcript, because the unit is the **turn**.

### The poll loop

One developer subagent on a Rust backend repo (2026-08-27) made **907 tool calls**, 806 of them
foreground `Bash`. A single command —

```
grep -c " ok$" agent_logs/executed_verbose/test-<ts>.log
```

— ran **95 times verbatim**, in unbroken runs of about twenty back to back with no other tool
call between them; thirteen consecutive probes returned the identical count. With its siblings on
the same log (`grep -c "\.\.\. FAILED"`, `tail -5`, `wc -l`), roughly **400 of the 806 calls were
one spin loop** waiting for `scripts/dev.sh test` to finish.

| | that agent | every other agent in the same workflow run |
|---|---|---|
| tool calls | 907 | 74 – 136 |
| turns | 1,409 | ~230 |
| cache-read tokens | 690M | 48M |
| cost | ~$30.51 | $3 – $7 |

Output was only 217k tokens. Nearly all of the spend is one 490k-token window re-sent 1,409
times — **~490,000 tokens billed to learn a number that had not changed.**

**The remedy was already in hand and simply unknown.** `run_in_background` is a parameter of the
`Bash` tool that agent already had, and the harness re-invokes you when the command exits. Wait in
**one** call that ends when the condition is true:

```
Bash(run_in_background=true,
     command="until grep -qE 'test result:|error: could not compile|panicked' run.log; do sleep 5; done")
```

Match the **failure** signatures too — a condition that only matches success is silent through a
crash, and silence is indistinguishable from still-running. Want one notification *per event*
rather than one at the end? That is the `Monitor` tool with a `--line-buffered` filter; for "tell
me when it's done", background `Bash` is the whole answer.

Scope is deliberately narrow, so an honest re-check never trips it: only a **read-only probe** of
a file that **exists**, only the **byte-identical command**, only within a rolling five minutes.
Two greps of one log with different patterns are two questions and both are allowed — it is the
same question, asked seven times, that is never worth a turn. Repeating a *build* is work, not
waiting, and is not counted; neither is the `until` loop the block message recommends.

**Both guards' escape hatches are parsed out of the command string, not read from the environment.**
A hook runs in its own process, so `BASH_READ_MAX_BYTES=… <command>` never reaches its env — the
assignment applies to the command being judged, which has not run yet. `pretool-hcat-size-guard.sh`
had promised `HCAT_MAX_BYTES=<bytes> hcat <file>` and silently ignored it for exactly this reason;
both now honour the inline form. A documented override that does nothing is worse than none: you
follow the instructions and get blocked again.

Proof lives in `.claude/hooks/dev-wrapper/guards-selftest.sh` (never a scratchpad script) —
64 cases covering all three rules, the bounded forms, operand-position and heredoc false positives,
and the inline overrides. Rule 3's cases are the stateful ones: each gets its own `transcript_path`
(parallel subagents can share a `session_id`, and a shared counter would charge agent B for agent
A's probes) and its own `TMPDIR`, and one case asserts the recommended `until` loop never trips the
guard that recommends it.

## The context floor — what every turn re-sends before it starts

The guards above police what a turn *adds*. They cannot see what every turn already carries: the
system prompt, the agent definition, the imported config, and — the part nobody budgets for — one
schema per granted tool. That floor is re-sent on every single turn, so it is not a one-time cost;
it is a multiplier on turn count.

Measured across one `dev-cycle` run — 151 subagents, 12,746 turns, 2,374.6M cache-read tokens:

| | tokens |
|---|---|
| total cache-read | 2,374.6M |
| **fixed floor, re-sent every turn** | **749.3M (31.6%)** |

The floor is not uniform, and the spread is almost entirely tool schemas:

```
role=general-purpose   floor =  9,975 tok
role=developer         floor = 96,360 tok
```

Same workspace, same imported config. The brief explains ~4K of that 86K gap and the agent
definition ~11K; the remaining ~70K is granted MCP tool schemas. Two `role=developer` agents from
the same phase with byte-identical briefs measured 96,360 and 42,767 — a 53.6K swing decided by
which MCP servers happened to be connected when they spawned. Half the context was not chosen.

**And it went unread.** Those 151 subagents held several hundred MCP tool schemas across 12,746
turns and made **154 MCP calls against 11 distinct tools** — nine of them the two Postgres servers,
two `codegraph`. Every schema for Redis, the triage servers, SonarQube, the graph docs and Figma was
paid for on every turn and never once called.

So: **grant verbs, not servers.** A bare `mcp__<server>` entry is not a small line in the
frontmatter — `mcp__redis` alone is ~53 schemas. Enumerate what the role uses, the way
`code-reviewer` and `qa-runner` already enumerate their sixteen Redis read verbs. The audit is one
command:

```sh
for a in .claude/agents/*.md; do
  grep -oE '^\s*-\s*mcp__[a-zA-Z0-9_]+\s*$' "$a" | grep -v '__.*__' \
    | sed "s|^|$(basename "$a" .md) |"
done
```

Anything it prints is a whole-server grant; keep it only where the server *is* the role's job.
Trimming is also a permission fix — a whole-server Redis grant hands a build agent `delete`,
`hset`, `xdel`, `rename` and `json_del`, which no plan ever asks it to run.

## The window, not the hit rate

A near-100% cache-hit rate is not a win to defend; it is the ceiling, and it says nothing about
the bill. Cache read is charged per request at the **full window size**:

```
cache_read = Σ (window size) over every request
```

Hit rate only decides *which tier* that sum is billed at — the discounted one or the 10× one.
It cannot shrink the sum. Two levers can: **fewer requests**, and a **smaller window**.

Measured over one 7-day period on the workspace this was written for — 3,112 requests,
730.7M cache read, mean window 234,805 tokens:

| window at request time | share of requests | share of cache read |
|---|---|---|
| >300k | 28% | **52%** |
| ≥150k | 53% | **84%** |
| <100k | 18% | 6% |

A single session that drifted to a 709k window was **56% of the whole week**. Capping every
request at 150k would have cut cache read 44%; at 120k, 53%.

Nothing in the normal loop surfaces this. The status-line badge shows headroom *remaining* — a
percentage that looks fine at 400k on a large-context model — not what the last turn cost. So two
checks make the number visible:

- **`posttool-context-budget.sh`** (PostToolUse, advisory, never blocks) reads the window off the
  live transcript and prints one line per 50k crossed: a warning at 150k, an escalation at 300k.
  Thresholds move with `AIWORKS_CONTEXT_WARN` / `AIWORKS_CONTEXT_ALARM`.
- **`context-handoff.sh`** (PostToolUse, `decision: block`) does not advise — at 140k it demands a
  handoff document the agent writes for *itself*, hands it back after the compaction, and re-arms.
  Inside a subagent both hooks measure the subagent's own transcript. `docs/agents/context-handoff.md`.
- **`aiworks doctor --only headroom`** samples recent transcripts and reports any session that ran
  past 300k, because the expensive sessions are the ones nobody noticed at the time.

What to do when one fires, in order of effect:

1. **Compact at ~150k** rather than at exhaustion. Same work, ~4.7× less per turn than at 700k.
2. **Split the thread.** A fresh session re-bases to the static floor above; a drifted one never
   comes back down on its own.
3. **Push fan-out reads into a subagent.** It reads 40 files in *its* window and returns a summary
   to yours. Doing that inline inflates every later turn in the session, permanently — which is
   how a mean window reaches 235k in the first place.

Note that a subagent's own tokens are billed but do **not** appear in the parent transcript, so a
per-session measurement like the one above is a floor, not a total.

## The gate, and why its defaults are not our defaults

A `PreToolUse` hook watches `Read` and bare `cat`:

- **`Read`** of an eligible file → denied **once per file per session**, with an `hcat` pointer. It
  is a redirect, not a wall: Read the same path again and it passes.
- **bare `cat <file>`** → rewritten in place to `hcat "<file>"`. Pipes, redirects, flags and
  `head`/`tail` are real processing and are left alone.

Eligible means a data extension (`.json .jsonl .ndjson .csv .tsv .log`) at or above the size
threshold. Source, Markdown and YAML are never eligible.

The knobs live in `.claude/settings.json` `env`, at the root and in every repo:

| Variable | Ours | Plugin default | Why |
|---|---|---|---|
| `HCAT_GATE_BYTES` | `65536` | `16384` | at 16 KB the gate denies `.claude/settings.json` (~18 KB) and redirects a file agents must edit **exactly** to a lossy rendering |
| `HCAT_GATE_NO_SNIFF` | `1` | off | the 512-byte structural sniff catches extensionless and `.txt` files whose extension "lies" — a false positive there costs accuracy for a guess |
| `DANGI_NO_NOTIFY` | `1` | off | desktop popups — this workspace already has `voice` and `stagehand` for that |

`DANGI_NUDGE_BYTES` **was** carried here as a statement of the intended threshold. It has been
removed from `.claude/settings.json`: it never worked (verified against the installed plugin —
no file under it references the variable, and the plugin's own design note calls `NUDGE_BYTES` a
hardcoded script variable with no env override), and a config line that states an intention the
system ignores is worse than no line, because the next reader believes it. `aiworks doctor --only
headroom` warned about it on every run, which is the correct place for that fact to live. The
threshold it was reaching for is now enforced for real, by a hook that fires *before* the read —
see below.

Escape hatches for a one-off: `HCAT_GATE_OFF=1` disables the gate, `HCAT_GATE_NO_REWRITE=1`
keeps `cat` from being rewritten.

### The ceiling the plugin does not have

The plugin's gate has a floor and **no upper bound**, and that is not a theoretical gap. Measured
on a 250 MB load-test log (262,006,925 bytes): headroom's safety gate correctly decided
compression would save 0.0% and passed the content through unchanged — so `hcat` printed all
262 MB, in 80 seconds. A `cat` of that file is rewritten straight into it, which makes the
protection the flood.

Ratio is not the whole story either: `graphify-out/graph.json` is 767 KB and compresses 56.1%,
which is still ~92,000 tokens of output.

`pretool-hcat-size-guard.sh` supplies the ceiling: above **2 MiB** (`HCAT_MAX_BYTES`) `hcat` is
denied, with dangi's own advice for the huge case — read the file inside a **disposable subagent**
that returns only conclusions, so the bytes never reach this context at any ratio. It is mirrored
into every declared repo alongside the `.env` guard, and `aiworks doctor` asserts both are present.

## ⚠️ `hcat` is a reading verb

`hcat <file>` prints any file it is handed, so it is a `.env` read like `cat`, and CLAUDE.md's ban
covers it by name. It needs its **own** alternative in `pretool-env-guard.sh`: `\bcat\b` cannot
match `hcat`, because the leading `h` is a word character and leaves no boundary before `cat`.

That coverage is asserted by `aiworks doctor --only headroom`, at the root **and** in every repo's
mirrored copy of the guard — a stale copy is a live hole in that repo alone.

## The accuracy contract

Everything headroom does here is **explicit and file-scoped**. Nothing rewrites conversation
history, so nothing can quietly change what an agent already read, and nothing perturbs the
message prefix the provider's cache is keyed on.

That is a deliberate choice, not a limitation of the tool. Headroom also ships a **proxy** that
compresses all traffic automatically. We do not run it:

- it is **fail-closed** — "a stopped proxy intentionally does not fall back to a direct Anthropic
  connection", so one dead daemon breaks every session across every declared repo at once;
- it puts a rewriting layer between the agent and the provider, which is exactly the thing you
  cannot audit from inside a transcript;
- `hcat` already captures the large win, and captures it *before* the bytes are paid for.

Anyone who wants it can run `headroom proxy` and set `ANTHROPIC_BASE_URL` by hand. It is a
personal experiment, not a workspace default, and nothing here depends on it.

Also **not** adopted: `headroom learn` (mines failed sessions and rewrites `CLAUDE.local.md`
unreviewed — the opposite of a curated, budget-capped, hook-enforced `CLAUDE.md`), `--memory`, and
the Serena code-memory MCP (`codegraph` already owns that job — ADR 0013).

## What it compresses — and what the "missed" counter overstates

`hcat` picks a tier from the content. Measured on this workspace, one run per shape:

| input | result | fidelity |
|---|---|---|
| structured JSON, 200 records | re-encoded as typed CSV, **66% saved** | **lossless** — every record, every value |
| varied log, 4,000 lines | **35% saved** | content kept |
| templated bulk + one anomaly | **99.8% saved** | anomaly kept **with ±3 lines of context**, plus `[N lines omitted]` and a retrieval hash |
| identical repeated lines | passthrough — *"compression would save 0.0%"* | untouched |
| shell script, 27 KB | passthrough | untouched — output is *larger* than input |
| `git diff` | passthrough — *"would save 0.4%"* | untouched |

Two things follow. **It does not silently drop unique information** — an outlier buried in 4,000
templated lines survives with context, and the omission is stated rather than implied. And **it
declines to compress code and diffs**, which is why reaching for it on source is a wasted turn, not
a risk.

⚠️ **So the badge's `N missed` overstates the opportunity.** It counts every large tool result,
including the code, diffs and script reads `hcat` would hand straight back. A session showing
"8 missed" may have had almost nothing worth compressing. Read that number as *"how much large
output happened"*, never as *"how much was wasted"* — and before treating a miss as a finding, ask
which shape it was. This is measured, not inferred; it is written down here because the number
sent one investigation down a dead end already.

## The MCP tools

The plugin registers a `headroom` MCP: `headroom_compress`, `headroom_retrieve`, `headroom_stats`.

Reach for them rarely. `headroom_compress` runs **after** content is already in the window, so you
have paid for the original and now also pay for the compressed copy — it is a net loss on the
common path. It earns its place in two spots:

- inside a **disposable subagent** that fetches something large and returns only the compressed
  digest, so the raw bytes never reach the main thread;
- `headroom_retrieve` to recover an original by hash after a compression.

For anything file-backed, `hcat` is strictly better: it compresses before the spend.

## Operations

`aiworks doctor --only headroom` reports five things, each with its owner command: the engine, the
plugin install, the `.env` guard's `hcat` coverage, the savings badge, and the badge's price table.

The badge is wired by the **plugin's own** doctor (`/headroom-usage-indicator:doctor`), never by
hand — its merge chains an existing `statusLine` command and keeps the original under
`_headroomStatusLineBackup` with a `.bak`, which a hand-edit of `~/.claude/settings.json` would
destroy. Because it writes to a machine-global user file, it is the per-person half: opt out with
`headroom.statusline: false` in `workspace.config.local.yaml`.

⚠️ **A wired badge is not a counting badge.** That doctor copies `scripts/statusline.sh` to
`~/.claude/headroom-statusline.sh` but **not** `scripts/lib/`, and the copy resolves
`attribution.jq` beside itself — without it `compute()` returns zeros silently, so the badge reads
`idle (not compressing yet)` however much `hcat` runs, and no `.totals` is written (that session's
money total is then gone for good). The plugin's own doctor scores the copy "current" regardless,
so treat its green as no evidence: `aiworks doctor --only headroom` is what checks for
`attribution.jq` + `headroom-state.sh` beside the copy, and its owner command restores them.
Re-run it after any plugin update, which recreates the lib-less copy.

The plugin's `--fix` also joins the badge onto the END of your existing `statusLine` line with two
spaces, so on a multi-line bar it lands on the last line and gets truncated. `printf '%s\n%s'`
instead of `printf '%s  %s'` in that command gives it its own line; it is preserved on later runs,
since the merge only fires when no `headroom-statusline` reference is present.
**Another tool may own `statusLine.command` and chain ours.** A bridge stores the command it
replaced in its own cache file and re-runs it, so the badge still renders while `settings.json` no
longer names it. Doctor therefore *renders the bar and looks* rather than grepping the string —
following the string generalises to nothing, since each vendor stashes the original somewhere
else. The probe is inert by construction: no `transcript_path`, so the badge's compute path never
runs, and a throwaway `HEADROOM_STATE_DIR`, so it can never write into the ledger it is auditing.

State lives outside the repo — `~/.headroom/` (engine) and `~/.claude/headroom-indicator/`
(badge, ledger, learned offender files). Nothing to gitignore.

**The price table is a data file, and a missing row is silent.** The badge turns tokens into money
with a per-model **input** `$/MTok` looked up by substring in `~/.claude/headroom-model-prices.json`
(a plugin copy under `data/model-prices.json` is the fallback). A model the table does not match is
not an error: the badge simply drops the `$` segment and records `0.000000` for that session, so the
`all-time` figure stays at zero no matter how much the team compresses — the one number that would
justify the feature is the one a missing row zeroes. The table ships from upstream and lags new
model releases, so add the row yourself rather than waiting for a plugin update:

```bash
jq '.prices |= [{match: "opus-5", usd_per_mtok: 5}] + .' ~/.claude/headroom-model-prices.json > /tmp/p && mv /tmp/p ~/.claude/headroom-model-prices.json
```

First substring match wins, so put a more specific `match` ahead of a shorter one that would also
hit it (`opus-5` before `opus`). The doctor's **badge price table** item catches the next gap from
the ledger itself — a session that saved tokens but recorded no dollars.

The install extra is `[mcp]`, not `[all]`: `[all]` drags in torch/ONNX/LLMLingua for the ML
relevance models and the proxy, none of which this workspace uses.

## Config

```yaml
headroom:
  enabled: true
  statusline: true
```

`enabled` gates **provisioning**, not the plugin: turning it off stops the doctor checking and
`.superset/setup.sh` installing. On a machine already provisioned, also run
`claude plugin uninstall headroom-usage-indicator@headroom-tools`.

Rationale: [ADR 0014](../adr/0014-compression-is-explicit-and-file-scoped.md).
