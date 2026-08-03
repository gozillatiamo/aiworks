-- Push-to-talk key handler for the voice adapter.
--
-- GENERATED into ~/.hammerspoon/ by `aiworks voice ptt install`. Edit THIS file (the template)
-- and re-run install; a hand-edit in ~/.hammerspoon is overwritten without warning.
--
-- The split of responsibilities is deliberate:
--   scripts/voice/ptt.sh   owns the microphone and the transcript
--   this file              owns the KEYBOARD — the hotkey, the HUD, and the decision about
--                          whether the frontmost window is a session it may type into
-- A shell cannot see the window list, and Lua has no business shelling out to vendors.
--
-- ── THE HOTKEY comes from `voice.push_to_talk.hotkey` ─────────────────────────────
-- Left and right modifiers are separate keycodes, so a RIGHT-side chord collides with nothing:
-- every existing ⌘-shortcut, Spotlight's ⌘Space included, keeps working untouched.
--
--   right_cmd+right_alt   works on ANY keyboard, no collision — the sane default
--   right_alt             single key, held past 0.25 s; ⌥ alone does nothing in most apps
--   right_cmd             single key; ⌘ alone is common, so the hold threshold matters more
--   fn+right_cmd          BUILT-IN Apple keyboard ONLY (see the fn note below)
--
-- ⚠ `fn` FROM AN EXTERNAL KEYBOARD DOES NOT EXIST as far as macOS is concerned — measured here
--   with a Keychron K1 attached: holding fn + Right ⌘ delivered `keyCode=54 flags=[cmd]` and no
--   fn event whatsoever. Its fn key is firmware-local. No `AppleFnUsageType` value changes that.
--
-- ⚠ If you DO use `fn+…` on the laptop keyboard, set `AppleFnUsageType -int 0` (Globe → Do
--   Nothing) and log out/in: with two input sources installed a bare fn tap otherwise means
--   "Change Input Source", so a mistimed release flips your layout mid-sentence. ⌃⌥Space still
--   switches language.
--
-- ── `space` DURING THE HOLD = REVIEW MODE ─────────────────────────────────────────
-- Paste the text but do NOT press Enter, so you can fix a mis-heard word first. The key is
-- SWALLOWED (the eventtap returns true), which is what stops the space from reaching the app —
-- and stops ⌘+space from opening Spotlight over your session.

local M = {}

local VOICE = "@@VOICE_DIR@@"          -- filled in by `aiworks voice ptt install`
local PTT = VOICE .. "/ptt.sh"
local LOGDIR = os.getenv("HOME") .. "/.cache/aiworks/voice/ptt"
local LOG = LOGDIR .. "/hammerspoon.log"
local DEBUG_FLAG = LOGDIR .. "/debug"   -- `aiworks voice ptt debug on` creates this
local PREVIEW = LOGDIR .. "/preview.txt"
local REC_RAW = LOGDIR .. "/rec.pcm"
local RATE = 16000

-- Declared HERE, above every function that touches it. Same reason as MODS below: a `local`
-- referenced from a function defined earlier in the file compiles as a nil GLOBAL and blows up at
-- runtime — which already cost this file one silently dead hotkey.
local state = { holding = false, review = false, hud = nil, poll = nil,
                down = {}, armTimer = nil, meter = {}, ticks = 0, text = nil }

-- ── the level meter ───────────────────────────────────────────────────────────────
-- Reads the tail of the raw capture and turns it into a bar. This is the answer to "it feels
-- laggy": the transcript cannot arrive faster than a recognizer can produce it (~1.5 s), but
-- "is it hearing me?" is answerable in one frame — and that is the question people are actually
-- asking. Costs nothing: no network, no process, just the last few kilobytes of a file that is
-- already being written.
--
-- Only possible because capture is raw PCM. A wav would still be zero bytes at this point.
local BLOCKS = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }
local METER_WIDTH = 44

local function tailPeak()
  local f = io.open(REC_RAW, "rb")
  if not f then return nil end
  local size = f:seek("end") or 0
  local want = math.floor(RATE * 2 * 0.08)          -- 80 ms of audio
  if size < 64 then f:close(); return nil end
  local from = math.max(0, size - want)
  if from % 2 == 1 then from = from + 1 end         -- int16 frames: never start mid-sample
  f:seek("set", from)
  local data = f:read(want)
  f:close()
  if not data or #data < 4 then return nil end

  -- Every 8th sample: 16-bit peak needs no better resolution than that for a bar, and it keeps
  -- this loop at a couple of hundred iterations per frame instead of a couple of thousand.
  local peak = 0
  for i = 1, #data - 1, 16 do
    local lo, hi = data:byte(i), data:byte(i + 1)
    if not hi then break end
    local v = hi * 256 + lo
    if v >= 32768 then v = v - 65536 end
    if v < 0 then v = -v end
    if v > peak then peak = v end
  end
  return peak / 32768
end

-- Speech occupies a small part of the top of the scale, so a linear bar barely moves. dBFS with
-- a -55 dB floor is what makes a normal voice fill most of the meter.
local function meterBar(level)
  local hist = state.meter
  local n = 1
  if level and level > 0 then
    local db = 20 * math.log(level, 10)
    n = math.floor(((db + 55) / 55) * #BLOCKS + 0.5)
    if n < 1 then n = 1 elseif n > #BLOCKS then n = #BLOCKS end
  end
  table.insert(hist, BLOCKS[n])
  while #hist > METER_WIDTH do table.remove(hist, 1) end
  return table.concat(hist)
end

-- Read a small file, or nil. Used for the live preview instead of `hs.execute("ptt.sh preview")`:
-- shelling out three times a second BLOCKS Hammerspoon's runloop, and a blocked runloop is how
-- macOS decides an eventtap is unresponsive and disables it — silently killing the hotkey. The
-- preview is just a file; read the file.
local function slurp(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  if not s then return nil end
  s = s:gsub("%s+$", "")
  if #s == 0 then return nil end
  return s
end

-- ── modifier keys, by SIDE ─────────────────────────────────────────────────────────
-- DECLARED HERE, ABOVE EVERYTHING THAT USES THEM. Lua resolves a `local` only from its
-- declaration onward, so when these lived further down, `describe()` referenced them as nil
-- GLOBALS and every single keyboard event died with "attempt to call a nil value (global
-- 'rawFlags')" — the hotkey looked completely dead while the tap was in fact receiving
-- everything. Keep the definition order.
--
-- `bit` is the DEVICE-DEPENDENT mask from IOKit (NX_DEVICEL/RCMDKEYMASK and friends), and it is
-- what makes a same-flag chord possible at all. The cooked flag is per-MODIFIER, not per-KEY:
-- Left ⌘ and Right ⌘ both set `flags.cmd`. So "is Right ⌘ still down?" cannot be answered from
-- `flags.cmd` while the other ⌘ is held — a chord like left_cmd+right_cmd would start recording
-- and then never stop. The raw bits say exactly which physical key is down.
local MODS = {
  right_cmd   = { code = 54, flag = "cmd",   bit = 0x00000010 },
  left_cmd    = { code = 55, flag = "cmd",   bit = 0x00000008 },
  right_alt   = { code = 61, flag = "alt",   bit = 0x00000040 },
  left_alt    = { code = 58, flag = "alt",   bit = 0x00000020 },
  right_ctrl  = { code = 62, flag = "ctrl",  bit = 0x00002000 },
  left_ctrl   = { code = 59, flag = "ctrl",  bit = 0x00000001 },
  right_shift = { code = 60, flag = "shift", bit = 0x00000004 },
  left_shift  = { code = 56, flag = "shift", bit = 0x00000002 },
}

-- Arithmetic rather than the `&` operator: `&` needs Lua 5.3+, and this file has to load in
-- whatever Lua the installed Hammerspoon carries.
local function hasBit(raw, bit)
  if not raw then return nil end
  return math.floor(raw / bit) % 2 == 1
end

local function rawFlags(e)
  local ok, data = pcall(function() return e:getRawEventData().CGEventData.flags end)
  if ok then return data end
  return nil
end

-- ── logging, to a FILE ────────────────────────────────────────────────────────────
-- Hammerspoon's console lives in the app's memory, which nothing outside it can read — so
-- diagnosing "the hotkey does nothing" meant guessing. Everything interesting goes to a file
-- instead, which is greppable, and which `aiworks voice ptt doctor` reads back.
local function log(msg)
  local f = io.open(LOG, "a")
  if not f then return end
  f:write(os.date("%H:%M:%S") .. "  " .. msg .. "\n")
  f:close()
end

local function debugOn()
  local f = io.open(DEBUG_FLAG, "r")
  if f then f:close(); return true end
  return false
end

-- A readable dump of what the machine ACTUALLY reported for a modifier event. This is the
-- answer to "did I hold the right keys?" — keycode plus every flag, verbatim.
-- Also dumps the per-SIDE raw bits, because the cooked flags cannot distinguish Left ⌘ from
-- Right ⌘ and that distinction is the whole basis of the chord.
local function describe(e)
  local fl, out = e:getFlags(), {}
  for _, k in ipairs({ "fn", "cmd", "alt", "ctrl", "shift", "capslock" }) do
    if fl[k] then table.insert(out, k) end
  end
  local sides = {}
  local raw = rawFlags(e)
  if raw then
    for name, m in pairs(MODS) do
      if hasBit(raw, m.bit) then table.insert(sides, name) end
    end
    table.sort(sides)
  end
  return string.format("keyCode=%d flags=[%s] keys_down=[%s]", e:getKeyCode(),
                       #out > 0 and table.concat(out, "+") or "none",
                       raw and (#sides > 0 and table.concat(sides, "+") or "none") or "raw unavailable")
end

-- Apps we may type into. An allow-list, not a deny-list: typing a dictated sentence into the
-- wrong window is unrecoverable (it could go into a chat, a browser form, a customer ticket),
-- so anything unrecognised gets the clipboard instead.
local SESSION_APPS = {
  ["iTerm2"] = true, ["Terminal"] = true, ["Ghostty"] = true, ["Alacritty"] = true,
  ["WezTerm"] = true, ["kitty"] = true, ["Warp"] = true,
  ["Cursor"] = true, ["Code"] = true, ["Visual Studio Code"] = true,
  ["Claude"] = true, ["Claude Code"] = true,
}

-- ── the chord, read from config ────────────────────────────────────────────────────
-- Every modifier key macOS reports by SIDE. Left and right are different keycodes on purpose:
-- binding "cmd" would eat a modifier you press a hundred times an hour.
-- `fn` is NOT in the MODS table above, and cannot be: it is a FLAG with no dependable key event.
--
-- MEASURED on this machine — with an external Keychron K1 attached, holding fn + Right ⌘ logged
-- `keyCode=54 flags=[cmd]` and NO fn event at all. An external keyboard's fn key is handled by
-- its own firmware and never reaches macOS as a modifier, so `fn+…` can only ever work on the
-- built-in Apple keyboard, whatever `AppleFnUsageType` is set to. It stays supported for people
-- on a laptop keyboard only; a two-modifier chord works everywhere.
local HOTKEY = "@@HOTKEY@@"            -- from voice.push_to_talk.hotkey
local HOLD_DELAY = 0.25                -- single-modifier chords only — see below

local chord = { parts = {}, needFn = false, single = false }
-- `raw` then `part`, not one reassigned variable: a `for … in` control variable is const under
-- Lua 5.4, which is what `luac -p` verifies with even though Hammerspoon runs an older Lua.
for raw in HOTKEY:gmatch("[^+]+") do
  local part = raw:gsub("%s", ""):lower()
  if part == "fn" then chord.needFn = true
  elseif MODS[part] then table.insert(chord.parts, part) end
end
if #chord.parts == 0 then chord.parts = { "right_cmd" } end
-- A chord that is ONE modifier and nothing else would fire every time you rest a finger on ⌘,
-- so it has to be HELD past a threshold before recording starts. A two-key chord is unambiguous
-- the moment both are down and needs no delay.
chord.single = (#chord.parts == 1 and not chord.needFn)

-- What to call the chord on screen. Symbols, because that is what is printed on the keys.
local SYMBOL = { right_cmd = "Right ⌘", left_cmd = "Left ⌘", right_alt = "Right ⌥",
                 left_alt = "Left ⌥", right_ctrl = "Right ⌃", left_ctrl = "Left ⌃",
                 right_shift = "Right ⇧", left_shift = "Left ⇧" }
local label
do
  local bits = {}
  if chord.needFn then table.insert(bits, "fn") end
  for _, part in ipairs(chord.parts) do table.insert(bits, SYMBOL[part] or part) end
  label = table.concat(bits, " + ")
end

-- ── HUD ───────────────────────────────────────────────────────────────────────────
-- An always-open microphone must never be invisible, and the preview text is the whole reason
-- auto-Enter is safe: you see what it heard before it is sent.
-- Built ONCE per hold and then mutated in place. Deleting and re-creating a canvas at 12 frames a
-- second churns objects on Hammerspoon's runloop, and a busy runloop is how macOS decides an
-- eventtap is unresponsive and disables it — the failure mode this file has already hit once.
-- Element indices: 1 backdrop · 2 status dot · 3 level meter · 4 text
local HUD_W, HUD_H = 640, 96

local function hudEnsure()
  if state.hud then return end
  local screen = hs.screen.mainScreen():frame()
  state.hud = hs.canvas.new({ x = screen.x + (screen.w - HUD_W) / 2,
                              y = screen.y + screen.h - 190, w = HUD_W, h = HUD_H })
  state.hud:appendElements(
    { type = "rectangle", action = "fill", roundedRectRadii = { xRadius = 14, yRadius = 14 },
      fillColor = { red = 0, green = 0, blue = 0, alpha = 0.84 } },
    { type = "circle", action = "fill", center = { x = 26, y = 30 }, radius = 7,
      fillColor = { red = 1, green = 0.25, blue = 0.25, alpha = 1 } },
    -- Monospaced, or the bar jitters horizontally as the block characters change width.
    { type = "text", text = "", textColor = { red = 0.45, green = 0.95, blue = 0.55, alpha = 1 },
      textSize = 15, textFont = "Menlo", frame = { x = 46, y = 14, w = HUD_W - 60, h = 26 } },
    { type = "text", text = "", textColor = { white = 1 }, textSize = 15,
      frame = { x = 46, y = 44, w = HUD_W - 60, h = HUD_H - 50 } }
  )
  state.hud:show()
end

local function hudSet(text)
  hudEnsure()
  if text then state.text = text end
  state.hud[2].fillColor = state.review and { red = 1, green = 0.75, blue = 0.1, alpha = 1 }
                                         or { red = 1, green = 0.25, blue = 0.25, alpha = 1 }
  state.hud[4].text = state.text or ""
end

-- One frame of the meter. Called on a fast timer; deliberately does nothing else.
local function hudTick()
  hudEnsure()
  state.hud[3].text = meterBar(tailPeak())
end

local function hudHide()
  if state.poll then state.poll:stop(); state.poll = nil end
  if state.hud then state.hud:delete(); state.hud = nil end
  state.meter, state.text, state.ticks = {}, nil, 0
end

local function hudFlash(text, secs)
  hudSet(text)
  if state.hud then state.hud[3].text = "" end     -- the meter is meaningless once recording stops
  hs.timer.doAfter(secs or 2.5, hudHide)
end

-- Kept so the older call sites read the same as before.
local function hudShow(text) hudSet(text) end

-- ── start / stop ──────────────────────────────────────────────────────────────────
local function startHold()
  if state.holding then return end
  state.holding, state.review = true, false
  log("hold START")
  state.meter, state.ticks = {}, 0
  hudSet("กำลังฟัง…  (ปล่อยเพื่อส่ง · space = แก้ก่อนส่ง)")
  hs.task.new("/bin/bash", nil, { PTT, "start" }):start()

  -- ONE timer, two jobs at different rates. The METER is the point: it moves within a frame of
  -- your voice, which answers "is it hearing me?" instantly — and that, not the transcript, is
  -- what "it feels laggy" actually means. The transcript cannot beat the recognizer (~1.5 s), so
  -- it is read at a fifth of the rate; re-reading it 12 times a second would buy nothing.
  state.poll = hs.timer.doEvery(0.08, function()
    if not state.holding then return end
    hudTick()
    state.ticks = state.ticks + 1
    if state.ticks % 5 == 0 then
      local out = slurp(PREVIEW)
      if out then hudSet(out) end
    end
  end)
end

local function inject(text)
  local app = hs.application.frontmostApplication()
  local name = app and app:name() or "?"
  if not SESSION_APPS[name] then
    -- Never type into a window we do not recognise. The clipboard keeps the work.
    log("frontmost app '" .. name .. "' is not in SESSION_APPS — clipboard instead of typing")
    hs.pasteboard.setContents(text)
    hudFlash("⌘V เพื่อวาง — หน้าต่างหน้าสุดคือ " .. name .. " ไม่ใช่ session", 4)
    return
  end
  log("injecting into '" .. name .. "' (" .. #text .. " chars)")

  -- Resolved once at load, not per utterance: it is config, it cannot change mid-session, and
  -- keeping shell calls off this path is the same reason the preview reads a file.
  -- `aiworks voice ptt install` re-reads it (it reloads Hammerspoon).
  local autosend = M.autosend

  -- keyStrokes with Thai text is the unproven part of this design (plan risk #1). If it ever
  -- mangles the text, swap the next line for a clipboard + synthetic ⌘V, which is unicode-safe.
  hs.eventtap.keyStrokes(text)
  if autosend and not state.review then
    hs.timer.doAfter(0.12, function() hs.eventtap.keyStroke({}, "return", 0) end)
    hudFlash("ส่งแล้ว: " .. text, 2)
  else
    hudFlash((state.review and "แก้ได้เลย แล้วกด Enter: " or "กด Enter เพื่อส่ง: ") .. text, 4)
  end
end

local function endHold()
  if not state.holding then return end
  state.holding = false
  if state.poll then state.poll:stop(); state.poll = nil end
  log("hold END — transcribing" .. (state.review and " (review mode)" or ""))
  hudShow("◌ ถอดเสียง…")
  -- hs.task, not hs.execute: transcription takes a second or two and blocking the Hammerspoon
  -- runloop freezes every hotkey on the machine, including this one.
  -- `-v` plus a KEPT stderr, because "nothing heard" was undiagnosable. ptt.sh exits 1 for four
  -- different reasons — nothing recorded · could not wrap the capture · no speech in the audio ·
  -- no transcript — and this callback used to throw stderr away and log all four with the same
  -- sentence. Measured against a real complaint: every link tested good in isolation (the chord
  -- fired, capture worked from the terminal AND from a Hammerspoon child, STT transcribed a known
  -- file) and the log still could not say which one gave up during an actual hold. The vlog writes
  -- to stderr, which nothing here was reading, so `-v` costs nothing and buys the reason.
  hs.task.new("/bin/bash", function(rc, stdout, stderr)
    local text = (stdout or ""):gsub("%s+$", "")
    if rc ~= 0 or #text == 0 then
      -- The LAST vlog line is the one that decided. The device and the levels are logged too when
      -- they are there: "no speech in 2s" is a different bug depending on whether the mic that was
      -- open is the one you were talking into.
      local why = ""
      for line in (stderr or ""):gmatch("[^\n]+") do
        if line:match("^voice: ptt:") then why = line:gsub("^voice: ptt: ", "") end
      end
      log("ptt.sh stop rc=" .. tostring(rc) .. " — " .. (why ~= "" and why or "no text, and no reason on stderr"))
      for line in (stderr or ""):gmatch("[^\n]+") do
        if line:match("mean .*dB") or line:match("mic '") then log("  " .. line:gsub("^voice: ptt: ", "")) end
      end
      hudFlash("ไม่ได้ยินอะไรครับ", 1.5)
      return
    end
    -- The WORDS only under debug. ptt.sh deletes the recording as soon as it has the transcript;
    -- writing that same transcript into a permanent log would put back on disk exactly what was
    -- just deleted, one representation over. The length is enough to diagnose with.
    if debugOn() then
      log("transcript (" .. #text .. " chars): " .. text)
    else
      log("transcript (" .. #text .. " chars)")
    end
    inject(text)
  end, { PTT, "-v", "stop" }):start()
end

-- ── the taps ──────────────────────────────────────────────────────────────────────
function M.start()
  os.execute("mkdir -p '" .. LOGDIR .. "'")

  -- `autosend` couples to the preview: pressing Enter on words you were never shown is not a
  -- feature, so ptt.sh forces it off when preview.provider is none — and that coupling is
  -- decided in ONE place, there, rather than re-derived here.
  local policy = hs.execute(PTT .. " policy 2>/dev/null") or ""
  M.autosend = policy:match("autosend=(%d)") == "1"
  M.previewProvider = policy:match("preview=(%S+)") or "?"
  log("policy: autosend=" .. tostring(M.autosend) .. " preview=" .. M.previewProvider)

  -- An eventtap with no Accessibility grant starts "successfully" and then receives NOTHING —
  -- the single most likely reason for "the hotkey does nothing", and silent by default. Say so
  -- loudly, in the log and on screen.
  if not hs.accessibilityState() then
    log("FATAL: Hammerspoon has no Accessibility permission — no key event will ever arrive.")
    log("  Fix: System Settings → Privacy & Security → Accessibility → enable Hammerspoon,")
    log("  then reload the Hammerspoon config.")
    hs.alert.show("Sunmi: Hammerspoon needs Accessibility permission", 6)
  else
    log("accessibility OK")
  end

  -- Two ways to ask the running Hammerspoon a question from a shell, both needed because each
  -- fails differently:
  --   hs.ipc      — feeds the `hs` CLI. NOTE it only answers the `hs` that Hammerspoon itself
  --                 installs; a Homebrew `hs` on PATH is a different build and just hangs.
  --   AppleScript — `osascript -e 'tell application "Hammerspoon" to execute lua code "…"'`.
  --                 Disabled by default, and enabled here ONLY while debugging: it lets any
  --                 local process run Lua inside Hammerspoon, which is not a standing state to
  --                 leave a machine in for the sake of a diagnostic.
  local ok_ipc = pcall(function() require("hs.ipc"); hs.ipc.cliInstall() end)
  log("hs.ipc " .. (ok_ipc and "installed" or "unavailable")
      .. " (the `hs` CLI only answers Hammerspoon's own build, not Homebrew's)")
  if debugOn() then
    pcall(function() hs.allowAppleScript(true) end)
    log("AppleScript bridge ON (debug only) — osascript can query this handler")
  else
    pcall(function() hs.allowAppleScript(false) end)
  end

  -- `fn` arrives as a flagsChanged event, and Right ⌘ has to be distinguished from Left ⌘ by
  -- keycode, so this is a raw eventtap rather than an hs.hotkey binding.
  M.flagsTap = hs.eventtap.new({ hs.eventtap.event.types.flagsChanged }, function(e)
    local flags, code = e:getFlags(), e:getKeyCode()
    -- pcall, because a diagnostic must never be able to break the thing it diagnoses. It already
    -- did once: a nil-reference inside describe() aborted the callback on its FIRST line, so no
    -- chord logic ever ran and the hotkey appeared stone dead — but only while debug was ON,
    -- which is exactly when someone is trying to find out why it is dead.
    if debugOn() then
      local ok, desc = pcall(describe, e)
      log("flagsChanged  " .. (ok and desc or ("describe() failed: " .. tostring(desc))))
    end

    -- Per-KEY state from the raw device bits, which is authoritative for every side and every
    -- combination. The keyCode path below is a fallback for a Hammerspoon build that will not
    -- hand over raw event data: it is correct for chords whose keys have DIFFERENT flags, and
    -- it is the best that can be done without the raw bits.
    local raw = rawFlags(e)
    for _, part in ipairs(chord.parts) do
      local m = MODS[part]
      local bitState = hasBit(raw, m.bit)
      if bitState ~= nil then
        state.down[part] = bitState
      elseif m.code == code then
        state.down[part] = flags[m.flag] and true or false
      end
    end

    local all = true
    for _, part in ipairs(chord.parts) do if not state.down[part] then all = false end end
    if chord.needFn and not flags.fn then all = false end

    if all and not state.holding then
      if chord.single and not state.armTimer then
        -- Held, not tapped: a bare ⌘/⌥ press is far too ordinary to treat as intent.
        state.armTimer = hs.timer.doAfter(HOLD_DELAY, function()
          state.armTimer = nil
          local still = true
          for _, part in ipairs(chord.parts) do if not state.down[part] then still = false end end
          if still then startHold() end
        end)
      elseif not chord.single then
        startHold()
      end
    elseif not all then
      if state.armTimer then state.armTimer:stop(); state.armTimer = nil end
      if state.holding then endHold() end
    end
    return false
  end)
  M.flagsTap:start()
  log(string.format("flagsTap started — chord '%s' (%s%s)", HOTKEY,
      table.concat(chord.parts, "+"), chord.needFn and " +fn flag" or ""))
  if chord.needFn then
    log("  NOTE fn only reaches macOS from the BUILT-IN keyboard; an external one never sends it")
  end

  -- space during the hold ⇒ review mode, and the key is SWALLOWED so it neither types a space
  -- nor lets ⌘+space reach Spotlight.
  M.spaceTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    if debugOn() and state.holding then log("keyDown       keyCode=" .. e:getKeyCode()) end
    if state.holding and e:getKeyCode() == hs.keycodes.map.space then
      state.review = true
      hudShow("◐ โหมดแก้ก่อนส่ง — จะวางให้แต่ไม่กด Enter")
      return true
    end
    return false
  end)
  M.spaceTap:start()

  log("loaded OK — hold " .. label .. (debugOn() and "  [DEBUG: logging every modifier event]" or ""))
  hs.alert.show("Sunmi push-to-talk พร้อม (" .. label .. ")")
end

-- Drive the whole chain WITHOUT a key press: hold for `secs`, then release. This separates the
-- two things that "the hotkey does nothing" can mean — a broken pipeline, or a key the machine
-- reports differently than expected. If simulate works and the physical keys do not, the
-- problem is purely key detection, and the debug log says what your keys actually send.
function M.simulate(secs)
  startHold()
  hs.timer.doAfter(tonumber(secs) or 3, endHold)
  return "holding for " .. (secs or 3) .. "s"
end

-- Callable from `hs -c 'require("voice-ptt").selftest()'` once hs.ipc is up.
function M.selftest()
  return string.format("accessibility=%s flagsTap=%s spaceTap=%s holding=%s ptt=%s",
    tostring(hs.accessibilityState()),
    tostring(M.flagsTap and M.flagsTap:isEnabled()),
    tostring(M.spaceTap and M.spaceTap:isEnabled()),
    tostring(state.holding), PTT)
end

M.start()
return M
