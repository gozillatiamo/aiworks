#!/usr/bin/env python3
"""One tool call in, one spoken Thai FACT out — the `max` narrator's source of lines.

    echo '<PostToolUse JSON>' | tool-fact.py            # → "info\tqueue.sh อ่านแล้ว 260 บรรทัด"
    tool-fact.py --selftest

Output is `<severity>\\t<line>`, severity `info` | `bad`, or NOTHING when the call is not worth
saying out loud. `bad` is what makes narrate.sh reach for the red cue and skip the rate floor.

WHY FACTS AND NOT THE ASSISTANT'S PROSE (which is what this replaces):

The narrator used to speak the sentence the assistant writes before a tool call — free, and true,
but it is an INTENTION ("อ่าน queue ก่อน แล้วค่อยแก้ cadence"). Research into how JARVIS actually
talks in the Iron Man films says intentions are the one thing he never voices: every line is a
state and a figure, spoken as it changes —

    "The armour is now at 92%."      "18,000 feet. 10,000 feet. 6,000 feet."
    "Thirteen, sir."                 "1974 Stark Expo model scan complete, sir."
    "Power: fifteen percent. Recommend you descend and re-charge, Sir."

Short (3–8 words), frequent, and always NEW information. A tool call plus its response is exactly
that: `tool_response` carries the figures — lines read, matches found, tests passed, exit status —
and a template turns them into one sentence with no model call, so this channel costs zero tokens
and cannot invent anything. If a figure is not in the payload it does not get said.

FORM: `[subject] [state] [figure]` — the file/command first, the Thai verb, then the number.
Identifiers, commands, paths and numerals stay Latin/Arabic (the workspace's English spine).
"""

from __future__ import annotations

import json
import os
import re
import sys

MAX_CHARS = 60          # ~4 s of Thai speech. JARVIS's lines are 3–8 words; so are these.

# Tools whose completion carries no news. Speaking these would turn the narrator into a
# metronome — the thing the deleted heartbeat was disliked for.
SKIP_TOOLS = {
    "ToolSearch", "TaskList", "TaskGet", "TaskOutput", "Monitor",
    "TodoWrite", "ReportFindings", "ExitPlanMode", "EnterPlanMode",
}


# ── helpers ───────────────────────────────────────────────────────────────────────────

def _text(resp) -> str:
    """The response as text, whatever shape the tool returned."""
    if isinstance(resp, str):
        return resp
    if isinstance(resp, dict):
        for k in ("stdout", "output", "content", "result", "text", "stderr"):
            v = resp.get(k)
            if isinstance(v, str) and v.strip():
                out = v
                if k == "stdout" and isinstance(resp.get("stderr"), str):
                    out += "\n" + resp["stderr"]
                return out
        # An error envelope with no textual payload has no CONTENT — dumping the JSON back would
        # make `{"is_error": true}` count as "1 line read", a figure about nothing.
        if any(resp.get(k) for k in ("is_error", "isError", "error")):
            return ""
        return json.dumps(resp, ensure_ascii=False)
    if isinstance(resp, list):
        return "\n".join(_text(x) for x in resp)
    return ""


def _lines(s: str) -> int:
    s = s.strip()
    return 0 if not s else s.count("\n") + 1


def _base(path: str) -> str:
    return os.path.basename(path.rstrip("/")) or path


def _cmd_head(cmd: str) -> str:
    """`cargo test --lib -p x` → "cargo test". The program plus its subcommand is what a person
    would name; the flags are what a machine would read out."""
    cmd = cmd.strip().split("&&")[0].split("|")[0].strip()
    parts = [p for p in re.split(r"\s+", cmd) if p and not p.startswith("-")]
    if not parts:
        return ""
    head = _base(parts[0])
    if len(parts) > 1 and re.fullmatch(r"[A-Za-z][\w.:-]*", parts[1]) and not parts[1].startswith("/"):
        head += " " + parts[1]
    return head[:28]


# ── test/lint figures, in the output of the runners this workspace actually uses ───────
# Each pattern is anchored on the runner's own summary line, so a figure is only ever spoken
# when the runner printed it. Order matters: the first match wins.
_TEST_PATTERNS = [
    # cargo: "test result: ok. 42 passed; 0 failed; 0 ignored"
    (r"test result:\s*(ok|FAILED)\.\s*(\d+)\s+passed;\s*(\d+)\s+failed", "cargo"),
    # jest/vitest: "Tests: 3 failed, 42 passed, 45 total"
    (r"Tests:\s*(?:(\d+)\s+failed,\s*)?(\d+)\s+passed", "jest"),
    # mocha/cypress: "42 passing" / "3 failing"
    (r"(\d+)\s+passing(?:.*?\n.*?(\d+)\s+failing)?", "mocha"),
    # pytest: "42 passed, 3 failed"
    (r"(\d+)\s+passed(?:,\s*(\d+)\s+failed)?", "pytest"),
]


def _test_figures(text: str):
    """(passed, failed) when a test runner printed a summary, else None."""
    for pat, flavour in _TEST_PATTERNS:
        m = re.search(pat, text, re.I | re.S)
        if not m:
            continue
        if flavour == "cargo":
            return int(m.group(2)), int(m.group(3))
        if flavour == "jest":
            return int(m.group(2)), int(m.group(1) or 0)
        if flavour == "mocha":
            return int(m.group(1)), int(m.group(2) or 0)
        return int(m.group(1)), int(m.group(2) or 0)
    return None


def _failed(text: str, event: str, resp) -> bool:
    if event == "PostToolUseFailure":
        return True
    if isinstance(resp, dict):
        for k in ("is_error", "isError", "error"):
            if resp.get(k):
                return True
        code = resp.get("exit_code", resp.get("exitCode"))
        if isinstance(code, int) and code != 0:
            return True
    return bool(re.search(r"^(error|fatal|panicked at|Traceback)", text, re.I | re.M))


# ── per-tool lines ────────────────────────────────────────────────────────────────────

def _bash(inp: dict, resp, event: str):
    cmd = inp.get("command", "") or ""
    head = _cmd_head(cmd) or "command"
    text = _text(resp)
    bad = _failed(text, event, resp)

    figs = _test_figures(text)
    if figs:
        passed, failed = figs
        if failed:
            return "bad", f"{head} ตก {failed} ผ่าน {passed}"
        return "info", f"{head} ผ่าน {passed}"

    if bad:
        return "bad", f"{head} ล้ม"

    n = _lines(text)
    if n > 3:
        return "info", f"{head} เสร็จ ได้ {n} บรรทัด"
    return "info", f"{head} เสร็จ"


def _edit(inp: dict, resp, event: str):
    f = _base(inp.get("file_path", "") or "")
    if not f:
        return None
    new = inp.get("new_string", inp.get("content", "")) or ""
    n = _lines(new)
    verb = "เขียนแล้ว" if "content" in inp else "แก้แล้ว"
    return ("info", f"{f} {verb} {n} บรรทัด") if n > 1 else ("info", f"{f} {verb}")


def _read(inp: dict, resp, event: str):
    f = _base(inp.get("file_path", "") or "")
    n = _lines(_text(resp))
    if not f:
        return None
    return "info", (f"{f} อ่านแล้ว {n} บรรทัด" if n else f"{f} อ่านแล้ว")


def _grep(inp: dict, resp, event: str):
    pat = (inp.get("pattern", "") or "")[:22]
    n = _lines(_text(resp))
    return ("info", f"{pat} เจอ {n} แห่ง") if pat else ("info", f"เจอ {n} แห่ง")


def _glob(inp: dict, resp, event: str):
    n = _lines(_text(resp))
    return "info", f"เจอ {n} ไฟล์"


def _agent(inp: dict, resp, event: str):
    who = inp.get("subagent_type", inp.get("description", "agent")) or "agent"
    return "info", f"agent {who} ตอบแล้ว"


def _web_search(inp: dict, resp, event: str):
    q = (inp.get("query", "") or "")[:24]
    return ("info", f"ค้น {q} แล้ว") if q else ("info", "ค้นแล้ว")


def _web_fetch(inp: dict, resp, event: str):
    url = inp.get("url", "") or ""
    host = re.sub(r"^https?://", "", url).split("/")[0][:26]
    return ("info", f"ดึง {host} แล้ว") if host else ("info", "ดึงหน้าเว็บแล้ว")


def _mcp(name: str, inp: dict, resp, event: str):
    parts = name.split("__")
    server = parts[1] if len(parts) > 2 else (parts[-1] if parts else name)
    op = parts[-1]
    n = _lines(_text(resp))
    who = f"{server} {op}".replace("_", " ")[:34]
    if n > 3:
        return "info", f"{who} ตอบ {n} แถว"
    return "info", f"{who} ตอบแล้ว"


def _bad_line(name: str, inp: dict):
    """What a FAILED call says. Bash owns its own wording (it has a command to name); every other
    tool fails in one of three ways, and naming the thing that failed beats naming the tool."""
    f = _base(inp.get("file_path", "") or "")
    if name == "Read":
        return ("bad", f"{f} อ่านไม่ได้" if f else "อ่านไม่ได้")
    if name in ("Edit", "Write", "NotebookEdit"):
        return ("bad", f"{f} เขียนไม่ได้" if f else "เขียนไม่ได้")
    if name in ("Grep", "Glob"):
        return ("bad", "ค้นไม่ได้")
    if name.startswith("mcp__"):
        parts = name.split("__")
        return ("bad", f"{(parts[1] if len(parts) > 2 else name)} ล้ม".replace("_", " ")[:MAX_CHARS])
    return ("bad", f"{name} ล้ม")


def fact(payload: dict):
    """(severity, line) or None."""
    name = payload.get("tool_name", "") or ""
    inp = payload.get("tool_input") or {}
    resp = payload.get("tool_response")
    event = payload.get("hook_event_name", "PostToolUse") or "PostToolUse"
    if not isinstance(inp, dict):
        inp = {}

    if name in SKIP_TOOLS:
        return None

    # A failure is the one thing worth interrupting for, so it is decided BEFORE the per-tool
    # success templates get a look at a response that has no content to measure.
    if name != "Bash" and _failed(_text(resp), event, resp):
        return _bad_line(name, inp)

    if name.startswith("mcp__"):
        out = _mcp(name, inp, resp, event)
    elif name == "Bash":
        out = _bash(inp, resp, event)
    elif name in ("Edit", "Write", "NotebookEdit"):
        out = _edit(inp, resp, event)
    elif name == "Read":
        out = _read(inp, resp, event)
    elif name == "Grep":
        out = _grep(inp, resp, event)
    elif name == "Glob":
        out = _glob(inp, resp, event)
    elif name in ("Agent", "Task"):
        out = _agent(inp, resp, event)
    elif name == "WebSearch":
        out = _web_search(inp, resp, event)
    elif name == "WebFetch":
        out = _web_fetch(inp, resp, event)
    elif name:
        sev = "bad" if _failed(_text(resp), event, resp) else "info"
        out = (sev, f"{name} {'ล้ม' if sev == 'bad' else 'เสร็จ'}")
    else:
        return None

    if not out:
        return None
    sev, line = out
    line = re.sub(r"\s+", " ", line).strip()
    return (sev, line[:MAX_CHARS]) if line else None


# ── selftest ──────────────────────────────────────────────────────────────────────────

def _selftest() -> int:
    def p(name, inp, resp, event="PostToolUse"):
        return {"tool_name": name, "tool_input": inp, "tool_response": resp,
                "hook_event_name": event}

    cases = [
        ("read counts lines", p("Read", {"file_path": "/a/b/queue.sh"}, "l1\nl2\nl3"),
         ("info", "queue.sh อ่านแล้ว 3 บรรทัด")),
        ("edit counts new lines", p("Edit", {"file_path": "x/narrate.sh", "new_string": "a\nb"}, {}),
         ("info", "narrate.sh แก้แล้ว 2 บรรทัด")),
        ("write says เขียน", p("Write", {"file_path": "x/new.py", "content": "a\nb\nc"}, {}),
         ("info", "new.py เขียนแล้ว 3 บรรทัด")),
        ("grep counts matches", p("Grep", {"pattern": "voice_cfg"}, "a\nb\nc\nd"),
         ("info", "voice_cfg เจอ 4 แห่ง")),
        ("glob counts files", p("Glob", {"pattern": "**/*.sh"}, "a\nb"), ("info", "เจอ 2 ไฟล์")),
        ("cargo green", p("Bash", {"command": "cargo test --lib"},
                          "test result: ok. 42 passed; 0 failed; 0 ignored"),
         ("info", "cargo test ผ่าน 42")),
        ("cargo red", p("Bash", {"command": "cargo test"},
                        "test result: FAILED. 39 passed; 3 failed; 0 ignored"),
         ("bad", "cargo test ตก 3 ผ่าน 39")),
        ("jest red", p("Bash", {"command": "npm test"},
                       "Tests:       3 failed, 42 passed, 45 total"),
         ("bad", "npm test ตก 3 ผ่าน 42")),
        ("mocha green", p("Bash", {"command": "npx cypress run"}, "  42 passing (3s)"),
         ("info", "npx cypress ผ่าน 42")),
        ("bash failure event", p("Bash", {"command": "git push origin develop"}, "rejected",
                                 "PostToolUseFailure"),
         ("bad", "git push ล้ม")),
        ("bash quiet ok", p("Bash", {"command": "git add -A"}, ""), ("info", "git add เสร็จ")),
        ("bash output lines", p("Bash", {"command": "ls -la"}, "a\nb\nc\nd\ne"),
         ("info", "ls เสร็จ ได้ 5 บรรทัด")),
        ("mcp rows", p("mcp__pg_triage__execute_sql", {}, "r1\nr2\nr3\nr4\nr5"),
         ("info", "pg triage execute sql ตอบ 5 แถว")),
        ("agent", p("Agent", {"subagent_type": "Explore"}, "..."),
         ("info", "agent Explore ตอบแล้ว")),
        ("websearch", p("WebSearch", {"query": "JARVIS lines"}, "..."),
         ("info", "ค้น JARVIS lines แล้ว")),
        ("webfetch host", p("WebFetch", {"url": "https://code.claude.com/docs/en/hooks"}, "..."),
         ("info", "ดึง code.claude.com แล้ว")),
        ("skip list is silent", p("TodoWrite", {}, "ok"), None),
        ("unknown tool still speaks", p("Skill", {"skill": "x"}, "ok"), ("info", "Skill เสร็จ")),
        ("dict stdout shape", p("Bash", {"command": "cargo build"},
                                {"stdout": "Finished\ndev\ntarget\nok", "stderr": ""}),
         ("info", "cargo build เสร็จ ได้ 4 บรรทัด")),
        ("is_error dict names the file", p("Read", {"file_path": "x/gone.txt"}, {"is_error": True}),
         ("bad", "gone.txt อ่านไม่ได้")),
        ("edit failure event", p("Edit", {"file_path": "a/b.rs", "new_string": "x"}, "blocked",
                                 "PostToolUseFailure"),
         ("bad", "b.rs เขียนไม่ได้")),
        ("mcp failure", p("mcp__pg_triage__execute_sql", {}, {"is_error": True}),
         ("bad", "pg triage ล้ม")),
    ]

    bad = 0
    for name, payload, want in cases:
        got = fact(payload)
        if got != want:
            bad += 1
            print(f"FAIL {name}\n  got  {got!r}\n  want {want!r}")
        else:
            print(f"ok   {name}")
        if got and len(got[1]) > MAX_CHARS:
            bad += 1
            print(f"FAIL {name}: over the {MAX_CHARS}-char ceiling")
    print(f"\n{len(cases)} cases, {bad} failed")
    return 1 if bad else 0


def main(argv: list[str]) -> int:
    if argv and argv[0] == "--selftest":
        return _selftest()
    if argv and argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0
    # --event overrides hook_event_name. The caller (narrate.sh) always knows which hook fired,
    # and a payload that reached it through a temp file is one rename away from losing the field.
    event = ""
    if "--event" in argv:
        i = argv.index("--event")
        if i + 1 < len(argv):
            event = argv[i + 1]
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if not isinstance(payload, dict):
        return 0
    if event:
        payload["hook_event_name"] = event
    out = fact(payload)
    if not out:
        return 0
    sys.stdout.write(f"{out[0]}\t{out[1]}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
