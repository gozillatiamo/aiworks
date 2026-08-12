# Codegraph keeps the code, graphify maps the prose

**Status:** Accepted

Two indexes serve this workspace, split by the kind of file they read. **codegraph** keeps every
product repo's code, because it returns a symbol's verbatim source in one call. **graphify** covers
this repo's own documentation, because codegraph does not index prose at all. Neither replaces the
other, and the swap that prompted this — rip out codegraph, put graphify everywhere — was evaluated
against a working install and rejected.

Anyone arriving with "why are there two graph tools?" should read this before consolidating them.

## What was proposed

Replace codegraph with graphify across this repo and every product repo: one merged graph, one MCP
server, `graphify install --project --strict`, the per-repo graph committed for the team, then a push
per repo. Graphify's pitch fits a workspace like this well on paper — code parsed locally with
tree-sitter, no telemetry, and docs, PDFs and images folded into the same graph, which codegraph
cannot do.

## The gate it failed

Graphify stores a map, not the text. Every node carries exactly:

```
label · file_type · source_file · source_location · _origin · id · community · norm_label · metadata
```

There is no `snippet`, `source`, `code` or `body` field, none of its ten MCP tools reads a file from
disk, and `source_location` is a bare start line (`"L54"`) with no end — so a caller cannot even
fetch just the symbol, only the file that contains it. The extractor says this is deliberate: it
*"intentionally preserves only the symbol's name and metadata about its location — not the actual
source code."* No flag adds a field the extractor never writes.

codegraph's `codegraph_explore` returns, in one call, the verbatim line-numbered source of the
relevant files, the call path among them, each symbol's callers, and a warning when a symbol has no
covering tests. The skills that reason about code call it for exactly that reason.

## Why that costs more than it looks

The obvious reading is that graphify's answer is smaller — hundreds of tokens against thousands — and
the agent just reads the files afterwards. Measuring a real pipeline run shows why that reading is
wrong.

One `dev-cycle` run spent **396,159** new tokens across 67 turns and **2,148,776** on cache reads —
5.4× the new tokens, being the accumulated context re-fed on every turn. That is **~32,000 tokens per
turn**. Round-trip count, not payload size, is what an agent workspace pays for.

So replacing one call that returns the code with one call that returns coordinates plus N calls that
fetch them does not cost a few hundred tokens. It costs ~32,000 per added turn. A three-file
exploration goes from one turn to four.

## Why codegraph is not simply pointed at this repo

It cannot read it. codegraph indexes programming languages and skips shell and prose entirely — in
one Rust service repo measured here, 9 `.sh` and 26 `.md` files were tracked and its index held 31
files, **none of them either**. This workspace repo is the inverse of a code repo: of 556 tracked
files, 209 were `.md` and 144 `.sh`, so **63% was invisible to codegraph** — and that 63% is the
hooks, the adapters, the `aiworks-*.sh` toolchain, the skills, the agent definitions and every ADR.

Running `codegraph init` here would index the `.py` and `.js` minority and skip the framework itself.
The product repo clones would be excluded for free, since each is an anchored `/<repo>/` line in
`.gitignore` maintained by `aiworks add`.

## The scope graphify gets

Documentation only: `docs/`, `docs/adr/`, and the markdown under `.claude/` and `scripts/`. Three
deliberate exclusions:

- **Shell files stay out.** Graphify does index them, as `bash_function` nodes, but the
  missing-source problem applies there identically — a name and a start line, then a blind read of
  the whole file. That half becomes worth doing if graphify's proposed `read_source` MCP tool lands,
  which returns a bounded slice rather than a file. Even then it is a second call, so it improves the
  tokens without recovering the round-trip.
- **`agent_logs/` stays out.** A `.graphifyignore` "never re-includes a file your `.gitignore`
  already excluded", so indexing it requires `--no-gitignore` — which disables gitignore wholesale
  and leaves `.graphifyignore` as the only barrier between the file walker and the adapters' live
  `.env` files. `agent_logs/` can also hold deployed-environment case reports naming real customer
  identifiers, and the graph is committed. One pattern typo would put either into git.
- **Strict mode stays off.** `graphify install --strict` blocks a session's first raw source read and
  redirects it to the graph. Against a graph that structurally cannot return source, that buys a
  metadata detour in front of a read that still has to happen.

`.graphifyignore` excludes by **file type, not by directory**. That turned out to be load-bearing:
the adapter READMEs are the densest part of the graph, and blacklisting `scripts/` to keep `.env`
out would have lost all of them.

## The cost we accepted

Two index tools, two install paths — codegraph is npm and self-updating, graphify is `uv tool` and
pinned to Python 3.12 because its Leiden clustering will not run on 3.13+. That means two upgrade
paths, two doctor groups, two MCP servers and two lines in the sync sweep, on a dependency still
pre-1.0.

What pays for it: this repo had no index at all, codegraph cannot give it one, and the doc half is
where graphify's design costs nothing. A concept node's label *is* its content — a node reading
`Bash(kubectl *) / Bash(gcloud *) denied to agents` needs no file read to be useful — and the
cross-document edges between ADRs are a relationship neither grep nor codegraph produces. The
generated community names read as a table of contents for the framework's own concepts.

## What the doc graph does not do

Measured on the first real build, so that nobody adopts it expecting more:

- **Doc nodes carry no line anchor at all** (`loc=None`). You get "this concept is in
  `scripts/vcs/README.md`" and then read the file. Upstream has an open issue for section ranges on
  doc nodes.
- **Query precision needs narrowing.** A breadth-first depth-2 question about one adapter returned
  123 nodes, including several from unrelated design skills. Usable, but the `--context` filter
  matters.
- **Questions spanning prose and its implementation are out of reach**, because the implementations
  are shell and excluded by the scope above.

## Two things measurement corrected

The README documents `--backend claude` for Claude; that is the Anthropic API path and needs
`ANTHROPIC_API_KEY`. The subscription-backed value is **`claude-cli`**, which shells out to the local
binary. Following the documentation would have failed every extraction.

The README also states that every query is logged to `~/.cache/graphify-queries.log`. The code says
the opposite, and is right: logging is off unless `GRAPHIFY_QUERY_LOG_ENABLE` or
`GRAPHIFY_QUERY_LOG` is set, because *"a default-on record of proprietary queries contradicts
graphify's on-device, no-telemetry posture."*

Separately, codegraph's own anonymous telemetry was found **enabled** with a machine ID and has been
turned off (`codegraph telemetry off`). Graphify has none.

## Consequences

- No product repo changed. Code intelligence behaves exactly as before.
- `codegraph_explore` remains the first call for any code question; the doc graph answers "where is
  this decided, and what else touches it" over prose the code index cannot see.
- The swap reopens only on single-round-trip parity — source returned *in the same payload* as the
  map. A separate source-reading tool does not clear that bar.
- **`graphify extract` fails open.** The first build returned exit 0 with 2 of 7 semantic chunks
  timed out and 59 of 198 files silently absent from the graph; a retry with `--api-timeout 1800`
  fixed it. Anything that ever gates on this tool must read its warnings, not its exit code — the
  same rule the test-suite gates already follow.
- Round-trip count is now a recorded cost metric, not an intuition. Any future tool that trades one
  call for several should be measured against the ~32,000-tokens-per-turn figure before adoption.
