#!/usr/bin/env bash
#
# Link + embedded-evidence regression for both tracker providers. A URL an agent writes
# into a ticket — description or comment — must render as a REAL clickable link, must
# NOT be linked where it is code or already a labelled link, and must survive being read
# back out (an upsert rewrites the whole description, so a href lost on read is deleted
# for good). An `![alt](attachment:<id>)` must become an ADF media node so a screenshot
# shows up IN the comment, and must NOT become one where it would dangle.
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

echo "--- jira: md_to_adf ticket-key autolink (ctx-aware) ---"
# ctx-aware variant: same doc pipeline, but with a {base, prefix} context so a bare
# mention of another ticket (e.g. "OFB-2266") in prose gets linked too, not just URLs.
tk() {
  local name=$1 want=$2 filter=$3 text=$4 got
  got=$(printf '%s' "$text" | jq -R -s -L "$J" -c "include \"jira\"; md_to_adf({base:\"https://bluepi.atlassian.net\",prefix:\"OFB\"}) | $filter" 2>&1)
  if [ "$got" = "$want" ]; then pass=$((pass+1)); printf 'ok   %s\n' "$name"
  else fail=$((fail+1)); printf 'FAIL %s\n     want %s\n     got  %s\n' "$name" "$want" "$got"; fi
}
tk "bare ticket key linked"        '["https://bluepi.atlassian.net/browse/OFB-2266"]' "$HREFS" 'blocked by OFB-2266 for now'
tk "two bare keys both linked"     '["https://bluepi.atlassian.net/browse/OFB-1","https://bluepi.atlassian.net/browse/OFB-22"]' \
                                   "$HREFS" 'see OFB-1 and OFB-22'
tk "ticket key in code not linked" '[]'                                                 "$HREFS" 'run `OFB-2266` check'
tk "already-linked key not doubled" '["https://bluepi.atlassian.net/browse/OFB-2266"]'  "$HREFS" 'plan: [OFB-2266](https://bluepi.atlassian.net/browse/OFB-2266)'
tk "key inside a url not re-split" '["https://bluepi.atlassian.net/browse/OFB-2266"]'   "$HREFS" 'see https://bluepi.atlassian.net/browse/OFB-2266 above'
tk "non-matching prefix not linked" '[]'                                                "$HREFS" 'ISO-8601 and UTF-8 are not tickets'
tk "no key no link"                '[]'                                                 "$HREFS" 'plain sentence, no ticket here'
t  "0-arity default: no ctx, key stays plain" '[]' "$HREFS" 'blocked by OFB-2266 for now'

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

echo "--- jira: md_to_adf embedded evidence (![alt](attachment:<id>)) ---"
# A test screenshot / rendered load report must land IN the prose that explains it.
# One image alone on a line = mediaSingle (a failure a human must see); several on one
# line = mediaGroup (a thumbnail strip of pass evidence). Anything else stays literal
# rather than becoming a media node pointing at a file Jira cannot resolve.
MEDIA='[.. | objects | select(.type=="mediaSingle" or .type=="mediaGroup") | {n:.type, ids:[.content[].attrs.id]}]'
t "single image is mediaSingle"   '[{"n":"mediaSingle","ids":["10501"]}]'          "$MEDIA" '![TC004 fail](attachment:10501)'
t "two images are one mediaGroup" '[{"n":"mediaGroup","ids":["10502","10503"]}]'   "$MEDIA" '![TC001](attachment:10502) ![TC002](attachment:10503)'
t "image after heading kept"      '[{"n":"mediaSingle","ids":["7"]}]'              "$MEDIA" '### TC004 — Error path
![shot](attachment:7)'
t "non-attachment image not media" '[]'                                            "$MEDIA" '![logo](https://x.com/logo.png)'
t "image mid-prose not media"     '[]'                                             "$MEDIA" 'see ![shot](attachment:99) here'
t "image mid-prose not a link"    '[]'                                             "$HREFS" 'see ![shot](attachment:99) here'
t "prose link beside image line"  '["https://x.com/r"]'                            "$HREFS" '![TC001](attachment:1)
Full run: [the report](https://x.com/r)'

echo "--- jira: md_to_adf image SIZE (a screenshot must not render as a 250x200 stamp) ---"
# A readable size takes BOTH halves: a width on the mediaSingle (or the block is the
# renderer's 250x200 fallback box) and width/height on the media node (or that box keeps
# the fallback RATIO and letterboxes the picture). `@<W>x<H>` on the id carries the size.
# 60% of the column = 446px measured, settled on by eye after 100% (760px) and 80% (604,
# level with a human's own 592-616 paste); the sizeless form gave 250x149.
SIZE='[.. | objects | select(.type=="mediaSingle" or .type=="mediaGroup")
       | {n:.type, w:.attrs.width, wt:.attrs.widthType, m:[.content[].attrs | {id, width, height, alt}]}]'
t "single image is full width, sized" \
  '[{"n":"mediaSingle","w":60,"wt":"percentage","m":[{"id":"f902c88f","width":1859,"height":1053,"alt":"TC004 fail"}]}]' \
  "$SIZE" '![TC004 fail](attachment:f902c88f@1859x1053)'
t "no size still asks for full width" \
  '[{"n":"mediaSingle","w":60,"wt":"percentage","m":[{"id":"f902c88f","width":null,"height":null,"alt":"TC004 fail"}]}]' \
  "$SIZE" '![TC004 fail](attachment:f902c88f)'
t "size survives in a group too" \
  '[{"n":"mediaGroup","w":null,"wt":null,"m":[{"id":"a1","width":800,"height":600,"alt":"TC001"},{"id":"a2","width":null,"height":null,"alt":"TC002"}]}]' \
  "$SIZE" '![TC001](attachment:a1@800x600) ![TC002](attachment:a2)'
t "empty alt is omitted, not empty-stringed" \
  '[{"n":"mediaSingle","w":60,"wt":"percentage","m":[{"id":"a1","width":800,"height":600,"alt":null}]}]' \
  "$SIZE" '![](attachment:a1@800x600)'
t "a malformed size stays part of the id (no half-parse)" \
  '[{"n":"mediaSingle","w":60,"wt":"percentage","m":[{"id":"a1@800x","width":null,"height":null,"alt":"x"}]}]' \
  "$SIZE" '![x](attachment:a1@800x)'

echo "--- jira: md_to_adf snake_case survives (intraword _ is not emphasis) ---"
# A snake_case identifier in prose used to be parsed as emphasis, which ATE the
# underscores: agent_logs/executed_verbose became italic "agentlogs/executedverbose".
# Measured on a real ticket. Underscores in our prose are table/field/path names far
# more often than they are intraword emphasis, and CommonMark forbids the latter too.
TXTS='[.. | objects | select(.type=="text") | .text] | join("")'
EM='[.. | objects | select(.type=="text") | select(([.marks[]?|select(.type=="em")]|length)>0) | .text]'
t "snake_case path keeps underscores" '"log: agent_logs/executed_verbose/test.log"' "$TXTS" 'log: agent_logs/executed_verbose/test.log'
t "…and is not italicised"            '[]'                                          "$EM"   'log: agent_logs/executed_verbose/test.log'
t "a lone snake_case word survives"   '"see bet_payout_stream now"'                 "$TXTS" 'see bet_payout_stream now'
t "snake_case survives inside a table" '["a","b","cell","agent_logs/x.log"]' '[.. | objects | select(.type=="text") | .text]' '| a | b |
| --- | --- |
| cell | agent_logs/x.log |'
# RESIDUAL, deliberately pinned: a SPACE-DELIMITED __dunder__ is still read as strong —
# CommonMark says the same, so `__init__` in prose renders bold and loses its
# underscores. The fix for that one is backticks, not a looser emphasis rule; pinning it
# here so the behaviour is a known contract rather than a surprise found on a ticket.
t "space-delimited __dunder__ is still strong (backtick it)" '"call init first"' "$TXTS" 'call __init__ first'
t "real emphasis still works"         '["emphasised"]'                              "$EM"   'this is _emphasised_ text'
t "emphasis at line start works"      '["start"]'                                   "$EM"   '_start_ of the line'
t "asterisk emphasis unaffected"      '["still"]'                                   "$EM"   'this is *still* italic'

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
echo "--- read-back: an embedded image must survive a read-then-rewrite, in place ---"
# A diagram or screenshot embedded in the description is lost from its position if the
# read hands back an opaque marker: the next upsert rewrites the whole field, so the
# image only survives via adf_append_media's carried-over section at the bottom.
rb "image round-trips in place" '[{"i":0,"n":"heading"},{"i":1,"n":"mediaSingle","ids":["7"]},{"i":2,"n":"paragraph"}]' \
   'md_to_adf | adf_to_text | md_to_adf
    | [.content | to_entries[] | {i:.key, n:.value.type} + (if .value.type=="mediaSingle" then {ids:[.value.content[].attrs.id]} else {} end)]
    | tojson' \
   '## Deposit Flow Diagram
![p2p_deposit.png](attachment:7)
[View / edit this diagram](https://mermaid.live/edit#pako:abc)'
# ...and must not then be appended a SECOND time by the carry-over safety net.
rb "carry-over skips media already in body" '[{"n":"mediaSingle","ids":["7"]}]' \
   'md_to_adf as $doc
    | ($doc | adf_append_media([{type:"mediaSingle", attrs:{layout:"center"}, content:[{type:"media", attrs:{type:"file", id:"7", collection:""}}]}]))
    | [.. | objects | select(.type=="mediaSingle") | {n:.type, ids:[.content[].attrs.id]}] | tojson' \
   '![shot](attachment:7)'
# The SIZE has to survive that round-trip too, or a description read out and written back
# loses the exact fit and re-renders letterboxed inside the fallback ratio.
rb "size round-trips with the image" '[{"id":"7","width":1859,"height":1053}]' \
   'md_to_adf | adf_to_text | md_to_adf
    | [.. | objects | select(.type=="media") | .attrs | {id, width, height}] | tojson' \
   '![flow.png](attachment:7@1859x1053)'
rb "carry-over still rescues absent media" '[{"n":"mediaSingle","ids":["9"]}]' \
   'md_to_adf | adf_append_media([{type:"mediaSingle", attrs:{layout:"center"}, content:[{type:"media", attrs:{type:"file", id:"9", collection:""}}]}])
    | [.. | objects | select(.type=="mediaSingle") | {n:.type, ids:[.content[].attrs.id]}] | tojson' \
   'Body with no image at all.'

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
