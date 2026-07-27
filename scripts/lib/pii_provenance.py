#!/usr/bin/env python3
"""pii_provenance — value-exact PII provenance: mask what PRODUCTION actually returned.

WHY THIS EXISTS
---------------
The older gate (`scripts/lib/pii-scan.sh`) judged a ticket/Slack payload by SHAPE alone: an
email-looking string was blocked no matter where it came from. That is wrong for how this
team works — prod investigation, staging QA, and local development run in PARALLEL all day,
so a shape gate blocks a seeded `fixture1@example.com` from a local fixture exactly as hard as a
real person's address. And no ambient signal (a time window, a session, a ticket key) can
separate those flows when they overlap in the same minute.

So provenance is tracked at the VALUE level:

  1. INGRESS — every sanctioned path that reads PRODUCTION data records a keyed hash of each
     personal value it saw (`record_text` / `record_rows`). The vault stores HMAC-SHA256
     digests ONLY; the values themselves are never written anywhere.
  2. EGRESS — a ticket body, comment, or Slack payload is scanned; a personal value is
     replaced with a `<prod-pii:CATEGORY>` placeholder ONLY if its digest is in the vault,
     i.e. only if production is where it came from.

Local and staging data therefore flow untouched (they never entered the vault), while a real
production value is redacted wherever it surfaces — in any session, any ticket, any minute.
Egress MASKS rather than dies: the write still lands, minus the personal value.

WHAT IT CATCHES / WHAT IT DOES NOT
----------------------------------
  - Shape-detectable values (email/phone/wallet/IBAN/national-id/…) come from the shared
    detector list `scripts/lib/pii-patterns.txt` — one policy, also read by the legacy
    shape scanner and by `scripts/db/prod_repro_seed.py`.
  - Values with NO reliable shape (a person's name, a street address) are covered too, but
    only via the PII-named COLUMNS of a prod query result: those cell values are vaulted
    whole and matched back as tokens. This is what makes names catchable at all.
  - Not caught: a value that never passed through an instrumented ingress — e.g. a human
    pasting a prod row into chat from a psql session, or a paraphrase ("the gmail one").
    That residue is the SOFT layer (prompt instruction), as before. Set `PII_GATE=on` to
    force shape-masking of everything when you are hand-writing a prod incident report.

MODES (env `PII_GATE`)
  auto (default) — mask only vault-matched values. The prod-only policy.
  on             — also mask every shape match, vault or not (paranoid; hand-written report).
  off            — mask nothing.

STORAGE
  `PII_VAULT_DIR` (default `~/.claude/prod-pii-vault`) holds `salt` (0600, per machine) and
  `vault.tsv` (`<hmac-hex>\t<category>\t<epoch>`). It lives under $HOME, NOT in the repo, so
  one machine shares one vault across every clone and Superset worktree — a value read in the
  main clone is still redacted when a worktree posts the ticket. Entries older than
  `PII_VAULT_TTL_DAYS` (default 30) are dropped on the next write.

CLI
  pii_provenance.py record [FILE|-] [--source LABEL]   # vault the prod values in this text
  pii_provenance.py mask   [FILE|-]                    # stdout = masked text, stderr = report
                                                       #   exit 0 clean, 10 masked something
  pii_provenance.py scan   [FILE|-]                    # report only, never rewrites (exit 10 on hit)
  pii_provenance.py stats                              # entry count / age, never any value
  pii_provenance.py forget [--all|--older-than DAYS]
  pii_provenance.py --selftest
"""

from __future__ import annotations

import hashlib
import hmac
import os
import re
import secrets
import sys
import time
from pathlib import Path

# --- shared policy: the detector list every engine reads -----------------------------------

PATTERNS_FILE = Path(__file__).resolve().parent / "pii-patterns.txt"

# Column names whose VALUE is personal regardless of shape (a name, a street address). Shared
# with scripts/db/prod_repro_seed.py, which masks these on a prod->local seed.
PII_COLUMN_RE = re.compile(
    r"(phone|tel|mobile|msisdn|e?mail|passport|national_?id|citizen|id_?card|"
    r"bank_?acc|account_?no|iban|crypto_?wallet|addr(ess)?|token|secret|passw(or)?d|"
    # `crypto_?wallet` not bare `wallet`, so wallet_type/wallet_id (inner-system enum/uuid)
    # aren't hit; a real wallet_address is still caught by addr(ess)?.
    r"(^|_)ip(_|$)|"  # ip / login_ip / ip_addr — external PII the value scanner can't shape-match
    r"(first|last|full|holder|real|customer)_?name)",
    re.IGNORECASE,
)

# For a LABEL-gated detector the match spans "label + value" (e.g. "bank account no 1234567890").
# Only the value part may be vaulted or masked — the label is ordinary prose.
VALUE_TAIL_RE = {
    "national_id": re.compile(r"[0-9]{13}$"),
    "bank_account": re.compile(r"[0-9]{6,17}$"),
    "passport": re.compile(r"[A-Z]{1,2}[0-9]{6,8}$", re.IGNORECASE),
}

# Never vault these even from a PII-named column: they are inner-system identity (explicitly
# ALLOWED to travel) or filler that would mask innocent prose if matched as a token.
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)
_STOP_TOKENS = {
    "unknown", "null", "none", "empty", "false", "true", "default", "system", "admin",
    "test", "testing", "example", "localhost", "anonymous", "pending", "active", "inactive",
    "deleted", "masked", "***masked***", "n/a", "na", "undefined", "nil",
}

TOKEN_MIN = int(os.environ.get("PII_TOKEN_MIN", "5"))
# A token candidate at egress: a run of word-ish characters, keeping the punctuation that is
# internal to an address/email/phone so the whole value is one token.
_TOKEN_RE = re.compile(r"[^\s,;:|/\\\"'`()\[\]{}<>]{%d,}" % TOKEN_MIN, re.UNICODE)


def load_patterns() -> list[tuple[str, "re.Pattern[str]"]]:
    """[(category, compiled)] from the shared policy file. Empty list if it is unreadable —
    the caller then degrades to doing nothing rather than guessing a policy."""
    out: list[tuple[str, re.Pattern[str]]] = []
    if not PATTERNS_FILE.is_file():
        return out
    for line in PATTERNS_FILE.read_text(encoding="utf-8").splitlines():
        if not line or line.lstrip().startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        cat, mode, pat = parts
        try:
            out.append((cat, re.compile(pat, re.IGNORECASE if mode == "ci" else 0)))
        except re.error:
            continue
    return out


_PATTERNS = load_patterns()


def value_has_pii(text: str) -> bool:
    """True if the text carries any shape-detectable external PII (shape only, no provenance)."""
    return any(rx.search(text) for _, rx in _PATTERNS)


# --- value extraction + normalization ------------------------------------------------------


def iter_pii_spans(text: str) -> list[tuple[int, int, str, str]]:
    """[(start, end, category, value)] for every shape-detected PII VALUE in `text`.

    For a label-gated detector the span is narrowed to the value tail, so masking rewrites
    "bank account no 1234567890" into "bank account no <prod-pii:bank_account>" and leaves the
    label readable. Overlapping matches keep the first (longest-wins by pattern order)."""
    spans: list[tuple[int, int, str, str]] = []
    for cat, rx in _PATTERNS:
        for m in rx.finditer(text):
            start, end, val = m.start(), m.end(), m.group(0)
            tail = VALUE_TAIL_RE.get(cat)
            if tail:
                tm = tail.search(val)
                if not tm:
                    continue
                start, end, val = start + tm.start(), start + tm.end(), tm.group(0)
            spans.append((start, end, cat, val))
    spans.sort(key=lambda s: (s[0], -(s[1] - s[0])))
    kept: list[tuple[int, int, str, str]] = []
    last_end = -1
    for s in spans:
        if s[0] >= last_end:
            kept.append(s)
            last_end = s[1]
    return kept


def variants(value: str, category: str = "") -> set[str]:
    """Every canonical form a value may legitimately be written in, so a phone vaulted as
    `+66891234567` still matches when a ticket writes `089-123-4567`. Both record and lookup
    run this, so the two sides always agree."""
    v = value.strip()
    if not v:
        return set()
    out = {v.lower()}
    compact = re.sub(r"[\s\-().+_]", "", v.lower())
    if compact:
        out.add(compact)
    digits = re.sub(r"\D", "", v)
    if len(digits) >= 6 and (category in ("phone", "bank_account", "national_id") or compact == digits):
        out.add(digits)
        if digits.startswith("66") and len(digits) >= 11:
            out.add("0" + digits[2:])
        elif digits.startswith("0") and len(digits) >= 9:
            out.add("66" + digits[1:])
    return {x for x in out if len(x) >= 4}


def _vaultable(value: str) -> bool:
    """Whether a whole cell value from a PII-named column may be vaulted. Excludes the ALLOWED
    inner-system identity (UUIDs) and filler words that would mask innocent prose."""
    v = value.strip()
    if len(v) < TOKEN_MIN:
        return False
    if v.lower() in _STOP_TOKENS:
        return False
    if _UUID_RE.match(v):
        return False
    if v.isdigit() and len(v) < 6:
        return False
    return True


# --- the vault -----------------------------------------------------------------------------


def vault_dir() -> Path:
    return Path(os.environ.get("PII_VAULT_DIR") or (Path.home() / ".claude" / "prod-pii-vault"))


def _ttl_days() -> int:
    try:
        return max(1, int(os.environ.get("PII_VAULT_TTL_DAYS", "30")))
    except ValueError:
        return 30


def _salt(create: bool) -> bytes | None:
    """The per-machine HMAC key. Without it a digest cannot be reproduced, so a stolen vault
    file is inert. 0600, created on first record."""
    path = vault_dir() / "salt"
    if path.is_file():
        raw = path.read_text(encoding="utf-8").strip()
        if raw:
            return bytes.fromhex(raw)
    if not create:
        return None
    path.parent.mkdir(parents=True, exist_ok=True)
    key = secrets.token_bytes(32)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(key.hex())
    return key


def _digest(key: bytes, value: str) -> str:
    return hmac.new(key, value.encode("utf-8"), hashlib.sha256).hexdigest()


def _vault_file() -> Path:
    return vault_dir() / "vault.tsv"


def _prune(path: Path) -> None:
    """Drop entries past the TTL. Runs on write, so a long-idle vault decays on its own."""
    if not path.is_file():
        return
    cutoff = time.time() - _ttl_days() * 86400
    keep, changed = [], False
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            changed = True
            continue
        try:
            ts = float(parts[2])
        except ValueError:
            changed = True
            continue
        if ts >= cutoff:
            keep.append(line)
        else:
            changed = True
    if changed:
        tmp = path.with_suffix(".tmp")
        tmp.write_text("\n".join(keep) + ("\n" if keep else ""), encoding="utf-8")
        os.replace(tmp, path)


def _load_vault() -> dict[str, str]:
    """{digest: category}. Empty when nothing has ever been read from production."""
    path = _vault_file()
    if not path.is_file():
        return {}
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            out[parts[0]] = parts[1]
    return out


def _store(entries: list[tuple[str, str]]) -> int:
    """Persist [(category, value)] as digests. Returns the number of NEW digests written.
    The plaintext value never touches the disk."""
    entries = [(c, v) for c, v in entries if v and v.strip()]
    if not entries:
        return 0
    key = _salt(create=True)
    assert key is not None
    path = _vault_file()
    path.parent.mkdir(parents=True, exist_ok=True)
    _prune(path)
    known = set(_load_vault())
    now = f"{time.time():.0f}"
    new: list[str] = []
    for cat, val in entries:
        for form in variants(val, cat):
            d = _digest(key, form)
            if d not in known:
                known.add(d)
                new.append(f"{d}\t{cat}\t{now}")
    if new:
        with path.open("a", encoding="utf-8") as fh:
            fh.write("\n".join(new) + "\n")
    return len(new)


# --- ingress: record what production returned ----------------------------------------------


def record_text(text: str) -> int:
    """Vault every shape-detectable PII value in a blob of production output (a log line, a
    trace payload). Returns the number of new digests."""
    if not text or os.environ.get("PII_GATE", "auto").lower() == "off":
        return 0
    return _store([(cat, val) for _, _, cat, val in iter_pii_spans(text)])


def record_rows(columns: list[str], rows: list[dict]) -> int:
    """Vault the personal values in a production query result.

    Two passes, because shape alone is not enough:
      - every string cell is shape-scanned (an email inside a free-text note still counts);
      - a cell from a PII-NAMED column is vaulted WHOLE, which is the only way a person's
        name or street address — neither of which has a detectable shape — can ever be
        recognized later at egress.
    Never raises: a provenance miss must not break a triage query."""
    if os.environ.get("PII_GATE", "auto").lower() == "off":
        return 0
    entries: list[tuple[str, str]] = []
    try:
        for row in rows:
            for col in columns or list(row.keys()):
                val = row.get(col)
                if not isinstance(val, str) or not val.strip():
                    continue
                for _, _, cat, v in iter_pii_spans(val):
                    entries.append((cat, v))
                if PII_COLUMN_RE.search(col) and _vaultable(val):
                    entries.append((_column_category(col), val.strip()))
        return _store(entries)
    except Exception:  # provenance is a safety net, never a failure mode for the query
        return 0


def _column_category(col: str) -> str:
    c = col.lower()
    for needle, cat in (
        ("mail", "email"), ("phone", "phone"), ("tel", "phone"), ("mobile", "phone"),
        ("msisdn", "phone"), ("passport", "passport"), ("iban", "iban"),
        ("bank", "bank_account"), ("account_no", "bank_account"), ("wallet", "crypto_wallet"),
        ("ip", "ip_address"), ("name", "name"), ("addr", "address"),
        ("national", "national_id"), ("citizen", "national_id"), ("id_card", "national_id"),
    ):
        if needle in c:
            return cat
    return "personal_data"


# --- egress: mask what production gave us --------------------------------------------------


def mask_text(text: str) -> tuple[str, dict[str, int]]:
    """(masked_text, {category: count}).

    `PII_GATE=off` returns the text untouched. In `auto` (default) a value is replaced only
    when its digest is in the vault — i.e. only when production is provably where it came
    from. In `on` every shape match is replaced as well, vault or not."""
    mode = os.environ.get("PII_GATE", "auto").lower()
    if mode == "off" or not text:
        return text, {}

    vault = _load_vault()
    key = _salt(create=False)
    force = mode == "on"
    if not vault and not force:
        return text, {}

    def vault_hit(value: str, category: str = "") -> str | None:
        if key is None:
            return None
        for form in variants(value, category):
            cat = vault.get(_digest(key, form))
            if cat:
                return cat
        return None

    hits: dict[str, int] = {}
    replacements: list[tuple[int, int, str]] = []
    covered: list[tuple[int, int]] = []

    # Pass 1 — shape-detected values.
    for start, end, cat, val in iter_pii_spans(text):
        matched = vault_hit(val, cat)
        if matched or force:
            label = matched or cat
            replacements.append((start, end, f"<prod-pii:{label}>"))
            hits[label] = hits.get(label, 0) + 1
        covered.append((start, end))

    # Pass 2 — shapeless values (names, addresses) recognized as whole tokens. Vault-only by
    # construction: with nothing recorded from prod there is nothing to compare a token to,
    # so ordinary prose can never be touched here.
    if vault and key is not None:
        for m in _TOKEN_RE.finditer(text):
            if any(m.start() < e and s < m.end() for s, e in covered):
                continue
            token = m.group(0).strip(".,!?;:")
            if not token or token.lower() in _STOP_TOKENS:
                continue
            cat = vault_hit(token)
            if cat:
                off = m.group(0).find(token)
                replacements.append((m.start() + off, m.start() + off + len(token), f"<prod-pii:{cat}>"))
                hits[cat] = hits.get(cat, 0) + 1

    if not replacements:
        return text, {}

    replacements.sort(key=lambda r: r[0])
    out, cursor = [], 0
    for start, end, sub in replacements:
        if start < cursor:
            continue
        out.append(text[cursor:start])
        out.append(sub)
        cursor = end
    out.append(text[cursor:])
    return "".join(out), hits


def _report(hits: dict[str, int]) -> str:
    return ", ".join(f"{cat} x{n}" for cat, n in sorted(hits.items()))


# --- CLI -------------------------------------------------------------------------------------


def _read_input(arg: str | None) -> str:
    """Text to judge. Read as BYTES and decode leniently: a caller may well pipe in the text
    pulled out of a binary container (a pdf, a png), which is not valid UTF-8 — that must be
    scannable, not a crash."""
    if not arg or arg == "-":
        return sys.stdin.buffer.read().decode("utf-8", errors="replace")
    return Path(arg).read_text(encoding="utf-8", errors="replace")


def _cmd_record(argv: list[str]) -> int:
    src = next((a for a in argv if not a.startswith("-")), None)
    n = record_text(_read_input(src))
    print(f"pii-provenance: recorded {n} new prod value digest(s)", file=sys.stderr)
    return 0


def _cmd_mask(argv: list[str]) -> int:
    src = next((a for a in argv if not a.startswith("-")), None)
    masked, hits = mask_text(_read_input(src))
    sys.stdout.write(masked)
    if hits:
        print(f"pii-provenance: masked {sum(hits.values())} production value(s) [{_report(hits)}]",
              file=sys.stderr)
        return 10
    return 0


def _cmd_scan(argv: list[str]) -> int:
    src = next((a for a in argv if not a.startswith("-")), None)
    _, hits = mask_text(_read_input(src))
    if hits:
        print(f"pii-provenance: {sum(hits.values())} production value(s) present [{_report(hits)}]",
              file=sys.stderr)
        return 10
    return 0


def _cmd_stats() -> int:
    path = _vault_file()
    vault = _load_vault()
    cats: dict[str, int] = {}
    for cat in vault.values():
        cats[cat] = cats.get(cat, 0) + 1
    print(f"vault: {path} ({'present' if path.is_file() else 'absent'})")
    print(f"salt:  {'set' if (vault_dir() / 'salt').is_file() else 'unset'}")
    print(f"entries: {len(vault)} digest(s)  ttl={_ttl_days()}d  mode={os.environ.get('PII_GATE', 'auto')}")
    for cat, n in sorted(cats.items()):
        print(f"  {cat:<18} {n}")
    return 0


def _cmd_forget(argv: list[str]) -> int:
    path = _vault_file()
    if "--all" in argv:
        path.unlink(missing_ok=True)
        print("vault cleared", file=sys.stderr)
        return 0
    if "--older-than" in argv:
        days = argv[argv.index("--older-than") + 1]
        os.environ["PII_VAULT_TTL_DAYS"] = days
        _prune(path)
        print(f"vault pruned to {days}d", file=sys.stderr)
        return 0
    print("usage: pii_provenance.py forget --all | --older-than DAYS", file=sys.stderr)
    return 64


def _selftest() -> int:
    import tempfile

    fails = 0

    def check(desc: str, cond: bool) -> None:
        nonlocal fails
        print(("ok   " if cond else "FAIL ") + desc)
        if not cond:
            fails += 1

    with tempfile.TemporaryDirectory() as tmp:
        os.environ["PII_VAULT_DIR"] = tmp
        os.environ.pop("PII_GATE", None)

        # --- empty vault: nothing is production yet, so nothing may be masked ---------------
        text = "account real.holder@example.net phoned from 0891234567"
        masked, hits = mask_text(text)
        check("empty vault masks nothing (local/staging work is untouched)", masked == text and not hits)

        # --- ingress: a prod query result gets vaulted --------------------------------------
        cols = ["entity_code", "email", "phone", "first_name", "balance", "account_id"]
        rows = [{
            "entity_code": "ACC000000021",
            "email": "real.holder@example.net",
            "phone": "+66891234567",
            "first_name": "Marlowe",
            "balance": 100000000,
            "account_id": "550e8400-e29b-41d4-a716-446655440000",
        }]
        check("record_rows vaults something", record_rows(cols, rows) > 0)

        # --- egress: the prod value is masked, the local lookalike is not -------------------
        masked, hits = mask_text("prod account real.holder@example.net is negative")
        check("prod email masked", "<prod-pii:email>" in masked and "real.holder@example.net" not in masked)
        masked, hits = mask_text("local fixture fixture1@example.com seeded fine")
        check("local email untouched", masked == "local fixture fixture1@example.com seeded fine")

        masked, _ = mask_text("staging QA used 0999999999 as the msisdn")
        check("staging phone untouched", "0999999999" in masked)

        # phone written in a different format than prod returned it
        masked, _ = mask_text("called 089-123-4567 twice")
        check("prod phone matched across formatting", "<prod-pii:phone>" in masked)

        # shapeless value — only reachable through the PII-named column vaulting
        masked, _ = mask_text("the account holder Marlowe disputes the payout")
        check("prod first_name masked (shapeless)", "<prod-pii:name>" in masked)

        # ALLOWED inner-system identity must survive: that is the whole point of the policy
        allowed = ("account ACC000000021 / txn 550e8400-e29b-41d4-a716-446655440000 / "
                   "balance 100000000 / SELECT count(*) FROM account WHERE entity_code = ABCDE00000001")
        masked, hits = mask_text(allowed)
        check("entity code / UUID / money / SQL all survive", masked == allowed and not hits)

        # --- label-gated value keeps its label ----------------------------------------------
        record_text("bank account no 1234567890")
        masked, _ = mask_text("refund to bank account no 1234567890 failed")
        check("bank label kept, value masked",
              "bank account no <prod-pii:bank_account>" in masked)

        # --- modes ---------------------------------------------------------------------------
        os.environ["PII_GATE"] = "off"
        masked, hits = mask_text("prod account real.holder@example.net is negative")
        check("PII_GATE=off masks nothing", "real.holder@example.net" in masked and not hits)

        os.environ["PII_GATE"] = "on"
        masked, hits = mask_text("hand-written report about newperson@elsewhere.com")
        check("PII_GATE=on masks unvaulted shapes too", "<prod-pii:email>" in masked)
        masked, _ = mask_text(allowed)
        check("PII_GATE=on still spares the ALLOW set", masked == allowed)
        os.environ["PII_GATE"] = "auto"

        # --- the vault never holds a value -----------------------------------------------
        raw = (Path(tmp) / "vault.tsv").read_text(encoding="utf-8")
        check("vault stores digests only, never a value",
              "real.holder@example.net" not in raw and "Marlowe" not in raw and "66891234567" not in raw)

    print("---")
    if fails:
        print(f"selftest FAIL ({fails})")
        return 1
    print("selftest PASS")
    return 0


def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    if argv[0] == "--selftest":
        return _selftest()
    cmd, rest = argv[0], argv[1:]
    if cmd == "record":
        return _cmd_record(rest)
    if cmd == "mask":
        return _cmd_mask(rest)
    if cmd == "scan":
        return _cmd_scan(rest)
    if cmd == "stats":
        return _cmd_stats()
    if cmd == "forget":
        return _cmd_forget(rest)
    print(f"unknown command {cmd!r} — see --help", file=sys.stderr)
    return 64


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
