#!/usr/bin/env bash
#
# Link regression for both tracker providers. A URL an agent writes into a ticket —
# description or comment — must render as a REAL clickable link, must NOT be linked
# where it is code or already a labelled link, and must survive being read back out
# (an upsert rewrites the whole description, so a href lost on read is deleted for good).
#
# Run:  scripts/tracker/links-selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
#
# Pure jq — no network, no credentials, no ticket touched.
set -uo pipefail
J="$(cd "$(dirname "${BASH_SOURCE[0]}")/jira" && pwd)"
N="$(cd "$(dirname "${BASH_SOURCE[0]}")/notion" && pwd)"
command -v jq >/dev/null 2>&1 || { echo "jq is required"; exit 1; }

pass=0; fail=0
# t <name> <expected-jq-result> <jq-filter-over-doc> <input-text> [notion]
t() {
  local name=$1 want=$2 filter=$3 text=$4 which=${5:-jira} got
  if [ "$which" = notion ]; then
    got=$(printf '%s' "$text" | jq -R -s -L "$N" -c "include \"notion\"; md_to_blocks | $filter" 2>&1)
  else
    got=$(printf '%s' "$text" | jq -R -s -L "$J" -c "include \"jira\"; md_to_adf | $filter" 2>&1)
  fi
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n     want %s\n     got  %s\n' "$name" "$want" "$got"; fi
}

# Every link href in the doc, in order.
HREFS='[.. | objects | select(.type=="text") | .marks[]? | select(.type=="link") | .attrs.href]'
# Every text node paired with whether it is linked.
TXT='[.. | objects | select(.type=="text") | {t:.text, l:(([.marks[]?|select(.type=="link")]|length)>0)}]'
NHREFS='[.. | objects | select(.type?=="text") | .text.link.url? // empty]'

echo "--- jira: md_to_adf autolink ---"
t "bare url linked"            '["https://claude.ai/code/artifact/59e4"]' "$HREFS" 'Doc: https://claude.ai/code/artifact/59e4'
t "trailing period excluded"   '["https://x.com/a"]'                      "$HREFS" 'See https://x.com/a.'
t "trailing comma excluded"    '["https://x.com/a"]'                      "$HREFS" 'https://x.com/a, then next'
t "wrapped in parens"          '["https://x.com/a"]'                      "$HREFS" '(see https://x.com/a) ok'
t "underscores kept whole"     '["https://x.com/a_b_c"]'                  "$HREFS" 'at https://x.com/a_b_c now'
t "two urls both linked"       '["https://a.com/1","https://b.com/2"]'    "$HREFS" 'https://a.com/1 and https://b.com/2'
t "labelled link still wins"   '["https://example.com/x"]'                "$HREFS" 'plan: [OFB-1944 plan](https://example.com/x)'
t "inline code not linked"     '[]'                                       "$HREFS" 'run `https://x.com/a` verbatim'
t "code fence not linked"      '[]'                                       "$HREFS" '```
curl https://x.com/a
```'
t "table cell linked"          '["https://x.com/a"]'                      "$HREFS" '| doc | url |
| --- | --- |
| plan | https://x.com/a |'
t "bullet linked"              '["https://x.com/a"]'                      "$HREFS" '- plan: https://x.com/a'
t "heading linked"             '["https://x.com/a"]'                      "$HREFS" '## https://x.com/a'
t "http linked too"            '["http://localhost:3000/x"]'              "$HREFS" 'local https://.. no: http://localhost:3000/x'
t "prose split correctly"      '[{"t":"Doc: ","l":false},{"t":"https://x.com/a","l":true},{"t":" ok.","l":false}]' \
                               "$TXT"   'Doc: https://x.com/a ok.'
t "no url no link"             '[]'                                       "$HREFS" 'plain sentence, no url here'

echo "--- jira: text_to_adf (one-line / --description path) ---"
tt() {
  local name=$1 want=$2 text=$3 got
  got=$(printf '%s' "$text" | jq -R -s -L "$J" -c "include \"jira\"; text_to_adf | $HREFS" 2>&1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n     want %s\n     got  %s\n' "$name" "$want" "$got"; fi
}
tt "bare url linked"      '["https://x.com/a"]'       'Artifact: https://x.com/a'
tt "labelled link linked" '["https://example.com/x"]' 'Artifact: [the plan](https://example.com/x)'
tt "empty string safe"    '[]'                        ''

echo "--- notion: md_to_blocks autolink ---"
t "bare url linked"          '["https://x.com/a"]'       "$NHREFS" 'Doc: https://x.com/a' notion
t "trailing period excluded" '["https://x.com/a"]'       "$NHREFS" 'See https://x.com/a.' notion
t "labelled link still wins" '["https://example.com/x"]' "$NHREFS" '[plan](https://example.com/x)' notion
t "inline code not linked"   '[]'                        "$NHREFS" 'run `https://x.com/a`' notion
t "code fence not linked"    '[]'                        "$NHREFS" '```
curl https://x.com/a
```' notion

echo "--- read-back: a link must survive a read, and a read-then-rewrite ---"
# Reading a description out must keep the href, else the next upsert (which rewrites the
# whole field) silently deletes it — the OFB-1952 shape of loss.
rb() { # rb <name> <expected> <filter> <input>
  local name=$1 want=$2 filter=$3 text=$4 got
  got=$(printf '%s' "$text" | jq -R -s -L "$J" -r "include \"jira\"; $filter" 2>&1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n     want %s\n     got  %s\n' "$name" "$want" "$got"; fi
}
rb "labelled link keeps href"   'plan: [the plan](https://example.com/x)' \
   'md_to_adf | adf_to_text | rtrimstr("\n")' 'plan: [the plan](https://example.com/x)'
rb "bare url not double-wrapped" 'doc https://x.com/a' \
   'md_to_adf | adf_to_text | rtrimstr("\n")' 'doc https://x.com/a'
rb "round-trip keeps both hrefs" '["https://example.com/x","https://x.com/a"]' \
   'md_to_adf | adf_to_text | md_to_adf | [.. | objects | select(.type=="text") | .marks[]? | select(.type=="link") | .attrs.href] | tojson' \
   '[label](https://example.com/x) and https://x.com/a'
nrb() {
  local name=$1 want=$2 json=$3 got
  got=$(printf '%s' "$json" | jq -L "$N" -r 'include "notion"; rich_to_text' 2>&1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n     want %s\n     got  %s\n' "$name" "$want" "$got"; fi
}
nrb "notion labelled link md form" '[the plan](https://example.com/x)' \
    '[{"plain_text":"the plan","href":"https://example.com/x"}]'
nrb "notion bare url stays bare"   'https://x.com/a' \
    '[{"plain_text":"https://x.com/a","href":"https://x.com/a"}]'

echo
echo "pass=$pass fail=$fail"
[ "$fail" -eq 0 ]
