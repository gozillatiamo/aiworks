# Jira ADF ⇄ plain-text + issue/comment rendering (jq module).
# Included by the Jira impl:  jq -L <dir> 'include "jira"; ...'

# Render an Atlassian Document Format (ADF) node/doc to plain text.
# Covers the common node types; unknown nodes fall through to their content.
def adf_to_text:
  def node:
    . as $n
    | ($n.type // "") as $t
    | if   $t == "text"        then ($n.text // "")
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
      elif $t == "mediaSingle" or $t == "media" then "[media]"
      else ( ($n.content // []) | map(node) | join("") )
      end;
  if . == null then "" elif (type == "string") then . else node end
  # collapse the trailing newline noise a little
  | gsub("\n{3,}"; "\n\n") | gsub("[ \t]+\n"; "\n");

# Build a minimal ADF doc from a plain-text string (for comment writes / one-line
# descriptions). Each non-empty line becomes a paragraph; ADF rejects empty text nodes.
def text_to_adf:
  . as $t
  | ($t | split("\n") | map(select(length > 0))) as $lines
  | { type: "doc", version: 1,
      content: ( (if ($lines | length) == 0 then [$t] else $lines end)
                 | map({ type: "paragraph", content: [{ type: "text", text: . }] }) ) };

# --- Markdown → ADF doc (write side; the Jira analogue of notion.jq md_to_blocks) -
# Turn a Markdown spec into an ADF document so a full ticket spec lands in the issue
# description as rich content (not flat text). Supports the subset the ticket
# templates use: headings, bullet / numbered / to-do lists, quotes, dividers (rule),
# fenced ``` code blocks, paragraphs. Adjacent list items are merged into one list
# node (ADF requires bullet/orderedList wrappers, unlike Notion's flat blocks).

# Leftmost inline-markup match, or null. Capture index identifies the kind:
#   0 `code`  1 [text](url)  2 **bold**  3 __bold__  4 *italic*  5 _italic_
def _md_first($s):
  [ $s | match("(`[^`]+`)|(\\[[^\\]]+\\]\\([^)]+\\))|(\\*\\*[^*]+\\*\\*)|(__[^_]+__)|(\\*[^*]+\\*)|(_[^_]+_)") ] | .[0];
def _adf_plain($s): if (($s // "") | length) == 0 then [] else [{ type: "text", text: $s }] end;

# Parse inline Markdown into ADF text nodes with marks (strong/em/code/link).
# Recurses on the tail; ADF forbids empty text nodes, so empties are dropped.
def _inline_adf:
  . as $s
  | if ($s | length) == 0 then []
    else (_md_first($s)) as $m
    | if $m == null then _adf_plain($s)
      else ($m.offset) as $o | ($m.length) as $n | ($m.string) as $tok
      | ($s[0:$o]) as $pre | ($s[($o + $n):]) as $post
      | ($m.captures | map(.string)) as $g
      | ( if   $g[0] != null then { type:"text", text:($tok[1:-1]), marks:[{type:"code"}] }
          elif $g[1] != null then ($tok | match("\\[([^\\]]+)\\]\\(([^)]+)\\)") | .captures) as $c
                                  | { type:"text", text:($c[0].string), marks:[{type:"link", attrs:{href:($c[1].string)}}] }
          elif ($g[2] != null or $g[3] != null) then { type:"text", text:($tok[2:-2]), marks:[{type:"strong"}] }
          else { type:"text", text:($tok[1:-1]), marks:[{type:"em"}] }
          end ) as $styled
      | _adf_plain($pre) + [$styled] + ($post | _inline_adf)
      end
    end;

def _adf_text($s):       ($s // "") | _inline_adf;                   # inline marks honoured
def _adf_text_plain($s): if (($s // "") | length) == 0 then [] else [{ type:"text", text:$s }] end;  # literal (code)
def _adf_para($s):
  (($s // "") | _inline_adf) as $c
  | if ($c | length) == 0 then { type:"paragraph" } else { type:"paragraph", content:$c } end;
def _adf_li($s):   { type: "listItem",  content: [_adf_para($s)] };
def _adf_list($kind; $items):
  { type: (if $kind == "ordered" then "orderedList" else "bulletList" end), content: $items };

# Pipe-table helpers (GitHub-flavoured Markdown) → an ADF table node. A 2nd
# separator row marks the first row as the column header (tableHeader cells).
def _split_cells($row):
  ($row | sub("^\\s*\\|"; "") | sub("\\|\\s*$"; "") | split("|") | map(gsub("(^\\s+)|(\\s+$)"; "")));
def _is_sep_row($row):
  ($row | test("-")) and ($row | test("^\\s*\\|?[\\s:|\\-]+\\|?\\s*$"));
def _adf_table($rows):
  ($rows | map(_split_cells(.))) as $all
  | (if (($rows | length) >= 2 and (_is_sep_row($rows[1])))
     then {hdr: true, head: $all[0], body: $all[2:]}
     else {hdr: false, head: null, body: $all} end) as $t
  | { type: "table", attrs: {isNumberColumnEnabled: false, layout: "default"},
      content: (
        ( if $t.hdr
          then [ {type:"tableRow", content: ($t.head | map({type:"tableHeader", attrs:{}, content:[_adf_para(.)]}))} ]
          else [] end )
        + ( $t.body | map({type:"tableRow", content: (map({type:"tableCell", attrs:{}, content:[_adf_para(.)]}))}) )
      ) };

# Classify one (non-fence, non-blank, non-table) line into a token {kind, level?, text?}.
def _md_classify:
  . as $l
  | if   ($l|test("^### "))             then {kind:"h",      level:3, text:($l|sub("^### ";""))}
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
def _md_tok_to_node:
  . as $t
  | if   $t.kind == "h"     then { type:"heading", attrs:{level:$t.level}, content:_adf_text($t.text) }
    elif $t.kind == "rule"  then { type:"rule" }
    elif $t.kind == "quote" then { type:"blockquote", content:[_adf_para($t.text)] }
    elif $t.kind == "code"  then ((_adf_text_plain($t.text)) as $c
                                  | if ($c|length) == 0 then { type:"codeBlock" } else { type:"codeBlock", content:$c } end)
    else                         { type:"paragraph",  content:_adf_text($t.text) }
    end;

def md_to_adf:
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
          (if $s.lk == $k then ($s | .items += [_adf_li($t.text)])
           else
             (if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)]) else $s end)
             | .lk = $k | .items = [_adf_li($t.text)]
           end)
        elif ($k == "table") then
          ((if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)] | .lk=null | .items=[]) else $s end)
           | .content += [ _adf_table($t.rows) ])
        else
          (if $s.lk != null then ($s | .content += [_adf_list($s.lk; $s.items)] | .lk=null | .items=[]) else $s end)
          | .content += [ ($t | _md_tok_to_node) ]
        end )
  | (if .lk != null then (.content += [_adf_list(.lk; .items)]) else . end)
  | { type:"doc", version:1, content: (if (.content|length) == 0 then [_adf_para("")] else .content end) };

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
  | "\($k) — \($summary)\n"
    + (if ($base | length) > 0 then "\($base)/browse/\($k)\n" else "" end)
    + (if ($rows | length) > 0
        then "\n" + ( $rows | map( .k + ":" + (" " * ($w - (.k | length) + 1)) + .v ) | join("\n") ) + "\n"
        else "" end)
    + (if (($desc | gsub("\\s"; "")) | length) > 0
        then "\n------------------------------------------------------------\n" + ($desc | sub("\n+$"; "")) + "\n"
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
