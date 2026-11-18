#!/usr/bin/env bash
#
# Hermetic regression for the Night Watch engine.
#
# No network, no credentials, no real agent: the engine is COPIED into a temp tree (so state lands
# in the temp tree, never in the real agent_logs/), the agent is a stub `claude` that prints a
# canned JSON envelope, and scripts/notify/send.sh is a stub that records channel, thread and
# stdin and answers `ts=<n>`. Time is injected with NIGHT_WATCH_NOW.
#
# Run:  scripts/night-watch/selftest.sh
# Exit: 0 = all green, 1 = at least one case regressed.
set -uo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SRC/../.." && pwd)"
pass=0; fail=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail+1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
ck()  { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected: $2 | got: $3"; fi; }
has() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else bad "$1" "missing '$2' in: $3"; fi; }
hasnt() { if grep -qF -- "$2" <<<"$3"; then bad "$1" "unexpected '$2' in: $3"; else ok "$1"; fi; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
NW="$T/scripts/night-watch"; mkdir -p "$NW" "$T/scripts/lib" "$T/scripts/notify" "$T/docs/night-watch" "$T/fx"
cp "$SRC/night_watch.py" "$SRC/prompt.md" "$SRC/verdict.schema.json" "$NW/"
cp "$REPO/scripts/lib/pii-patterns.txt" "$T/scripts/lib/"
echo "playbook" > "$T/docs/night-watch/playbook.md"
export FX="$T/fx" NIGHT_WATCH_CLAUDE="$T/claude" NIGHT_WATCH_ALERT_REPEAT_SEC=0 NIGHT_WATCH_PROD_ALLOWED=1
unset NIGHT_WATCH_TIMEOUT_SEC

# send.sh stub: one line per call "<thread>|<stdin>", stdout ts=<n>; `ts=` only when FX/nots absent.
cat > "$T/scripts/notify/send.sh" <<'EOF'
#!/usr/bin/env bash
thread=""; while [[ $# -gt 0 ]]; do [[ "$1" == --thread-ts ]] && thread="$2"; shift; done
n=$(( $(cat "$FX/n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FX/n"
printf '%s|%s|%s\n' "${thread:--}" "$PII_GATE" "$(tr '\n' ' ')" >> "$FX/sends.log"
[[ -f "$FX/nots" ]] || echo "ts=$n"
EOF
cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FX/claude.argv"
[[ -n "${FAKE_SLEEP:-}" ]] && sleep "$FAKE_SLEEP"
cat "$FX/claude.out"
EOF
chmod +x "$T/scripts/notify/send.sh" "$T/claude"

cfg() { # hours
  cat > "$T/workspace.config.yaml" <<EOF
night_watch:
  channel: C1
  interval_minutes: 60
  active_hours: "${1:-00:00-23:59}"
  mention: ["U1"]
  tick_timeout_minutes: 20
EOF
}
reset() { rm -rf "$T/agent_logs" "$FX/n" "$FX/sends.log" "$FX/nots"; : > "$FX/sends.log"; }
# say '<verdict json>' — wrap it the way the real CLI does: fenced JSON inside .result
say() { python3 -c 'import json,sys; print(json.dumps({"is_error":False,"result":"done\n```json\n"+sys.argv[1]+"\n```"}))' "$1" > "$FX/claude.out"; }
tick() { NIGHT_WATCH_NOW="$1" python3 "$NW/night_watch.py" tick >/dev/null 2>&1; echo $?; }
# stderr only (progress lines); stdout discarded
tickerr() { NIGHT_WATCH_NOW="$1" python3 "$NW/night_watch.py" tick 2>&1 >/dev/null; }
sends() { cat "$FX/sends.log"; }
nsends() { wc -l < "$FX/sends.log" | tr -d ' '; }
sendn() { sed -n "${1}p" "$FX/sends.log"; }
tlog() { cat "$T/agent_logs/night-watch/ticks.log" 2>/dev/null; }
py() { (cd "$NW" && python3 -c "import night_watch as n, json; $1"); }

OKV='{"state":"OK","headline":"all quiet","findings":[],"gaps":[]}'
finding() { # rule severity
  echo '{"rule":"'"$1"'","rule_id":"r1","severity":"'"$2"'","realm":"payments","title":"payout stuck","evidence":[{"kind":"trace","id":"abc123"}]}'
}
verdict() { # state rule severity
  echo '{"state":"'"$1"'","headline":"h","findings":['"$(finding "$2" "$3")"'],"gaps":[],"brief_en":"brief"}'
}
BLINDV='{"state":"BLIND","headline":"cannot read","findings":[],"gaps":[{"realm":"all","reason":"token expired"}],"reauth":"run login","brief_en":"blind"}'

# --- slots + active_hours ----------------------------------------------------------------------
cfg "08:00-20:00"
ck "plan: active slot floors to the hour" \
  "slot=2026-01-01T10:00:00 active=1 next=2026-01-01T11:00:00" \
  "$(NIGHT_WATCH_NOW=2026-01-01T10:30:00 python3 "$NW/night_watch.py" plan)"
ck "plan: after hours rolls to next morning" \
  "slot=2026-01-01T21:00:00 active=0 next=2026-01-02T08:00:00" \
  "$(NIGHT_WATCH_NOW=2026-01-01T21:30:00 python3 "$NW/night_watch.py" plan)"
cfg "22:00-06:00"
ck "plan: overnight window wraps midnight" \
  "slot=2026-01-01T03:00:00 active=1 next=2026-01-01T04:00:00" \
  "$(NIGHT_WATCH_NOW=2026-01-01T03:10:00 python3 "$NW/night_watch.py" plan)"
cfg "08:00-20:00"; reset; say "$OKV"
ck "outside active_hours: no agent, no post" "0|0" "$(tick 2026-01-01T22:10:00)|$(nsends)"
has "outside active_hours: logged" OUTSIDE "$(tlog)"
cfg "bad"; ck "bad active_hours exits 2" 2 "$(tick 2026-01-01T10:00:00)"

# --- agent invocation shape --------------------------------------------------------------------
cfg; reset; say "$OKV"; tick 2026-01-01T10:00:00 >/dev/null
argv="$(cat "$FX/claude.argv")"
has "agent: --agent oncall" "--agent oncall" "$argv"
has "agent: json output" "--output-format json" "$argv"
has "agent: posting tools disallowed" "scripts/notify/" "$argv"

# --- OK: one parent per day, replies in thread -------------------------------------------------
reset; say "$OKV"; tick 2026-01-01T10:00:00 >/dev/null; tick 2026-01-01T11:00:00 >/dev/null
ck "OK x2: parent + 2 replies" 3 "$(nsends)"
has "OK: parent is top-level day line" "-|on|Night Watch 2026-01-01" "$(sendn 1)"
has "OK: reply threads under parent" "1|on|OK 10:00" "$(sendn 2)"
has "OK: second tick reuses parent" "1|on|OK 11:00" "$(sendn 3)"
tick 2026-01-02T10:00:00 >/dev/null
has "OK: new day, new parent" "-|on|Night Watch 2026-01-02" "$(sendn 4)"
hasnt "OK: no mention" "<@U1>" "$(sends)"
ck "re-run of same slot is skipped" "6" "$(tick 2026-01-02T10:20:00 >/dev/null; nsends)"
has "re-run logged already-ran" already-ran "$(tlog)"

# --- SUSPICIOUS / ALERT ------------------------------------------------------------------------
reset; say "$(verdict SUSPICIOUS fixed SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
ck "SUSPICIOUS: top-level + brief thread" 2 "$(nsends)"
has "SUSPICIOUS: top-level with mention" "-|on|<@U1> SUSPICIOUS 10:00" "$(sendn 1)"
has "SUSPICIOUS: brief in thread" "1|on|" "$(sendn 2)"
reset; say "$(verdict ALERT fixed ALERT)"; tick 2026-01-01T10:00:00 >/dev/null
ck "ALERT: top, brief, repeat" 3 "$(nsends)"
has "ALERT: mention" "<@U1> ALERT 10:00" "$(sendn 1)"
has "ALERT: repeated top-level" "-|on|ALERT repeat:" "$(sendn 3)"

# --- baseline learning -------------------------------------------------------------------------
reset; say "$(verdict SUSPICIOUS count SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
hasnt "learning: count finding mentions nobody" "<@U1>" "$(sends)"
has "learning: labelled" "baseline learning" "$(sends)"
reset; say "$(verdict ALERT count ALERT)"; tick 2026-01-01T10:00:00 >/dev/null
ck "learning: suppressed ALERT is not repeated" 2 "$(nsends)"
reset; say "$(verdict ALERT fixed ALERT)"; tick 2026-01-01T10:00:00 >/dev/null
has "learning: fixed rule mentions from tick 1" "<@U1>" "$(sendn 1)"
reset; mkdir -p "$T/agent_logs/night-watch"
python3 - "$T" <<'EOF'
import json, sys
s = {"version": 1, "ticks_ok": 24, "last_slot": None, "last_success_slot": None,
     "day": {"date": None, "parent_ts": None}, "blind": {"active": False},
     "failures": {"consecutive": 0}, "baselines": {}, "notes": []}
json.dump(s, open(sys.argv[1] + "/agent_logs/night-watch/state.json", "w"))
EOF
say "$(verdict SUSPICIOUS count SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
has "after 24 ticks count finding mentions" "<@U1>" "$(sendn 1)"
hasnt "after 24 ticks no learning label" "baseline learning" "$(sends)"

# --- BLIND: first top-level, consecutive in thread, reset by success ---------------------------
reset; say "$BLINDV"; tick 2026-01-01T10:00:00 >/dev/null
has "BLIND first: top-level with mention" "-|on|<@U1> BLIND 10:00" "$(sendn 1)"
n1="$(nsends)"; tick 2026-01-01T11:00:00 >/dev/null
hasnt "BLIND consecutive: no mention" "<@U1> BLIND 11:00" "$(sends)"
has "BLIND consecutive: in thread" "|on|BLIND 11:00" "$(sendn $((n1+2)))"
say "$OKV"; tick 2026-01-01T12:00:00 >/dev/null
say "$BLINDV"; tick 2026-01-01T13:00:00 >/dev/null
has "BLIND after success: mentions again" "<@U1> BLIND 13:00" "$(sends)"
reset; NIGHT_WATCH_PROD_ALLOWED=0 tick 2026-01-01T10:00:00 >/dev/null
has "prod not allowed: BLIND without agent" "BLIND 10:00" "$(sends)"

# --- failures: gap line, mention only on the 2nd in a row --------------------------------------
reset; echo '{"is_error":false,"result":"no verdict here"}' > "$FX/claude.out"
tick 2026-01-01T10:00:00 >/dev/null
has "failed tick: gap line in thread" "|on|FAILED 10:00" "$(sends)"
hasnt "failed tick 1: no mention" "<@U1>" "$(sends)"
tick 2026-01-01T11:00:00 >/dev/null
has "failed tick 2: mentions" "<@U1> FAILED 11:00" "$(sends)"
say "$OKV"; tick 2026-01-01T12:00:00 >/dev/null
echo '{"is_error":false,"result":"x"}' > "$FX/claude.out"; tick 2026-01-01T13:00:00 >/dev/null
hasnt "success resets the failure counter" "<@U1> FAILED 13:00" "$(sends)"
reset; FAKE_SLEEP=5 NIGHT_WATCH_TIMEOUT_SEC=1 tick 2026-01-01T10:00:00 >/dev/null
has "timeout is a FAILED tick" "timeout after 1s" "$(sends)"
reset; echo '{"is_error":true,"result":"boom"}' > "$FX/claude.out"; tick 2026-01-01T10:00:00 >/dev/null
has "agent error is a FAILED tick" "agent-error" "$(sends)"

# --- gap after missed slots --------------------------------------------------------------------
reset; say "$OKV"; tick 2026-01-01T10:00:00 >/dev/null; tick 2026-01-01T13:10:00 >/dev/null
has "gap: one line naming missed slots" "Missed slots, not replayed: 11:00, 12:00" "$(sends)"
ck "gap: counted once, no replay" 1 "$(grep -c 'Missed slots' "$FX/sends.log")"

# --- lock --------------------------------------------------------------------------------------
reset; say "$OKV"; mkdir -p "$T/agent_logs/night-watch"
python3 -c 'import fcntl,time,sys; f=open(sys.argv[1],"w"); fcntl.flock(f,fcntl.LOCK_EX); time.sleep(4)' \
  "$T/agent_logs/night-watch/tick.lock" & holder=$!
sleep 1
ck "lock held: slot skipped, nothing posted" "0|0" "$(tick 2026-01-01T10:00:00)|$(nsends)"
has "lock held: logged" "previous Tick still holds the lock" "$(tlog)"
has "term: lock skip shown" "SKIPPED previous Tick still holds the lock" "$(tickerr 2026-01-01T10:00:00)"
wait "$holder"

# --- posting failures --------------------------------------------------------------------------
reset; touch "$FX/nots"; say "$OKV"; tick 2026-01-01T10:00:00 >/dev/null
has "no ts= from sender: POST_FAILED logged" POST_FAILED "$(tlog)"

# --- fenced-JSON extraction (pure) -------------------------------------------------------------
ck "extract: fenced block in result" "OK" \
  "$(py 'print(n.extract_verdict(json.dumps({"result":"hi\n```json\n{\"state\":\"OK\"}\n```"}),0)[0]["state"])')"
ck "extract: last fenced block wins" "ALERT" \
  "$(py 'print(n.extract_verdict(json.dumps({"result":"```json\n{\"state\":\"OK\"}\n```\nx\n```json\n{\"state\":\"ALERT\"}\n```"}),0)[0]["state"])')"
ck "extract: bare JSON result" "OK" \
  "$(py 'print(n.extract_verdict(json.dumps({"result":"{\"state\":\"OK\"}"}),0)[0]["state"])')"
ck "extract: prose only" "unparseable" "$(py 'print(n.extract_verdict(json.dumps({"result":"nothing"}),0)[1])')"
ck "extract: non-JSON stdout" "unparseable" "$(py 'print(n.extract_verdict("garbage",0)[1])')"
ck "extract: nonzero exit" "agent-error" "$(py 'print(n.extract_verdict(json.dumps({"result":"{}"}),1)[1])')"

# --- Verdict validation (pure) -----------------------------------------------------------------
v() { py "print(n.validate(json.loads('''$1''')))"; }
F="$(finding fixed ALERT)"
ck "validate: good OK" None "$(v "$OKV")"
ck "validate: good ALERT" None "$(v "$(verdict ALERT fixed ALERT)")"
has "validate: unknown state" "invalid: state" "$(v '{"state":"MAYBE","headline":"h","findings":[],"gaps":[]}')"
has "validate: OK with findings" "invalid" "$(v '{"state":"OK","headline":"h","findings":['"$F"'],"gaps":[]}')"
has "validate: state below worst severity" "does not match" \
  "$(v '{"state":"SUSPICIOUS","headline":"h","findings":['"$F"'],"gaps":[],"brief_en":"b"}')"
has "validate: finding without evidence" "evidence" \
  "$(v '{"state":"ALERT","headline":"h","findings":[{"rule":"fixed","severity":"ALERT","realm":"auth","title":"t","evidence":[]}],"gaps":[],"brief_en":"b"}')"
has "validate: ALERT without brief" "brief_en" "$(v '{"state":"ALERT","headline":"h","findings":['"$F"'],"gaps":[]}')"
has "validate: BLIND without reauth or gaps" "BLIND" "$(v '{"state":"BLIND","headline":"h","findings":[],"gaps":[],"brief_en":"b"}')"
has "validate: headline with newline" "headline" "$(v '{"state":"OK","headline":"a\\nb","findings":[],"gaps":[]}')"
has "validate: bad baselines" "baselines" "$(v '{"state":"OK","headline":"h","findings":[],"gaps":[],"state_update":{"baselines":{"a":{"value":"x"}}}}')"

# --- PII rejection -----------------------------------------------------------------------------
has "pii: email in headline rejected" "pii-in-verdict (email)" \
  "$(v '{"state":"OK","headline":"mail jane@example.com","findings":[],"gaps":[]}')"
has "pii: bank account in finding title rejected" "pii-in-verdict (bank_account)" \
  "$(v '{"state":"ALERT","headline":"h","findings":[{"rule":"fixed","severity":"ALERT","realm":"auth","title":"bank account 123456789","evidence":[{"kind":"log","id":"x1"}]}],"gaps":[],"brief_en":"b"}')"
reset; say '{"state":"OK","headline":"mail jane@example.com","findings":[],"gaps":[]}'; tick 2026-01-01T10:00:00 >/dev/null
hasnt "pii: never posted" "jane@example.com" "$(sends)"
has "pii: tick is FAILED" "pii-in-verdict" "$(sends)"

# --- terminal progress lines -------------------------------------------------------------------
cfg "08:00-20:00"
ck "plan: nothing on stderr" "" "$(NIGHT_WATCH_NOW=2026-01-01T10:30:00 python3 "$NW/night_watch.py" plan 2>&1 >/dev/null)"
reset; say "$OKV"
ck "tick: stdout stays empty" "" "$(NIGHT_WATCH_NOW=2026-01-01T10:00:00 python3 "$NW/night_watch.py" tick 2>/dev/null)"
reset; say "$OKV"; out="$(tickerr 2026-01-01T10:00:00)"
has "term: timestamped" "2026-01-01 10:00:00 night-watch: " "$out"
has "term: start line" "2026-01-01T10:00:00 START window 08:50-10:00, timeout 20 min" "$out"
has "term: end line (state + headline)" "2026-01-01T10:00:00 OK all quiet ts=2 (took 0m" "$out"
has "term: OK posted in thread" "posted thread)" "$out"
has "term: one-shot next Tick" "next Tick at 2026-01-01 11:00" "$out"
hasnt "term: ticks.log keeps its format" "took " "$(tlog)"
reset; say "$(verdict SUSPICIOUS fixed SUSPICIOUS)"; out="$(tickerr 2026-01-01T10:00:00)"
has "term: SUSPICIOUS end line" "SUSPICIOUS h ts=1 (took 0m" "$out"
has "term: posted top-level" "posted top-level)" "$out"
hasnt "term: no finding title" "payout stuck" "$out"
hasnt "term: no evidence id" "abc123" "$out"
hasnt "term: no mention id" "U1" "$out"
reset; echo '{"is_error":false,"result":"no verdict here"}' > "$FX/claude.out"
has "term: FAILED with reason" "FAILED unparseable" "$(tickerr 2026-01-01T10:00:00)"
reset; touch "$FX/nots"; say "$OKV"; out="$(tickerr 2026-01-01T10:00:00)"
has "term: post failure shown" "POST_FAILED" "$out"
has "term: not posted" "not posted)" "$out"
reset; say "$OKV"
has "term: outside hours" "OUTSIDE outside active_hours" "$(tickerr 2026-01-01T22:10:00)"
reset; say "$OKV"; tick 2026-01-01T10:00:00 >/dev/null
has "term: gap line" "GAP 11:00, 12:00" "$(tickerr 2026-01-01T13:10:00)"
reset; say '{"state":"OK","headline":"mail jane@example.com","findings":[],"gaps":[]}'
hasnt "term: rejected PII never printed" "jane@example.com" "$(tickerr 2026-01-01T10:00:00)"
# loop: a frozen clock never reaches the slot, so only the start lines are observable offline.
reset; NIGHT_WATCH_NOW=2026-01-01T10:25:00 python3 "$NW/night_watch.py" loop 2>"$T/loop.err" >/dev/null & lp=$!
for _ in $(seq 50); do grep -q 'next Tick' "$T/loop.err" && break; sleep 0.1; done
kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
has "loop: banner" "watch started: channel C1, every 60 min, active 08:00-20:00" "$(cat "$T/loop.err")"
has "loop: next Tick (flushed, not a TTY)" "next Tick at 2026-01-01 11:00" "$(cat "$T/loop.err")"
ck "loop: no post" 0 "$(nsends)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
