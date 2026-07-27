#!/usr/bin/env bash
# scripts/lib/pii-scan.sh — SHAPE-only external-PII scanner.
#
# ⚠️ NOT the egress gate any more. Shape alone cannot tell a real personal address from a
# seeded fixture one, and a team runs prod / staging / local investigations in PARALLEL — so
# judging by shape blocked local and staging work as hard as prod. The egress decision now
# belongs to scripts/lib/pii_provenance.py, which redacts a value only when a sanctioned
# prod-read path actually saw it (docs/agents/pii-provenance.md).
#
# What still uses this file:
#   - `pii_scannable_text` — pulling the real text out of a PDF container, reused by the
#     notify adapter's binary-file check.
#   - shape detection as a library / CLI for ad-hoc checks and for `PII_GATE=on` semantics.
#   - the detector list itself (scripts/lib/pii-patterns.txt), shared with the provenance
#     engine so the policy still lives in ONE place.
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

# pii_scannable_text FILE → prints the text a shape-based scan should actually see.
# Plain text passes through. A PDF is a CONTAINER, not text: its xref table is a run of
# 10-digit zero-padded byte offsets ("0000000015 00000 n") that matches the phone detector in
# EVERY pdf ever produced — scanning the container bytes therefore blocked 100% of pdf
# uploads. So a pdf is reduced to its real content (page text + metadata dicts) by
# scripts/lib/pdf-text.py first; without python3 we fall back to the raw bytes with the xref
# subsection lines stripped, which removes that one deterministic false positive.
pii_scannable_text() {
  local file="$1" helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/pdf-text.py" out=""
  if [[ "$(head -c 4 "$file" 2>/dev/null)" == "%PDF" ]]; then
    if command -v python3 >/dev/null && [[ -r "$helper" ]] && out="$(python3 "$helper" "$file" 2>/dev/null)"; then
      printf '%s' "$out"; return 0
    fi
    LC_ALL=C sed -E 's/^[0-9]{10} [0-9]{5} [fn][[:space:]]*$/ /' "$file" 2>/dev/null; return 0
  fi
  cat "$file"
}

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

  # CONTAINER — a pdf must be judged on its content, never on its xref/stream bytes.
  _expect_file() { # DESC EXPECT(clean|flag) FILE
    local desc="$1" expect="$2" file="$3" rc=0
    pii_scan_text "$(pii_scannable_text "$file")" || rc=$?
    if [[ "$expect" == clean && $rc -eq 0 ]]; then echo "ok   (clean) $desc"
    elif [[ "$expect" == flag && $rc -eq 2 ]]; then echo "ok   (flag: $_PII_LAST_CATS) $desc"
    else echo "FAIL (rc=$rc, cats='$_PII_LAST_CATS') $desc"; fails=$((fails+1)); fi
  }
  if command -v python3 >/dev/null; then
    local tmp; tmp="$(mktemp -d)"
    # $3 = "linked" (a normal pdf: the page points at its content stream) or "orphan" (the
    # /Contents edge is missing — a shape the extractor must still read, since an unreachable
    # text stream is exactly what must not slip through a PII check).
    _mkpdf() { python3 -c '
import sys, zlib
body = zlib.compress(sys.argv[2].encode())
page = b"<</Type/Page /Contents 2 0 R>>" if sys.argv[3] == "linked" else b"<</Type/Page>>"
open(sys.argv[1], "wb").write(
    b"%PDF-1.4\n1 0 obj" + page + b"endobj\n2 0 obj<</Length "
    + str(len(body)).encode() + b">>stream\n" + body
    + b"\nendstream\nendobj\nxref\n0 3\n0000000000 65535 f \n0000000015 00000 n \n"
      b"0000000327 00000 n \ntrailer<</Size 3>>\nstartxref\n999\n%%EOF\n")
' "$1" "$2" "$3"; }
    _mkpdf "$tmp/clean.pdf" 'BT (ADR-0003 personal runtime config overrides) Tj ET' linked
    _expect_file "pdf with no PII (xref offsets ignored)"  clean "$tmp/clean.pdf"
    _mkpdf "$tmp/phone.pdf" 'BT [(call 08) -20 (91234567)] TJ ET' linked
    _expect_file "pdf with a phone in its text layer"      flag  "$tmp/phone.pdf"
    _mkpdf "$tmp/mail.pdf" 'BT (write to somebody@example.com) Tj ET' linked
    _expect_file "pdf with an email in its text layer"     flag  "$tmp/mail.pdf"
    _mkpdf "$tmp/orphan.pdf" 'BT (write to somebody@example.com) Tj ET' orphan
    _expect_file "pdf whose text stream no page references" flag "$tmp/orphan.pdf"
    rm -rf "$tmp"
  else
    echo "skip (no python3) pdf container fixtures"
  fi

  echo "---"; [[ $fails -eq 0 ]] && echo "selftest PASS" || { echo "selftest FAIL ($fails)"; return 1; }
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  set -euo pipefail
  case "${1:-}" in
    --selftest) _pii_selftest ;;
    --check)
      src="${2:--}"; if [[ "$src" == "-" ]]; then body="$(cat)"; else body="$(pii_scannable_text "$src")"; fi
      if pii_scan_text "$body"; then echo "clean"; exit 0
      else echo "BLOCKED: external PII detected (categories: $_PII_LAST_CATS)" >&2; exit 2; fi ;;
    *) echo "usage: pii-scan.sh --check FILE|-   |   --selftest" >&2; exit 64 ;;
  esac
fi
