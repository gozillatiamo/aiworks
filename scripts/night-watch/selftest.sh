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
NW="$T/scripts/night-watch"; mkdir -p "$NW" "$T/scripts/lib" "$T/scripts/notify" "$T/scripts/observability" "$T/docs/night-watch" "$T/fx"
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
printf '%s\n' "$(printf '%s' "${PII_SPARE:-}" | tr '\n' ',')" >> "$FX/spare.log"
[[ -f "$FX/nots" ]] || echo "ts=$n"
EOF
cat > "$T/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FX/claude.argv"
[[ -n "${FAKE_SLEEP:-}" ]] && sleep "$FAKE_SLEEP"
[[ -n "${FAKE_WRITE:-}" ]] && cp "$FAKE_WRITE" "$PWD/agent_logs/night-watch/resolved.json"
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
reset() { rm -rf "$T/agent_logs" "$FX/n" "$FX/sends.log" "$FX/nots" "$T/scripts/observability/ui-url.sh"; : > "$FX/sends.log"; : > "$FX/spare.log"; }
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
has "OK: reply threads under parent" "1|on|✅ OK 10:00" "$(sendn 2)"
has "OK: second tick reuses parent" "1|on|✅ OK 11:00" "$(sendn 3)"
tick 2026-01-02T10:00:00 >/dev/null
has "OK: new day, new parent" "-|on|Night Watch 2026-01-02" "$(sendn 4)"
hasnt "OK: no mention" "<@U1>" "$(sends)"
ck "re-run of same slot is skipped" "6" "$(tick 2026-01-02T10:20:00 >/dev/null; nsends)"
has "re-run logged already-ran" already-ran "$(tlog)"

# --- SUSPICIOUS / ALERT ------------------------------------------------------------------------
reset; say "$(verdict SUSPICIOUS fixed SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
ck "SUSPICIOUS: one top-level post, brief not posted" 1 "$(nsends)"
has "SUSPICIOUS: top-level with mention" "-|on|🟡 *SUSPICIOUS 10:00* <@U1>" "$(sendn 1)"
has "SUSPICIOUS: numbered finding, rule, title, evidence id" '*1.* 🟡 *payments* · `r1` payout stuck > • trace: `abc123`' "$(sendn 1)"
hasnt "SUSPICIOUS: brief_en is never posted" "brief" "$(sends)"
reset; say '{"state":"SUSPICIOUS","headline":"h","findings":[{"rule":"lead","severity":"SUSPICIOUS","realm":"auth","title":"t","evidence":[{"kind":"trace","id":"a1"},{"kind":"trace","id":"a2"},{"kind":"trace","id":"a3"},{"kind":"trace","id":"a4"},{"kind":"trace","id":"a5"}]}],"gaps":[{"realm":"wallet","reason":"x"},{"realm":"wallet","reason":"y"}],"conclusion":"look at a1 first","brief_en":"brief"}'
tick 2026-01-01T10:00:00 >/dev/null
has "post: conclusion line" "*Conclusion:* look at a1 first" "$(sendn 1)"
has "post: unchecked realms, deduped" "_Not checked:_ wallet" "$(sendn 1)"
has "post: evidence lines show the first items" '• trace: `a4`' "$(sendn 1)"
has "post: no rule_id falls back to the rule kind" '`lead`' "$(sendn 1)"
reset; say "$(verdict ALERT fixed ALERT)"; tick 2026-01-01T10:00:00 >/dev/null
ck "ALERT: top, repeat" 2 "$(nsends)"
has "ALERT: mention" "🚨 *ALERT 10:00* <@U1>" "$(sendn 1)"
has "ALERT: repeated top-level" "-|on|🚨 *ALERT repeat 10:00* <@U1> h" "$(sendn 2)"

# --- baseline learning -------------------------------------------------------------------------
reset; say "$(verdict SUSPICIOUS count SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
hasnt "learning: count finding mentions nobody" "<@U1>" "$(sends)"
has "learning: labelled" "baseline learning" "$(sends)"
reset; say "$(verdict ALERT count ALERT)"; tick 2026-01-01T10:00:00 >/dev/null
ck "learning: suppressed ALERT is not repeated" 1 "$(nsends)"
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
has "BLIND first: top-level with mention" "-|on|🙈 *BLIND 10:00* — re-authenticate: run login <@U1>" "$(sendn 1)"
n1="$(nsends)"; tick 2026-01-01T11:00:00 >/dev/null
hasnt "BLIND consecutive: no mention" "<@U1>" "$(sendn $((n1+2)))"
has "BLIND consecutive: in thread" "|on|🙈 *BLIND 11:00*" "$(sendn $((n1+2)))"
say "$OKV"; tick 2026-01-01T12:00:00 >/dev/null
say "$BLINDV"; tick 2026-01-01T13:00:00 >/dev/null
has "BLIND after success: mentions again" "*BLIND 13:00* — re-authenticate: run login <@U1>" "$(sends)"
reset; NIGHT_WATCH_PROD_ALLOWED=0 tick 2026-01-01T10:00:00 >/dev/null
has "prod not allowed: BLIND without agent" "BLIND 10:00" "$(sends)"

# --- failures: gap line, mention only on the 2nd in a row --------------------------------------
reset; echo '{"is_error":false,"result":"no verdict here"}' > "$FX/claude.out"
tick 2026-01-01T10:00:00 >/dev/null
has "failed tick: gap line in thread" "|on|⚠️ *FAILED 10:00*" "$(sends)"
hasnt "failed tick 1: no mention" "<@U1>" "$(sends)"
tick 2026-01-01T11:00:00 >/dev/null
has "failed tick 2: mentions" "<@U1> ⚠️ *FAILED 11:00*" "$(sends)"
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
ck "validate: overlong and excess notes are trimmed, not rejected" "None 50 300" "$(py "
v = {'state':'OK','headline':'h','findings':[],'gaps':[],'state_update':{'notes':['x'*353]*60}}
r = n.validate(v); print(r, len(v['state_update']['notes']), len(v['state_update']['notes'][0]))")"
has "validate: non-string note" "state_update.notes" "$(v '{"state":"OK","headline":"h","findings":[],"gaps":[],"state_update":{"notes":[1]}}')"
ck "validate: excess baselines and an overlong baseline note are trimmed, not rejected" "None 400 300" "$(py "
v = {'state':'OK','headline':'h','findings':[],'gaps':[],'state_update':{'baselines':{f'k{i}':{'value':i,'note':'x'*353} for i in range(402)}}}
r = n.validate(v); b = v['state_update']['baselines']; print(r, len(b), len(b['k0']['note']))")"
has "validate: bad baselines" "baselines" "$(v '{"state":"OK","headline":"h","findings":[],"gaps":[],"state_update":{"baselines":{"a":{"value":"x"}}}}')"

# --- PII rejection -----------------------------------------------------------------------------
has "pii: email in headline rejected" "pii-in-verdict (email)" \
  "$(v '{"state":"OK","headline":"mail jane@example.com","findings":[],"gaps":[]}')"
ck "pii: a service account in a gap is a machine identity, not an e-mail" None \
  "$(v '{"state":"OK","headline":"h","findings":[],"gaps":[{"realm":"infra","reason":"denied for k8s-triage@proj-123456.iam.gserviceaccount.com"}]}')"
has "pii: a person e-mail beside a service account still rejected" "pii-in-verdict (email)" \
  "$(v '{"state":"OK","headline":"h","findings":[],"gaps":[{"realm":"infra","reason":"sa@p.iam.gserviceaccount.com asked by jane@example.com"}]}')"
has "pii: bank account in finding title rejected" "pii-in-verdict (bank_account)" \
  "$(v '{"state":"ALERT","headline":"h","findings":[{"rule":"fixed","severity":"ALERT","realm":"auth","title":"bank account 123456789","evidence":[{"kind":"log","id":"x1"}]}],"gaps":[],"brief_en":"b"}')"
reset; say '{"state":"OK","headline":"mail jane@example.com","findings":[],"gaps":[]}'; tick 2026-01-01T10:00:00 >/dev/null
hasnt "pii: never posted" "jane@example.com" "$(sends)"
has "pii: tick is FAILED" "pii-in-verdict" "$(sends)"

# --- evidence detail: labels, staff identity, id-only matching ---------------------------------
evv() { # evidence-array-json -> an ALERT Verdict whose single finding carries it
  echo '{"state":"ALERT","headline":"h","findings":[{"rule":"fixed","rule_id":"r1","severity":"ALERT","realm":"payments","title":"t","evidence":'"$1"'}],"gaps":[],"brief_en":"b"}'
}
STAFF='{"kind":"identity","id":"03518ef7-2c1a-4b6e-9d3f-5e8a1b2c4d6f","role":"admin","label":"acting admin","username":"ops.lead","name":"Ops Lead","email":"ops.lead@corp.example"}'
ck "E1 validate: labelled evidence accepted" None \
  "$(v "$(evv '[{"kind":"row","id":"r9","label":"order approval","table":"orders","target":"db-1"}]')")"
ck "E2 validate: staff identity e-mail accepted" None "$(v "$(evv "[$STAFF]")")"
has "E3 validate: e-mail in title still rejected" "pii-in-verdict (email)" \
  "$(v '{"state":"ALERT","headline":"h","findings":[{"rule":"fixed","severity":"ALERT","realm":"auth","title":"admin ops.lead@corp.example","evidence":[{"kind":"log","id":"x1"}]}],"gaps":[],"brief_en":"b"}')"
has "E3 validate: e-mail in a label still rejected" "pii-in-verdict (email)" \
  "$(v "$(evv '[{"kind":"log","id":"x1","label":"mail ops.lead@corp.example"}]')")"
has "E3 validate: e-mail in the id of a staff item still rejected" "pii-in-verdict (email)" \
  "$(v "$(evv '[{"kind":"identity","id":"ops.lead@corp.example","role":"admin"}]')")"
ck "E4 validate: staff fields stripped from a player identity" "None False False False" "$(py "
v = json.loads('''$(evv '[{"kind":"identity","id":"p-1","role":"player","username":"u","name":"Jane Roe","email":"jane@example.com"}]')''')
r = n.validate(v); e = v['findings'][0]['evidence'][0]; print(r, 'email' in e, 'name' in e, 'username' in e)")"
ck "E4 validate: staff fields stripped from an identity with no role" "None False" "$(py "
v = json.loads('''$(evv '[{"kind":"identity","id":"p-1","email":"jane@example.com"}]')''')
r = n.validate(v); print(r, 'email' in v['findings'][0]['evidence'][0])")"
ck "E5 validate: staff fields stripped from a non-identity item" "None False False" "$(py "
v = json.loads('''$(evv '[{"kind":"row","id":"r9","role":"admin","email":"jane@example.com","name":"Jane Roe"}]')''')
r = n.validate(v); e = v['findings'][0]['evidence'][0]; print(r, 'email' in e, 'name' in e)")"
ck "E5 validate: a staff e-mail that is not an e-mail is dropped, item kept" "None False True" "$(py "
v = json.loads('''$(evv '[{"kind":"identity","id":"a-1","role":"agent","email":"not an email","name":"Ops Lead"}]')''')
r = n.validate(v); e = v['findings'][0]['evidence'][0]; print(r, 'email' in e, 'name' in e)")"
ck "E5 validate: an e-mail with text around it is not a staff e-mail" "None False" "$(py "
v = json.loads('''$(evv '[{"kind":"identity","id":"a-1","role":"admin","email":"call me at x@y.example now"}]')''')
r = n.validate(v); print(r, 'email' in v['findings'][0]['evidence'][0])")"
has "E6 validate: phone in staff name rejected" "pii-in-verdict (phone)" \
  "$(v "$(evv '[{"kind":"identity","id":"a-1","role":"admin","name":"0891234567"}]')")"
has "E6 validate: bank account in staff username rejected" "pii-in-verdict (bank_account)" \
  "$(v "$(evv '[{"kind":"identity","id":"a-1","role":"admin","username":"bank account 123456789"}]')")"
ck "E8 validate: a hex trace id shaped like a BTC address is accepted" None \
  "$(v "$(evv '[{"kind":"trace","id":"17e9812345a6bcd7efa8b9c11def22ab"}]')")"
ck "E8 validate: a table name ahead of a row uuid is not a bank account" None \
  "$(v "$(evv '[{"kind":"config","id":"payout_bank_account 123456ce-123c-4567-bc89-eefdadf9ca12"}]')")"
ck "E8 validate: nor ahead of a uuid prefix" None \
  "$(v "$(evv '[{"kind":"config","id":"payout_bank_account 123456ce"}]')")"
has "E8 validate: a bank account in an evidence id still rejected" "pii-in-verdict (bank_account)" \
  "$(v "$(evv '[{"kind":"config","id":"payout_bank_account 1234567890"}]')")"
has "E8 validate: a BTC address in an evidence id still rejected" "pii-in-verdict (crypto_wallet_btc)" \
  "$(v "$(evv '[{"kind":"row","id":"1BoatSLRHtKNngkdXEeobR76b53LETtpyT"}]')")"
has "E7 validate: non-string label" "invalid: evidence fields" "$(v "$(evv '[{"kind":"log","id":"x1","label":5}]')")"
has "E7 validate: non-string table" "invalid: evidence fields" "$(v "$(evv '[{"kind":"row","id":"x1","table":["t"]}]')")"
has "E7 validate: unknown role" "invalid: evidence fields" "$(v "$(evv '[{"kind":"identity","id":"x1","role":"root"}]')")"
has "E7 validate: non-string staff field" "invalid: evidence fields" \
  "$(v "$(evv '[{"kind":"identity","id":"x1","role":"admin","name":7}]')")"
ck "E8 validate: label over 80 trimmed, not rejected" "None 80" "$(py "
v = json.loads('''$(evv '[{"kind":"log","id":"x1","label":"'"$(printf 'x%.0s' $(seq 1 100))"'"}]')''')
r = n.validate(v); print(r, len(v['findings'][0]['evidence'][0]['label']))")"

posted() { reset; say "$(evv "$1")"; tick 2026-01-01T10:00:00 >/dev/null; sendn 1; }
EV8=""; for i in 1 2 3 4 5 6 7 8; do EV8="$EV8${EV8:+,}{\"kind\":\"log\",\"id\":\"a$i\"}"; done
out="$(posted "[$EV8]")"
has "E9 post: sixth evidence line present" '`a6`' "$out"
hasnt "E9 post: seventh evidence line capped" '`a7`' "$out"
has "E9 post: overflow count" '> +2' "$out"
has "E10 post: row line" '• row `orders` @ db-1 — order approval: `r9`' \
  "$(posted '[{"kind":"row","id":"r9","label":"order approval","table":"orders","target":"db-1"}]')"
has "E11 post: staff identity line" '• admin — acting admin: `03518ef7-2c1a-4b6e-9d3f-5e8a1b2c4d6f` · ops.lead · Ops Lead · ops.lead@corp.example' \
  "$(posted "[$STAFF]")"
hasnt "E12 post: player identity line has no personal fields" "jane" \
  "$(posted '[{"kind":"identity","id":"p-1","role":"player","label":"player","name":"Jane Roe","email":"jane@example.com"}]')"
has "E12 post: player identity line keeps role and id" '• player — player: `p-1`' \
  "$(posted '[{"kind":"identity","id":"p-1","role":"player","label":"player","name":"Jane Roe"}]')"
has "E13 post: old evidence without a label renders kind and id" '> • log: `x1`' "$(posted '[{"kind":"log","id":"x1"}]')"
has "E14 post: label is Slack-escaped" 'a&lt;b&gt;&amp;c' "$(posted '[{"kind":"log","id":"x1","label":"a<b>&c"}]')"

# ui-url.sh stub (absent by default; reset removes it): one URL per id, or a canned broken output
stub_ui() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$T/scripts/observability/ui-url.sh"; chmod +x "$T/scripts/observability/ui-url.sh"; }
TR='[{"kind":"trace","id":"abc123","label":"approve call","target":"svc"},{"kind":"row","id":"r9","table":"orders"}]'
posted_ui() { reset; stub_ui "$1"; say "$(evv "$2")"; tick 2026-01-01T10:00:00 >/dev/null; sendn 1; }
has "E15 post: trace id is a link" '<https://obs.example/trace/abc123|abc123>' \
  "$(posted_ui 'shift; for i in "$@"; do echo "https://obs.example/trace/$i"; done' "$TR")"
out="$(posted "$TR")"
has "E16 post: helper missing gives plain code id" 'approve call: `abc123`' "$out"
ck "E16 post: helper missing, post and repeat still sent" 2 "$(nsends)"
has "E17 post: non-zero exit gives plain text" 'approve call: `abc123`' "$(posted_ui 'echo https://obs.example/x; exit 1' "$TR")"
has "E17 post: wrong line count gives plain text" 'approve call: `abc123`' "$(posted_ui 'echo https://obs.example/x; echo https://obs.example/y' "$TR")"
has "E17 post: empty line leaves that id plain" 'approve call: `abc123`' "$(posted_ui 'echo ""' "$TR")"
has "E17 post: non-https output is not linked" 'approve call: `abc123`' "$(posted_ui 'echo javascript:x' "$TR")"
out="$(posted_ui 'shift; for i in "$@"; do echo "https://obs.example/trace/$i"; done' "$TR")"
hasnt "E20 post: a row is never linked" 'obs.example/trace/r9' "$out"
has "E20 post: row stays code" '`r9`' "$out"
posted_ui 'echo' "[$STAFF]" >/dev/null
ck "E18 post: spare list is this Verdict's staff values" "ops.lead,Ops Lead,ops.lead@corp.example" "$(sed -n 1p "$FX/spare.log")"
reset; say '{"state":"OK","headline":"h","findings":[],"gaps":[]}'; tick 2026-01-01T10:00:00 >/dev/null
ck "E19 post: parent and OK carry an empty spare list" "||" "$(tr '\n' '|' < "$FX/spare.log")"
reset; say "$(evv "[$STAFF]")"; tick 2026-01-01T10:00:00 >/dev/null
ck "E19 post: the ALERT repeat carries no spare" "" "$(sed -n 2p "$FX/spare.log")"

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

# --- brief (dig-down) --------------------------------------------------------------------------
cp "$SRC/run.sh" "$NW/"
brief() { python3 "$NW/night_watch.py" brief "$@" 2>&1; }
cfg
V="$T/agent_logs/night-watch/verdicts"
reset; say "$(verdict SUSPICIOUS fixed SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
out="$(brief latest)"
has "B1 file path" "agent_logs/night-watch/verdicts/20260101T1000.json" "$out"
has "B1 brief_en" "brief_en: brief" "$out"
has "B1 finding" "1. SUSPICIOUS payments r1: payout stuck" "$out"
has "B1 evidence id" "trace abc123" "$out"
tick 2026-01-02T10:00:00 >/dev/null
out="$(brief 10:00)"
has "B2 newest day wins" "agent_logs/night-watch/verdicts/20260102T1000.json" "$out"
has "B2 other day named" "other days: 20260101T1000" "$out"
has "B3 exact stamp" "agent_logs/night-watch/verdicts/20260101T1000.json" "$(brief 20260101T1000)"
out="$(brief 09:00)"; rc=0; python3 "$NW/night_watch.py" brief 09:00 >/dev/null 2>&1 || rc=$?
ck "B4 no match exits 1" 1 "$rc"; has "B4 names the argument" "09:00" "$out"
rc=0; python3 "$NW/night_watch.py" brief nonsense >/dev/null 2>&1 || rc=$?
ck "B5 bad argument exits 2" 2 "$rc"
reset; printf '%s\n' '{"is_error":false,"result":"no verdict here"}' > "$FX/claude.out"; tick 2026-01-01T10:00:00 >/dev/null
out="$(brief latest)"
has "B6 failed tick: note" "note: FAILED Tick — no Verdict" "$out"
has "B6 failed tick: raw text" "no verdict here" "$out"
reset; python3 -c 'import json; print(json.dumps({"is_error":False,"result":"```json\n{\"state\":\"OK\",\"headline\":\"recovered\"}\n```"}))' > "$FX/claude.out"
mkdir -p "$V"; cp "$FX/claude.out" "$V/20260101T1100.json"
out="$(brief 11:00)"
has "B6b raw envelope recovered" "Verdict recovered from raw agent output" "$out"
has "B6b raw envelope headline" "headline: recovered" "$out"
reset; say "$(verdict SUSPICIOUS fixed SUSPICIOUS)"; tick 2026-01-01T10:00:00 >/dev/null
mv "$T/workspace.config.yaml" "$T/cfg.bak"; : > "$T/marker"; sleep 1
out="$(brief latest)"; has "B7 works without config" "brief_en: brief" "$out"
ck "B7 writes nothing" "" "$(find "$T/agent_logs" -newer "$T/marker")"
mv "$T/cfg.bak" "$T/workspace.config.yaml"
ck "B8 run.sh brief matches" "$(brief latest)" "$("$NW/run.sh" brief latest 2>&1)"

# --- resolved cases: the resolve / unresolve / resolved commands -------------------------------------
fx() { # realm rule severity rule_id id... -> one finding with trace evidence ids
  local realm=$1 rule=$2 sev=$3 rid=$4; shift 4; local ev="" i
  for i in "$@"; do ev+="${ev:+,}{\"kind\":\"${KIND:-trace}\",\"id\":\"$i\"}"; done
  echo '{"rule":"'"$rule"'","rule_id":"'"$rid"'","severity":"'"$sev"'","realm":"'"$realm"'","title":"t","evidence":['"$ev"']}'
}
vx() { # state finding... -> verdict
  local s=$1; shift; local IFS=,
  echo '{"state":"'"$s"'","headline":"h","findings":['"$*"'],"gaps":[],"conclusion":"c","brief_en":"b"}'
}
nw() { NIGHT_WATCH_NOW="${AT:-2026-01-01T10:30:00}" python3 "$NW/night_watch.py" "$@" 2>&1; }
nwrc() { local rc=0; NIGHT_WATCH_NOW="${AT:-2026-01-01T10:30:00}" python3 "$NW/night_watch.py" "$@" >/dev/null 2>&1 || rc=$?; echo "$rc"; }
NWD="$T/agent_logs/night-watch"; RJ="$NWD/resolved.json"
rcount() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["resolutions"]))' "$RJ"; }
cfg
SUSP="$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r1 abc123)")"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null
out="$(nw resolve latest 1 --note "retry by design")"
has "X1 resolved line" "resolved 20260101T1000-1 until " "$out"
has "X1 undo hint" "undo: scripts/night-watch/run.sh unresolve 20260101T1000-1" "$out"
has "X1 realm stored" '"realm": "payments"' "$(cat "$RJ")"
has "X1 evidence stored" '"abc123"' "$(cat "$RJ")"
has "X1 note stored" '"note": "retry by design"' "$(cat "$RJ")"
ck "X1 UTC, expires 7 days later" "True" "$(python3 -c '
import json,sys; from datetime import datetime, timedelta
r=json.load(open(sys.argv[1]))["resolutions"][0]; a=datetime.fromisoformat(r["resolved_at"]); b=datetime.fromisoformat(r["expires_at"])
print(r["resolved_at"].endswith("+00:00") and b-a==timedelta(days=7))' "$RJ")"
ck "X2 unknown slot exits 1" 1 "$(nwrc resolve 09:00 1 --note x)"
has "X2 names the slot" "09:00" "$(nw resolve 09:00 1 --note x)"
ck "X2 malformed slot exits 2" 2 "$(nwrc resolve nonsense 1 --note x)"
ck "X3 number out of range exits 1" 1 "$(nwrc resolve latest 2 --note x)"
has "X3 says how many it has" "it has 1" "$(nw resolve latest 2 --note x)"
ck "X3 zero exits 1" 1 "$(nwrc resolve latest 0 --note x)"
ck "X3 non-integer exits 2" 2 "$(nwrc resolve latest x --note x)"
rm -f "$RJ"
ck "X4 no note exits 2" 2 "$(nwrc resolve latest 1)"
ck "X4 empty note exits 2" 2 "$(nwrc resolve latest 1 --note "")"
out="$(nw resolve latest 1 --note "ask jane@example.com")"
ck "X4 email in note exits 2" 2 "$(nwrc resolve latest 1 --note "ask jane@example.com")"
has "X4 says personal data" "personal data" "$out"
ck "X4 nothing written" "no" "$([[ -e "$RJ" ]] && echo yes || echo no)"
ck "X4 multi-line note exits 2" 2 "$(nwrc resolve latest 1 --note $'a\nb')"
ck "X4 201-char note exits 2" 2 "$(nwrc resolve latest 1 --note "$(printf 'x%.0s' $(seq 201))")"
mv "$T/scripts/lib/pii-patterns.txt" "$T/pii.bak"
ck "X4 missing PII file exits 2 (fail closed)" "2|no" "$(nwrc resolve latest 1 --note x)|$([[ -e "$RJ" ]] && echo yes || echo no)"
mv "$T/pii.bak" "$T/scripts/lib/pii-patterns.txt"
nw resolve latest 1 --note "retry by design" >/dev/null
ck "X5 resolve again exits 0" 0 "$(nwrc resolve latest 1 --note "other words")"
has "X5 says already" "already resolved 20260101T1000-1" "$(nw resolve latest 1 --note "other words")"
ck "X5 still one entry" 1 "$(rcount)"
reset; say "$(vx ALERT "$(fx payments fixed ALERT r1 abc123)")"; tick 2026-01-01T10:00:00 >/dev/null
ck "X6 ALERT without --alert exits 2" 2 "$(nwrc resolve latest 1 --note x)"
ck "X6 ALERT with --alert exits 0" 0 "$(nwrc resolve latest 1 --note x --alert)"
reset; echo '{"is_error":false,"result":"no verdict here"}' > "$FX/claude.out"; tick 2026-01-01T10:00:00 >/dev/null
ck "X7 FAILED Tick exits 1" 1 "$(nwrc resolve latest 1 --note x)"
has "X7 says FAILED Tick" "FAILED Tick" "$(nw resolve latest 1 --note x)"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; nw resolve latest 1 --note "retry by design" >/dev/null
ck "X8 unresolve exits 0" 0 "$(nwrc unresolve 20260101T1000-1)"
ck "X8 list is empty" "no active resolutions" "$(nw resolved)"
ck "X8 unresolve again exits 1" 1 "$(nwrc unresolve 20260101T1000-1)"
ck "X8 malformed id exits 2" 2 "$(nwrc unresolve bogus)"
nw resolve latest 1 --note "retry by design" >/dev/null
out="$(nw resolved)"
has "X9 lists the id" "20260101T1000-1" "$out"
has "X9 lists the expiry" "until " "$out"
has "X9 lists the note" "note: retry by design" "$out"
: > "$T/marker"; sleep 1; nw resolved >/dev/null
ck "X9 resolved writes nothing" "" "$(find "$NWD" -newer "$T/marker")"
echo '{not json' > "$RJ"; sleep 1; : > "$T/marker"; nw resolved >/dev/null
ck "X9 corrupt file: read-only list creates no aside" "" "$(ls "$NWD" | grep corrupt)"
nw resolve latest 1 --note "retry by design" >/dev/null
mv "$T/workspace.config.yaml" "$T/cfg.bak"
ck "X10 resolve needs no config" 0 "$(nwrc resolve latest 1 --note "again")"
mv "$T/cfg.bak" "$T/workspace.config.yaml"
reset; say "$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r1 a1)" "$(fx auth fixed SUSPICIOUS r2 b1)")"; tick 2026-01-01T10:00:00 >/dev/null
NIGHT_WATCH_NOW=2026-01-01T10:30:00 python3 "$NW/night_watch.py" resolve latest 1 --note one >/dev/null 2>&1 &
NIGHT_WATCH_NOW=2026-01-01T10:30:00 python3 "$NW/night_watch.py" resolve latest 2 --note two >/dev/null 2>&1 &
wait
ck "X11 concurrent resolves keep both" 2 "$(rcount)"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null
echo '{not json' > "$RJ"
ck "C1 corrupt file + resolve exits 0" 0 "$(nwrc resolve latest 1 --note x)"
ck "C1 corrupt file kept aside" "1" "$(ls "$NWD" | grep -c 'resolved.json.corrupt-')"
ck "C1 new file has one entry" 1 "$(rcount)"

# --- resolved cases: a Tick drops a repeat ----------------------------------------------------------
resolve1() { nw resolve latest 1 --note "retry by design" "$@" >/dev/null; }
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1; tick 2026-01-01T11:00:00 >/dev/null
ck "S1 exact repeat: parent + first post + one reply, no new top-level" 3 "$(nsends)"
has "S1 thread reply says only resolved cases" "|on|✅ OK 11:00 — only cases already marked resolved (1)" "$(sendn 3)"
hasnt "S1 no mention on the reply" "<@U1>" "$(sendn 3)"
has "S1 ticks.log counts it" "OK h (resolved earlier: 1)" "$(tlog)"
has "S1 saved Verdict keeps it under suppressed" '"suppressed"' "$(cat "$V/20260101T1100.json")"
has "S1 brief shows it" "resolved earlier (20260101T1000-1)" "$(brief 11:00)"
reset; say "$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r1 a1 a2)")"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
say "$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r1 a2)")"; tick 2026-01-01T11:00:00 >/dev/null
ck "S2 subset of resolved ids is dropped" 3 "$(nsends)"
say "$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r1 a1 new999)")"; tick 2026-01-01T12:00:00 >/dev/null
has "S3 a new evidence id posts top-level, mention, all ids" "-|on|🟡 *SUSPICIOUS 12:00* <@U1>" "$(sendn 4)"
has "S3 shows the new id" "new999" "$(sendn 4)"
reset; say "$(vx ALERT "$(fx payments fixed ALERT r9 x1)" "$(fx payments fixed SUSPICIOUS r1 abc123)")"; tick 2026-01-01T10:00:00 >/dev/null
nw resolve latest 1 --alert --note "known" >/dev/null; n0="$(nsends)"; tick 2026-01-01T11:00:00 >/dev/null
ck "S4 partial: one new top-level post, no ALERT repeat" "$((n0+1))" "$(nsends)"
has "S4 state recomputed to SUSPICIOUS" "-|on|🟡 *SUSPICIOUS 11:00*" "$(sendn "$((n0+1))")"
has "S4 remaining finding shown" '`r1`' "$(sendn "$((n0+1))")"
hasnt "S4 resolved finding hidden" "r9" "$(sendn "$((n0+1))")"
has "S4 count line" "_Already marked resolved, not repeated: 1_" "$(sendn "$((n0+1))")"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
say "$(vx ALERT "$(fx payments fixed ALERT r1 abc123)")"; tick 2026-01-01T11:00:00 >/dev/null
has "S5 escalation to ALERT still posts" "🚨 *ALERT 11:00* <@U1>" "$(sends)"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
say "$(vx SUSPICIOUS "$(fx auth fixed SUSPICIOUS r1 abc123)")"; tick 2026-01-01T11:00:00 >/dev/null
has "S6 other realm posts" "🟡 *SUSPICIOUS 11:00* <@U1>" "$(sends)"
say "$(vx SUSPICIOUS "$(fx payments fixed SUSPICIOUS r2 abc123)")"; tick 2026-01-01T12:00:00 >/dev/null
has "S6 other rule_id posts" "🟡 *SUSPICIOUS 12:00* <@U1>" "$(sends)"
reset; say "$(vx SUSPICIOUS "$(fx auth lead SUSPICIOUS 'odd login burst' t1)")"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
say "$(vx SUSPICIOUS "$(fx auth lead SUSPICIOUS 'login burst' t1)")"; tick 2026-01-01T11:00:00 >/dev/null
ck "S7 lead matches on evidence, not on reworded rule_id" 3 "$(nsends)"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
tick 2026-01-08T11:00:00 >/dev/null
has "S8 expired resolution posts again" "🟡 *SUSPICIOUS 11:00* <@U1>" "$(sends)"
reset; say "$(vx SUSPICIOUS "$(KIND=metric fx payments count SUSPICIOUS c1 pay.counter)")"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
tick 2026-01-02T11:00:00 >/dev/null
has "S9 aggregate-only evidence expires after 1 day" "SUSPICIOUS 11:00" "$(sends)"
reset; say "$(vx SUSPICIOUS "$(KIND=metric fx payments count SUSPICIOUS c1 pay.counter)")"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
tick 2026-01-01T12:00:00 >/dev/null
hasnt "S9 within the day it is suppressed" "SUSPICIOUS 12:00" "$(sends)"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
cfg; echo 'case_report_language: th' >> "$T/workspace.config.yaml"
tick 2026-01-01T11:00:00 >/dev/null
has "S13 Thai OK reply" "มีแต่เคสที่ตรวจแล้วว่าปลอดภัย (1)" "$(sends)"
cfg
reset; say "$SUSP"; mkdir -p "$NWD"; echo '{not json' > "$RJ"; tick 2026-01-01T10:00:00 >/dev/null
has "C2 corrupt file is treated as empty: finding posts" "🟡 *SUSPICIOUS 10:00* <@U1>" "$(sends)"
ck "C2 corrupt file kept aside" 1 "$(ls "$NWD" | grep -c 'resolved.json.corrupt-')"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; resolve1
tick 2026-01-01T11:00:00 >/dev/null
has "S10 prompt carries the resolution id" "20260101T1000-1" "$(cat "$FX/claude.argv")"
has "S10 prompt carries the note" "retry by design" "$(cat "$FX/claude.argv")"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null
has "S10 no resolutions: none" "none" "$(cat "$FX/claude.argv")"
argv="$(cat "$FX/claude.argv")"
has "S12 engine commands disallowed (run.sh)" "night-watch/run.sh" "$argv"
has "S12 engine commands disallowed (py)" "night_watch.py" "$argv"
RT="$(cd "$T" && pwd -P)"
has "S12 Edit on the records dir disallowed" "Edit(/$RT/agent_logs/night-watch/**)" "$argv"
has "S12 Write on the records dir disallowed" "Write(/$RT/agent_logs/night-watch/**)" "$argv"
reset; say "$SUSP"; tick 2026-01-01T10:00:00 >/dev/null; : > "$T/empty.json"
python3 -c 'import json,sys; json.dump({"version":1,"resolutions":[{"id":"20260101T0900-1","realm":"payments","rule":"fixed","rule_id":"r1","severity":"SUSPICIOUS","evidence":["abc123"],"expires_at":"2030-01-01T00:00:00+00:00"}]},open(sys.argv[1],"w"))' "$T/forged.json"
echo '{"version":1,"resolutions":[]}' > "$RJ"; : > "$T/marker"
export FAKE_WRITE="$T/forged.json"; tick 2026-01-01T11:00:00 >/dev/null; unset FAKE_WRITE
has "S11 a write during the Tick does not change that Tick" "🟡 *SUSPICIOUS 11:00* <@U1>" "$(sends)"
ck "P1 matches truth table" "True True False False False False True" "$(py "
f=lambda realm='payments',sev='SUSPICIOUS',rid='r1',ids=('a',),rule='fixed': {'realm':realm,'severity':sev,'rule_id':rid,'rule':rule,'evidence':[{'id':i} for i in ids]}
r={'realm':'payments','severity':'SUSPICIOUS','rule_id':'R1','rule':'fixed','evidence':['a','b']}
ra=dict(r,severity='ALERT')
print(n.matches(f(),r), n.matches(f(ids=('a','b')),r), n.matches(f(ids=('a','c')),r), n.matches(f(realm='auth'),r),
      n.matches(f(rid='r2'),r), n.matches(f(sev='ALERT'),r), n.matches(f(sev='SUSPICIOUS',rid='other',rule='lead'),dict(r,rule='lead')))")"
ck "P2 both findings covered: 2 dropped, state OK" "2 OK" "$(py "
mk=lambda i:{'realm':'payments','severity':'SUSPICIOUS','rule_id':'r%d'%i,'rule':'fixed','evidence':[{'id':'a%d'%i}]}
rs=[{'id':'x%d'%i,'realm':'payments','severity':'SUSPICIOUS','rule_id':'r%d'%i,'rule':'fixed','evidence':['a%d'%i]} for i in (1,2)]
v={'state':'SUSPICIOUS','findings':[mk(1),mk(2)]}
print(n.apply_resolutions(v,rs), v['state'])")"

# --- retention ---------------------------------------------------------------------------------
cfg; NWD="$T/agent_logs/night-watch"
age() { touch -t "$1" "${@:2}"; }
reset; say "$OKV"; mkdir -p "$NWD/verdicts" "$T/outside" "$T/outside2"
: > "$NWD/verdicts/20260101T1000.json"; age 202601020000 "$NWD/verdicts/20260101T1000.json"
: > "$NWD/verdicts/20260105T1000.json"; age 202601050000 "$NWD/verdicts/20260105T1000.json"
for f in state.json tick.lock ticks.log; do echo x > "$NWD/$f"; age 202512010000 "$NWD/$f"; done
echo '{"version":1,"resolutions":[]}' > "$NWD/resolved.json"; age 202512010000 "$NWD/resolved.json"
for f in state.json.corrupt-20251201T1000 agent.stderr .state.x.tmp; do : > "$NWD/$f"; age 202512010000 "$NWD/$f"; done
: > "$T/outside/f"; age 202512010000 "$T/outside/f"; ln -s "$T/outside/f" "$NWD/verdicts/old.json"
mkdir -p "$NWD/verdicts/sub"; : > "$NWD/verdicts/sub/f"; age 202512010000 "$NWD/verdicts/sub/f" "$NWD/verdicts/sub"
tick 2026-01-10T10:00:00 >/dev/null
[[ ! -e "$NWD/verdicts/20260101T1000.json" ]] && ok "R1 old verdict deleted" || bad "R1 old verdict deleted" "still there"
[[ -e "$NWD/verdicts/20260105T1000.json" && -e "$NWD/verdicts/20260110T1000.json" ]] && ok "R1 recent verdicts kept" || bad "R1 recent verdicts kept" "$(ls "$NWD/verdicts")"
[[ -e "$NWD/state.json" && -e "$NWD/tick.lock" && -e "$NWD/ticks.log" ]] && ok "R2 state, lock, log kept" || bad "R2 state, lock, log kept" "$(ls -a "$NWD")"
[[ -e "$NWD/resolved.json" ]] && ok "R8 resolved.json kept" || bad "R8 resolved.json kept" "$(ls -a "$NWD")"
[[ ! -e "$NWD/state.json.corrupt-20251201T1000"&& ! -e "$NWD/agent.stderr" && ! -e "$NWD/.state.x.tmp" ]] && ok "R3 stray old files deleted" || bad "R3 stray old files deleted" "$(ls -a "$NWD")"
[[ -L "$NWD/verdicts/old.json" && -e "$T/outside/f" ]] && ok "R4 symlink and target intact" || bad "R4 symlink and target intact" ""
[[ -e "$NWD/verdicts/sub/f" ]] && ok "R6 directory and contents intact" || bad "R6 directory and contents intact" ""
reset; say "$OKV"; mkdir -p "$NWD"; : > "$T/outside2/old.json"; age 202512010000 "$T/outside2/old.json"
ln -s "$T/outside2" "$NWD/verdicts"; tick 2026-01-10T10:00:00 >/dev/null
[[ -e "$T/outside2/old.json" ]] && ok "R5 linked verdicts/ untouched" || bad "R5 linked verdicts/ untouched" ""
reset; say "$OKV"; mkdir -p "$NWD/verdicts"; : > "$NWD/verdicts/20260101T1000.json"; age 202601020000 "$NWD/verdicts/20260101T1000.json"
cfg "08:00-20:00"; tick 2026-01-10T22:00:00 >/dev/null; cfg
[[ -e "$NWD/verdicts/20260101T1000.json" ]] && ok "R7 OUTSIDE slot does not prune" || bad "R7 OUTSIDE slot does not prune" ""

# --- linked records directory ------------------------------------------------------------------
reset; say "$OKV"; mkdir -p "$T/primary-nw" "$T/agent_logs"; ln -s "$T/primary-nw" "$NWD"
rc="$(tick 2026-01-01T10:00:00)"; ck "G1 tick exits 2" 2 "$rc"; ck "G1 no post" 0 "$(nsends)"
rc=0; NIGHT_WATCH_NOW=2026-01-01T10:00:00 python3 "$NW/night_watch.py" loop >/dev/null 2>&1 || rc=$?
ck "G2 loop exits 2" 2 "$rc"
ck "G3 primary untouched" "" "$(ls -A "$T/primary-nw")"
mkdir -p "$T/primary-nw/verdicts"; echo '{"state":"OK","headline":"x"}' > "$T/primary-nw/verdicts/20260101T1000.json"
has "G3 brief still works through the link" "headline: x" "$(brief latest)"
echo "$SUSP" > "$T/primary-nw/verdicts/20260101T1100.json"
ck "L1 resolve through the link exits 0" 0 "$(nwrc resolve latest 1 --note x)"
ck "L1 lands in the primary directory" "yes" "$([[ -e "$T/primary-nw/resolved.json" ]] && echo yes || echo no)"
ck "L1 the link is still a link" "yes" "$([[ -L "$NWD" ]] && echo yes || echo no)"
has "L1 resolved works through the link" "20260101T1100-1" "$(nw resolved)"
ck "L1 tick still exits 2" 2 "$(tick 2026-01-01T11:00:00)"
rm -f "$NWD"

# --- labelled evidence stays id-keyed ------------------------------------------------------------
rm -rf "$T/primary-nw" "$NWD"; mkdir -p "$NWD"
LAB='{"rule":"fixed","rule_id":"r1","severity":"SUSPICIOUS","realm":"payments","title":"t","evidence":[{"kind":"trace","id":"abc123","label":"first run","target":"svc"},{"kind":"identity","id":"a-1","role":"admin","label":"actor","name":"Ops Lead","email":"ops.lead@corp.example"}]}'
LAB2="${LAB//first run/second run}"
reset; say "$(vx SUSPICIOUS "$LAB")"; tick 2026-01-01T10:00:00 >/dev/null; nw resolve latest 1 --note n >/dev/null
ck "E21 resolve stores ids only" "[['abc123', 'a-1']]" "$(python3 -c 'import json,sys; print([r["evidence"] for r in json.load(open(sys.argv[1]))["resolutions"]])' "$RJ")"
hasnt "E21 resolved.json has no staff data" "ops.lead" "$(cat "$RJ")"
say "$(vx SUSPICIOUS "$LAB2")"; tick 2026-01-01T11:00:00 >/dev/null
has "E22 labelled repeat is dropped" "✅ OK 11:00 — only cases already marked resolved (1)" "$(sends)"
out="$(brief 10:00)"
has "E23 brief prints label" "trace abc123 target=svc label=first run" "$out"
has "E23 brief prints role and staff fields" "identity a-1 label=actor role=admin name=Ops Lead email=ops.lead@corp.example" "$out"
argv="$(cat "$FX/claude.argv")"
has "E24 prompt carries the evidence label rule" "\`label\`" "$argv"
has "E24 prompt carries the staff role rule" "\`role\`" "$argv"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
