#!/usr/bin/env python3
"""Night Watch engine: one Tick per slot. The agent returns a Verdict; this script owns everything
else (validation, memory, threading, mentions, re-posts) and posts only through scripts/notify/.
See scripts/night-watch/README.md and docs/adr/0047-*.md.

  night_watch.py tick   run one Tick now and exit
  night_watch.py loop   wait for each slot, run a Tick, repeat
  night_watch.py plan   print the slot for now, whether it is active, and the next one
  night_watch.py brief [latest|HH:MM|YYYYMMDDTHHMM]   print a Verdict for a follow-up (read-only)
  night_watch.py resolve <latest|HH:MM|YYYYMMDDTHHMM> <n> --note "<one line>" [--alert]
                         mark finding n of that Verdict safe; later Ticks drop a repeat of it
  night_watch.py unresolve <id>   remove a resolution (id printed by resolve and resolved)
  night_watch.py resolved         list active resolutions (read-only)
"""
import argparse
import fcntl
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NWDIR = ROOT / "agent_logs" / "night-watch"
LEARN_TICKS = 24
RETAIN_DAYS = 7
KEEP = {"state.json", "tick.lock", "ticks.log", "resolved.json"}
RESOLVE_DAYS, AGG_DAYS = 7, 1  # aggregate-only evidence names no occurrence, so it lives 1 day
AGGREGATE = {"metric", "config"}
MAX_RESOLVED, MAX_RES_IDS, MAX_RES_NOTE = 200, 50, 200
RANK = {"SUSPICIOUS": 1, "ALERT": 2}
MAX_NOTES, MAX_NOTE_LEN, MAX_BASELINES = 50, 300, 200
RAW_CAP = 256 * 1024
DISALLOW = ["Bash(*scripts/notify/*)", "Bash(*scripts/tracker/*)", "Bash(*scripts/vcs/*)",
            "Bash(*night-watch/run.sh*)", "Bash(*night_watch.py*)"]
REALMS = {"auth", "payments", "wallet", "callbacks", "infrastructure", "errors", "other"}
EVIDENCE_KINDS = {"trace", "row", "identity", "metric", "log", "config"}
MAX_IDS, MAX_CONCLUSION = 4, 600
MAX_EVIDENCE_LINES, MAX_LABEL = 6, 80
STAFF_FIELDS, STAFF_ROLES = ("username", "name", "email"), ("admin", "agent")
EVIDENCE_ROLES = ("admin", "agent", "player", "service", "unknown")
EMAIL_RX = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
ICON = {"SUSPICIOUS": "🟡", "ALERT": "🚨"}
DOT = {"ALERT": "🔴", "SUSPICIOUS": "🟡"}

STR = {
    "en": {
        "day": "Night Watch {date}",
        "gap": "Missed slots, not replayed: {slots}",
        "failed": "⚠️ *FAILED {hm}* — {reason}",
        "ok": "✅ OK {hm} — {headline}",
        "gaps": "not checked: {n}",
        "unchecked": "Not checked",
        "conclusion": "Conclusion",
        "learning": "(baseline learning)",
        "repeat": "ALERT repeat",
        "blind": "🙈 *BLIND {hm}* — re-authenticate: {reauth}",
        "resolved_only": "only cases already marked resolved ({n})",
        "resolved": "_Already marked resolved, not repeated: {n}_",
    },
    "th": {
        "day": "Night Watch {date}",
        "gap": "ข้ามรอบตรวจ ไม่ย้อนตรวจ: {slots}",
        "failed": "⚠️ *FAILED {hm}* — รอบนี้ไม่ได้ผลตรวจ: {reason}",
        "ok": "✅ OK {hm} — {headline}",
        "gaps": "ตรวจไม่ได้: {n}",
        "unchecked": "ตรวจไม่ได้",
        "conclusion": "สรุป",
        "learning": "(กำลังเรียน baseline)",
        "repeat": "ALERT ซ้ำ",
        "blind": "🙈 *BLIND {hm}* — ต้องยืนยันตัวตนใหม่: {reauth}",
        "resolved_only": "มีแต่เคสที่ตรวจแล้วว่าปลอดภัย ({n})",
        "resolved": "_เคสที่ตรวจแล้วว่าปลอดภัย ไม่แจ้งซ้ำ: {n}_",
    },
}


class ConfigError(Exception):
    pass


# ── config (local-first, whole `night_watch:` block wins, like the tracker/planning blocks) ──────
def _clean(raw):
    v = re.sub(r"\s+#.*$", "", raw).strip()
    return v if v.startswith("[") else v.strip("'\"")


def _files():
    return [ROOT / "workspace.config.local.yaml", ROOT / "workspace.config.yaml"]


def _block(path, name):
    if not path.is_file():
        return None
    out = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^[A-Za-z_]\w*:", line):
            if out is not None:
                break
            if line.startswith(name + ":"):
                out = {}
            continue
        m = re.match(r"^\s+([A-Za-z_]\w*):\s*(.*)$", line)
        if out is not None and m:
            out[m[1]] = _clean(m[2])
    return out


def _scalar(key):
    for path in _files():
        if path.is_file():
            for line in path.read_text(encoding="utf-8").splitlines():
                m = re.match(rf"^{key}:\s*(.*)$", line)
                if m and _clean(m[1]):
                    return _clean(m[1])
    return ""


def parse_hm(s):
    m = re.fullmatch(r"([01]\d|2[0-3]):([0-5]\d)", s)
    if not m:
        raise ConfigError(f"active_hours: '{s}' is not HH:MM")
    return int(m[1]) * 60 + int(m[2])


def load_config():
    raw = {}
    for path in _files():
        raw = _block(path, "night_watch")
        if raw is not None:
            break
    raw = raw or {}
    try:
        interval = int(raw.get("interval_minutes", "60"))
        timeout = int(raw.get("tick_timeout_minutes", "20"))
    except ValueError:
        raise ConfigError("interval_minutes and tick_timeout_minutes must be integers")
    if not (1 <= interval <= 1440 and 1440 % interval == 0):
        raise ConfigError(f"interval_minutes: {interval} must be 1..1440 and divide 1440")
    if not (1 <= timeout <= interval):
        raise ConfigError(f"tick_timeout_minutes: {timeout} must be 1..interval_minutes")
    m = re.fullmatch(r"([^-]+)-([^-]+)", raw.get("active_hours", "00:00-23:59"))
    if not m:
        raise ConfigError("active_hours must be HH:MM-HH:MM")
    try:
        mention = json.loads(raw.get("mention", "[]").replace("'", '"'))
    except ValueError:
        raise ConfigError("mention must be a list such as [\"U00000000000\"]")
    if not isinstance(mention, list) or not all(isinstance(x, str) for x in mention):
        raise ConfigError("mention must be a list of strings")
    channel = raw.get("channel", "")
    if not channel:
        raise ConfigError("night_watch.channel is not set")
    lang = _scalar("case_report_language") or _scalar("language") or "en"
    return {
        "channel": channel, "interval": interval, "timeout": timeout, "mention": mention,
        "playbook": raw.get("playbook", "docs/night-watch/playbook.md"),
        "hours": (parse_hm(m[1]), parse_hm(m[2])), "lang": lang,
        "active": m[0],
    }


# ── slots ────────────────────────────────────────────────────────────────────────────────────────
def now():
    env = os.environ.get("NIGHT_WATCH_NOW")
    return datetime.fromisoformat(env) if env else datetime.now()


def slot_of(t, cfg):
    mins = t.hour * 60 + t.minute
    return t.replace(hour=0, minute=0, second=0, microsecond=0) + timedelta(
        minutes=mins // cfg["interval"] * cfg["interval"])


def is_active(slot, cfg):
    s, e = cfg["hours"]
    m = slot.hour * 60 + slot.minute
    return s <= m <= e if s <= e else m >= s or m <= e


def next_slot(t, cfg):
    """First active slot starting strictly after t."""
    s = slot_of(t, cfg)
    for _ in range(2 * 1440):
        s += timedelta(minutes=cfg["interval"])
        if is_active(s, cfg):
            return s
    raise ConfigError("active_hours leaves no active slot")


def missed_slots(last, slot, cfg):
    out, s = [], last + timedelta(minutes=cfg["interval"])
    while s < slot:
        if is_active(s, cfg):
            out.append(s)
        s += timedelta(minutes=cfg["interval"])
    return out


# ── state, log ───────────────────────────────────────────────────────────────────────────────────
def fresh_state():
    return {"version": 1, "ticks_ok": 0, "last_slot": None, "last_success_slot": None,
            "day": {"date": None, "parent_ts": None}, "blind": {"active": False},
            "failures": {"consecutive": 0}, "baselines": {}, "notes": []}


def say(line):
    # stderr: stdout stays machine-readable (`plan`); flush: prompt under a process manager.
    print(f"{now():%Y-%m-%d %H:%M:%S} night-watch: {line}", file=sys.stderr, flush=True)


def tlog(slot, status, text="", ts="", note=""):
    NWDIR.mkdir(parents=True, exist_ok=True)
    text = " ".join(str(text).split())[:300]
    line = f"{slot.isoformat()} {status} {text}{f' ts={ts}' if ts else ''}"
    with open(NWDIR / "ticks.log", "a", encoding="utf-8") as f:
        f.write(line + "\n")
    say(line + (f" ({note})" if note else ""))


def load_state(slot):
    path = NWDIR / "state.json"
    if not path.is_file():
        return fresh_state()
    try:
        st = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(st, dict) or st.get("version") != 1:
            raise ValueError("bad shape")
        return {**fresh_state(), **st}
    except ValueError as e:
        path.rename(NWDIR / f"state.json.corrupt-{slot.strftime('%Y%m%dT%H%M')}")
        tlog(slot, "STATE_RESET", f"corrupt state kept aside: {e}")
        return fresh_state()


def prune():
    """Delete regular files older than RETAIN_DAYS in NWDIR and NWDIR/verdicts. Never follows a link."""
    cutoff = now().timestamp() - RETAIN_DAYS * 86400
    for d in (NWDIR, NWDIR / "verdicts"):
        if d.is_symlink() or not d.is_dir():
            continue
        for p in d.iterdir():
            try:
                st = p.lstat()
                if p.name not in KEEP and stat.S_ISREG(st.st_mode) and st.st_mtime < cutoff:
                    p.unlink()
            except OSError:
                pass  # retention is housekeeping: never fail a Tick over it


def save_json(name, obj):
    NWDIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=NWDIR, prefix=f".{name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2)
        os.replace(tmp, NWDIR / name)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def save_state(st):
    save_json("state.json", st)


# ── Verdict ──────────────────────────────────────────────────────────────────────────────────────
def pii_patterns():
    path = ROOT / "scripts" / "lib" / "pii-patterns.txt"
    out = []
    for line in path.read_text(encoding="utf-8").splitlines():
        parts = line.split("\t")
        if line.startswith("#") or len(parts) != 3:
            continue
        try:
            out.append((parts[0], re.compile(parts[2], re.I if parts[1] == "ci" else 0)))
        except re.error:
            continue
    if not out:
        raise OSError("no PII patterns loaded")
    return out


def _staff_strings(v):
    """Staff identity fields: scanned with every detector except e-mail (the one carve-out)."""
    for f in v["findings"]:
        for e in f["evidence"]:
            for k in STAFF_FIELDS:
                if k in e:
                    yield e[k]


def _is_staff(e):
    return e.get("kind") == "identity" and e.get("role") in STAFF_ROLES


def _clean_evidence(e):
    """Type-check the descriptive fields in place; False when one is malformed."""
    for k in ("label", "target", "table", "role") + STAFF_FIELDS:
        if k in e and not isinstance(e[k], str):
            return False
    if "role" in e and e["role"] not in EVIDENCE_ROLES:
        return False
    if "label" in e:
        e["label"] = e["label"][:MAX_LABEL]
    if not _is_staff(e):
        for k in STAFF_FIELDS:
            e.pop(k, None)
    elif "email" in e and not EMAIL_RX.fullmatch(e["email"]):
        del e["email"]
    return True


def _posted_strings(v):
    yield v["headline"]
    yield v.get("conclusion") or ""
    yield v.get("reauth") or ""
    for g in v.get("gaps", []):
        yield g["reason"]
    for f in v["findings"]:
        yield f["title"]
        yield str(f.get("rule_id") or "")
        for e in f["evidence"]:
            yield e["id"]
            for k in ("target", "label", "table"):
                yield e.get(k, "")


def validate(v):
    """Return an error string, or None when the Verdict is acceptable."""
    if not isinstance(v, dict):
        return "invalid: not an object"
    if v.get("state") not in ("OK", "SUSPICIOUS", "ALERT", "BLIND"):
        return "invalid: state"
    h = v.get("headline")
    if not isinstance(h, str) or not h.strip() or len(h) > 200 or "\n" in h:
        return "invalid: headline"
    fs, gaps = v.get("findings"), v.get("gaps", [])
    if not isinstance(fs, list) or not isinstance(gaps, list):
        return "invalid: findings/gaps"
    for f in fs:
        if not isinstance(f, dict) or f.get("rule") not in ("fixed", "count", "lead") \
                or f.get("severity") not in ("SUSPICIOUS", "ALERT") or f.get("realm") not in REALMS \
                or not isinstance(f.get("title"), str) or not f["title"].strip():
            return "invalid: finding"
        ev = f.get("evidence")
        if not isinstance(ev, list) or not ev or not all(
                isinstance(e, dict) and e.get("kind") in EVIDENCE_KINDS
                and isinstance(e.get("id"), str) and e["id"].strip() for e in ev):
            return "invalid: finding without evidence id"
        if not all(_clean_evidence(e) for e in ev):
            return "invalid: evidence fields"
    if not all(isinstance(g, dict) and isinstance(g.get("reason"), str) and isinstance(g.get("realm"), str)
               for g in gaps):
        return "invalid: gaps"
    worst = "ALERT" if any(f["severity"] == "ALERT" for f in fs) else "SUSPICIOUS" if fs else "OK"
    if v["state"] in ("SUSPICIOUS", "ALERT") and v["state"] != worst:
        return "invalid: state does not match highest finding severity"
    if v["state"] == "OK" and fs:
        return "invalid: OK with findings"
    if v["state"] == "BLIND" and not ((v.get("reauth") or "").strip() or gaps):
        return "invalid: BLIND without reauth or gaps"
    if v["state"] != "OK" and not (v.get("brief_en") or "").strip():
        return "invalid: brief_en"
    # Posted prose is trimmed, never a reason to drop a Verdict. brief_en is kept in verdicts/, not posted.
    c = v.get("conclusion")
    v["conclusion"] = c.strip()[:MAX_CONCLUSION] if isinstance(c, str) else ""
    up = v.get("state_update")
    if up is not None:
        b = up.get("baselines", {}) if isinstance(up, dict) else None
        n = up.get("notes", []) if isinstance(up, dict) else None
        if not isinstance(b, dict) or len(b) > MAX_BASELINES or not all(
                isinstance(x, dict) and isinstance(x.get("value"), (int, float))
                and not isinstance(x["value"], bool) for x in b.values()):
            return "invalid: state_update.baselines"
        if not isinstance(n, list) or not all(isinstance(x, str) for x in n):
            return "invalid: state_update.notes"
        # Notes are memory, not report: an overlong one is trimmed, never a reason to drop a Verdict.
        up["notes"] = [x[:MAX_NOTE_LEN] for x in n[:MAX_NOTES]]
    try:
        pats = pii_patterns()
    except OSError:
        return "pii-patterns-missing"
    for strings, skip in ((_posted_strings(v), ""), (_staff_strings(v), "email")):
        for s in strings:
            for cat, rx in pats:
                if cat != skip and rx.search(s):
                    return f"pii-in-verdict ({cat})"
    return None


def extract_verdict(stdout, rc):
    """(verdict, None) or (None, reason)."""
    try:
        out = json.loads(stdout)
    except ValueError:
        return None, "unparseable"
    if rc != 0 or not isinstance(out, dict) or out.get("is_error"):
        return None, "agent-error"
    if isinstance(out.get("structured_output"), dict):
        return out["structured_output"], None
    res = out.get("result")
    if not isinstance(res, str):
        return None, "unparseable"
    blocks = re.findall(r"```json\s*(.*?)```", res, re.S)
    for cand in ([blocks[-1]] if blocks else []) + [res]:
        try:
            return json.loads(cand), None
        except ValueError:
            continue
    return None, "unparseable"


# ── agent launch ─────────────────────────────────────────────────────────────────────────────────
def window_start(cfg, state, slot):
    last = state["last_success_slot"]
    start = datetime.fromisoformat(last) - timedelta(minutes=10) if last else \
        slot - timedelta(minutes=cfg["interval"] + 10)
    return max(start, slot - timedelta(hours=6))


def build_prompt(cfg, state, slot, t, res=()):
    ok = state["ticks_ok"]
    start = window_start(cfg, state, slot)
    sub = {
        "LANGUAGE_DIRECTIVE": f"LANGUAGE_DIRECTIVE: OUTPUT LANGUAGE = {cfg['lang']} "
                              "(case-report prose: headline and finding titles; brief_en stays English)",
        "PLAYBOOK": cfg["playbook"],
        "SLOT": slot.astimezone().isoformat(),
        "WINDOW_START": start.astimezone().isoformat(),
        "WINDOW_END": t.astimezone().isoformat(),
        "TICK_NUMBER": str(ok),
        "LEARNING": "baseline learning: count-based findings are labelled and mention nobody"
                    if ok < LEARN_TICKS else "baselines learned",
        "STATE": json.dumps({"baselines": state["baselines"], "notes": state["notes"]}, indent=1),
        "RESOLVED": json.dumps(
            [{**{k: r.get(k) for k in ("id", "realm", "rule_id", "severity", "note", "expires_at")},
              "evidence": r["evidence"][:8]} for r in res], indent=1) if res else "none",
        "SCHEMA": (HERE / "verdict.schema.json").read_text(encoding="utf-8"),
    }
    text = (HERE / "prompt.md").read_text(encoding="utf-8")
    for k, v in sub.items():
        text = text.replace("{{" + k + "}}", v)
    return text


def launch(cfg, prompt):
    """(stdout, rc) or (None, reason)."""
    claude = os.environ.get("NIGHT_WATCH_CLAUDE", "claude")
    argv = [claude, "-p", prompt, "--agent", "oncall", "--output-format", "json",
            "--json-schema", (HERE / "verdict.schema.json").read_text(encoding="utf-8"),
            "--disallowedTools", *DISALLOW, f"Edit(/{NWDIR}/**)", f"Write(/{NWDIR}/**)"]
    secs = float(os.environ.get("NIGHT_WATCH_TIMEOUT_SEC") or cfg["timeout"] * 60)
    try:
        p = subprocess.Popen(argv, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True,
                             env={**os.environ, "STAGEHAND": "off"})
    except OSError as e:
        return None, f"claude-missing ({e.strerror})"
    try:
        out, err = p.communicate(timeout=secs)
    except subprocess.TimeoutExpired:
        _kill(p)
        return None, f"timeout after {secs:g}s"
    except BaseException:
        _kill(p)
        raise
    if err.strip() and p.returncode != 0:
        (NWDIR / "agent.stderr").write_text(err[-RAW_CAP:], encoding="utf-8")
    return (out, p.returncode)


def _kill(p):
    for sig, wait in ((signal.SIGTERM, 10), (signal.SIGKILL, 5)):
        try:
            os.killpg(p.pid, sig)
            p.communicate(timeout=wait)
            return
        except ProcessLookupError:
            return
        except subprocess.TimeoutExpired:
            continue


def prod_allowed():
    env = os.environ.get("NIGHT_WATCH_PROD_ALLOWED")
    if env is not None:
        return env == "1"
    sys.path.insert(0, str(ROOT / "scripts" / "lib"))
    try:
        import triage_policy
        return triage_policy.prod_allowed()
    except Exception:
        return False


# ── posting ──────────────────────────────────────────────────────────────────────────────────────
class Poster:
    def __init__(self, cfg, state, slot):
        self.cfg, self.state, self.slot, self.t = cfg, state, slot, STR.get(cfg["lang"], STR["en"])
        self.hm = slot.strftime("%H:%M")
        self.mentions = " ".join(f"<@{m}>" for m in cfg["mention"])
        self.err = ""
        self.where = ""

    def post(self, text, thread=None, need_ts=False, spare=()):
        """Return the posted ts ('' when posted without one), or None when the post failed.
        spare: exact values the PII mask must leave alone in THIS post (staff names); every other post passes none."""
        argv = [str(ROOT / "scripts" / "notify" / "send.sh"), "--channel", self.cfg["channel"]]
        if thread:
            argv += ["--thread-ts", thread]
        try:
            r = subprocess.run(argv, input=text, capture_output=True, text=True, timeout=120,
                               env={**os.environ, "PII_GATE": "on", "PII_SPARE": "\n".join(spare)})
        except (OSError, subprocess.TimeoutExpired) as e:
            return self._fail(str(e))
        if r.returncode != 0:
            return self._fail(r.stderr.strip() or r.stdout.strip() or f"send.sh exit {r.returncode}")
        ts = next((ln[3:] for ln in r.stdout.splitlines() if ln.startswith("ts=")), "")
        if need_ts and not ts:
            return self._fail("send output has no ts= — threading needs SLACK_BOT_TOKEN in the notify adapter")
        return ts

    def _fail(self, why):
        self.err = why
        tlog(self.slot, "POST_FAILED", why.splitlines()[0] if why else "unknown")
        return None

    def parent(self):
        day = self.state["day"]
        if day["date"] != self.slot.date().isoformat() or not day["parent_ts"] \
                or day.get("channel") != self.cfg["channel"]:
            ts = self.post(self.t["day"].format(date=self.slot.date().isoformat()), need_ts=True)
            day.update(date=self.slot.date().isoformat(), parent_ts=ts or None, channel=self.cfg["channel"])
        return day["parent_ts"]

    def reply(self, text):
        self.where = "thread"
        for attempt in (0, 1):
            parent = self.parent()
            if not parent:
                return None
            ts = self.post(text, parent)
            if ts is not None or attempt or "thread_not_found" not in self.err:
                return ts
            self.state["day"]["parent_ts"] = None

    def top(self, text, spare=()):
        self.where = "top-level"
        return self.post(text, spare=spare)

    def gap(self, missed):
        shown = ", ".join(s.strftime("%H:%M") for s in missed[:24]) + (
            f" (+{len(missed) - 24})" if len(missed) > 24 else "")
        self.reply(self.t["gap"].format(slots=shown))
        tlog(self.slot, "GAP", shown)


def _code(s):
    return "`" + s.replace("`", "'") + "`"


def _esc(s):
    """Slack mrkdwn control characters in agent-authored text."""
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def evidence_line(e, links):
    """One quoted line: what the item is, where it lives, and its id (a link for a trace when known)."""
    kind, eid = e["kind"], e["id"]
    staff = _is_staff(e)
    head = e["role"] if kind == "identity" and e.get("role") else kind
    if e.get("table"):
        head += f" {_code(_esc(e['table']))}"
    if e.get("target"):
        head += f" @ {_esc(e['target'])}"
    if e.get("label"):
        head += f" — {_esc(e['label'])}"
    ref = f"<{links[eid]}|{_esc(eid)}>" if kind == "trace" and eid in links else _code(_esc(eid))
    extra = "".join(f" · {_esc(e[k])}" for k in STAFF_FIELDS if staff and e.get(k))
    return f"> • {head}: {ref}{extra}"


def finding_lines(findings, learning, t, links=None):
    """One numbered block per finding: severity, realm and rule; the title; up to MAX_EVIDENCE_LINES items."""
    lines = []
    for i, f in enumerate(findings, 1):
        ev = f["evidence"]
        more = [f"> +{len(ev) - MAX_EVIDENCE_LINES}"] if len(ev) > MAX_EVIDENCE_LINES else []
        tag = f" {t['learning']}" if learning and f["rule"] == "count" else ""
        rule = _code(str(f.get("rule_id") or f["rule"]))
        lines += ["", f"*{i}.* {DOT[f['severity']]} *{f['realm']}* · {rule}{tag}", f["title"],
                  *(evidence_line(e, links or {}) for e in ev[:MAX_EVIDENCE_LINES]), *more]
    return lines


def _posted_evidence(findings):
    return [e for f in findings for e in f["evidence"][:MAX_EVIDENCE_LINES]]


def ui_links(findings):
    """{trace id: URL} from the observability adapter; {} on any failure, never raises."""
    ids = [e["id"] for e in _posted_evidence(findings) if e["kind"] == "trace"]
    if not ids:
        return {}
    try:
        r = subprocess.run([str(ROOT / "scripts" / "observability" / "ui-url.sh"), "trace", *ids],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return {}
    lines = r.stdout.splitlines()
    if r.returncode != 0 or len(lines) != len(ids):
        return {}
    return {i: u for i, u in zip(ids, lines) if u.startswith("https://")}


def staff_values(findings):
    return [e[k] for e in _posted_evidence(findings) if _is_staff(e) for k in STAFF_FIELDS if e.get(k)]


def deliver(poster, v, st):
    """Post a valid Verdict; update counters in st. Returns the ts logged."""
    t, hm, state = poster.t, poster.hm, v["state"]
    learning = st["ticks_ok"] < LEARN_TICKS
    st["failures"]["consecutive"] = 0
    if state == "BLIND":
        text = t["blind"].format(hm=hm, reauth=v.get("reauth") or v["headline"])
        gaps = [f"• {g['realm']}: {g['reason']}" for g in v.get("gaps", [])]
        if st["blind"]["active"]:
            return poster.reply("\n".join([text, *gaps]))
        st["blind"]["active"] = True
        return poster.top("\n".join([f"{text} {poster.mentions}".strip(), *gaps]))
    st["blind"]["active"] = False
    st["ticks_ok"] += 1
    if state == "OK":
        extra = f" ({t['gaps'].format(n=len(v['gaps']))})" if v.get("gaps") else ""
        head = t["resolved_only"].format(n=len(v["suppressed"])) if v.get("suppressed") else v["headline"]
        return poster.reply(t["ok"].format(hm=hm, headline=head) + extra)
    suppress = learning and all(f["rule"] == "count" for f in v["findings"])
    who = "" if suppress else poster.mentions
    counts = " · ".join(f"{DOT[s]} {s} {n}" for s in ("ALERT", "SUSPICIOUS")
                        if (n := sum(f["severity"] == s for f in v["findings"])))
    lines = [f"{ICON[state]} *{state} {hm}* {who}".strip(), f"*{v['headline']}*", counts,
             *finding_lines(v["findings"], learning, t, ui_links(v["findings"])), ""]
    if v.get("conclusion"):
        lines.append(f"*{t['conclusion']}:* {v['conclusion']}")
    if v.get("suppressed"):
        lines.append(t["resolved"].format(n=len(v["suppressed"])))
    if v.get("gaps"):
        lines.append(f"_{t['unchecked']}:_ " + ", ".join(sorted({g["realm"] for g in v["gaps"]})))
    ts = poster.top("\n".join(lines).rstrip(), spare=staff_values(v["findings"]))
    if state == "ALERT" and not suppress:
        time.sleep(float(os.environ.get("NIGHT_WATCH_ALERT_REPEAT_SEC", "60")))
        poster.top(f"{ICON[state]} *{t['repeat']} {hm}* {who}".strip() + f"\n{v['headline']}")
    return ts


# ── tick ─────────────────────────────────────────────────────────────────────────────────────────
def tick(cfg):
    t = now()
    slot = slot_of(t, cfg)
    if not is_active(slot, cfg):
        tlog(slot, "OUTSIDE", "outside active_hours")
        return 0
    NWDIR.mkdir(parents=True, exist_ok=True)
    lock = open(NWDIR / "tick.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        tlog(slot, "SKIPPED", "previous Tick still holds the lock")
        return 0
    try:
        return _tick_locked(cfg, t, slot)
    finally:
        prune()
        lock.close()


def _note(poster, ts, t0):
    # ts None = post failed; "" = posted without a ts, so test `is None`, never falsiness.
    d = int(time.monotonic() - t0)
    return f"took {d // 60}m{d % 60:02d}s, {'not posted' if ts is None else 'posted ' + poster.where}"


def _tick_locked(cfg, t, slot):
    st = load_state(slot)
    if st["last_slot"] and slot <= datetime.fromisoformat(st["last_slot"]):
        tlog(slot, "SKIPPED", "already-ran")
        return 0
    t0 = time.monotonic()
    say(f"{slot.isoformat()} START window {window_start(cfg, st, slot):%H:%M}-{t:%H:%M}, "
        f"timeout {cfg['timeout']} min")
    poster = Poster(cfg, st, slot)
    if st["last_slot"]:
        missed = missed_slots(datetime.fromisoformat(st["last_slot"]), slot, cfg)
        if missed:
            poster.gap(missed)

    verdict, raw, reason, res, dropped = None, "", "", [], 0
    playbook = ROOT / cfg["playbook"]
    if not prod_allowed():
        verdict = {"state": "BLIND", "headline": "production is not readable on this machine",
                   "findings": [], "gaps": [{"realm": "all", "reason": "triage.prod is off"}],
                   "reauth": "triage.prod is off on this machine", "brief_en":
                   "Night Watch could not read production: set triage.prod to true in the local config."}
    elif not playbook.is_file():
        reason = f"playbook-missing ({cfg['playbook']})"
    else:
        res = active(load_resolved())  # snapshot before the agent runs: nothing it does changes this Tick
        out, rc = launch(cfg, build_prompt(cfg, st, slot, t, res))
        if out is None:
            reason = rc
        else:
            raw = out
            verdict, reason = extract_verdict(out, rc)
            if verdict is not None:
                err = validate(verdict)
                if err:
                    verdict, reason = None, err
                elif verdict["state"] in ("SUSPICIOUS", "ALERT"):
                    dropped = apply_resolutions(verdict, res)

    stamp = slot.strftime("%Y%m%dT%H%M")
    (NWDIR / "verdicts").mkdir(exist_ok=True)
    vfile = NWDIR / "verdicts" / f"{stamp}.json"
    if verdict is not None:
        vfile.write_text(json.dumps(verdict, indent=2), encoding="utf-8")
        up = verdict.get("state_update")
        if up is not None and verdict["state"] != "BLIND":
            st["baselines"], st["notes"] = up.get("baselines", {}), up.get("notes", [])
        ts = deliver(poster, verdict, st)
        if verdict["state"] != "BLIND":
            st["last_success_slot"] = slot.isoformat()
        tlog(slot, verdict["state"], verdict["headline"] + (f" (resolved earlier: {dropped})" if dropped else ""),
             ts or "", note=_note(poster, ts, t0))
    else:
        vfile.write_text(raw[:RAW_CAP] or reason, encoding="utf-8")
        st["failures"]["consecutive"] += 1
        text = poster.t["failed"].format(hm=poster.hm, reason=reason)
        if st["failures"]["consecutive"] >= 2 and poster.mentions:
            text = f"{poster.mentions} {text}"
        ts = poster.reply(text)
        tlog(slot, "FAILED", reason, ts or "", note=_note(poster, ts, t0))
    st["last_slot"] = slot.isoformat()
    save_state(st)
    return 0


# ── loop ─────────────────────────────────────────────────────────────────────────────────────────
def preflight(cfg):
    missing = []
    if not (ROOT / cfg["playbook"]).is_file():
        missing.append(f"playbook not found: {cfg['playbook']}")
    if not os.access(ROOT / "scripts" / "notify" / "send.sh", os.X_OK):
        missing.append("scripts/notify/send.sh is not executable")
    claude = os.environ.get("NIGHT_WATCH_CLAUDE", "claude")
    if not any(os.access(Path(d) / claude, os.X_OK) for d in os.environ.get("PATH", "").split(":")) \
            and not os.access(claude, os.X_OK):
        missing.append("claude is not on PATH")
    return missing


def loop(cfg):
    missing = preflight(cfg)
    if missing:
        print("night-watch: preflight failed:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 2
    say(f"watch started: channel {cfg['channel']}, every {cfg['interval']} min, active {cfg['active']}")
    while True:
        nxt = next_slot(now(), cfg)
        say(f"next Tick at {nxt:%Y-%m-%d %H:%M}")
        # Wall-clock check at least every 30 s: time.sleep pauses while the machine sleeps.
        while now() < nxt:
            time.sleep(max(0.0, min(30.0, (nxt - now()).total_seconds())))
        try:
            tick(cfg)
        except Exception as e:  # never let one Tick end the watch
            tlog(nxt, "FAILED", f"internal error: {e}")


# ── follow-up ──────────────────────────────────────────────────────────────────
def _print_verdict(v):
    for k in ("state", "headline", "conclusion", "brief_en"):
        if v.get(k):
            print(f"{k}: {v[k]}")
    for i, f in enumerate(v.get("findings") or [], 1):
        print(f"{i}. {f.get('severity')} {f.get('realm')} {f.get('rule_id') or f.get('rule')}: {f.get('title')}")
        for e in f.get("evidence") or []:
            print(f"   {e.get('kind')} {e.get('id')}" + "".join(
                f" {k}={e[k]}" for k in ("target", "label", "table", "role", *STAFF_FIELDS) if e.get(k)))
    for s in v.get("suppressed") or []:
        f = s.get("finding") or {}
        print(f"resolved earlier ({s.get('resolution')}): {f.get('severity')} {f.get('realm')} "
              f"{f.get('rule_id') or f.get('rule')}: {f.get('title')}")
        for e in f.get("evidence") or []:
            print(f"   {e.get('kind')} {e.get('id')}")
    for g in v.get("gaps") or []:
        print(f"gap {g.get('realm')}: {g.get('reason')}")


def _find_verdicts(arg):
    """Verdict files for a slot argument, newest first; None when the argument is malformed."""
    files = sorted((NWDIR / "verdicts").glob("*.json"))
    if arg == "latest":
        return files[-1:]
    if re.fullmatch(r"\d{2}:\d{2}", arg):
        return [f for f in files if f.stem.endswith(arg.replace(":", ""))][::-1]
    if re.fullmatch(r"\d{8}T\d{4}", arg):
        return [f for f in files if f.stem == arg]
    return None


def brief(arg):
    """Print a Verdict file for a follow-up session. Read-only: no config, lock, state or write."""
    hit = _find_verdicts(arg)
    if hit is None:
        print("usage: night_watch.py brief [latest|HH:MM|YYYYMMDDTHHMM]", file=sys.stderr)
        return 2
    if not hit:
        print(f"night-watch: no Verdict for {arg} under {NWDIR / 'verdicts'}", file=sys.stderr)
        return 1
    f = hit[0]
    print(f"file: {f}")
    if len(hit) > 1:
        print("other days: " + ", ".join(h.stem for h in hit[1:]))
    text = f.read_text(encoding="utf-8", errors="replace")
    try:
        v = json.loads(text)
    except ValueError:
        v = None
    if not (isinstance(v, dict) and "state" in v):
        v, _ = extract_verdict(text, 0)
        if isinstance(v, dict) and "state" in v:
            print("note: FAILED Tick — Verdict recovered from raw agent output, not validated")
        else:
            print("note: FAILED Tick — no Verdict")
            print(text[:2000])
            return 0
    _print_verdict(v)
    return 0


# ── resolved cases ───────────────────────────────────────────────────────────────────────────────
def utcnow():
    return now().astimezone(timezone.utc).replace(microsecond=0)


def load_resolved(aside=True):
    """{"version":1,"resolutions":[...]}; corrupt -> kept as resolved.json.corrupt-<time>, empty."""
    path = NWDIR / "resolved.json"
    empty = {"version": 1, "resolutions": []}
    if not path.is_file():
        return empty
    try:
        r = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(r, dict) or r.get("version") != 1 or not isinstance(r.get("resolutions"), list) \
                or not all(isinstance(x, dict) and isinstance(x.get("evidence"), list) for x in r["resolutions"]):
            raise ValueError("bad shape")
        return r
    except ValueError:
        if aside:
            try:
                path.rename(NWDIR / f"resolved.json.corrupt-{now():%Y%m%dT%H%M%S}")
            except OSError:
                pass  # a concurrent reader already moved it
        return empty


def active(res):
    t = utcnow()
    out = []
    for r in res["resolutions"]:
        try:
            if datetime.fromisoformat(r["expires_at"]) > t:
                out.append(r)
        except (KeyError, TypeError, ValueError):
            continue  # an unreadable entry never suppresses
    return out


def _rule_key(f):
    # A lead's rule_id is free text the agent rewords; its evidence is its identity.
    return "lead" if f.get("rule") == "lead" else str(f.get("rule_id") or f.get("rule") or "").strip().casefold()


def matches(f, r):
    """Same realm and rule, severity not higher, every evidence id already inside the resolved set."""
    return f["realm"] == r.get("realm") and _rule_key(f) == _rule_key(r) \
        and RANK[f["severity"]] <= RANK.get(r.get("severity"), 0) \
        and {e["id"].strip() for e in f["evidence"]} <= set(r["evidence"])


def apply_resolutions(v, res):
    """Drop findings an active resolution covers; recompute state. Returns how many were dropped."""
    keep, gone = [], []
    for f in v["findings"]:
        r = next((r for r in res if matches(f, r)), None)
        if r is None:
            keep.append(f)
        else:
            gone.append({"resolution": r["id"], "finding": f})
    if gone:
        v["findings"], v["suppressed"] = keep, gone
        v["state"] = "ALERT" if any(f["severity"] == "ALERT" for f in keep) else "SUSPICIOUS" if keep else "OK"
    return len(gone)


def _err(msg):
    print(f"night-watch: {msg}", file=sys.stderr)


def resolve(argv):
    ap = argparse.ArgumentParser(prog="run.sh resolve")
    ap.add_argument("slot")
    ap.add_argument("n", type=int)
    ap.add_argument("--note", required=True)
    ap.add_argument("--alert", action="store_true")
    a = ap.parse_args(argv)  # argparse exits 2 with usage on bad args
    note = a.note.strip()
    if not note or "\n" in a.note.strip() or len(note) > MAX_RES_NOTE:
        _err(f"--note must be one line, 1..{MAX_RES_NOTE} characters")
        return 2
    try:
        pats = pii_patterns()
    except OSError:
        _err("pii-patterns-missing")
        return 2
    for cat, rx in pats:
        if rx.search(note):
            _err(f"note looks like personal data ({cat}); identifiers only")
            return 2
    hits = _find_verdicts(a.slot)
    if hits is None:
        _err("usage: run.sh resolve <latest|HH:MM|YYYYMMDDTHHMM> <n> --note \"<one line>\" [--alert]")
        return 2
    if not hits:
        _err(f"no Verdict for {a.slot} under {NWDIR / 'verdicts'}")
        return 1
    f0 = hits[0]
    try:
        v = json.loads(f0.read_text(encoding="utf-8", errors="replace"))
    except ValueError:
        v = None
    if not (isinstance(v, dict) and isinstance(v.get("findings"), list)):
        _err(f"{f0.stem} is a FAILED Tick: nothing to resolve")
        return 1
    if not 1 <= a.n <= len(v["findings"]):
        _err(f"no finding {a.n} in {f0.stem} (it has {len(v['findings'])})")
        return 1
    f = v["findings"][a.n - 1]
    if f["severity"] == "ALERT" and not a.alert:
        _err(f"finding {a.n} is ALERT: pass --alert only when a person in the thread asked to resolve it")
        return 2
    rid = f"{f0.stem}-{a.n}"
    NWDIR.mkdir(parents=True, exist_ok=True)
    with open(NWDIR / "resolved.lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)  # blocking; held for milliseconds, not tick.lock's 20 minutes
        live = active(load_resolved())
        old = next((r for r in live if r["id"] == rid), None)
        if old:
            print(f"already resolved {rid} until {old['expires_at']}")
            return 0
        t = utcnow()
        days = AGG_DAYS if all(e["kind"] in AGGREGATE for e in f["evidence"]) else RESOLVE_DAYS
        new = {"id": rid, "slot": f0.stem, "finding": a.n, "realm": f["realm"], "rule": f["rule"],
               "rule_id": str(f.get("rule_id") or ""), "severity": f["severity"], "title": f["title"][:200],
               "evidence": [e["id"].strip() for e in f["evidence"]][:MAX_RES_IDS], "note": note,
               "resolved_at": t.isoformat(), "expires_at": (t + timedelta(days=days)).isoformat()}
        live.append(new)
        live.sort(key=lambda r: r.get("resolved_at", ""))
        save_json("resolved.json", {"version": 1, "resolutions": live[-MAX_RESOLVED:]})
    print(f"resolved {rid} until {new['expires_at']} (file: {f0})")
    print(f"undo: scripts/night-watch/run.sh unresolve {rid}")
    return 0


def unresolve(argv):
    if len(argv) != 1 or not re.fullmatch(r"\d{8}T\d{4}-\d+", argv[0]):
        _err("usage: run.sh unresolve <id>  (id looks like 20260101T1000-1)")
        return 2
    NWDIR.mkdir(parents=True, exist_ok=True)
    with open(NWDIR / "resolved.lock", "w") as lk:
        fcntl.flock(lk, fcntl.LOCK_EX)
        live = active(load_resolved())
        rest = [r for r in live if r["id"] != argv[0]]
        if len(rest) == len(live):
            _err(f"no active resolution {argv[0]}")
            return 1
        save_json("resolved.json", {"version": 1, "resolutions": rest})
    print(f"unresolved {argv[0]}")
    return 0


def list_resolved():
    live = active(load_resolved(aside=False))
    for r in live:
        ids = r["evidence"]
        more = f" +{len(ids) - MAX_IDS}" if len(ids) > MAX_IDS else ""
        print(f"{r['id']}  {r.get('severity')} {r.get('realm')} {r.get('rule_id') or r.get('rule')}  "
              f"until {r['expires_at']}  ids: {' '.join(ids[:MAX_IDS])}{more}  note: {r.get('note')}")
    if not live:
        print("no active resolutions")
    return 0


def main(argv):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd not in ("tick", "loop", "plan", "brief", "resolve", "unresolve", "resolved"):
        print(__doc__, file=sys.stderr)
        return 2
    if cmd == "brief":
        return brief(argv[2] if len(argv) > 2 else "latest")
    if cmd == "resolve":
        return resolve(argv[2:])
    if cmd == "unresolve":
        return unresolve(argv[2:])
    if cmd == "resolved":
        return list_resolved()
    if cmd in ("tick", "loop") and NWDIR.is_symlink():
        print("night-watch: agent_logs/night-watch is a link to another checkout; run the watch there", file=sys.stderr)
        return 2
    try:
        cfg = load_config()
        if cmd == "plan":
            s = slot_of(now(), cfg)
            print(f"slot={s.isoformat()} active={int(is_active(s, cfg))} next={next_slot(now(), cfg).isoformat()}")
            return 0
        if cmd == "tick":
            rc = tick(cfg)
            say(f"next Tick at {next_slot(now(), cfg):%Y-%m-%d %H:%M}")
            return rc
        return loop(cfg)
    except ConfigError as e:
        print(f"night-watch: config error: {e}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv))
