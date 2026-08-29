#!/usr/bin/env bash
#
# PreToolUse(Bash) hook — steer a repo's SUITE RUN to scripts/dev.sh.
#
# Blocks a raw suite command when it is NEITHER routed through scripts/dev.sh NOR
# redirected to a file. Two costs, and the second is the one that actually bites:
#
#   - context: a raw run dumps full verbose output into the window. Measured over 312
#     transcripts, a raw run's tool result averages 1,453 bytes against 749 for the
#     wrapper's one-liner — 1.9x, on every run.
#   - THE RECEIPT: dev.sh is what writes agent_logs/executed_verbose/<cmd>-<ts>.log and
#     what `status` / `why` read back. A raw run leaves none, and per
#     docs/agents/loadtest-gate.md a test-suite gate never fails open — no receipt
#     (command + exit code + summary) means NOT RUN. So a raw green suite does not
#     count as a green suite, however green it was.
#
# Fires for the MAIN session and for a SUBAGENT alike: a PreToolUse hook runs on a
# subagent's Bash call too (the payload carries .agent_id — see
# pretool-orchestrator-guard.sh), and this guard reads no discriminator, so both are
# held to the same rule. That is deliberate: the subagent is the one that actually runs
# the suites, and a receipt it skips is a gate the orchestrator later cannot verify.
#
# Covered verbs are SUITE RUNS ONLY — the ones a gate reads a receipt for. Deliberately
# NOT blocked, because they are fast, small and no gate reads them (measured: 30 of the
# 70 raw calls in the corpus):
#   - cargo check / cargo fmt / cargo clippy / cargo build / cargo run
#   - npm|pnpm|yarn install / ci / a non-test `run` script (lint, dev, storybook)
#   - scripts/dev.sh ...  (the wrapper itself; its internal `cargo`/`npm` call is a
#                          subprocess and never reaches this hook)
#   - a run whose output is redirected to a file (agent is capturing it deliberately)
#
# The flutter/dart patterns predate this workspace and are kept for a Flutter consumer
# of the framework; no repo here declares that stack.
#
# Exit 0 = allow. Exit 2 = block, stderr is shown to the model as actionable feedback.

set -uo pipefail

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null)
[ -z "$cmd" ] && exit 0

# Already using the wrapper — always fine.
case "$cmd" in
  *scripts/dev.sh*) exit 0 ;;
esac

# Is this one of the noisy, wrapped suite runs, issued raw?
#
# `B` is the boundary before a verb: start of string, or whitespace/;/&/| — so `npx cypress
# run` and `cd svc && cargo test` both match, and a substring like `mycargo` does not.
B='(^|[[:space:];&|(])'
noisy=0
# Rust — the suite only. build/check/clippy/fmt/run are fast and no gate reads them.
printf '%s' "$cmd" | grep -qE "${B}cargo[[:space:]]+test([[:space:];&|]|$)" && noisy=1
# Node — `npm test`, `pnpm test`, `yarn test`, and the `run test…` / `test:…` script forms.
printf '%s' "$cmd" | grep -qE "${B}(npm|pnpm|yarn)[[:space:]]+(run[[:space:]]+)?test([[:space:]:]|$)" && noisy=1
# E2E / API / load suites — each is a gate with a receipt, and each is very loud raw.
printf '%s' "$cmd" | grep -qE "${B}cypress[[:space:]]+(run|open)([[:space:];&|]|$)" && noisy=1
printf '%s' "$cmd" | grep -qE "${B}newman[[:space:]]+run([[:space:];&|]|$)" && noisy=1
printf '%s' "$cmd" | grep -qE "${B}k6[[:space:]]+run([[:space:];&|]|$)" && noisy=1
# Kept for a Flutter consumer of this framework; no repo in this workspace declares it.
printf '%s' "$cmd" | grep -qE "${B}flutter[[:space:]]+(test|analyze|clean)([[:space:];&|]|$)" && noisy=1
printf '%s' "$cmd" | grep -qE "${B}dart[[:space:]]+run[[:space:]]+build_runner[[:space:]]+build" && noisy=1
[ "$noisy" -eq 0 ] && exit 0

# Allow if output is redirected to a FILE (`> f` / `>> f`), not merely `2>&1`.
if printf '%s' "$cmd" | grep -qE '>>?[[:space:]]*[^[:space:]&]'; then
  exit 0
fi

# Block with guidance — stderr is fed back to the model.
{
  echo "⛔ Blocked raw suite run: $cmd"
  echo
  echo "A raw run leaves NO RECEIPT. A test-suite gate never fails open: with no"
  echo "command + exit code + summary on record, the suite counts as NOT RUN however"
  echo "green it was (docs/agents/loadtest-gate.md)."
  echo
  echo "Run it through the wrapper, which records the run and logs the verbose output to"
  echo "agent_logs/executed_verbose/ instead of flooding your context:"
  echo "  scripts/dev.sh test | gen | analyze | clean"
  echo "Then inspect with:"
  echo "  scripts/dev.sh why <name>     # only the failure lines"
  echo "  scripts/dev.sh status [name]  # the recorded one-line summary"
  echo
  echo "(The developer owns builds; the code-reviewer runs the suite too — its approval is"
  echo " gated on a green run — and both go through the wrapper. Other roles read results"
  echo " via status/why."
  echo " If you truly need raw output, redirect it to a file: $cmd > /tmp/out.log 2>&1)"
} >&2
exit 2
