#!/usr/bin/env bash
#
# stagehand selftest — asserts the behaviour that is easy to get wrong and impossible to eyeball.
#
#   ./scripts/stagehand/selftest.sh
#
# Three groups:
#   GATES   — the root-worktree-only rule, proved against a REAL linked git worktree, not a mock.
#             This is the constraint the feature was asked for; a selftest that only checked an
#             env var would pass while the actual git plumbing was wrong.
#   ROUTER  — every routing branch, via `show.sh --dry-run`, so no window moves during a test run.
#             Includes the allowlist, which is a security boundary and therefore needs a case that
#             proves a hostile host is REFUSED, not just that a friendly one is accepted.
#   GEOMETRY— the NSScreen → Accessibility coordinate flip, checked by requiring every chosen slot
#             to sit inside a real display. Get the flip wrong and windows land off-screen on any
#             display with a negative origin — i.e. exactly the multi-monitor setup this is for.
#
# Read-only apart from a temp worktree it creates and removes, and a temp file under $TMPDIR.

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"
SHOW="$DIR/show.sh"
PASS=0 FAIL=0
tmp="$(mktemp -d "${TMPDIR:-/tmp}/stagehand-selftest.XXXXXX")"
cleanup() {
  [[ -n "${wt:-}" && -d "${wt:-}" ]] && git -C "$ROOT" worktree remove --force "$wt" >/dev/null 2>&1
  rm -rf "$tmp" "$ROOT/.selftest-repo" 2>/dev/null
}
trap cleanup EXIT

ok()   { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL %s\n     %s\n' "$1" "${2:-}"; }
check(){ # check <name> <expected-substring> <actual>
  case "$3" in *"$2"*) ok "$1" ;; *) bad "$1" "expected to contain '$2', got: $3" ;; esac
}

payload() {   # payload <json> → path
  local f; f="$(mktemp "$tmp/p.XXXXXX")"; printf '%s' "$1" > "$f"; printf '%s' "$f"
}

# stagehand ships OFF, so the suite turns it on FOR ITSELF with STAGEHAND=on rather than requiring
# whoever runs it to have opted in first. Exported so every helper below inherits it; the cases that
# specifically test the kill switch set STAGEHAND=off explicitly and still win, since `off` is checked
# first.
export STAGEHAND=on
run_dry() { "$SHOW" --dry-run --payload "$1" 2>/dev/null; }

printf '\nGATES\n'

# EVERY case below uses its own URL. The debounce is keyed by target, so a case that legitimately
# routes leaves a stamp that silences the next case using the same URL — which is exactly how a
# passing suite started reporting "the root worktree does not route".
# The suite must not depend on anyone's personal config, so it asserts the OVERRIDE works instead.
out="$(STAGEHAND=on "$SHOW" --dry-run --payload "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://gitlab.com/gate-on"}}')" 2>&1)"
check "STAGEHAND=on runs even when the config ships the feature off" '"kind":"browser"' "$out"

out="$(STAGEHAND=off "$SHOW" --dry-run --payload "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://gitlab.com/gate-off"}}')" 2>&1)"
[[ -z "$out" ]] && ok "STAGEHAND=off silences everything" || bad "STAGEHAND=off silences everything" "got: $out"

out="$(SUPERSET_ROOT_PATH=/tmp/fake "$SHOW" --dry-run --payload "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://gitlab.com/gate-superset"}}')" 2>&1)"
[[ -z "$out" ]] && ok "SUPERSET_ROOT_PATH set silences everything" || bad "SUPERSET_ROOT_PATH set silences everything" "got: $out"

# The real thing: a linked worktree must be silent even with the feature enabled and no env hints.
wt="$tmp/wt"
if git -C "$ROOT" worktree add --detach "$wt" HEAD >/dev/null 2>&1; then
  mkdir -p "$wt/scripts/stagehand"
  cp "$DIR/lib.sh" "$DIR/show.sh" "$DIR/place.js" "$wt/scripts/stagehand/" 2>/dev/null
  cp "$ROOT/workspace.config.local.yaml" "$wt/" 2>/dev/null
  cp "$ROOT/workspace.config.yaml" "$wt/" 2>/dev/null
  chmod +x "$wt/scripts/stagehand/show.sh" 2>/dev/null
  out="$("$wt/scripts/stagehand/show.sh" --dry-run --payload "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://gitlab.com/gate-worktree"}}')" 2>&1)"
  [[ -z "$out" ]] && ok "a REAL linked git worktree is silent (root-worktree-only rule holds)" \
                  || bad "a REAL linked git worktree is silent" "got: $out"
  out="$(cd "$ROOT" && "$SHOW" --dry-run --payload "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://gitlab.com/gate-root"}}')" 2>&1)"
  check "the root worktree itself still routes" '"kind":"browser"' "$out"
else
  bad "a REAL linked git worktree is silent" "could not create a test worktree"
fi

printf '\nROUTER\n'

check "Read routes nowhere" '"kind":"none"' \
  "$(run_dry "$(payload '{"tool_name":"Read","tool_input":{"file_path":"'"$ROOT"'/CLAUDE.md"}}')")"

check "Grep routes nowhere" '"kind":"none"' \
  "$(run_dry "$(payload '{"tool_name":"Grep","tool_input":{"pattern":"x"}}')")"

check "WebFetch routes to the browser" '"kind":"browser"' \
  "$(run_dry "$(payload '{"tool_name":"WebFetch","tool_input":{"url":"https://code.claude.com/docs/en/computer-use"}}')")"

check "WebSearch routes to a search URL" 'google.com/search' \
  "$(run_dry "$(payload '{"tool_name":"WebSearch","tool_input":{"query":"rectangle url scheme"}}')")"

check "an allowlisted host in a tool RESPONSE is opened" 'atlassian.net' \
  "$(run_dry "$(payload '{"tool_name":"mcp__jira__getIssue","tool_response":{"text":"see https://example.atlassian.net/browse/APP-1234"}}')")"

check "a NON-allowlisted host in a tool response is REFUSED" '"kind":"blocked"' \
  "$(run_dry "$(payload '{"tool_name":"Bash","tool_response":{"stdout":"visit https://evil.example.com/pwn"}}')")"

# The line-landing path, on a real file with known content.
probe="$tmp/probe.txt"; printf 'alpha\nbeta\nGAMMA_MARKER\ndelta\n' > "$probe"
out="$(run_dry "$(payload '{"tool_name":"Edit","tool_input":{"file_path":"'"$probe"'","new_string":"GAMMA_MARKER"}}')")"
check "a file outside the workspace root is refused" '"kind":"none"' "$out"

probe2="$ROOT/scripts/stagehand/.selftest-probe.txt"
printf 'alpha\nbeta\nGAMMA_MARKER\ndelta\n' > "$probe2"
out="$(run_dry "$(payload '{"tool_name":"Edit","tool_input":{"file_path":"'"$probe2"'","new_string":"GAMMA_MARKER\nrest"}}')")"
check "Edit routes to the editor" '"kind":"editor"' "$out"
check "Edit lands on the edited line, not line 1" '"line":"3"' "$out"
rm -f "$probe2" 2>/dev/null

printf '\nGEOMETRY\n'

disp="$(osascript -l JavaScript "$DIR/place.js" --displays 2>/dev/null)"
check "displays enumerate" '"ok":true' "$disp"
ndisp="$(printf '%s' "$disp" | grep -o '"x":' | wc -l | tr -d ' ')"
[[ "${ndisp:-0}" -ge 1 ]] && ok "$ndisp display(s) resolved" || bad "displays resolved" "$disp"

# Dry-place a real running app and require the chosen slot to sit inside a real display. This is
# the assertion that catches a botched coordinate flip.
for app in Cursor "Google Chrome"; do
  pgrep -x "$app" >/dev/null 2>&1 || { printf '  skip %s is not running\n' "$app"; continue; }
  res="$(osascript -l JavaScript "$DIR/place.js" "$app" --dry-run --protect iTerm2 2>/dev/null)"
  check "$app: dry placement succeeds" '"ok":true' "$res"
  inside="$(python3 - "$disp" "$res" <<'PY' 2>/dev/null
import json,sys
d=json.loads(sys.argv[1])["displays"]; c=json.loads(sys.argv[2])["chosen"]
print("yes" if any(c["x"]>=s["x"]-1 and c["y"]>=s["y"]-1 and
                   c["x"]+c["w"]<=s["x"]+s["w"]+1 and c["y"]+c["h"]<=s["y"]+s["h"]+1
                   for s in d) else "no")
PY
)"
  [[ "$inside" == "yes" ]] && ok "$app: chosen slot lies inside a real display" \
                           || bad "$app: chosen slot lies inside a real display" "$res"
done

printf '\nFOLLOW (the screen follows what the reply TALKED ABOUT)\n'

FOLLOW="$DIR/follow.sh"
fdry() { "$FOLLOW" --dry-run --text "$1" 2>/dev/null; }

# `<repo>!<iid>` resolution reads the repo's OWN git remote, so the test brings its own repo rather
# than naming one that happens to exist in somebody's workspace. The remote deliberately has a NESTED
# group: hand-assembling such a URL is how a 404 was produced during development (the project lived
# under a different group than the guess), so the nested path has to survive resolution intact.
PREFIX="$(bash -c ". '$DIR/lib.sh'; stage_cfg tracker.ticket_prefix FM")"
TBASE="$(bash -c ". '$DIR/lib.sh'; stage_cfg tracker.base_url")"
fake="$ROOT/.selftest-repo"
rm -rf "$fake"; mkdir -p "$fake"
git -C "$fake" init -q 2>/dev/null
git -C "$fake" remote add origin git@gitlab.com:outer-group/inner-group/thing.git 2>/dev/null

out="$(fdry '.selftest-repo!14 is the one to look at')"
check "prose: <repo>!<iid> resolves through the repo's own git remote" \
  'https://gitlab.com/outer-group/inner-group/thing/-/merge_requests/14' "$out"
case "$out" in *'/thing/-/merge_requests/14'*) ok "the nested group survives — the remote decides, not a guess" ;;
               *) bad "the nested group survives resolution" "$out" ;; esac

# Regression: ${u/://} rewrote the colon inside "https:" and produced https///host/…
case "$out" in *'https///'*|*'https//'[^/]*) bad "scp-style remote converts to a well-formed https URL" "$out" ;;
               *) ok "scp-style remote converts to a well-formed https URL" ;; esac
rm -rf "$fake"

# A ticket key needs tracker.base_url. Both branches are real behaviour worth asserting: with a base
# it resolves, without one it must be DROPPED rather than turned into a broken URL.
out="$(fdry "look at ${PREFIX}-2179 please")"
if [[ -n "$TBASE" ]]; then
  check "prose: a ticket key resolves against tracker.base_url" "/browse/${PREFIX}-2179" "$out"
else
  [[ -z "$out" ]] && ok "with no tracker.base_url a ticket key is dropped, not half-resolved" \
                  || bad "a ticket key without tracker.base_url is dropped" "$out"
fi

out="$(fdry "noise ${PREFIX}-9999 noise
SHOW: scripts/stagehand/follow.sh")"
check "SHOW resolves a repo-relative path to the editor" $'follow.sh\tfile' "$out"
case "$out" in *"${PREFIX}-9999"*) bad "a SHOW tag SUPPRESSES the prose scan" "${PREFIX}-9999 leaked in" ;;
               *) ok "a SHOW tag SUPPRESSES the prose scan" ;; esac

cap="$(bash -c ". '$DIR/lib.sh'; stage_cfg_int stagehand.follow_max 3 1 10")"
if [[ -n "$TBASE" ]]; then
  n="$(fdry "SHOW: ${PREFIX}-1, ${PREFIX}-2, ${PREFIX}-3, ${PREFIX}-4, ${PREFIX}-5" | wc -l | tr -d ' ')"
  [[ "$n" == "$cap" ]] && ok "the follow_max cap is enforced ($n opened)" \
                       || bad "the follow_max cap is enforced" "opened $n, cap $cap"
else
  # No tracker.base_url means ticket keys cannot resolve, so cap the countable targets with paths.
  n="$(fdry 'SHOW: scripts/stagehand/lib.sh, scripts/stagehand/show.sh, scripts/stagehand/place.js, scripts/stagehand/follow.sh, scripts/stagehand/README.md' | wc -l | tr -d ' ')"
  [[ "$n" == "$cap" ]] && ok "the follow_max cap is enforced ($n opened)" \
                       || bad "the follow_max cap is enforced" "opened $n, cap $cap"
fi

out="$(fdry 'this reply names nothing openable at all')"
[[ -z "$out" ]] && ok "a reply naming nothing opens nothing" || bad "a reply naming nothing opens nothing" "$out"

out="$(fdry 'SHOW: no-such-repo-here!42, does/not/exist.rs')"
[[ -z "$out" ]] && ok "unresolvable targets are dropped, not guessed at" || bad "unresolvable targets are dropped" "$out"

out="$(STAGEHAND=off "$FOLLOW" --dry-run --text 'SHOW: scripts/stagehand/lib.sh' 2>&1)"
[[ -z "$out" ]] && ok "STAGEHAND=off silences the follow path too" || bad "STAGEHAND=off silences the follow path" "$out"

printf '\nINTERACT (open, then work inside the window)\n'

fake2="$ROOT/.selftest-repo"
rm -rf "$fake2"; mkdir -p "$fake2"
git -C "$fake2" init -q 2>/dev/null
git -C "$fake2" remote add origin git@gitlab.com:outer-group/thing.git 2>/dev/null
out="$(fdry 'SHOW: .selftest-repo!555 ~signature_key')"
check "a focus phrase becomes a URL text fragment" '#:~:text=signature_key' "$out"
# A phrase names an identifier, and an identifier lives in the diff. Measured on the real page:
# innerText holds 3 occurrences and the highlighter reports hit:3 there.
check "a focus phrase on an MR targets the diff" '/-/merge_requests/555/diffs' "$out"
# Regression: markdown stripping used to remove "_" too, so signature_key became signaturekey and
# matched nothing on the page it was supposed to scroll to.
case "$out" in *signaturekey*) bad "an underscore survives markdown stripping" "snake_case was mangled" ;;
               *) ok "an underscore survives markdown stripping" ;; esac

out="$(fdry 'SHOW: .selftest-repo!555')"
case "$out" in *'#:~:text='*) bad "no phrase means no text fragment" "$out" ;;
               *) ok "no phrase means no text fragment" ;; esac
rm -rf "$fake2"

# Tab REUSE hinges on page identity: the same MR reached by a different sub-path is the same PAGE,
# which is what stops the window turning into a graveyard of near-duplicate tabs.
i1="$("$SHOW" --ident 'https://gitlab.com/a/b/-/merge_requests/14')"
i2="$("$SHOW" --ident 'https://gitlab.com/a/b/-/merge_requests/14/diffs#:~:text=x')"
[[ -n "$i1" && "$i1" == "$i2" ]] && ok "an MR and its /diffs share one page identity ($i1)" \
                                 || bad "an MR and its /diffs share one page identity" "'$i1' vs '$i2'"
i3="$("$SHOW" --ident 'https://example.atlassian.net/browse/APP-2179?focusedId=9#frag')"
[[ "$i3" == "https://example.atlassian.net/browse/APP-2179" ]] && ok "a ticket identity drops query and fragment" \
                                                         || bad "a ticket identity drops query and fragment" "$i3"
i4="$("$SHOW" --ident 'https://gitlab.com/a/b/-/merge_requests/14')"
i5="$("$SHOW" --ident 'https://gitlab.com/a/b/-/merge_requests/141')"
[[ "$i4" != "$i5" ]] && ok "MR 14 and MR 141 are different pages" || bad "MR 14 and MR 141 are different pages" "$i4"

# The editor lands on the phrase, not on the first line of the file.
probe3="$ROOT/scripts/stagehand/.selftest-phrase.txt"
printf 'one\ntwo\nTARGET_PHRASE here\nfour\n' > "$probe3"
out="$("$SHOW" --dry-run --tool Edit --file "$probe3" --phrase 'TARGET_PHRASE' 2>/dev/null)"
check "a focus phrase drives the editor line" '"line":"3"' "$out"
rm -f "$probe3" 2>/dev/null

# The in-page enhancement needs a Chrome setting that is OFF by default and is the USER'S call to
# enable. All that is asserted here is that the probe returns a definite answer and never hangs.
jsok="$(bash -c ". '$DIR/lib.sh'; if stage_chrome_js_ok; then echo on; else echo off; fi" 2>/dev/null)"
[[ "$jsok" == "on" || "$jsok" == "off" ]] && ok "the Chrome JS capability probe answers definitively ($jsok)" \
                                          || bad "the Chrome JS capability probe answers" "got '$jsok'"

printf '\nPLACEMENT (halves, reserved displays, stickiness)\n'

PJ=(osascript -l JavaScript "$DIR/place.js")
plan() { "${PJ[@]}" --plan --protect iTerm2 "$@" 2>/dev/null; }
slot() { plan "$@" | sed -nE 's/.*"display":([0-9]+),"name":"([a-z-]+)".*/\1:\2/p'; }

disp="$("${PJ[@]}" --displays 2>/dev/null)"
check "displays report a builtin flag" '"builtin"' "$disp"

# Orientation decides the split, and that is the whole point of `halves`: a portrait screen cut
# left/right yields two unreadable slivers. Force each display in turn by taking every other half.
python3 - "$disp" > "$tmp/dsp.txt" <<'PYY' 2>/dev/null
import json,sys
d=json.loads(sys.argv[1])["displays"]
for i,s in enumerate(d):
    print(i, "landscape" if s["w"]>=s["h"] else "portrait", 1 if s.get("builtin") else 0)
PYY
allhalves=""
while read -r i orient bi; do
  if [[ "$orient" == "landscape" ]]; then allhalves="${allhalves:+$allhalves,}$i:left-half,$i:right-half"
  else                                    allhalves="${allhalves:+$allhalves,}$i:top-half,$i:bottom-half"; fi
done < "$tmp/dsp.txt"

while read -r i orient bi; do
  others="$(printf '%s' "$allhalves" | tr ',' '\n' | grep -v "^$i:" | paste -sd, -)"
  got="$(slot --taken "$others" --all-displays)"
  case "$orient" in
    landscape) case "$got" in "$i:left-half"|"$i:right-half") ok "display $i is landscape → split left/right ($got)" ;;
                              *) bad "display $i landscape split" "got $got" ;; esac ;;
    portrait)  case "$got" in "$i:top-half"|"$i:bottom-half") ok "display $i is portrait → split top/bottom ($got)" ;;
                              *) bad "display $i portrait split" "got $got" ;; esac ;;
  esac
done < "$tmp/dsp.txt"

# The laptop screen is reserved for the person, so it must not turn up in ordinary picks. Sampled
# rather than reasoned about, because the choice is random by design.
bi="$(awk '$3==1{print $1}' "$tmp/dsp.txt" | head -1)"
if [[ -n "$bi" ]]; then
  hits=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    [[ "$(slot)" == "$bi:"* ]] && hits=$((hits+1))
  done
  [[ "$hits" == "0" ]] && ok "the built-in display (index $bi) is never chosen in 12 random picks" \
                       || bad "the built-in display is reserved" "chosen $hits/12 times"
  # Reserved is NOT banned: a laptop with no external screen must still get a placement.
  ext="$(printf '%s' "$allhalves" | tr ',' '\n' | grep -v "^$bi:" | paste -sd, -)"
  got="$(slot --taken "$ext")"
  [[ "$got" == "$bi:"* ]] && ok "with every external half taken it falls back to the built-in ($got)" \
                          || bad "built-in is the last-resort tier" "got $got"
else
  printf '  skip no built-in display detected\n'
fi

# A half another role owns is out of the pool — this is what stops "random" meaning "on top of the
# window opened a moment ago".
one="$(printf '%s' "$allhalves" | tr ',' '\n' | head -1)"
rest="$(printf '%s' "$allhalves" | tr ',' '\n' | tail -n +2 | paste -sd, -)"
got="$(slot --taken "$rest" --all-displays)"
[[ "$got" == "$one" ]] && ok "taken halves are excluded — only the free one is chosen ($got)" \
                       || bad "taken halves are excluded" "want $one got $got"

# Stickiness: a role that already owns a half keeps it, so a window does not hop when a tab opens.
pick="$(printf '%s' "$allhalves" | tr ',' '\n' | tail -1)"
same=1
for _ in 1 2 3 4 5; do [[ "$(slot --prefer "$pick" --all-displays)" == "$pick" ]] || same=0; done
[[ "$same" == "1" ]] && ok "--prefer pins the same half across repeats ($pick)" \
                     || bad "--prefer pins the same half" "drifted away from $pick"

# tidy must not resize anything that is not actually filling a display.
out="$(plan --tidy left)"
case "$out" in *'"tidied":null'*|*'"tidied":"'*) ok "tidy reports what it did (or null)" ;;
               *) bad "tidy reports its action" "$out" ;; esac

# One browser window, by construction: the state file must not be per-role any more.
if grep -q 'chrome-window-\$role' "$DIR/show.sh"; then
  bad "the browser uses ONE window" "show.sh still keys the window file by role"
else
  ok "the browser uses ONE window (state file is not per-role)"
fi

printf '\nREGRESSIONS (bugs found by running this for real — keep these)\n'

# 1. `tab` inside a `tell application "Google Chrome"` block resolves to CHROME'S tab class, not the
#    tab character, so the id|bounds delimiter came back as the literal letters "tab" and the whole
#    Chrome-bounds placement branch silently fell through to the weaker Accessibility fallback.
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
  info="$(osascript <<'AS' 2>/dev/null
on run
  tell application "Google Chrome"
    set b to bounds of window 1
    return (id of window 1 as text) & "|" & (item 1 of b as text)
  end tell
end run
AS
)"
  id="${info%%|*}"
  [[ "$id" =~ ^[0-9]+$ ]] && ok "Chrome id|bounds delimiter parses to a numeric id" \
                          || bad "Chrome id|bounds delimiter parses to a numeric id" "got: $info"
  # Chrome's `bounds` and the Accessibility API must agree on coordinates, or the two placement
  # paths would disagree with each other on a negative-origin display.
  #
  # Matched by TITLE, never by index: Chrome's own window ordering and the Accessibility API's are
  # independent, so `window 1` on each side is frequently a DIFFERENT window. The first version of
  # this check compared those two and passed only while the orderings happened to coincide — then
  # reported a coordinate-space mismatch (2560,767 vs 3225,904) that was really two windows.
  pair="$(osascript <<'AS' 2>/dev/null
on run
  set t to ""
  set cb to ""
  tell application "Google Chrome"
    set t to title of active tab of window 1
    set b to bounds of window 1
    set cb to (item 1 of b as text) & "," & (item 2 of b as text)
  end tell
  tell application "System Events" to tell process "Google Chrome"
    repeat with w in windows
      if (name of w as text) starts with t then
        set p to position of w
        return cb & "|" & (item 1 of p as text) & "," & (item 2 of p as text)
      end if
    end repeat
  end tell
  return cb & "|no-ax-match"
end run
AS
)"
  cb="${pair%%|*}"; ax="${pair#*|}"
  if [[ "$ax" == "no-ax-match" ]]; then
    printf '  skip could not match the same Chrome window on both sides\n'
  else
    [[ "$cb" == "$ax" ]] && ok "Chrome bounds and Accessibility share one coordinate space ($cb)" \
                         || bad "Chrome bounds and Accessibility share one coordinate space" "chrome=$cb ax=$ax"
  fi
else
  printf '  skip Chrome is not running\n'
fi

# 2. Never hijack a window that is not ours. The first version took proc.windows[0] and resized
#    whichever window happened to be frontmost inside the app — with three Chrome windows open,
#    that was one of the user's.
res="$(osascript -l JavaScript "$DIR/place.js" "Google Chrome" --match "zzz-no-such-window-zzz" --dry-run 2>/dev/null)"
check "an unmatched --match places NOTHING" '"ok":false' "$res"

# 3. The Chrome AppleScript heredoc is UNQUOTED (theURL / wantID / max_tabs must expand), so the
#    shell also executes anything backquoted inside it. A backticked "make new window" written in a
#    COMMENT in that heredoc really did run make, printing "No rule to make target new" into the
#    middle of a run. A grep is the whole test: no backtick may appear in that block.
hd="$(awk '/^info="\$\(osascript <<APPLESCRIPT/,/^APPLESCRIPT$/' "$DIR/show.sh")"
[[ -n "$hd" ]] || bad "found the AppleScript heredoc in show.sh" "awk matched nothing"
case "$hd" in
  *'`'*) bad "no backtick inside the unquoted AppleScript heredoc" "a backtick there is executed by the shell" ;;
  *)     ok "no backtick inside the unquoted AppleScript heredoc" ;;
esac

# 4. The browser must open under the configured ACCOUNT. Chrome exposes no profile property, so the
#    profile is REMEMBERED in the state file as "<id>|<profile>" — a stored window with a different
#    (or absent) profile has to be discarded rather than reused, which is what made every Jira and
#    GitLab tab render a login wall.
acct="$(bash -c ". '$DIR/lib.sh'; stage_cfg stagehand.browser_account" 2>/dev/null)"
if [[ -n "$acct" ]]; then
  pdir="$(bash -c ". '$DIR/lib.sh'; stage_chrome_profile" 2>/dev/null)"
  pname="$(bash -c ". '$DIR/lib.sh'; stage_chrome_profile_name" 2>/dev/null)"
  [[ -n "$pdir" ]] && ok "browser_account '$acct' resolves to a Chrome profile ($pdir / $pname)" \
                   || bad "browser_account resolves to a Chrome profile" "no profile matched $acct in Chrome's Local State"
  sf="$(bash -c ". '$DIR/lib.sh'; printf '%s' \"\$STAGE_STATE_DIR/chrome-window\"" 2>/dev/null)"
  if [[ -f "$sf" ]]; then
    got="$(cat "$sf")"
    [[ "$got" == *"|$pdir" ]] && ok "the remembered browser window records the right profile ($got)" \
                              || bad "the remembered browser window records the right profile" "state=$got want suffix |$pdir"
  else
    printf '  skip no browser window remembered yet\n'
  fi
else
  printf '  skip stagehand.browser_account is not set\n'
fi

if [[ "${1:-}" == "--live" ]]; then
  printf '\nLIVE (moves a real window, then puts it back)\n'
  if pgrep -x Cursor >/dev/null 2>&1; then
    orig="$(osascript -l JavaScript "$DIR/place.js" Cursor --dry-run 2>/dev/null)"
    ob="$(printf '%s' "$orig" | sed -nE 's/.*"before":\{"x":(-?[0-9]+),"y":(-?[0-9]+),"w":([0-9]+),"h":([0-9]+)\}.*/\1 \2 \3 \4/p')"
    read -r ox oy ow oh <<<"$ob"
    win="$(printf '%s' "$orig" | sed -nE 's/.*"window":"([^"]*)".*/\1/p')"
    if [[ -n "${ox:-}" && -n "$win" ]]; then
      # TWO passes, and then PROVE the park took. Single-pass parking silently fails exactly the way
      # placement did — a cross-display move gets clamped on the first pass — so the earlier version
      # of this test parked nothing, found the window already sitting on its ideal slot, and passed
      # for free. A move test that cannot fail is worse than no move test.
      osascript -e "tell application \"System Events\" to tell process \"Cursor\" to repeat with w in windows
        if name of w is \"$win\" then
          repeat 2 times
            set size of w to {700, 520}
            set position of w to {150, 150}
          end repeat
        end if
      end repeat" >/dev/null 2>&1
      parked="$(osascript -l JavaScript "$DIR/place.js" Cursor --match "$win" --dry-run 2>/dev/null)"
      check "the test really parked the window first (else the move test is a no-op)" '"before":{"x":150,"y":150' "$parked"
      res="$(osascript -l JavaScript "$DIR/place.js" Cursor --match "$win" --protect iTerm2 2>/dev/null)"
      check "a parked window is really moved and lands where planned" '"landed":true' "$res"
      moved_from="$(printf '%s' "$res" | sed -nE 's/.*"before":\{"x":(-?[0-9]+).*/\1/p')"
      [[ "$moved_from" == "150" ]] && ok "the move started from the parked position, not the target" \
                                   || bad "the move started from the parked position" "before.x=$moved_from"
      osascript -e "tell application \"System Events\" to tell process \"Cursor\" to repeat with w in windows
        if name of w is \"$win\" then
          set size of w to {$ow, $oh}
          set position of w to {$ox, $oy}
        end if
      end repeat" >/dev/null 2>&1
      ok "the window was restored to $ox,$oy ${ow}x${oh}"
    else
      bad "a parked window is really moved" "could not read Cursor's current window"
    fi
  else
    printf '  skip Cursor is not running\n'
  fi
else
  printf '\n  (run with --live to also move a real window and put it back)\n'
fi

printf '\nCONFIG READER\n'

# `stagehand.enabled: ture` sat in a personal config for weeks. Every reader resolved it to false,
# which is exactly what a deliberate `false` looks like, so every surface honestly reported "off"
# and nothing named the typo. These cases pin the two halves of the fix: a value in NEITHER the
# truthy nor the falsy set must SAY so, and must resolve to the documented DEFAULT rather than to
# an invented false — while a legitimately falsy spelling stays silent, or the warning is noise.
# stage_cfg is overridden per case so the reader is tested without a config file on disk.
cfgbool() {  # cfgbool <value> <default> → "<TRUE|FALSE> <warned|silent>"
  local out rc
  out="$(STAGE_VERBOSE=1 bash -c ". '$DIR/lib.sh'
    stage_cfg() { printf '%s' '$1'; }
    stage_cfg_bool stagehand.enabled '$2'" 2>&1 >/dev/null)"
  STAGE_VERBOSE=0 bash -c ". '$DIR/lib.sh'
    stage_cfg() { printf '%s' '$1'; }
    stage_cfg_bool stagehand.enabled '$2'" >/dev/null 2>&1 && rc=TRUE || rc=FALSE
  case "$out" in *"is not a boolean"*) printf '%s warned' "$rc" ;; *) printf '%s silent' "$rc" ;; esac
}

check "a typo'd boolean is NAMED, not silently read as off" 'warned' "$(cfgbool ture false)"
check "a typo'd boolean with an off default still resolves off"  'FALSE' "$(cfgbool ture false)"
check "a typo'd boolean falls back to the DOCUMENTED default, not to false" 'TRUE' "$(cfgbool ture true)"
check "a legitimate 'off' is falsy and stays SILENT"     'FALSE silent' "$(cfgbool off true)"
check "a legitimate 'on' is truthy and stays SILENT"     'TRUE silent'  "$(cfgbool on false)"
check "an absent value is falsy and stays SILENT"        'FALSE silent' "$(cfgbool '' false)"

printf '\n%s passed, %s failed\n\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
