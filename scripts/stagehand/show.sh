#!/usr/bin/env bash
#
# stagehand — the router. Reads one PostToolUse payload and puts what the tool just touched
# on screen: an edited file in the editor, a URL in a browser tab. Then places the window in
# whatever screen space is free (see place.js) without taking the keyboard away.
#
# Usage: show.sh --payload <file>   (the hook's form)
#        show.sh --tool Edit --file path/to/x.rs
#        show.sh --tool WebFetch --url https://…
#
# Always exits 0. Never prints to stdout unless -v. Runs detached from the hook, so a slow
# AppleScript round-trip is never felt in the turn.
#
# WHAT IT ROUTES, AND WHY NOT EVERYTHING:
#   Write / Edit / NotebookEdit  → editor at file:line
#   WebFetch / WebSearch         → browser tab (the URL the model itself asked for)
#   everything else              → a URL sniffed out of the tool RESPONSE, allowlisted host only
#   Read / Grep / Glob           → nothing
# Read is the loud one: a single turn reads dozens of files it merely glances at, and mirroring
# those would flip windows faster than anyone can follow, burying the edit that mattered. Show
# what the assistant CHANGED or FETCHED, not what it skimmed.
#
# THE ALLOWLIST IS A SECURITY BOUNDARY, not tidiness. A URL found in a tool response is a string
# from a file, a web page, or a remote API — i.e. attacker-influenceable content. Auto-opening it
# would turn any injected link into a drive-by browser navigation on the user's logged-in profile.
# So response-sniffed URLs must match stagehand.url_hosts; only WebFetch/WebSearch inputs (which
# the model requested explicitly, and which Claude Code already gates) bypass it.

set -uo pipefail

STAGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
[[ -f "$STAGE_LIB" ]] || exit 0
# shellcheck source=./lib.sh
. "$STAGE_LIB" 2>/dev/null || exit 0
set +e

stage_gate_or_exit

payload="" tool="" file="" url="" line="" phrase="" dry=0 ident_probe=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --payload)  payload="${2:-}"; shift 2 ;;
    --tool)     tool="${2:-}"; shift 2 ;;
    --file)     file="${2:-}"; shift 2 ;;
    --url)      url="${2:-}"; shift 2 ;;
    --phrase)   phrase="${2:-}"; shift 2 ;;
    --dry-run)  dry=1; shift ;;
    --ident)    ident_probe="${2:-}"; shift 2 ;;
    -v)         STAGE_VERBOSE=1; shift ;;
    *)          shift ;;
  esac
done

# --dry-run prints the ROUTING DECISION and touches nothing. This is what selftest.sh asserts on:
# every branch below (which tool routes where, which host is allowlisted, which line is landed on)
# is then checkable without a window moving on someone's desk.
decide() {   # decide <kind> <target> [line]
  [[ "$dry" == "1" ]] || return 1
  printf '{"kind":"%s","tool":"%s","target":"%s","line":"%s","placement":"%s"}\n' \
    "$1" "$tool" "$2" "${3:-}" "$(stage_cfg stagehand.placement halves)"
  return 0
}

stage_mkdirs

# PAGE IDENTITY — what counts as "the same page already open in a tab".
# Not the full URL and not just the fragment-stripped URL: a person reading merge request 14 who
# then wants its diff does not open a second tab, they reuse the one they have. So an MR/PR collapses
# to everything up to its number, and a ticket to /browse/<KEY> — sub-paths like /diffs, /pipelines
# and query strings are the same PAGE for this purpose. Anything else falls back to "URL minus #".
page_ident() {
  local u="${1%%#*}"
  case "$u" in
    *"/-/merge_requests/"*) printf '%s' "${u%%/-/merge_requests/*}/-/merge_requests/$(printf '%s' "${u#*/-/merge_requests/}" | grep -oE '^[0-9]+')" ;;
    *"/pull/"*)             printf '%s' "${u%%/pull/*}/pull/$(printf '%s' "${u#*/pull/}" | grep -oE '^[0-9]+')" ;;
    *"/browse/"*)           printf '%s' "${u%%/browse/*}/browse/$(printf '%s' "${u#*/browse/}" | grep -oE '^[A-Z][A-Z0-9]*-[0-9]+')" ;;
    *)                      printf '%s' "$u" ;;
  esac
}
if [[ -n "$ident_probe" ]]; then page_ident "$ident_probe"; printf '\n'; exit 0; fi


# ── parse the hook payload ────────────────────────────────────────────────────────
if [[ -n "$payload" && -f "$payload" ]] && command -v jq >/dev/null 2>&1; then
  tool="$(jq -r '.tool_name // empty' "$payload" 2>/dev/null)"
  case "$tool" in
    Write|Edit|MultiEdit|NotebookEdit)
      file="$(jq -r '.tool_response.filePath // .tool_input.file_path // .tool_input.notebook_path // empty' "$payload" 2>/dev/null)"
      # The line to land on: the first non-empty line of what was just written. Grepping the
      # file for it afterwards is more reliable than arithmetic on hunk offsets, which go wrong
      # the moment an edit changes the line count above it.
      needle="$(jq -r '(.tool_input.new_string // .tool_input.content // .tool_input.new_source // "")
                       | split("\n") | map(select(length > 0)) | .[0] // ""' "$payload" 2>/dev/null)"
      ;;
    WebFetch)  url="$(jq -r '.tool_input.url // empty' "$payload" 2>/dev/null)" ;;
    WebSearch)
      q="$(jq -r '.tool_input.query // empty' "$payload" 2>/dev/null)"
      [[ -n "$q" ]] && url="https://www.google.com/search?q=$(printf '%s' "$q" | jq -sRr @uri)"
      ;;
    Read|Grep|Glob|TodoWrite|Task|Agent) decide none -; exit 0 ;;
    *)
      # Sniff the response for a URL — this is how a Jira ticket, a GitLab MR, a Slack permalink
      # or a SigNoz trace link gets on screen without stagehand knowing anything about those
      # tools or holding any credential of theirs.
      cand="$(jq -r '[.tool_response, .tool_input] | tostring' "$payload" 2>/dev/null \
              | grep -oE 'https?://[A-Za-z0-9._~:/?#@!$&+,;=%-]+' | head -1)"
      if [[ -n "$cand" ]]; then
        host="$(printf '%s' "$cand" | sed -E 's#^https?://([^/:]+).*#\1#')"
        allow="$(stage_cfg stagehand.url_hosts 'atlassian.net gitlab.com github.com slack.com signoz sonar figma.com mermaid.live localhost 127.0.0.1')"
        for h in $allow; do
          case "$host" in *"$h"*) url="$cand"; break ;; esac
        done
        [[ -z "$url" ]] && { slog "host not allowlisted: $host"; decide blocked "$host"; exit 0; }
      fi
      ;;
  esac
fi

[[ -n "$file$url" ]] || { decide none -; exit 0; }

# The app that had the keyboard BEFORE stagehand touched anything. Everything below either
# never takes focus, or takes it and hands it straight back to this.
prev_front=""
[[ "$dry" == "1" ]] || prev_front="$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null)"
restore_focus() {
  [[ -n "$prev_front" ]] || return 0
  osascript -e "tell application \"System Events\" to set frontmost of process \"$prev_front\" to true" >/dev/null 2>&1
}

placement="$(stage_cfg stagehand.placement halves)"
pmode="halves"; [[ "$placement" == "score" ]] && pmode="score"

# Which window must not be covered. Normally that is whatever had the keyboard — your terminal.
# But when the app being placed IS the one that had focus (you were reading a browser tab and the
# next tool call opens another), protecting it would penalise its own display and push the new
# window somewhere worse. Fall back to the configured terminal in that case.
protect="${prev_front:-}"
guard="$(stage_cfg stagehand.protect_process iTerm2)"
[[ -z "$protect" || "$protect" == "$(stage_cfg stagehand.browser_process 'Google Chrome')" \
   || "$protect" == "$(stage_cfg stagehand.editor_process Cursor)" ]] && protect="$guard"

place() {   # place <process-name> <window-title-substring> <role>
  local proc="$1" match="${2:-}" role="${3:-other}" avoid out d tidy mine
  # `auto` is the legacy spelling of the current default; both mean halves. `score` selects the old
  # overlap scorer. A value this case does not know must NOT silently mean "place nothing" — that is
  # exactly what happened when the default was renamed to `halves` while this still matched only `auto`.
  case "$placement" in
    auto|halves|score)
      # --match is mandatory in normal operation: without it place.js would take whichever window
      # is frontmost inside the app, which on a machine with three Chrome windows means resizing
      # one of the user's. See the comment on findWindow() in place.js.
      # --avoid-display is what spreads the roles apart: it names the displays stagehand's OTHER
      # windows are already on, so the editor and the browser stop stacking on the same screen.
      avoid="$(stage_sibling_slots "$role")"
      tidy="$(stage_cfg stagehand.protected_half left)"; [[ "$tidy" == "off" ]] && tidy=""
      local alld=""; [[ "$(stage_cfg stagehand.displays external)" == "all" ]] && alld="--all-displays"
      local mine; mine="$(cat "$STAGE_STATE_DIR/disp-$role" 2>/dev/null || printf '')"
      out="$(osascript -l JavaScript "$STAGE_DIR/place.js" "$proc" \
        ${match:+--match "$match"} ${avoid:+--taken "$avoid"} ${tidy:+--tidy "$tidy"} \
        ${mine:+--prefer "$mine"} $alld \
        --mode "$pmode" --protect "$protect" --gap "$(stage_gap)" 2>/dev/null)"
      [[ "$STAGE_VERBOSE" == "1" ]] && printf '%s\n' "$out" >&2
      d="$(printf '%s' "$out" | sed -nE 's/.*"display":([0-9]+),"name":"([a-z-]+)".*/\1:\2/p')"
      [[ -n "$d" ]] && stage_role_slot_set "$role" "$d"
      ;;
    rectangle)
      # Rectangle's execute-action has no app-bundle-id, so the target must be frontmost first.
      # That is the whole cost of this mode, and why `auto` is the default.
      osascript -e "tell application \"System Events\" to set frontmost of process \"$proc\" to true" >/dev/null 2>&1
      osascript -e 'delay 0.25' >/dev/null 2>&1
      open -g "rectangle://execute-action?name=$(stage_cfg stagehand.rectangle_action right-half)" >/dev/null 2>&1
      osascript -e 'delay 0.35' >/dev/null 2>&1
      restore_focus
      ;;
    *) : ;;
  esac
}

# ── code → editor ─────────────────────────────────────────────────────────────────
if [[ -n "$file" ]]; then
  stage_cfg_bool stagehand.triggers.code true || exit 0
  [[ -f "$file" ]] || exit 0
  # A path outside this checkout is not this session's business to display — it is another
  # worktree's file, or somewhere else on the disk entirely.
  case "$file" in
    "$STAGE_ROOT"/*) ;;
    /*) slog "outside root: $file"; decide none "$file"; exit 0 ;;
    *)  file="$STAGE_ROOT/$file" ;;
  esac
  stage_debounce "editor:$file" || exit 0

  line=""
  # A focus phrase from a SHOW target wins over the edited-line guess: it is the thing being
  # talked about, which is the whole point of landing somewhere specific.
  if [[ -n "$phrase" ]]; then
    line="$(grep -nF -m1 -- "$phrase" "$file" 2>/dev/null | cut -d: -f1)"
    [[ -n "$line" ]] || line="$(grep -nE -m1 -- "$phrase" "$file" 2>/dev/null | cut -d: -f1)"
  fi
  if [[ -z "$line" && -n "${needle:-}" ]]; then
    line="$(grep -nF -m1 -- "$needle" "$file" 2>/dev/null | cut -d: -f1)"
  fi

  decide editor "$file" "$line" && exit 0

  editor="$(stage_cfg stagehand.editor cursor)"
  if command -v "$editor" >/dev/null 2>&1; then
    if [[ -n "$line" ]]; then "$editor" --goto "$file:$line" >/dev/null 2>&1
    else                      "$editor" --goto "$file"       >/dev/null 2>&1
    fi
  else
    open -g -a Cursor "$file" >/dev/null 2>&1
  fi
  # The editor CLI activates its app; hand the keyboard straight back.
  osascript -e 'delay 0.45' >/dev/null 2>&1
  restore_focus
  # An editor window's title carries the file's basename, which is how the right one of several
  # open editor windows is identified.
  place "$(stage_cfg stagehand.editor_process Cursor)" "$(basename "$file")" editor
  exit 0
fi

# ── url → browser ─────────────────────────────────────────────────────────────────
stage_cfg_bool stagehand.triggers.browser true || exit 0
stage_debounce "browser:$url" || exit 0
decide browser "$url" && exit 0

# ── ONE BROWSER WINDOW, always ────────────────────────────────────────────────────
# Everything web goes into a single window that stagehand owns, as a new tab or by switching to the
# tab already showing that page (see page_ident above for what counts as "the same page").
#
# This deliberately reverses an earlier split by KIND — tracker / vcs / web each owning a window — which
# did let three displays be used at once, one window each. It was also three browser windows, and a
# desk full of stagehand windows is worse than an idle display. So the trade is explicit: one window
# means the browser occupies ONE half, so the reachable spread is the editor plus the browser.
role=browser

max_tabs="$(stage_cfg_int stagehand.max_tabs 8 1 40)"

ident="$(page_ident "$url")"
winfile="$STAGE_STATE_DIR/chrome-window"

# ── the right ACCOUNT ─────────────────────────────────────────────────────────────
# The state file records "<window-id>|<profile-directory>", and a remembered window is reusable only
# if the recorded profile still matches the configured one.
#
# The profile is REMEMBERED rather than detected because it cannot be detected reliably. Chrome's
# AppleScript dictionary exposes no profile property, so the only outside signal is the profile's
# display name appended to the window TITLE — and the title is only reachable through the
# Accessibility API, whose window ordering is independent of Chrome's, so there is no sound way to
# ask "which profile is window id N in?". The first attempt here checked whether ANY Chrome window
# carried the wanted profile name, which is true as soon as the user has one such window open — so
# it kept reusing a window in the PERSONAL profile and every Jira/GitLab tab rendered a login wall.
# stagehand creates the window itself, so it already knows the answer: write it down.
#
# A state file from before this existed carries no profile, which reads as "unknown" and is
# discarded — the recovery path is the same as a stale window id.
prof_dir="$(stage_chrome_profile)"
prof_name="$(stage_chrome_profile_name)"
stored="$(cat "$winfile" 2>/dev/null || printf '')"
winid="${stored%%|*}"
stored_prof="${stored#*|}"
[[ "$stored_prof" == "$stored" ]] && stored_prof=""      # no "|" in the file at all
[[ "$winid" =~ ^[0-9]+$ ]] || winid=""
if [[ -n "$winid" && "$stored_prof" != "$prof_dir" ]]; then
  slog "remembered window is profile '${stored_prof:-unknown}', want '$prof_dir' — discarding it"
  winid=""; rm -f "$winfile" 2>/dev/null
fi

# No usable window yet: create one IN THE RIGHT PROFILE. AppleScript cannot do this — `make new
# window` has no profile parameter and silently uses the last-used profile — so the window is born
# via Chrome's own `--profile-directory` flag, and then identified by diffing the window-id set
# before and after. `-g` keeps it in the background, `-n` forces a new window rather than a tab in
# whatever profile happens to be frontmost.
if [[ -z "$winid" && -n "$prof_dir" ]]; then
  # Identify the new window by the URL IT IS SHOWING, not by diffing the window-id set before and
  # after. The set-difference version was racy and provably wrong: `open -n` can bring up more than
  # one window, the loop then took whichever new id it saw first, and two different roles ended up
  # recording the SAME window id (measured: tracker and vcs both stored 1205653844). Matching on the
  # URL is identity rather than timing — each role opens its own URL, so each finds its own window.
  want="${url%%#*}"
  open -g -n -a "Google Chrome" --args --profile-directory="$prof_dir" --new-window "$url" >/dev/null 2>&1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    osascript -e 'delay 0.4' >/dev/null 2>&1
    winid="$(osascript <<APPLESCRIPT 2>/dev/null
on run
  set wantURL to "$want"
  tell application "Google Chrome"
    repeat with w in windows
      try
        set u to URL of active tab of w
        if u is not missing value then
          if u starts with wantURL then return (id of w as text)
        end if
      end try
    end repeat
  end tell
  return ""
end run
APPLESCRIPT
)"
    [[ "$winid" =~ ^[0-9]+$ ]] && break
    winid=""
  done
  if [[ -n "$winid" ]]; then
    printf '%s|%s' "$winid" "$prof_dir" > "$winfile" 2>/dev/null
    slog "role $role: window $winid in profile '$prof_dir' ($prof_name)"
    url=""   # the window was born holding this URL; do not add it a second time below
  fi
fi

# One window that stagehand owns, with a tab ring inside it. Opening into the user's own window
# would bury their tabs; `open location` would both do that AND activate Chrome.
#
# Returns "id<TAB>left top right bottom" so placement can address this exact window by ID rather
# than by title. Chrome's own dictionary can both identify a window (`window id N`) and move it
# (`set bounds`), which is strictly better than the Accessibility path used for the editor — no
# title matching, so no race with a page that has not finished loading its <title> yet.
info="$(osascript <<APPLESCRIPT 2>/dev/null
on run
  set theURL to "$url"
  set wantID to "$winid"
  tell application "Google Chrome"
    set targetWin to missing value
    if wantID is not "" then
      repeat with w in windows
        try
          if (id of w as text) is wantID then set targetWin to w
        end try
      end repeat
    end if
    -- REUSE an existing tab for the same page instead of stacking another copy of it. A person
    -- working does not open a fourth tab of the same MR; they switch back to it and jump to the new
    -- spot. Matching ignores the fragment (everything after "#") so the same page with a different
    -- text-fragment target counts as the same tab, and re-assigning its URL is what makes Chrome
    -- re-run the scroll-and-highlight.
    set wantIdent to "$ident"
    if targetWin is not missing value and theURL is not "" and wantIdent is not "" then
      set idx to 0
      set i to 0
      repeat with tb in tabs of targetWin
        set i to i + 1
        try
          set u to URL of tb
          if u is not missing value then
            if u starts with wantIdent then set idx to i
          end if
        end try
      end repeat
      if idx > 0 then
        set URL of tab idx of targetWin to theURL
        set active tab index of targetWin to idx
        set b to bounds of targetWin
        return (id of targetWin as text) & "|" & (item 1 of b as text) & " " & (item 2 of b as text) & " " & (item 3 of b as text) & " " & (item 4 of b as text)
      end if
    end if
    if targetWin is missing value then
      -- Reached only when no profile could be resolved; otherwise the window was already created
      -- above with --profile-directory. This branch inherits Chrome's LAST-USED profile, which is
      -- why it is the fallback and not the main path.
      -- NEVER put a backtick in this heredoc: it is unquoted (so theURL/wantID/max_tabs expand),
      -- which means the shell also runs anything backquoted. A backticked "make new window" in a
      -- comment here really did execute make, printing "No rule to make target new" mid-run.
      set targetWin to (make new window)
      if theURL is not "" then set URL of active tab of targetWin to theURL
    else if theURL is not "" then
      tell targetWin to make new tab at end of tabs with properties {URL:theURL}
      set active tab index of targetWin to (count of tabs of targetWin)
    end if
    repeat while (count of tabs of targetWin) > $max_tabs
      close tab 1 of targetWin
    end repeat
    set b to bounds of targetWin
    return (id of targetWin as text) & "|" & (item 1 of b as text) & " " & (item 2 of b as text) & " " & (item 3 of b as text) & " " & (item 4 of b as text)
  end tell
end run
APPLESCRIPT
)"

# "|" and not `tab`: inside a `tell application "Google Chrome"` block the identifier `tab` resolves
# to CHROME'S `tab` class, not AppleScript's tab character, so the delimiter came back as the
# literal three letters "tab" and the id never parsed as a number. The whole Chrome-bounds branch
# below then silently fell through to the Accessibility fallback — a bug that looked like nothing
# at all, because the fallback mostly worked.
newid="${info%%|*}"
bounds="${info#*|}"
[[ "$newid" =~ ^[0-9]+$ ]] && printf '%s|%s' "$newid" "$prof_dir" > "$winfile" 2>/dev/null

if [[ "$placement" != "rectangle" && "$placement" != "off" && "$newid" =~ ^[0-9]+$ ]]; then
  ex=""
  if [[ "$bounds" =~ ^(-?[0-9]+)\ (-?[0-9]+)\ (-?[0-9]+)\ (-?[0-9]+)$ ]]; then
    ex="${BASH_REMATCH[1]},${BASH_REMATCH[2]},$(( BASH_REMATCH[3] - BASH_REMATCH[1] )),$(( BASH_REMATCH[4] - BASH_REMATCH[2] ))"
  fi
  avoid="$(stage_sibling_slots "$role")"
  tidy="$(stage_cfg stagehand.protected_half left)"; [[ "$tidy" == "off" ]] && tidy=""
  alld=""; [[ "$(stage_cfg stagehand.displays external)" == "all" ]] && alld="--all-displays"
  mine="$(cat "$STAGE_STATE_DIR/disp-$role" 2>/dev/null || printf '')"
  slot="$(osascript -l JavaScript "$STAGE_DIR/place.js" --plan \
            ${ex:+--exclude-rect "$ex"} ${avoid:+--taken "$avoid"} ${tidy:+--tidy "$tidy"} \
            ${mine:+--prefer "$mine"} $alld \
            --mode "$pmode" --protect "$protect" --gap "$(stage_gap)" 2>/dev/null)"
  bd="$(printf '%s' "$slot" | sed -nE 's/.*"display":([0-9]+),"name":"([a-z-]+)".*/\1:\2/p')"
  [[ -n "$bd" ]] && stage_role_slot_set "$role" "$bd"
  [[ "$STAGE_VERBOSE" == "1" ]] && printf '%s\n' "$slot" >&2
  read -r sx sy sw sh <<<"$(printf '%s' "$slot" | sed -nE 's/.*"x":(-?[0-9]+),"y":(-?[0-9]+),"w":([0-9]+),"h":([0-9]+).*/\1 \2 \3 \4/p')"
  if [[ -n "${sx:-}" ]]; then
    osascript -e "tell application \"Google Chrome\" to set bounds of window id $newid to {$sx, $sy, $((sx+sw)), $((sy+sh))}" >/dev/null 2>&1
  fi
else
  place "$(stage_cfg stagehand.browser_process 'Google Chrome')" "" "$role"
fi

# ── in-page follow-through (OPTIONAL, and off in Chrome by default) ────────────────
# A URL text fragment already makes Chrome scroll to the phrase and highlight it, with no
# permission at all — that is the default path and why this block is an enhancement, not a
# requirement. Where it falls down is single-page apps: Jira and GitLab render their content after
# navigation, and a text fragment is resolved against the FIRST paint, so on those the phrase is
# often not in the DOM yet and nothing scrolls.
#
# This closes that gap by asking the page itself, after it has rendered, to scroll to the phrase and
# flash it. It needs Chrome's "Allow JavaScript from Apple Events" (View > Developer), which is OFF
# by default and is a REAL security boundary: with it on, ANY AppleScript on the machine can run
# JavaScript in any of your logged-in tabs. That is the user's decision to make, not this script's —
# so nothing here turns it on. The capability is probed, cached, and simply skipped when absent.
if [[ -n "$phrase" && "$(stage_cfg stagehand.interact true)" != "false" && "$newid" =~ ^[0-9]+$ ]]; then
  if stage_chrome_js_ok "$newid"; then
    # The phrase is substituted into a PLACEHOLDER rather than concatenated into the source, and the
    # whole thing is escaped exactly once on its way into AppleScript. Hand-nesting the quotes is how
    # the first version shipped `go(6)})('TrueMoney");` — opened with ' and closed with " — a JavaScript
    # syntax error, so nothing ran at all while the log cheerfully said the highlight was requested.
    # A page with three matching text nodes highlighted none of them, and `2>/dev/null` hid the reason.
    js_phrase="$(printf '%s' "$phrase" | sed 's/\\/\\\\/g; s/"/\\\\"/g')"
    # TWO PHASES, and this is not a style choice — it is the difference between working and hanging
    # the user's tab. The first version wrapped each match DURING the TreeWalker walk; inserting the
    # <mark> put a fresh text node still containing the phrase into the live tree, the walker stepped
    # into it, matched again, wrapped again — an infinite loop that pinned the page's main thread, so
    # `execute javascript` never returned (rc=124) and the tab had to be reloaded. Collect every text
    # node first, finish the walk, and only then mutate. The cap is a second belt: a phrase like "the"
    # on a long page is not a highlight, it is a mess.
    js='(function(p){function go(n){var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT),e,todo=[];while(e=w.nextNode()){if(e.nodeValue.indexOf(p)>=0){todo.push(e);if(todo.length>=20)break}}var hit=0,first=null;for(var k=0;k<todo.length;k++){var t=todo[k],i=t.nodeValue.indexOf(p);if(i<0)continue;var r=document.createRange();r.setStart(t,i);r.setEnd(t,i+p.length);var m=document.createElement("mark");m.setAttribute("data-stagehand","1");m.style.cssText="background:#ffe066;outline:3px solid #f59f00;border-radius:3px";try{r.surroundContents(m)}catch(x){continue}if(!first)first=m;hit++}if(first){first.scrollIntoView({behavior:"smooth",block:"center"});return "hit:"+hit}if(n>0){setTimeout(function(){go(n-1)},1000);return "retry"}return "miss"}return go(20)})("__PHRASE__")'
    js="${js/__PHRASE__/$js_phrase}"
    # Retries live inside the JS, not the shell: an SPA can take seconds to paint a diff, and one
    # AppleScript round trip that polls the page beats six round trips from out here.
    # A catch on surroundContents CONTINUES to the next match instead of giving up — a range that
    # straddles element boundaries is normal in rendered markup and must not end the scan.
    # Bounded, always. `execute javascript` blocks on the page's main thread, so a page that is busy
    # for any reason — a heavy SPA, an extension, or a bug in the snippet above — would otherwise hold
    # this process open indefinitely. Measured: the mutation-during-walk loop hung for the full run.
    run_js=(osascript -e "tell application \"Google Chrome\" to execute (active tab of window id $newid) javascript \"$(printf '%s' "$js" | sed 's/"/\\"/g')\"")
    command -v timeout >/dev/null 2>&1 && run_js=(timeout 15 "${run_js[@]}")
    out="$("${run_js[@]}" 2>&1)"
    # "retry" is not an outcome — it means the first pass missed and the page is being polled, so the
    # highlight may still land seconds later. Only "hit:N" and "miss" are verdicts.
    # A "turned off" here means the cached capability is stale — drop it so the next run re-probes
    # rather than repeating a call that cannot work.
    case "$out" in *"turned off"*) stage_chrome_js_invalidate; slog "capability went stale — cache dropped" ;; esac
    slog "in-page scroll+highlight for '$phrase' → ${out:-no result}"
  else
    slog "Chrome JS-from-Apple-Events is off — relying on the URL text fragment alone"
  fi
fi

restore_focus
exit 0
