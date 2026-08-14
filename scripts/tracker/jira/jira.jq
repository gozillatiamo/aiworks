# Jira ADF ⇄ plain-text + issue/comment rendering (jq module).
# Included by the Jira impl:  jq -L <dir> 'include "jira"; ...'

# Render an Atlassian Document Format (ADF) node/doc to plain text.
# Covers the common node types; unknown nodes fall through to their content.
def adf_to_text:
  def node:
    . as $n
    | ($n.type // "") as $t
    # A link is rendered in Markdown form `[text](href)` so the URL survives a read AND
    # round-trips: a description read out and written back through md_to_adf rebuilds the
    # same link instead of flattening it to dead text (the read-then-rewrite path is how
    # APP-1952 lost pasted media — same shape of loss). A label that IS its URL renders
    # bare; the autolink in _md_first relinks it on the way back in.
    | if   $t == "text"        then ( ($n.text // "") as $x
                                      | ([ $n.marks[]? | select(.type == "link") | .attrs.href ][0] // "") as $h
                                      | if ($h != "" and $h != $x) then "[\($x)](\($h))" else $x end )
      elif $t == "hardBreak"   then "\n"
      elif $t == "paragraph"   then ( (($n.content // []) | map(node) | join("")) + "\n" )
      elif $t == "heading"     then ( (("#" * (($n.attrs.level // 1))) + " ") + (($n.content // []) | map(node) | join("")) + "\n" )
      elif $t == "bulletList"  then ( ($n.content // []) | map("- " + (node)) | join("") )
      elif $t == "orderedList" then ( ($n.content // []) | map("- " + (node)) | join("") )
      elif $t == "listItem"    then ( (($n.content // []) | map(node) | join("")) )
      elif $t == "codeBlock"   then ( (($n.content // []) | map(node) | join("")) + "\n" )
      elif $t == "blockquote"  then ( "> " + (($n.content // []) | map(node) | join("")) )
      elif $t == "rule"        then "----------\n"
      elif $t == "mention"     then ($n.attrs.text // "@user")
      elif $t == "emoji"       then ($n.attrs.text // $n.attrs.shortName // "")
      elif $t == "inlineCard"  then ($n.attrs.url // "")
      # An embedded image renders as the SAME `![alt](attachment:<id>)` token md_to_adf
      # parses, alone on its line — so a description read out, edited and written back
      # keeps its images exactly where the author put them (the link case above does this
      # for the same reason). A bare `[image/attachment]` marker used to make that
      # round-trip lose the position, leaving adf_append_media to rescue the image into a
      # "carried over" section at the bottom.
      elif $t == "media"       then "![attachment](attachment:\($n.attrs.id // ""))\n"
      elif $t == "mediaSingle" or $t == "mediaGroup"
                               then ( ($n.content // []) | map(node) | join("") )
      else ( ($n.content // []) | map(node) | join("") )
      end;
  if . == null then "" elif (type == "string") then . else node end
  # collapse the trailing newline noise a little
  | gsub("\n{3,}"; "\n\n") | gsub("[ \t]+\n"; "\n");

# Editor-pasted images/attachments live as block-level `mediaSingle` / `mediaGroup`
# nodes (each wrapping `media` children that reference an attachment by id). A
# description write via PUT replaces the whole field, so these must be carried across a
# rewrite or the images are lost for good (APP-1952). Return an ADF doc's media blocks,
# in order, walking into non-media containers but taking each media block whole.
def adf_media_blocks:
  def collect:
    (.type // "") as $t
    | if ($t == "mediaSingle" or $t == "mediaGroup") then [.]
      else ((.content // []) | map(collect) | add // []) end;
  ((.content // []) | map(collect) | add // []);

# Re-append preserved media blocks to a freshly rendered ADF doc, under a divider +
# heading so it reads as carried-over rather than authored anew. No-op when empty.
# Media the new body ALREADY embeds (the author kept the `![](attachment:<id>)` token
# adf_to_text now hands back) is dropped from the carry-over: appending it again would
# show the same image twice, once in place and once under the heading.
def adf_append_media($media):
  ([ .. | objects | select((.type // "") == "media") | .attrs.id // empty ] | map({(.):true}) | add // {}) as $have
  | ( $media | map(select([ .. | objects | select((.type // "") == "media") | .attrs.id // empty ]
                          | any(. as $id | $have[$id] // false) | not)) ) as $fresh
  | if ($fresh | length) == 0 then .
    else .content += ([ {type:"rule"},
                        {type:"heading", attrs:{level:3},
                         content:[{type:"text", text:"Attachments (carried over)"}]} ] + $fresh)
    end;

# `text_to_adf` (a minimal doc from a one-line/plain string) is defined further down,
# after `_adf_para`, because it shares the same inline parser — a URL must come out
# clickable there too, not only in a full Markdown body.

# --- Markdown → ADF doc (write side; the Jira analogue of notion.jq md_to_blocks) -
# Turn a Markdown spec into an ADF document so a full ticket spec lands in the issue
# description as rich content (not flat text). Supports the subset the ticket
# templates use: headings, bullet / numbered / to-do lists, quotes, dividers (rule),
# fenced ``` code blocks, paragraphs. Adjacent list items are merged into one list
# node (ADF requires bullet/orderedList wrappers, unlike Notion's flat blocks).

# Leftmost inline-markup match, or null. Capture index identifies the kind:
#   0 `code`  1 [text](url)  2 **bold**  3 __bold__  4 *italic*  5 _italic_
#   6 bare ticket key (e.g. APP-123)  7 bare url
# The link alternative carries a `(?<!!)` lookbehind so an IMAGE (`![alt](…)`) is not
# claimed as a link with a stray `!` left in front of it. Images are block nodes
# (mediaSingle/mediaGroup, see _md_media_nodes) and are folded out before this runs;
# the lookbehind only guards the case of one appearing mid-prose.
# Index 6/7 (autolinks) are last on purpose: `match` picks the leftmost START position
# and only breaks a tie by alternative order, so a URL/key inside `code` or inside a
# [label](url) is still claimed by the earlier-starting token, not by the autolink —
# same reasoning as the URL fix in [[tracker-urls-autolink-and-roundtrip]], extended to
# a second mention kind (APP-2286: "mentioned another ticket in prose" was dead text).
# The URL body excludes brackets/parens/quotes (so a wrapped "(see https://x)" stops
# at the paren) and may not END on sentence punctuation (so a trailing "." is prose).
# The `_`/`__` alternatives are guarded against INTRAWORD matches, per CommonMark. A
# snake_case identifier written as prose is otherwise read as emphasis and its
# underscores are EATEN: `agent_logs/executed_verbose/x.log` rendered as italic
# "agentlogs/executedverbose/x.log" on a real ticket — a path the reader cannot copy,
# and silently wrong rather than visibly broken. Underscores are far more common in
# our prose (table names, field names, file paths) than intraword emphasis ever is.
# The ticket-key alternative is built from $ctx.prefix (e.g. "APP", the project's own
# key) rather than a generic [A-Z]+-[0-9]+ pattern — a generic pattern false-positives
# on ISO-8601/UTF-8/RFC-2119-shaped prose that is not a ticket reference at all. When
# $ctx.prefix is empty (no project configured for this call), the alternative is built
# from a placeholder that cannot occur in real text, so it structurally never matches —
# this keeps capture-group indices identical whether or not a prefix is known.
def _md_first($s; $ctx):
  ( ($ctx.prefix // "") ) as $p0
  | (if ($p0 | length) > 0 then $p0 else "NOPFX" end) as $p
  | [ $s | match("(`[^`]+`)|((?<!!)\\[[^\\]]+\\]\\([^)]+\\))|(\\*\\*[^*]+\\*\\*)|((?<![A-Za-z0-9])__[^_]+__(?![A-Za-z0-9]))|(\\*[^*]+\\*)|((?<![A-Za-z0-9_])_[^_]+_(?![A-Za-z0-9_]))|(\\b\($p)-[0-9]+\\b)|(https?://[^\\s<>()\\[\\]\"'`]*[^\\s<>()\\[\\]\"'`.,;:!?])") ] | .[0];
def _adf_plain($s): if (($s // "") | length) == 0 then [] else [{ type: "text", text: $s }] end;

# Parse inline Markdown into ADF text nodes with marks (strong/em/code/link).
# Recurses on the tail; ADF forbids empty text nodes, so empties are dropped.
# $ctx = {base: <tracker base url, "" to disable ticket-key linking>, prefix: <project key, "" to disable>}.
def _inline_adf($ctx):
  . as $s
  | if ($s | length) == 0 then []
    else (_md_first($s; $ctx)) as $m
    | if $m == null then _adf_plain($s)
      else ($m.offset) as $o | ($m.length) as $n | ($m.string) as $tok
      | ($s[0:$o]) as $pre | ($s[($o + $n):]) as $post
      | ($m.captures | map(.string)) as $g
      | ( if   $g[0] != null then { type:"text", text:($tok[1:-1]), marks:[{type:"code"}] }
          elif $g[1] != null then ($tok | match("\\[([^\\]]+)\\]\\(([^)]+)\\)") | .captures) as $c
                                  | { type:"text", text:($c[0].string), marks:[{type:"link", attrs:{href:($c[1].string)}}] }
          elif ($g[2] != null or $g[3] != null) then { type:"text", text:($tok[2:-2]), marks:[{type:"strong"}] }
          elif $g[6] != null then
            ( if (($ctx.base // "") | length) > 0
              then { type:"text", text:$tok, marks:[{type:"link", attrs:{href:("\($ctx.base)/browse/\($tok)")}}] }
              else { type:"text", text:$tok } end )
          elif $g[7] != null then { type:"text", text:$tok, marks:[{type:"link", attrs:{href:$tok}}] }
          else { type:"text", text:($tok[1:-1]), marks:[{type:"em"}] }
          end ) as $styled
      | _adf_plain($pre) + [$styled] + ($post | _inline_adf($ctx))
      end
    end;

def _adf_text($s; $ctx):       ($s // "") | _inline_adf($ctx);       # inline marks honoured
def _adf_text_plain($s): if (($s // "") | length) == 0 then [] else [{ type:"text", text:$s }] end;  # literal (code)
def _adf_para($s; $ctx):
  (($s // "") | _inline_adf($ctx)) as $c
  | if ($c | length) == 0 then { type:"paragraph" } else { type:"paragraph", content:$c } end;
# Build a minimal ADF doc from a plain-ish string (for comment writes / one-line
# descriptions). Each non-empty line becomes a paragraph, parsed with the same inline
# rules as a body — so a URL is a real link mark, not dead text a reader must copy.
def text_to_adf($ctx):
  . as $t
  | ($t | split("\n") | map(select(length > 0))) as $lines
  | { type: "doc", version: 1,
      content: ( (if ($lines | length) == 0 then [$t] else $lines end) | map(_adf_para(.; $ctx)) ) };
# 0-arity default: back-compat for existing callers that don't have a base/prefix to
# hand (e.g. the plain regression suite) — behaves exactly as before (no ticket-key link).
def text_to_adf: text_to_adf({base:"", prefix:""});

def _adf_li($s; $ctx):   { type: "listItem",  content: [_adf_para($s; $ctx)] };
def _adf_list($kind; $items):
  { type: (if $kind == "ordered" then "orderedList" else "bulletList" end), content: $items };

# Pipe-table helpers (GitHub-flavoured Markdown) → an ADF table node. A 2nd
# separator row marks the first row as the column header (tableHeader cells).
def _split_cells($row):
  ($row | sub("^\\s*\\|"; "") | sub("\\|\\s*$"; "") | split("|") | map(gsub("(^\\s+)|(\\s+$)"; "")));
def _is_sep_row($row):
  ($row | test("-")) and ($row | test("^\\s*\\|?[\\s:|\\-]+\\|?\\s*$"));
def _adf_table($rows; $ctx):
  ($rows | map(_split_cells(.))) as $all
  | (if (($rows | length) >= 2 and (_is_sep_row($rows[1])))
     then {hdr: true, head: $all[0], body: $all[2:]}
     else {hdr: false, head: null, body: $all} end) as $t
  | { type: "table", attrs: {isNumberColumnEnabled: false, layout: "default"},
      content: (
        ( if $t.hdr
          then [ {type:"tableRow", content: ($t.head | map({type:"tableHeader", attrs:{}, content:[_adf_para(.; $ctx)]}))} ]
          else [] end )
        + ( $t.body | map({type:"tableRow", content: (map({type:"tableCell", attrs:{}, content:[_adf_para(.; $ctx)]}))}) )
      ) };

# --- Images → ADF media (write side) ---------------------------------------------
# `![alt](attachment:<id>)` renders an issue ATTACHMENT inside the body/comment, so
# evidence (a test screenshot, a rendered load-test report) sits in the prose that
# explains it instead of only in the Attachments panel. `<id>` is the numeric id the
# attachments endpoint returns on upload — see tracker_add_attachment, which prints it
# for exactly this purpose. An image token that is NOT alone on its line stays literal
# text: a media node is block-level in ADF, so there is nowhere valid to put it inside a
# paragraph, and a silent drop would lose the evidence without saying so.
#
# Two block shapes, because they read differently:
#   one image on a line  → mediaSingle, full width — for a failure a human must SEE.
#   many images on a line → mediaGroup, a thumbnail strip — for pass evidence that is
#                           proof-of-record, not something anyone reads one by one.
def _md_image_ids($l):
  [ $l | scan("!\\[[^\\]]*\\]\\(attachment:([^)]+)\\)") | .[0] ];
# A line is a media BLOCK only when it holds nothing but image tokens (and whitespace).
def _is_media_line($l):
  (($l | test("!\\[[^\\]]*\\]\\(attachment:[^)]+\\)"))
   and ($l | gsub("!\\[[^\\]]*\\]\\(attachment:[^)]+\\)"; "") | test("^\\s*$")));
def _adf_media($id):
  { type:"media", attrs:{ type:"file", id:$id, collection:"" } };
def _adf_media_node($ids):
  if ($ids | length) == 1
  then { type:"mediaSingle", attrs:{layout:"center", width:100}, content:[ _adf_media($ids[0]) ] }
  else { type:"mediaGroup", content:( $ids | map(_adf_media(.)) ) }
  end;

# Classify one (non-fence, non-blank, non-table) line into a token {kind, level?, text?}.
def _md_classify:
  . as $l
  | if   (_is_media_line($l))           then {kind:"media",  ids:(_md_image_ids($l))}
    elif ($l|test("^### "))             then {kind:"h",      level:3, text:($l|sub("^### ";""))}
    elif ($l|test("^## "))              then {kind:"h",      level:2, text:($l|sub("^## ";""))}
    elif ($l|test("^# "))               then {kind:"h",      level:1, text:($l|sub("^# ";""))}
    elif ($l|test("^[-*] \\[ \\] "))    then {kind:"bullet",  text:("[ ] " + ($l|sub("^[-*] \\[ \\] ";"")))}
    elif ($l|test("^[-*] \\[[xX]\\] ")) then {kind:"bullet",  text:("[x] " + ($l|sub("^[-*] \\[[xX]\\] ";"")))}
    elif ($l|test("^-{3,}$"))           then {kind:"rule"}
    elif ($l|test("^[-*] "))            then {kind:"bullet",  text:($l|sub("^[-*] ";""))}
    elif ($l|test("^[0-9]+\\. "))       then {kind:"ordered", text:($l|sub("^[0-9]+\\. ";""))}
    elif ($l|test("^> "))               then {kind:"quote",   text:($l|sub("^> ";""))}
    else                                     {kind:"para",    text:$l}
    end;

# A non-list, non-table token → its ADF block node.
def _md_tok_to_node($ctx):
  . as $t
  | if   $t.kind == "h"     then { type:"heading", attrs:{level:$t.level}, content:_adf_text($t.text; $ctx) }
    elif $t.kind == "media" then _adf_media_node($t.ids)
    elif $t.kind == "rule"  then { type:"rule" }
    elif $t.kind == "quote" then { type:"blockquote", content:[_adf_para($t.text; $ctx)] }
    elif $t.kind == "code"  then ((_adf_text_plain($t.text)) as $c
                                  | if ($c|length) == 0 then { type:"codeBlock" } else { type:"codeBlock", content:$c } end)
    else                         { type:"paragraph",  content:_adf_text($t.text; $ctx) }
    end;

# $ctx = {base: <tracker base url>, prefix: <project key>} — see _inline_adf. Both empty
# (the 0-arity default below) reproduces the exact prior behaviour: no ticket-key linking.
def md_to_adf($ctx):
  # phase 1 — fold fenced code blocks and pipe-table runs into tokens; classify the rest
  ( ( . // "" ) | gsub("\r"; "") | split("\n")
    | reduce .[] as $l ( {toks:[], incode:false, buf:[], trows:[]};
        if .incode then
          ( if ($l|test("^```")) then (.toks += [{kind:"code", text:(.buf|join("\n"))}] | .incode=false | .buf=[])
            else (.buf += [$l]) end )
        elif ((.trows|length) > 0) then
          ( if ($l|test("^\\s*\\|.*\\|\\s*$")) then (.trows += [$l])
            else (.toks += [{kind:"table", rows:.trows}] | .trows=[])
              | ( if ($l|test("^```"))      then (.incode=true | .buf=[])
                  elif ($l|test("^\\s*$"))  then .
                  else (.toks += [($l | _md_classify)]) end )
            end )
        elif ($l|test("^```"))               then (.incode=true | .buf=[])
        elif ($l|test("^\\s*\\|.*\\|\\s*$")) then (.trows=[$l])
        elif ($l|test("^\\s*$"))             then .
        else (.toks += [($l | _md_classify)]) end )
    | ( if .incode and ((.buf|length) > 0)  then (.toks + [{kind:"code", text:(.buf|join("\n"))}])
        elif ((.trows|length) > 0)          then (.toks + [{kind:"table", rows:.trows}])
        else .toks end )
  )
  # phase 2 — assemble content, merging adjacent bullet/ordered items into one list
  | reduce .[] as $t ( {content:[], lk:null, items:[]};
      . as $s
      | ($t.kind) as $k
      | if ($k == "bullet" or $k == "ordered") then
          (if $s.lk == $k then ($s | .items += [_adf_li($t.text; $ctx)])
           else
             (if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)]) else $s end)
             | .lk = $k | .items = [_adf_li($t.text; $ctx)]
           end)
        elif ($k == "table") then
          ((if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)] | .lk=null | .items=[]) else $s end)
           | .content += [ _adf_table($t.rows; $ctx) ])
        else
          (if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)] | .lk=null | .items=[]) else $s end)
          | .content += [ ($t | _md_tok_to_node($ctx)) ]
        end )
  | (if .lk != null then (.content += [_adf_list(.lk; .items)]) else . end)
  | { type:"doc", version:1, content: (if (.content|length) == 0 then [_adf_para(""; $ctx)] else .content end) };
def md_to_adf: md_to_adf({base:"", prefix:""});

# Render a single issue's fields to aligned "Key: value" plain text.
def issue_details_text($base):
  . as $i
  | ($i.key // "") as $k
  | ($i.fields.summary // "Untitled") as $summary
  | ( [ {k: "Status",   v: ($i.fields.status.name // "")},
        {k: "Type",     v: ($i.fields.issuetype.name // "")},
        {k: "Priority", v: ($i.fields.priority.name // "")},
        {k: "Assignee", v: ($i.fields.assignee.displayName // "")},
        {k: "Parent",   v: ($i.fields.parent.key // "")},
        {k: "Labels",   v: (($i.fields.labels // []) | join(", "))} ]
      | map(select(.v != null and .v != "")) ) as $rows
  | ($rows | map(.k | length) | max // 0) as $w
  | ($i.fields.description | adf_to_text) as $desc
  | ($i.fields.description | adf_media_blocks | length) as $nmedia
  | ($i.fields.attachment // []) as $attach
  # Issue links, grouped by the phrase THIS issue sees. In a GET, Jira names the OTHER end in
  # the field that matches the phrase to show FROM THIS ISSUE: an `outwardIssue` field → show
  # the OUTWARD phrase (e.g. "blocks") toward it; an `inwardIssue` field → show the INWARD
  # phrase (e.g. "is blocked by"). (Verified against the live board — note this GET convention
  # is the OPPOSITE of the POST convention in jira_create_links.) Each target carries the status.
  | ( [ $i.fields.issuelinks[]?
        | if .outwardIssue
          then {phrase: (.type.outward // .type.name), tgt: "\(.outwardIssue.key) [\(.outwardIssue.fields.status.name // "?")]"}
          else {phrase: (.type.inward  // .type.name), tgt: "\(.inwardIssue.key) [\(.inwardIssue.fields.status.name // "?")]"} end ]
      | group_by(.phrase)
      | map("  " + .[0].phrase + ": " + (map(.tgt) | join(", "))) ) as $links
  | "\($k) — \($summary)\n"
    + (if ($base | length) > 0 then "\($base)/browse/\($k)\n" else "" end)
    + (if ($rows | length) > 0
        then "\n" + ( $rows | map( .k + ":" + (" " * ($w - (.k | length) + 1)) + .v ) | join("\n") ) + "\n"
        else "" end)
    + (if ($links | length) > 0
        then "\nLinked issues:\n" + ($links | join("\n")) + "\n"
        else "" end)
    + (if (($desc | gsub("\\s"; "")) | length) > 0
        then "\n------------------------------------------------------------\n" + ($desc | sub("\n+$"; "")) + "\n"
        else "" end)
    + (if $nmedia > 0
        then "\n⚠ \($nmedia) embedded image/attachment(s) in the description — carried over automatically when the body is rewritten via upsert-ticket-details.sh.\n"
        else "" end)
    + (if ($attach | length) > 0
        then "\n📎 \($attach | length) attachment(s) — CORE input, fetch before relying on the description alone: \($attach | map(.filename) | join(", ")). List + download via get-ticket-attachments.sh / download-ticket-attachment.sh.\n"
        else "" end);

# Render the /comment payload to plain text.
def comments_text:
  (.comments // []) as $cs
  | "Comments (\($cs | length))\n"
    + (if ($cs | length) == 0 then "\nNo comments on this issue.\n"
       else "\n" + ( $cs
         | sort_by(.created)
         | map( ((.author.displayName // .author.accountId // "?") + "  " + (.created // ""))
                + "\n"
                + ( ((.body | adf_to_text) | sub("\n+$"; "")) | split("\n") | map("  " + .) | join("\n") ) )
         | join("\n\n") ) + "\n"
       end);
