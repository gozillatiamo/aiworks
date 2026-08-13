# Compression is explicit and file-scoped

**Status:** Accepted

Headroom joins this workspace as **`hcat` plus a redirect gate**, and nothing more. A large
structured file is compressed at the moment an agent chooses to read it, by a command that leaves a
receipt in the transcript. Headroom's compressing **proxy** — the mode that would do this
automatically to everything — is deliberately not adopted.

Anyone arriving with "why aren't we just running the proxy, it compresses everything for free?"
should read this before turning it on.

## What headroom offers

Two integration paths, and they are not variations on one idea:

| | `hcat` + MCP | proxy |
|---|---|---|
| when it acts | at the moment a file is read | on every request, forever |
| what it touches | one file's bytes | the whole message array |
| visible in the transcript | yes — a receipt line | no |
| if it breaks | the read is uncompressed | **every session stops** |

The savings are real on both paths. Measured here on `graphify-out/manifest.json`, a 37.7 KB
workspace artifact: ~16,217 tokens → ~992, a **93.9%** reduction, via `hcat` alone.

## Why not the proxy

**It is fail-closed by design.** From headroom's own documentation: "A stopped proxy intentionally
does not fall back to a direct Anthropic connection." That is the correct choice for the proxy's
threat model — silently bypassing compression would be worse than an error — but it means a local
daemon becomes a hard dependency of every Claude Code session across all 21 repos. This workspace
already treats a single point of failure as a finding; adopting one as a *default* is the opposite
of what `aiworks doctor` is for.

**It cannot be audited from inside a transcript.** The proxy rewrites the message array after the
agent has composed it. When an agent later reasons from something subtly different than what it
read, there is no line in the transcript to point at. `hcat` prints a receipt naming the file, the
sizes and the ratio, and the original stays on disk at a path the agent can re-read exactly. Every
compression this workspace performs is therefore attributable to a command someone can see.

**The marginal win is small.** `hcat` already captures the large case — a big file — and captures
it *before* the tokens are spent. The proxy's default `coding` profile runs in `cache` mode
precisely to avoid rewriting prior turns, so its incremental savings over the delta are modest,
while its blast radius is total.

None of this makes the proxy a bad tool. It is a good fit for a single developer who can restart it
when it dies. It is a poor fit for a shared framework where the failure lands on someone who did
not install it.

## What this rules in

- `hcat <file>` — the sanctioned way to ingest a large structured file.
- A `PreToolUse` gate that redirects an oversized `Read` there **once per file**, and rewrites a
  bare `cat`. A redirect with an escape hatch, never a wall.
- The `headroom` MCP, for the narrow cases where a file path is not what you have — chiefly a
  disposable subagent returning a compressed digest.

## What this rules out

- The proxy, `headroom wrap`, and any `ANTHROPIC_BASE_URL` redirection as a workspace default.
- `headroom learn`, which mines failed sessions and writes corrections into `CLAUDE.local.md`
  unreviewed. `CLAUDE.md` here is curated, line-budgeted and hook-enforced; an agent-authored
  instruction file that no one approved is a different artifact wearing the same name.
- `--memory` and the Serena code-memory MCP. Code navigation is codegraph's job (ADR 0013).

## The consequence that is not about tokens

`hcat` prints any file it is given, which makes it a **renamed `cat`** — and CLAUDE.md's `.env` ban
covers exactly that. `pretool-env-guard.sh` needed a dedicated `hcat` alternative, because `\bcat\b`
cannot match `hcat`: the leading `h` is a word character, so there is no boundary before `cat`. The
guard is mirrored into all 21 repos, so `aiworks doctor --only headroom` asserts the coverage at the
root and in every copy rather than trusting the mirror.

Adopting a compression tool moved a security boundary. That is the part worth remembering.

A second guard came out of the same review. The plugin's gate has a size **floor** and no ceiling,
so `hcat` inherits none either — and headroom's documented behaviour when compression would not
help is to pass the content through **unchanged**. Measured on a 262 MB `.log`: 0.0% saved, 262 MB
printed, 80 seconds. Since the gate rewrites `cat <that file>` into exactly that call, the
protection produces the flood. `pretool-hcat-size-guard.sh` caps `hcat` at 2 MiB and routes
anything larger to a disposable subagent. Both guards are mirrored into all 21 repos and asserted
by `aiworks doctor --only headroom`.

## Corollary

An accuracy loss is a cost, not a saving. The gate's own defaults (deny any structured `Read` over
16 KB, plus a 512-byte content sniff) would redirect `.claude/settings.json` and other files agents
must edit *exactly* into a lossy rendering — so this workspace raises the threshold to 64 KB and
turns the sniff off. Tuning is recorded in `docs/agents/headroom.md`; the reasoning is that a wrong
answer costs more than the tokens it saved.
