# Headroom — input-side context compression

`caveman` compresses what an agent **writes**. Headroom compresses what an agent **reads**, and
it is the cheaper half: an output token you never emit saves one token, while a 40 KB file you
never ingest saves ~16,000 — and keeps saving them on every subsequent turn, because everything
already in the window is re-sent with each request.

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
| `DANGI_NUDGE_BYTES` | `32768` | `4096` | at 4 KB ordinary `grep`/`git log` output triggers a nudge; headroom's own docs say search results are already minimal, so those nudges are pure token drip |
| `DANGI_NO_NOTIFY` | `1` | off | desktop popups — this workspace already has `voice` and `stagehand` for that |

Escape hatches for a one-off: `HCAT_GATE_OFF=1` disables the gate, `HCAT_GATE_NO_REWRITE=1`
keeps `cat` from being rewritten.

### The ceiling the plugin does not have

The plugin's gate has a floor and **no upper bound**, and that is not a theoretical gap. Measured
on `ofb-k6-loadtests/step-rampup.log` (262,006,925 bytes): headroom's safety gate correctly decided
compression would save 0.0% and passed the content through unchanged — so `hcat` printed all
262 MB, in 80 seconds. A `cat` of that file is rewritten straight into it, which makes the
protection the flood.

Ratio is not the whole story either: `graphify-out/graph.json` is 767 KB and compresses 56.1%,
which is still ~92,000 tokens of output.

`pretool-hcat-size-guard.sh` supplies the ceiling: above **2 MiB** (`HCAT_MAX_BYTES`) `hcat` is
denied, with dangi's own advice for the huge case — read the file inside a **disposable subagent**
that returns only conclusions, so the bytes never reach this context at any ratio. It is mirrored
into all 21 repos alongside the `.env` guard, and `aiworks doctor` asserts both are present.

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
  connection", so one dead daemon breaks every session across all 21 repos at once;
- it puts a rewriting layer between the agent and the provider, which is exactly the thing you
  cannot audit from inside a transcript;
- `hcat` already captures the large win, and captures it *before* the bytes are paid for.

Anyone who wants it can run `headroom proxy` and set `ANTHROPIC_BASE_URL` by hand. It is a
personal experiment, not a workspace default, and nothing here depends on it.

Also **not** adopted: `headroom learn` (mines failed sessions and rewrites `CLAUDE.local.md`
unreviewed — the opposite of a curated, budget-capped, hook-enforced `CLAUDE.md`), `--memory`, and
the Serena code-memory MCP (`codegraph` already owns that job — ADR 0013).

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

`aiworks doctor --only headroom` reports four things, each with its owner command: the engine, the
plugin install, the `.env` guard's `hcat` coverage, and the savings badge.

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

State lives outside the repo — `~/.headroom/` (engine) and `~/.claude/headroom-indicator/`
(badge, ledger, learned offender files). Nothing to gitignore.

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
