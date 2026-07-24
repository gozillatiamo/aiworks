#!/usr/bin/env bash
# scripts/lib/pii-scan.sh — shared external-PII egress scanner.
#
# ONE deterministic gate, reused by every path that lets production-derived data leave the
# prod boundary:
#   - scripts/tracker/*  (egress → a ticket / Slack)         via tracker_assert_no_pii
#   - scripts/db/prod_repro_seed.py (persist → local sandbox) via its own value-level mask
#
# Policy:
#   ALLOW  — inner-system identity: any *_code identifier, internal UUID; reproduce SQL query
#            text; aggregate stats (counts / GROUP BY); money integers (fixed-point amounts
#            stored as integers). These are the ground truth a triage summary or a repro seed
#            legitimately needs, and none of them identify a real-world person.
#   BLOCK  — external-world PII in value form: phone / msisdn, email, crypto wallet, IBAN /
#            bank account, and formatted national-id / passport. This is the data that must
#            never land in a ticket (tracker / Slack) or on a dev laptop.
#
# Design notes / honest limits:
#   - Conservative by construction: every detector is shaped so the ALLOW set does not trip
#     it. In particular a bare long digit run is NOT flagged (it collides with a money value
#     stored as a fixed-point integer) — national ids are matched only in their formatted or
#     labelled form. A *_code / UUID has no email/phone/wallet shape, so it passes.
#   - Names have no reliable lexical shape — they are the SOFT layer (prompt instruction),
#     not caught here. This scanner is a backstop for the shape-detectable PII, not a
#     complete DLP. Bank-account / passport / national-id (bare) are LABEL-gated to avoid
#     nuking the allowed *_code identifiers.
#   - The gate NEVER echoes the matched value (that would itself leak PII into the
#     transcript/logs). It reports only the category + a count.
#
# Usage as a lib:
#   . scripts/lib/pii-scan.sh
#   if ! pii_scan_text "$body"; then ...blocked... fi     # returns 2 on a hit, 0 clean
#   pii_scan_categories                                    # after a scan: names the hit cats
#
# Usage as a CLI (for tests / manual checks):
#   scripts/lib/pii-scan.sh --check FILE        # or - for stdin; exit 0 clean, 2 flagged
#   scripts/lib/pii-scan.sh --selftest          # run the built-in fixtures

# --- Detectors ---------------------------------------------------------------------------
# The detector list is the shared policy file scripts/lib/pii-patterns.txt (also read by the
# Python seed tool), so the block/allow rules live in ONE place. Each line is
# "<category>\t<mode>\t<ERE>" with mode = plain (case-sensitive) | ci (case-insensitive).
_PII_PATTERNS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pii-patterns.txt"

_PII_LAST_CATS=""   # space-separated categories from the most recent scan

# pii_scan_text TEXT → 0 clean, 2 if any external-PII category matched. Sets _PII_LAST_CATS.
pii_scan_text() {
  local text="$1" cats="" cat mode re line
  _PII_LAST_CATS=""
  command -v grep >/dev/null || return 0   # no grep → cannot scan; degrade open, never false-block
  [[ -r "$_PII_PATTERNS_FILE" ]] || return 0   # pattern file absent → degrade open, never false-block

  while IFS=$'\t' read -r cat mode re; do
    [[ -z "$cat" || "$cat" == \#* ]] && continue
    [[ -z "$re" ]] && continue
    local flags="-qE"; [[ "$mode" == "ci" ]] && flags="-qiE"
    if printf '%s' "$text" | grep $flags "$re" 2>/dev/null; then
      case " $cats " in *" $cat "*) ;; *) cats="$cats $cat" ;; esac
    fi
  done < "$_PII_PATTERNS_FILE"

  cats="${cats# }"
  _PII_LAST_CATS="$cats"
  [[ -z "$cats" ]] && return 0
  return 2
}

# pii_scan_categories → prints the categories hit by the last pii_scan_text (never the values).
pii_scan_categories() { printf '%s\n' "$_PII_LAST_CATS"; }

# --- CLI ---------------------------------------------------------------------------------
_pii_selftest() {
  local fails=0
  _expect() { # DESC EXPECT(clean|flag) TEXT
    local desc="$1" expect="$2" text="$3" rc=0
    pii_scan_text "$text" || rc=$?
    if [[ "$expect" == clean && $rc -eq 0 ]]; then echo "ok   (clean) $desc"
    elif [[ "$expect" == flag && $rc -eq 2 ]]; then echo "ok   (flag: $_PII_LAST_CATS) $desc"
    else echo "FAIL (rc=$rc, cats='$_PII_LAST_CATS') $desc"; fails=$((fails+1)); fi
  }
  # ALLOW — must stay clean
  _expect "entity code"          clean 'account ACC000000021 has negative balance'
  _expect "generic *_code"       clean 'tenant_code ABCDE misconfigured'
  _expect "more *_code"          clean 'promo_code SUMMER2026, region_code ABCDE'
  _expect "internal UUID"        clean 'txn 550e8400-e29b-41d4-a716-446655440000 missing'
  _expect "money integer"        clean 'balance 100000000 (=100.000000) too low; 1240000000000 total'
  _expect "aggregate"            clean '1240 accounts negative since 2026-07-20'
  _expect "reproduce SQL"        clean 'SELECT count(*) FROM entity WHERE entity_code = ABCDE00000001'
  # BLOCK — must flag
  _expect "mobile 0-led"         flag  'contact the account holder at 0891234567'
  _expect "e164 phone"           flag  'msisdn +66891234567 bounced'
  _expect "email"                flag  'contact email is somebody@example.com'
  _expect "ipv4 address"         flag  'last login ip 203.0.113.7'
  _expect "eth wallet"           flag  'credited 0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
  _expect "formatted national id" flag 'id 1-2345-67890-12-3 on file'
  _expect "labeled bank account" flag  'bank account no 1234567890'
  echo "---"; [[ $fails -eq 0 ]] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; return 1; }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
    --selftest) _pii_selftest ;;
    --check)
      src="${2:--}"; if [[ "$src" == "-" ]]; then body="$(cat)"; else body="$(cat "$src")"; fi
      if pii_scan_text "$body"; then echo "clean"; exit 0
      else echo "BLOCKED: external PII detected (categories: $_PII_LAST_CATS)" >&2; exit 2; fi ;;
    *) echo "usage: pii-scan.sh --check FILE|-   |   --selftest" >&2; exit 64 ;;
  esac
fi
