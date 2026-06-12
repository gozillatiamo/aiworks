# Notion → plain-text rendering helpers (jq module).
# Included by the ticket scripts:  jq -L <dir> 'include "notion"; ...'

# Render a Notion rich_text array to plain text. Annotations are dropped;
# links are kept as "text (url)" so PR/Figma URLs aren't lost.
def rich_to_text:
  ( . // [] )
  | map(
      (.plain_text // .text.content // "") as $t
      | (.href // null) as $h
      | (if ($h != null and $h != "" and $h != $t) then "\($t) (\($h))" else $t end)
    )
  | join("");

# Render a single block to {list, text}: `list` marks tight list items so the
# assembler can keep them on adjacent lines.
def block_text:
  . as $b
  | $b.type as $t
  | (($b[$t].rich_text // []) | rich_to_text) as $x
  | if   $t == "paragraph"          then {list:false, text:$x}
    elif $t == "heading_1"          then {list:false, text:("# "   + $x)}
    elif $t == "heading_2"          then {list:false, text:("## "  + $x)}
    elif $t == "heading_3"          then {list:false, text:("### " + $x)}
    elif $t == "bulleted_list_item" then {list:true,  text:("- "   + $x)}
    elif $t == "numbered_list_item" then {list:true,  text:("- "   + $x)}
    elif $t == "to_do"              then {list:true,  text:((if $b.to_do.checked then "[x] " else "[ ] " end) + $x)}
    elif $t == "quote"              then {list:false, text:("> " + $x)}
    elif $t == "callout"            then {list:false, text:$x}
    elif $t == "toggle"             then {list:false, text:("▸ " + $x)}
    elif $t == "code"               then {list:false, text:(($b.code.rich_text // []) | map(.plain_text) | join(""))}
    elif $t == "divider"            then {list:false, text:"----------"}
    elif $t == "image"              then (($b.image.external.url // $b.image.file.url // "") as $u | {list:false, text:(if $u == "" then "" else "[image: \($u)]" end)})
    elif $t == "bookmark"           then {list:false, text:($b.bookmark.url // "")}
    elif $t == "child_page"         then {list:false, text:("📄 " + ($b.child_page.title // ""))}
    else {list:false, text:$x}
    end;

# Render an array of blocks to plain text: list items stay tight (single
# newline), other blocks are separated by a blank line.
def render_blocks_text:
  [ .[] | block_text | select(.text != "") ]
  | reduce .[] as $b ( {out:"", started:false, prevList:false};
      (if (.started | not) then ""
       elif ($b.list and .prevList) then "\n"
       else "\n\n" end) as $sep
      | {out: (.out + $sep + $b.text), started:true, prevList:$b.list}
    )
  | .out;

# The page's title property value as plain text.
def page_title_text:
  ( [ .properties[] | select(.type == "title") ][0].title // [] )
  | map(.plain_text // "") | join("");

# Render a single page-property value to plain text.
def prop_to_text:
  . as $p
  | $p.type as $t
  | if   $t == "title"            then ($p.title     | rich_to_text)
    elif $t == "rich_text"        then ($p.rich_text | rich_to_text)
    elif $t == "select"           then ($p.select.name // "")
    elif $t == "status"           then ($p.status.name // "")
    elif $t == "multi_select"     then ($p.multi_select | map(.name) | join(", "))
    elif $t == "people"           then ($p.people | map(.name // .id) | join(", "))
    elif $t == "date"             then (($p.date.start // "") + (if ($p.date.end // null) then " → \($p.date.end)" else "" end))
    elif $t == "unique_id"        then ((if ($p.unique_id.prefix // null) then "\($p.unique_id.prefix)-" else "" end) + ($p.unique_id.number | tostring))
    elif $t == "last_edited_time" then $p.last_edited_time
    elif $t == "created_time"     then $p.created_time
    elif $t == "url"              then ($p.url // "")
    elif $t == "number"           then (if ($p.number // null) == null then "" else ($p.number | tostring) end)
    elif $t == "checkbox"         then (if $p.checkbox then "yes" else "no" end)
    elif $t == "files"            then ($p.files | map(.name // "file") | join(", "))
    else ""
    end;

# Render all non-title, non-empty properties as aligned "Key: value" lines.
def props_text:
  [ .properties | to_entries[]
    | select(.value.type != "title")
    | {k: .key, v: (.value | prop_to_text)}
    | select(.v != null and .v != "") ]
  | (map(.k | length) | max // 0) as $w
  | map( .k + ":" + (" " * ($w - (.k | length) + 1)) + .v )
  | join("\n");

# --- Markdown → Notion blocks (write side) ----------------------------------
# The inverse of render_blocks_text: turn a Markdown spec into page-body block
# objects so the full ticket spec lands in the page BODY (like a feature ticket),
# not a comment. Supports the subset the ticket templates use: headings, bullet /
# numbered / to-do lists, quotes, dividers, pipe tables, fenced ``` code blocks,
# paragraphs — and inline **bold** / *italic* / `code` / [text](url) within them.

# Split a long string into <=2000-char rich_text objects (Notion's per-object cap).
def _rt_chunks($n):
  if (length <= $n) then [.] else [.[0:$n]] + (.[$n:] | _rt_chunks($n)) end;

# Leftmost inline-markup match in $s, or null. One alternation so the *first*
# token wins regardless of kind; capture index identifies which kind matched:
#   0 `code`  1 [text](url)  2 **bold**  3 __bold__  4 *italic*  5 _italic_
def _md_first($s):
  [ $s | match("(`[^`]+`)|(\\[[^\\]]+\\]\\([^)]+\\))|(\\*\\*[^*]+\\*\\*)|(__[^_]+__)|(\\*[^*]+\\*)|(_[^_]+_)") ] | .[0];

# Plain (un-annotated) text → rich_text objects, chunked to Notion's 2000 cap.
def _plain_rt($s):
  ($s // "") | if length == 0 then [] else (_rt_chunks(2000) | map({type: "text", text: {content: .}})) end;

# Parse inline Markdown in a string into rich_text objects with annotations.
# Recurses on the tail; a single annotation per object (no nesting — rare in tickets).
def _inline_rt:
  . as $s
  | if ($s | length) == 0 then []
    else (_md_first($s)) as $m
    | if $m == null then _plain_rt($s)
      else ($m.offset) as $o | ($m.length) as $n | ($m.string) as $tok
      | ($s[0:$o]) as $pre | ($s[($o + $n):]) as $post
      | ($m.captures | map(.string)) as $g
      | ( if   $g[0] != null then {type: "text", text: {content: ($tok[1:-1])}, annotations: {code: true}}
          elif $g[1] != null then ($tok | match("\\[([^\\]]+)\\]\\(([^)]+)\\)") | .captures) as $c
                                  | {type: "text", text: {content: ($c[0].string), link: {url: ($c[1].string)}}}
          elif ($g[2] != null or $g[3] != null) then {type: "text", text: {content: ($tok[2:-2])}, annotations: {bold: true}}
          else {type: "text", text: {content: ($tok[1:-1])}, annotations: {italic: true}}
          end ) as $styled
      | _plain_rt($pre) + [$styled] + ($post | _inline_rt)
      end
    end;

def _rich($s):       ($s // "") | _inline_rt;   # block text: inline marks honoured
def _rich_plain($s): _plain_rt($s);             # code blocks: content is literal
# {object:"block", type:$type, ($type): $payload}
def _blk($type; $payload): {object: "block", type: $type} + {($type): $payload};

# Pipe-table helpers (GitHub-flavoured Markdown).
def _split_cells($row):
  ($row | sub("^\\s*\\|"; "") | sub("\\|\\s*$"; "") | split("|") | map(gsub("(^\\s+)|(\\s+$)"; "")));
def _is_sep_row($row):
  ($row | test("-")) and ($row | test("^\\s*\\|?[\\s:|\\-]+\\|?\\s*$"));
# Rows (raw "| a | b |" lines) → a Notion table block. A 2nd separator row marks
# the first row as the column header.
def _table_block($rows):
  ($rows | map(_split_cells(.))) as $all
  | (if (($rows | length) >= 2 and (_is_sep_row($rows[1])))
     then {hdr: true, head: $all[0], body: $all[2:]}
     else {hdr: false, head: null, body: $all} end) as $t
  | ((([$t.head] + $t.body) | map(length) | max) // 1) as $w
  | _blk("table"; {
      table_width: $w,
      has_column_header: $t.hdr,
      has_row_header: false,
      children: (
        ( if $t.hdr then [$t.head] else [] end ) + $t.body
        | map( . as $r | {object: "block", type: "table_row",
                          table_row: {cells: ([range(0; $w)] | map(_rich(($r[.] // ""))))}} )
      )
    });

# Map one (non-fence, non-blank, non-table) line to a block. Order matters:
# dividers and checkboxes are matched before the plain "- " bullet they resemble.
def _line_to_block:
  . as $l
  | if   ($l|test("^### "))            then _blk("heading_3";          {rich_text: _rich($l|sub("^### ";""))})
    elif ($l|test("^## "))             then _blk("heading_2";          {rich_text: _rich($l|sub("^## ";""))})
    elif ($l|test("^# "))              then _blk("heading_1";          {rich_text: _rich($l|sub("^# ";""))})
    elif ($l|test("^[-*] \\[ \\] "))   then _blk("to_do";              {rich_text: _rich($l|sub("^[-*] \\[ \\] ";"")),  checked: false})
    elif ($l|test("^[-*] \\[[xX]\\] "))then _blk("to_do";              {rich_text: _rich($l|sub("^[-*] \\[[xX]\\] ";"")), checked: true})
    elif ($l|test("^-{3,}$"))          then _blk("divider";            {})
    elif ($l|test("^[-*] "))           then _blk("bulleted_list_item"; {rich_text: _rich($l|sub("^[-*] ";""))})
    elif ($l|test("^[0-9]+\\. "))      then _blk("numbered_list_item"; {rich_text: _rich($l|sub("^[0-9]+\\. ";""))})
    elif ($l|test("^> "))              then _blk("quote";              {rich_text: _rich($l|sub("^> ";""))})
    else                                    _blk("paragraph";          {rich_text: _rich($l)})
    end;

# Tokenise a Markdown string into {kind} tokens, folding fenced code blocks and
# consecutive pipe-table rows into single tokens (the rest stay per-line).
def _md_tokens:
  ( . // "" ) | gsub("\r"; "") | split("\n")
  | reduce .[] as $l ( {toks: [], incode: false, buf: [], trows: []};
      if .incode then
        ( if ($l|test("^```")) then (.toks += [{kind: "code", text: (.buf|join("\n"))}] | .incode = false | .buf = [])
          else (.buf += [$l]) end )
      elif ((.trows|length) > 0) then
        ( if ($l|test("^\\s*\\|.*\\|\\s*$")) then (.trows += [$l])
          else (.toks += [{kind: "table", rows: .trows}] | .trows = [])
            | ( if ($l|test("^```"))        then (.incode = true | .buf = [])
                elif ($l|test("^\\s*$"))    then .
                else (.toks += [{kind: "line", line: $l}]) end )
          end )
      elif ($l|test("^```"))                then (.incode = true | .buf = [])
      elif ($l|test("^\\s*\\|.*\\|\\s*$"))  then (.trows = [$l])
      elif ($l|test("^\\s*$"))              then .
      else (.toks += [{kind: "line", line: $l}]) end )
  | ( if .incode and ((.buf|length) > 0)   then (.toks += [{kind: "code", text: (.buf|join("\n"))}])
      elif ((.trows|length) > 0)           then (.toks += [{kind: "table", rows: .trows}])
      else . end )
  | .toks;

# Convert a Markdown string to an array of Notion block objects.
def md_to_blocks:
  _md_tokens
  | map(
      if   .kind == "code"  then _blk("code"; {rich_text: _rich_plain(.text), language: "plain text"})
      elif .kind == "table" then _table_block(.rows)
      else (.line | _line_to_block) end );

# --- Markdown → a single Notion *comment* rich_text run ----------------------
# The Notion /comments endpoint takes ONLY a rich_text array — no block children —
# so a comment can't hold heading/list/table *blocks*. We therefore render the
# Markdown into one prettified rich_text run: bold headings, • bullets, indented
# numbering, inline marks/links kept as real annotations, and tables laid out as
# aligned monospace (`code`) text. Coalesced and capped to stay within API limits.

# One line → its rich_text fragment (ending in a newline).
def _cmt_line_rt($l):
  ( [{type: "text", text: {content: "\n"}}] ) as $nl
  | if   ($l|test("^### "))             then ([{type: "text", text: {content: ($l|sub("^### ";""))}, annotations: {bold: true}}] + $nl)
    elif ($l|test("^## "))              then ([{type: "text", text: {content: ($l|sub("^## ";""))},  annotations: {bold: true}}] + $nl)
    elif ($l|test("^# "))               then ([{type: "text", text: {content: ($l|sub("^# ";""))},   annotations: {bold: true}}] + $nl)
    elif ($l|test("^[-*] \\[ \\] "))    then ([{type: "text", text: {content: "☐  "}}] + (($l|sub("^[-*] \\[ \\] ";"")) | _inline_rt) + $nl)
    elif ($l|test("^[-*] \\[[xX]\\] ")) then ([{type: "text", text: {content: "☑  "}}] + (($l|sub("^[-*] \\[[xX]\\] ";"")) | _inline_rt) + $nl)
    elif ($l|test("^-{3,}$"))           then ([{type: "text", text: {content: "────────────"}}] + $nl)
    elif ($l|test("^[-*] "))            then ([{type: "text", text: {content: "•  "}}] + (($l|sub("^[-*] ";"")) | _inline_rt) + $nl)
    elif ($l|test("^[0-9]+\\. "))       then ([{type: "text", text: {content: (($l|capture("^(?<n>[0-9]+)\\. ").n) + ".  ")}}] + (($l|sub("^[0-9]+\\. ";"")) | _inline_rt) + $nl)
    elif ($l|test("^> "))               then ([{type: "text", text: {content: "│ "}}] + (($l|sub("^> ";"")) | _inline_rt) + $nl)
    else (($l | _inline_rt) + $nl)
    end;

# Inline markup stripped to its plain text (for the monospace table fallback, where
# a single `code` object can't carry per-cell bold/links anyway).
def _strip_inline($s): ($s | _inline_rt | map(.text.content) | join(""));
# Table rows → aligned monospace text fragment (one `code`-annotated object).
def _cmt_table_rt($rows):
  ($rows | map(_split_cells(.) | map(_strip_inline(.)))) as $all
  | (if (($rows | length) >= 2 and (_is_sep_row($rows[1]))) then ([$all[0]] + $all[2:]) else $all end) as $data
  | (reduce $data[] as $r ({};
        reduce range(0; ($r|length)) as $i (.; .[($i|tostring)] = ([(.[($i|tostring)] // 0), ($r[$i]|length)] | max)))) as $w
  | ($data
      | map( . as $r | [range(0; ($r|length))]
             | map( ($r[.]) + (" " * (($w[(.|tostring)] // 0) - ($r[.]|length))) )
             | join("  │  ") )
      | join("\n")) as $txt
  | [{type: "text", text: {content: ($txt + "\n")}, annotations: {code: true}}];

# Merge adjacent plain (un-annotated, link-free) text objects, then re-split any
# merged run that exceeds the 2000-char per-object cap.
def _rt_coalesce:
  reduce .[] as $o ([];
    if (length > 0) and (.[-1].type == "text") and ($o.type == "text")
       and ((.[-1] | has("annotations")) | not) and (($o | has("annotations")) | not)
       and ((.[-1].text.link // null) == null) and (($o.text.link // null) == null)
    then (.[0:-1] + [(.[-1] | .text.content += $o.text.content)])
    else (. + [$o]) end)
  | ( [ .[] | if (.type == "text") and ((.text.content | length) > 2000) and ((has("annotations")) | not) and ((.text.link // null) == null)
              then (.text.content | _rt_chunks(2000) | map({type: "text", text: {content: .}}))
              else [.] end ] | add // [] );

# Cap the run at $n objects (Notion's per-array limit), flagging any truncation.
def _rt_cap($n):
  if (length > $n)
  then (.[0:($n - 1)] + [{type: "text", text: {content: "\n…(comment truncated — full text is in the ticket body)"}, annotations: {italic: true}}])
  else . end;

def md_to_comment_rt:
  _md_tokens
  | map(
      if   .kind == "code"  then [{type: "text", text: {content: (.text + "\n")}, annotations: {code: true}}]
      elif .kind == "table" then _cmt_table_rt(.rows)
      else _cmt_line_rt(.line) end )
  | (add // [])
  | _rt_coalesce
  | _rt_cap(100);
