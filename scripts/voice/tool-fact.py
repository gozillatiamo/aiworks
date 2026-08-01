#!/usr/bin/env python3
"""One tool call in, one spoken Thai line out — the `max` narrator's source of lines.

    echo '<PostToolUse JSON>'  | tool-fact.py                        # the RESULT of a step
    echo '<PreToolUse JSON>'   | tool-fact.py --event PreToolUse     # what the step is ABOUT to do
    tool-fact.py --selftest

Output is `<severity>\\t<line>`, severity `info` | `bad`, or NOTHING when the call is not worth
saying out loud. `bad` is what makes narrate.sh reach for the red cue and skip the rate floor.

TWO LINES PER STEP, WHICH IS WHAT `max` MEANS. A step has two moments worth hearing and they
answer different questions — "what is it doing right now?" and "how did it go?":

    รัน cargo test          →  cargo test ผ่าน 42
    อ่าน queue.sh           →  queue.sh อ่านแล้ว 260 บรรทัด
    แก้ narrate.sh          →  narrate.sh แก้แล้ว 12 บรรทัด

The result alone leaves every wait unexplained: a 90-second `cargo test` is 90 seconds of silence
followed by a verdict, and the person listening cannot tell a long step from a wedged one. The
intent line is what turns that silence into a wait you can place. It is also the cheaper half —
the PreToolUse payload has no `tool_response`, the line is shorter, and short lines repeat, which
means the audio cache answers most of them for free.

An intent is spoken as `[verb] [subject]` and a result as `[subject] [state] [figure]` — verb-first
against subject-first, and only the result carries `แล้ว` and a number. That contrast is the whole
reason a pair does not sound like the same sentence twice; keep it if you add a tool.

Both halves are TEMPLATES over the payload's own fields — no model call, so the channel costs zero
tokens and cannot invent anything. If a figure is not in the payload it does not get said.

Identifiers, commands, paths and numerals stay Latin/Arabic (the workspace's English spine).
"""

from __future__ import annotations

import json
import os
import re
import sys

MAX_CHARS = 60          # ~4 s of Thai speech. JARVIS's lines are 3–8 words; so are these.
INTENT_CHARS = 34       # the intent half is deliberately HALF that: a pair has to fit inside the
                        # step it describes, and the informative word (the file, the command) is
                        # already there by character 34.

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


# ── the intent half: what the step is about to do, from tool_input alone ───────────────
# Nothing here may look at `tool_response` — there is none yet. Which is also why an intent is
# always `info`: a call that has not run cannot have failed.

def _intent_line(name: str, inp: dict):
    if name == "Bash":
        return f"รัน {_cmd_head(inp.get('command', '') or '') or 'คำสั่ง'}"
    if name == "Read":
        f = _base(inp.get("file_path", "") or "")
        return f"อ่าน {f}" if f else "อ่านไฟล์"
    if name == "Edit":
        f = _base(inp.get("file_path", "") or "")
        return f"แก้ {f}" if f else "แก้ไฟล์"
    if name in ("Write", "NotebookEdit"):
        f = _base(inp.get("file_path", "") or "")
        return f"เขียน {f}" if f else "เขียนไฟล์"
    if name == "Grep":
        pat = (inp.get("pattern", "") or "")[:22]
        return f"ค้น {pat}" if pat else "ค้นในโค้ด"
    if name == "Glob":
        # The result line does not speak the pattern either ("เจอ 2 ไฟล์"): `**/*.sh` read aloud is
        # punctuation, not words. The extension is the only speakable part of a glob.
        m = re.search(r"\.([A-Za-z0-9]{1,6})$", inp.get("pattern", "") or "")
        return f"หาไฟล์ .{m.group(1)}" if m else "หาไฟล์"
    if name in ("Agent", "Task"):
        who = inp.get("subagent_type", inp.get("description", "")) or ""
        return f"เรียก agent {who}"[:INTENT_CHARS] if who else "เรียก agent"
    if name == "WebSearch":
        q = (inp.get("query", "") or "")[:24]
        return f"ค้นเว็บ {q}" if q else "ค้นเว็บ"
    if name == "WebFetch":
        url = inp.get("url", "") or ""
        host = re.sub(r"^https?://", "", url).split("/")[0][:26]
        return f"ดึง {host}" if host else "ดึงหน้าเว็บ"
    if name == "Skill":
        s = inp.get("skill", "") or ""
        return f"เรียก skill {s}" if s else "เรียก skill"
    if name.startswith("mcp__"):
        parts = name.split("__")
        server = parts[1] if len(parts) > 2 else (parts[-1] if parts else name)
        return f"ถาม {server} {parts[-1]}".replace("_", " ")
    return f"เรียก {name}" if name else ""


def intent(payload: dict):
    """(severity, line) or None — the PreToolUse half. Always `info`."""
    name = payload.get("tool_name", "") or ""
    inp = payload.get("tool_input") or {}
    if not isinstance(inp, dict):
        inp = {}
    if not name or name in SKIP_TOOLS:
        return None
    line = re.sub(r"\s+", " ", _intent_line(name, inp)).strip()
    return ("info", line[:INTENT_CHARS]) if line else None


def fact(payload: dict):
    """(severity, line) or None."""
    name = payload.get("tool_name", "") or ""
    inp = payload.get("tool_input") or {}
    resp = payload.get("tool_response")
    event = payload.get("hook_event_name", "PostToolUse") or "PostToolUse"
    if not isinstance(inp, dict):
        inp = {}

    # Dispatched HERE rather than in main(), so no caller can hand a PreToolUse payload to the
    # result templates: they would read a response that does not exist yet and say "อ่านแล้ว 0
    # บรรทัด" — a figure about nothing, in the past tense, before the work happened.
    if event == "PreToolUse":
        return intent(payload)

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

    # The intent half. Same payload shape minus the response, `--event PreToolUse`.
    def q(name, inp):
        return {"tool_name": name, "tool_input": inp, "hook_event_name": "PreToolUse"}

    intent_cases = [
        ("bash names the command", q("Bash", {"command": "cargo test --lib -p core"}),
         ("info", "รัน cargo test")),
        ("read names the file", q("Read", {"file_path": "/a/b/queue.sh"}),
         ("info", "อ่าน queue.sh")),
        ("edit says แก้", q("Edit", {"file_path": "x/narrate.sh", "new_string": "a"}),
         ("info", "แก้ narrate.sh")),
        ("write says เขียน", q("Write", {"file_path": "x/new.py", "content": "a"}),
         ("info", "เขียน new.py")),
        ("grep names the pattern", q("Grep", {"pattern": "voice_cfg"}),
         ("info", "ค้น voice_cfg")),
        ("glob speaks the extension, not the glob", q("Glob", {"pattern": "**/*.sh"}),
         ("info", "หาไฟล์ .sh")),
        ("agent names who", q("Agent", {"subagent_type": "Explore"}),
         ("info", "เรียก agent Explore")),
        ("websearch names the query", q("WebSearch", {"query": "JARVIS lines"}),
         ("info", "ค้นเว็บ JARVIS lines")),
        ("webfetch names the host", q("WebFetch", {"url": "https://code.claude.com/docs/en/hooks"}),
         ("info", "ดึง code.claude.com")),
        ("mcp names server and op", q("mcp__pg_triage__execute_sql", {}),
         ("info", "ถาม pg triage execute sql")),
        ("skill names the skill", q("Skill", {"skill": "caveman:caveman"}),
         ("info", "เรียก skill caveman:caveman")),
        ("the skip list is silent before the call too", q("TodoWrite", {}), None),
        ("an unknown tool still announces itself", q("SomeNewTool", {}),
         ("info", "เรียก SomeNewTool")),
        # An intent can never be `bad`: the call has not run. Proved with the payload shape that
        # WOULD look like a failure to the result path.
        ("a PreToolUse payload never comes back bad",
         {"tool_name": "Read", "tool_input": {"file_path": "/x/gone.txt"},
          "tool_response": {"is_error": True}, "hook_event_name": "PreToolUse"},
         ("info", "อ่าน gone.txt")),
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

    for name, payload, want in intent_cases:
        # Through fact(), not intent(): the event dispatch is part of what is under test.
        got = fact(payload)
        if got != want:
            bad += 1
            print(f"FAIL intent: {name}\n  got  {got!r}\n  want {want!r}")
        else:
            print(f"ok   intent: {name}")
        if got and len(got[1]) > INTENT_CHARS:
            bad += 1
            print(f"FAIL intent: {name}: over the {INTENT_CHARS}-char ceiling")

    total = len(cases) + len(intent_cases)
    print(f"\n{total} cases, {bad} failed")
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
