#!/usr/bin/env python3
"""Night Watch engine: one Tick per slot. The agent returns a Verdict; this script owns everything
else (validation, memory, threading, mentions, re-posts) and posts only through scripts/notify/.
See scripts/night-watch/README.md and docs/adr/0047-*.md.

  night_watch.py tick   run one Tick now and exit
  night_watch.py loop   wait for each slot, run a Tick, repeat
  night_watch.py plan   print the slot for now, whether it is active, and the next one
"""
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timedelta
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
NWDIR = ROOT / "agent_logs" / "night-watch"
LEARN_TICKS = 24
MAX_NOTES, MAX_NOTE_LEN, MAX_BASELINES = 50, 300, 200
RAW_CAP = 256 * 1024
DISALLOW = ["Bash(*scripts/notify/*)", "Bash(*scripts/tracker/*)", "Bash(*scripts/vcs/*)"]
REALMS = {"auth", "payments", "wallet", "callbacks", "infrastructure", "errors", "other"}
EVIDENCE_KINDS = {"trace", "row", "identity", "metric", "log", "config"}
MAX_IDS, MAX_CONCLUSION = 4, 600
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


def save_state(st):
    NWDIR.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=NWDIR, prefix=".state.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(st, f, indent=2)
        os.replace(tmp, NWDIR / "state.json")
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


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
            yield e.get("target", "")


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
    for s in _posted_strings(v):
        for cat, rx in pats:
            if rx.search(s):
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


def build_prompt(cfg, state, slot, t):
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
            "--disallowedTools", *DISALLOW]
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

    def post(self, text, thread=None, need_ts=False):
        """Return the posted ts ('' when posted without one), or None when the post failed."""
        argv = [str(ROOT / "scripts" / "notify" / "send.sh"), "--channel", self.cfg["channel"]]
        if thread:
            argv += ["--thread-ts", thread]
        try:
            r = subprocess.run(argv, input=text, capture_output=True, text=True, timeout=120,
                               env={**os.environ, "PII_GATE": "on"})
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

    def top(self, text):
        self.where = "top-level"
        return self.post(text)

    def gap(self, missed):
        shown = ", ".join(s.strftime("%H:%M") for s in missed[:24]) + (
            f" (+{len(missed) - 24})" if len(missed) > 24 else "")
        self.reply(self.t["gap"].format(slots=shown))
        tlog(self.slot, "GAP", shown)


def _code(s):
    return "`" + s.replace("`", "'") + "`"


def finding_lines(findings, learning, t):
    """One numbered block per finding: severity, realm and rule; the title; up to MAX_IDS evidence ids."""
    lines = []
    for i, f in enumerate(findings, 1):
        ids = [e["id"] for e in f["evidence"]]
        more = f" +{len(ids) - MAX_IDS}" if len(ids) > MAX_IDS else ""
        tag = f" {t['learning']}" if learning and f["rule"] == "count" else ""
        rule = _code(str(f.get("rule_id") or f["rule"]))
        lines += ["", f"*{i}.* {DOT[f['severity']]} *{f['realm']}* · {rule}{tag}", f["title"],
                  "> " + " ".join(_code(x) for x in ids[:MAX_IDS]) + more]
    return lines


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
        return poster.reply(t["ok"].format(hm=hm, headline=v["headline"]) + extra)
    suppress = learning and all(f["rule"] == "count" for f in v["findings"])
    who = "" if suppress else poster.mentions
    counts = " · ".join(f"{DOT[s]} {s} {n}" for s in ("ALERT", "SUSPICIOUS")
                        if (n := sum(f["severity"] == s for f in v["findings"])))
    lines = [f"{ICON[state]} *{state} {hm}* {who}".strip(), f"*{v['headline']}*", counts,
             *finding_lines(v["findings"], learning, t), ""]
    if v.get("conclusion"):
        lines.append(f"*{t['conclusion']}:* {v['conclusion']}")
    if v.get("gaps"):
        lines.append(f"_{t['unchecked']}:_ " + ", ".join(sorted({g["realm"] for g in v["gaps"]})))
    ts = poster.top("\n".join(lines).rstrip())
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

    verdict, raw, reason = None, "", ""
    playbook = ROOT / cfg["playbook"]
    if not prod_allowed():
        verdict = {"state": "BLIND", "headline": "production is not readable on this machine",
                   "findings": [], "gaps": [{"realm": "all", "reason": "triage.prod is off"}],
                   "reauth": "triage.prod is off on this machine", "brief_en":
                   "Night Watch could not read production: set triage.prod to true in the local config."}
    elif not playbook.is_file():
        reason = f"playbook-missing ({cfg['playbook']})"
    else:
        out, rc = launch(cfg, build_prompt(cfg, st, slot, t))
        if out is None:
            reason = rc
        else:
            raw = out
            verdict, reason = extract_verdict(out, rc)
            if verdict is not None:
                err = validate(verdict)
                if err:
                    verdict, reason = None, err

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
        tlog(slot, verdict["state"], verdict["headline"], ts or "", note=_note(poster, ts, t0))
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


def main(argv):
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    cmd = argv[1] if len(argv) > 1 else ""
    if cmd not in ("tick", "loop", "plan"):
        print(__doc__, file=sys.stderr)
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
