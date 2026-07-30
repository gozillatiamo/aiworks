#!/usr/bin/env bash
#
# stagehand — make the screen follow the EXPLANATION, not just the tool calls.
#
# Usage: follow.sh --transcript <path> [--text "…"] [--dry-run] [-v]
#
# WHY THIS EXISTS SEPARATELY FROM show.sh: show.sh is driven by PostToolUse, so it shows what a
# tool TOUCHED. But a reply that says "MR !14 has been stuck 37 days and OFB-2179 spans three
# repos" touched neither — the interesting subjects of a turn are frequently things the assistant
# only TALKED about. The Stop hook is the one place with the finished reply in hand, so that is
# where the screen gets pointed at what was just said.
#
# TWO WAYS IT LEARNS WHAT TO SHOW, in the same shape voice uses for its closing line:
#   1. An explicit `SHOW: <target>` line in the reply — exact, free, and the assistant's own choice
#      of what mattered. Several are allowed; comma-separate or repeat the line.
#   2. No tag → the prose is scanned in reading ORDER and the first few subjects are opened. Reading
#      order is the right priority signal because a reply leads with its headline.
#
# TARGETS a tag or the prose may name:
#   https://…                      → browser tab
#   <repo>!<iid>  /  <repo>#<n>    → that repo's MR/PR, resolved from its git remote
#   OFB-1234                       → the tracker ticket
#   path/to/file.rs[:42]           → the editor, at that line
#
# `<repo>!<iid>` is resolved through `git remote get-url`, never by assembling a URL from parts.
# Hand-assembling one is how a "https://gitlab.com/bluepicode/ofb/ofb-k6-loadtests/-/merge_requests/14"
# came out 404 — the project actually lives under `qa/`, not `ofb/`. The remote knows; guessing does not.
#
# Opening is delegated to show.sh, so the account-correct browser window, the tab ring, the
# debounce and the placement are all the same code paths as the tool-driven route.

set -uo pipefail

STAGE_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
[[ -f "$STAGE_LIB" ]] || exit 0
# shellcheck source=./lib.sh
. "$STAGE_LIB" 2>/dev/null || exit 0
set +e

stage_gate_or_exit
stage_cfg_bool stagehand.triggers.narration true || { slog "narration trigger off"; exit 0; }

TRANSCRIPT="" TEXT="" dry=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --transcript) TRANSCRIPT="${2:-}"; shift 2 ;;
    --text)       TEXT="${2:-}"; shift 2 ;;
    --dry-run)    dry=1; shift ;;
    -v)           STAGE_VERBOSE=1; shift ;;
    *)            shift ;;
  esac
done

if [[ -z "$TEXT" ]]; then
  [[ -n "$TRANSCRIPT" && -f "$TRANSCRIPT" ]] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  # The last assistant TEXT block of the turn — tool calls and thinking are not what was said.
  TEXT="$(jq -rs '[.[] | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text] | last // ""' \
          "$TRANSCRIPT" 2>/dev/null || printf '')"
fi
[[ -n "$TEXT" ]] || exit 0

MAX="$(stage_cfg_int stagehand.follow_max 3 1 10)"
tracker_url="$(stage_cfg tracker.base_url)"
tracker_url="${tracker_url%/}"
provider="$(stage_cfg vcs.provider gitlab)"
prefix="$(stage_cfg tracker.ticket_prefix OFB)"

# repo_web <repo-dir> → the repo's web base URL, from its own git remote. Empty when unknown.
repo_web() {
  local d="$STAGE_ROOT/$1" u
  [[ -d "$d/.git" ]] || return 0
  u="$(git -C "$d" remote get-url origin 2>/dev/null)" || return 0
  [[ -n "$u" ]] || return 0
  u="${u%.git}"
  # scp-style remote → https, by SPLITTING on the single ":" that separates host from path.
  # Pattern substitution is the wrong tool here and produced "https///gitlab.com/…": ${u/://}
  # rewrites the FIRST colon in the string, which after the https:// prefix was already added is
  # the one inside the scheme.
  case "$u" in
    git@*:*)
      local rest="${u#git@}"
      u="https://${rest%%:*}/${rest#*:}"
      ;;
    ssh://git@*)
      local r2="${u#ssh://git@}"
      u="https://${r2}"
      ;;
  esac
  printf '%s' "$u"
}

# urlenc <text> → percent-encoded, for a text fragment
urlenc() { printf '%s' "$1" | jq -sRr @uri 2>/dev/null; }

# resolve <token> → TAB-separated "url <URL> [phrase]" | "file <PATH> [phrase]" | "" (unresolvable)
#
# A target may carry a FOCUS PHRASE after "~": `agent-db!555 ~signature_key`. That is what turns
# "open the thing" into "look at the part I am talking about":
#   • in the browser it becomes a URL text fragment (#:~:text=…), which Chrome itself scrolls to
#     AND highlights — no extra permission, no injected JavaScript;
#   • in the editor the file is grepped for the phrase and the line becomes the --goto target.
resolve() {
  local t="$1" phrase=""
  if [[ "$t" == *"~"* ]]; then
    phrase="${t#*~}"
    t="${t%%~*}"
    phrase="$(printf '%s' "$phrase" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    t="$(printf '%s' "$t" | sed -E 's/[[:space:]]+$//')"
  fi
  case "$t" in
    https://*|http://*)
      if [[ -n "$phrase" ]]; then printf 'url\t%s#:~:text=%s\t%s' "$t" "$(urlenc "$phrase")" "$phrase"
      else                        printf 'url\t%s\t' "$t"
      fi
      return 0 ;;
  esac
  local frag=""
  [[ -n "$phrase" ]] && frag="#:~:text=$(urlenc "$phrase")"

  # <repo>!<iid> (GitLab) or <repo>#<n> (GitHub)
  if [[ "$t" =~ ^([A-Za-z0-9._-]+)[!#]([0-9]+)$ ]]; then
    local repo="${BASH_REMATCH[1]}" n="${BASH_REMATCH[2]}" base
    base="$(repo_web "$repo")"
    [[ -n "$base" ]] || { slog "no remote for repo '$repo'"; return 0; }
    # A focus phrase means "the diff", because that is where a named identifier lives.
    #
    # This was briefly removed on the strength of a BAD MEASUREMENT and is restored on a good one. The
    # probe that "proved" GitLab keeps diff text out of the DOM was run against an MR that never
    # contained the identifier being searched for, so of course it found zero — the conclusion
    # ("lazy-loaded, can never be highlighted") did not follow. Re-measured against the MR that really
    # does contain it: body innerText holds 3 occurrences and the highlighter reports hit:3 on the
    # /diffs page itself. GitLab does collapse LARGE files, so a phrase inside an unexpanded file is
    # still unreachable — but that is a per-file limit, not a property of the diff view.
    local sub="/-/merge_requests/$n"; [[ "$provider" == "github" ]] && sub="/pull/$n"
    if [[ -n "$phrase" ]]; then
      [[ "$provider" == "github" ]] && sub="$sub/files" || sub="$sub/diffs"
    fi
    printf 'url\t%s%s%s\t%s' "$base" "$sub" "$frag" "$phrase"
    return 0
  fi
  # a ticket key
  if [[ "$t" =~ ^[A-Z][A-Z0-9]+-[0-9]+$ ]]; then
    [[ -n "$tracker_url" ]] || { slog "no tracker.base_url — cannot open $t"; return 0; }
    printf 'url\t%s/browse/%s%s\t%s' "$tracker_url" "$t" "$frag" "$phrase"
    return 0
  fi
  # a repo-relative (or absolute) file path, optionally :line
  local p="${t%%:*}"
  case "$p" in /*) ;; *) p="$STAGE_ROOT/$p" ;; esac
  [[ -f "$p" ]] && { printf 'file\t%s\t%s' "$p" "$phrase"; return 0; }
  return 0
}

# ── 1. the explicit tag ────────────────────────────────────────────────────────────
targets=()
while IFS= read -r line; do
  body="$(printf '%s' "$line" | sed -E 's/^.*SHOW:[[:space:]]*//')"
  # Strip the markdown a reply may wrap a target in — backticks and asterisks ONLY.
  # NOT the underscore: it is markdown emphasis in prose but it is also half of every snake_case
  # identifier, and stripping it turned a focus phrase of "signature_key" into "signaturekey",
  # which then matched nothing in the diff it was supposed to scroll to.
  body="$(printf '%s' "$body" | tr -d '`*')"
  IFS=',' read -r -a parts <<<"$body"
  for p in "${parts[@]}"; do
    p="$(printf '%s' "$p" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [[ -n "$p" ]] && targets+=("$p")
  done
done < <(printf '%s\n' "$TEXT" | grep -E '(^|[[:space:]>*_`-])SHOW:[[:space:]]*.' || true)

tagged=0
[[ ${#targets[@]} -gt 0 ]] && { tagged=1; slog "explicit SHOW tag: ${targets[*]}"; }

# ── 2. no tag → read the prose in order ────────────────────────────────────────────
# Deliberately narrow. Only shapes that are unambiguous subjects get picked up; anything looser
# turns a reply that merely MENTIONS a word into a window flying open.
if [[ "$tagged" == "0" ]]; then
  while IFS= read -r m; do
    [[ -n "$m" ]] && targets+=("$m")
  done < <(printf '%s' "$TEXT" | tr -d '`*' | grep -oE "https?://[A-Za-z0-9._~:/?#@!\$&+,;=%-]+|[A-Za-z0-9._-]+![0-9]+|${prefix}-[0-9]+" | head -40)
fi

# ── don't re-stage the same reply ──────────────────────────────────────────────────
# This runs on PostToolUse as well as Stop, so the SAME assistant text is seen once per tool call
# for the rest of the turn. Without this the screen would re-open the same three things over and
# over while the turn continued working — the opposite of following along.
if [[ "$dry" != "1" ]]; then
  th="$STAGE_STATE_DIR/followed"
  hash="$(printf '%s' "$TEXT" | shasum -a 256 | cut -c1-40)"
  [[ "$(cat "$th" 2>/dev/null)" == "$hash" ]] && { slog "this text was already staged"; exit 0; }
  printf '%s' "$hash" > "$th" 2>/dev/null
fi

# ── open, in order, up to the cap ──────────────────────────────────────────────────
seen="" opened=0
for t in "${targets[@]}"; do
  [[ "$opened" -ge "$MAX" ]] && { slog "cap $MAX reached — stopping"; break; }
  case "|$seen|" in *"|$t|"*) continue ;; esac
  seen="$seen|$t"
  IFS=$'\t' read -r kind val phrase <<<"$(resolve "$t")"
  [[ -n "${kind:-}" ]] || continue
  if [[ "$dry" == "1" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$t" "$kind" "$val" "${phrase:-}"
  else
    case "$kind" in
      url)  "$STAGE_DIR/show.sh" --url "$val" ${phrase:+--phrase "$phrase"} ;;
      file) "$STAGE_DIR/show.sh" --tool Edit --file "$val" ${phrase:+--phrase "$phrase"} ;;
    esac
  fi
  opened=$((opened+1))
done

exit 0
