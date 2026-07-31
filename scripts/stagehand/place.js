#!/usr/bin/osascript -l JavaScript
//
// stagehand — the occupancy-based auto placer.
//
// Usage:  osascript -l JavaScript place.js <process-name> [--dry-run] [--protect <process>]
//
// WHAT IT DOES: looks at where every visible window on every display actually is right now,
// scores a grid of candidate slots by how much they would OVERLAP those windows, and moves the
// target app's front window to the cheapest slot. Nothing is pinned to a display — the target
// goes wherever there is real free space at that moment.
//
// WHY NOT RECTANGLE FOR THIS: Rectangle is installed and its URL scheme works (measured:
// `open -g 'rectangle://execute-action?name=top-half'` resized Cursor and did NOT activate
// Rectangle). But `execute-action` takes no app-bundle-id — it acts on the FRONTMOST window
// only, so driving it means focusing the target app first, i.e. stealing the keyboard mid-turn
// while the user is typing in the terminal. Placement here goes straight through the
// Accessibility API instead, which needs no focus change. `placement: rectangle` in config
// still exists for anyone who prefers Rectangle's exact grid and does not mind the focus cost.
//
// COORDINATES — the one real trap. NSScreen is bottom-left origin with +y UP and the main
// screen's origin at ITS bottom-left; the Accessibility API (System Events) is top-left origin
// with +y DOWN and the origin at the main screen's TOP-left. So an AX top edge is
//     axTop = mainFrameHeight - (nsOriginY + nsHeight)
// Validated against live windows on this machine before this file was written: the built-in
// display (ns y=0 h=982, main h=1440) predicts axTop=458 and Slack sat at y=491; a portrait
// external (ns y=-287 h=1920) predicts axTop=-193 and Cursor sat at y=-163. Both consistent. Get
// this backwards and windows land off-screen on a negative-origin display, which is precisely
// the multi-monitor case this feature exists for.
//
// visibleFrame, not frame: it already excludes the menu bar and the Dock, so a placed window
// never hides under either.

ObjC.import('AppKit');
ObjC.import('CoreGraphics');

function run(argv) {
  var target = null, dryRun = false, protect = null, gap = 0, match = null;
  var plan = false, excludeRect = null, avoidDisplays = [];
  var mode = 'halves', taken = [], tidyHalf = null, externalsOnly = true, prefer = null;
  for (var i = 0; i < argv.length; i++) {
    if (argv[i] === '--dry-run') dryRun = true;
    else if (argv[i] === '--plan') plan = true;
    else if (argv[i] === '--protect') protect = argv[++i];
    else if (argv[i] === '--gap') gap = parseInt(argv[++i], 10) || 0;
    else if (argv[i] === '--match') match = argv[++i];
    else if (argv[i] === '--mode') mode = String(argv[++i]);
    else if (argv[i] === '--tidy') tidyHalf = String(argv[++i]);
    else if (argv[i] === '--all-displays') externalsOnly = false;
    else if (argv[i] === '--prefer') prefer = String(argv[++i]);
    else if (argv[i] === '--taken') {
      taken = String(argv[++i]).split(',').map(function (t) { return t.trim() }).filter(Boolean);
    }
    else if (argv[i] === '--avoid-display') {
      avoidDisplays = String(argv[++i]).split(',').map(Number).filter(function (n) { return !isNaN(n) });
    }
    else if (argv[i] === '--exclude-rect') {
      var p = String(argv[++i]).split(',').map(Number);
      if (p.length === 4) excludeRect = { x: p[0], y: p[1], w: p[2], h: p[3] };
    }
    else if (!target) target = argv[i];
  }
  if (!target && !plan) return JSON.stringify({ ok: false, error: 'no target process given' });

  var se = Application('System Events');
  var displays = readDisplays(gap);
  if (!displays.length) return JSON.stringify({ ok: false, error: 'no displays' });
  // --displays is for selftest and for eyeballing the coordinate flip on a new monitor layout.
  if (target === '--displays') return JSON.stringify({ ok: true, displays: displays });

  // --plan computes the slot and applies nothing, for a caller that can move its own window more
  // precisely than the Accessibility API can. Chrome is exactly that case: its AppleScript
  // dictionary addresses a window by ID and sets its `bounds` directly, so the tab stagehand just
  // opened is targeted by identity instead of by guessing at a window title that may still say
  // "New Tab" while the page loads. --exclude-rect is where that window currently sits, so the
  // planner does not treat the window it is about to move as an obstacle.
  var win = null;
  if (!plan) {
    win = findWindow(se, target, match);
    if (!win) return JSON.stringify({ ok: false, error: 'no window for ' + target + (match ? ' matching "' + match + '"' : '') });
  }

  // Shrink a display-filling protected window FIRST, so the half it gives up is already free by the
  // time occupancy is read below. Doing it after would need a second pass.
  var tidied = null;
  if (tidyHalf) tidied = tidyProtected(se, protect || frontmost(se), readDisplays(gap), tidyHalf);

  var occupancy = readOccupancy(se, plan ? null : target);
  if (excludeRect) {
    occupancy = occupancy.filter(function (o) {
      return !(Math.abs(o.x - excludeRect.x) < 4 && Math.abs(o.y - excludeRect.y) < 4 &&
               Math.abs(o.w - excludeRect.w) < 4 && Math.abs(o.h - excludeRect.h) < 4);
    });
  }
  var frontProc = frontmost(se);
  var protectName = protect || frontProc;
  var protectRects = occupancy.filter(function (o) { return o.proc === protectName; });
  var mouse = mouseDisplayIndex(displays);

  var best = null;
  if (mode === 'halves') best = chooseHalf(displays, protectRects, taken, externalsOnly, prefer);

  var slots = [];
  if (!best) displays.forEach(function (d, di) {
    candidateSlots(d).forEach(function (s) {
      s.display = di;
      s.score = scoreSlot(s, occupancy, d, di, protectRects, mouse, avoidDisplays);
      slots.push(s);
    });
  });
  // Cheapest overlap wins; on a tie the bigger slot wins, so a wide-open display gets used
  // properly instead of the window being parked in a quadrant of it. Scores are compared with a
  // small epsilon because they are fractions, and two genuinely-free slots should reach the
  // size tie-break rather than being separated by float noise.
  if (!best) {
    slots.sort(function (a, b) {
      if (Math.abs(a.score - b.score) > 0.001) return a.score - b.score;
      return (b.w * b.h) - (a.w * a.h);
    });
    best = slots[0];
  }

  if (plan) {
    return JSON.stringify({
      ok: true, plan: true,
      chosen: { display: best.display, name: best.name, x: best.x, y: best.y, w: best.w, h: best.h,
                score: Math.round(best.score * 1000) / 1000 },
      protected: protectName, tidied: tidied, displays: displays.length, windowsSeen: occupancy.length
    });
  }

  var before = { x: win.pos[0], y: win.pos[1], w: win.size[0], h: win.size[1] };
  var after = null;
  if (!dryRun) {
    // ORDER MATTERS, and this cost a live debugging round to find. Setting position first and
    // size second silently CLAMPS the move: a window whose old size does not fit at the new
    // origin gets pushed back by the window server, so a request for (3100,-193) landed at
    // (412,30) with only the size applied — it looked like a successful placement in the return
    // value and was visibly wrong on the desk. Shrink first so the target origin is legal, then
    // move, then re-assert both, because a cross-display move can re-clamp on the first pass.
    try {
      for (var pass = 0; pass < 2; pass++) {
        win.ref.size = [best.w, best.h];
        win.ref.position = [best.x, best.y];
      }
    } catch (e) {
      return JSON.stringify({ ok: false, error: 'set failed: ' + e.message, chosen: best });
    }
    // Read back rather than trust the write. This is the only honest way to report success: the
    // API accepts a value the window server may decline. The settle delay is not superstition —
    // reading immediately caught a half-applied state (new position, old width) that corrected
    // itself a moment later and made a good placement look like a failure.
    $.NSThread.sleepForTimeInterval(0.2);
    try {
      var p = win.ref.position(), s = win.ref.size();
      after = { x: p[0], y: p[1], w: s[0], h: s[1] };
    } catch (e) { after = null; }
  }

  // "Landed" is measured as overlap with the slot that was asked for, not exact coordinates. The
  // window server legitimately nudges a placement — a non-main display appears to reserve ~30px at
  // its top edge, so a request for y=-193 settles at y=-163 — and calling that a failure would
  // report a correct placement as broken. 90% of the intended slot is the real question.
  var landed = true;
  if (after) {
    var want = best.w * best.h;
    landed = want > 0 && (intersection(after, best) / want) >= 0.9;
  }

  return JSON.stringify({
    ok: true,
    landed: landed,
    target: target,
    window: win.name || null,
    dryRun: dryRun,
    before: before,
    after: after,
    chosen: { display: best.display, name: best.name, x: best.x, y: best.y, w: best.w, h: best.h, score: Math.round(best.score * 1000) / 1000 },
    protected: protectName,
    tidied: tidied,
    displays: displays.length,
    windowsSeen: occupancy.length
  });
}

// ── displays ────────────────────────────────────────────────────────────────────────
function readDisplays(gap) {
  var screens = $.NSScreen.screens;
  if (!screens || screens.count === 0) return [];
  var mainH = $.NSScreen.screens.objectAtIndex(0).frame.size.height;
  // Index 0 of NSScreen.screens is the screen with the menu bar on macOS, which is also the
  // one AX treats as the coordinate origin. Verified against a real layout (the menu-bar screen at origin 0,0).
  var out = [];
  for (var i = 0; i < screens.count; i++) {
    var s = screens.objectAtIndex(i);
    var vf = s.visibleFrame;
    // BUILT-IN vs EXTERNAL, detected mechanically. CGDisplayIsBuiltin against the screen's
    // NSScreenNumber is the real signal; matching a display NAME would break on the next machine,
    // which is the whole point of not hard-coding a monitor model or "Color LCD" anywhere.
    var builtin = false, name = '';
    try { builtin = $.CGDisplayIsBuiltin(s.deviceDescription.objectForKey('NSScreenNumber').intValue) === 1; }
    catch (e) { /* unknown → treated as external, i.e. usable */ }
    try { name = ObjC.unwrap(s.localizedName) || ''; } catch (e) {}
    out.push({
      x: Math.round(vf.origin.x) + gap,
      y: Math.round(mainH - (vf.origin.y + vf.size.height)) + gap,
      w: Math.round(vf.size.width) - gap * 2,
      h: Math.round(vf.size.height) - gap * 2,
      builtin: builtin, name: name
    });
  }
  return out;
}

function mouseDisplayIndex(displays) {
  try {
    var p = $.NSEvent.mouseLocation;
    var mainH = $.NSScreen.screens.objectAtIndex(0).frame.size.height;
    var mx = p.x, my = mainH - p.y;   // same flip as everything else
    for (var i = 0; i < displays.length; i++) {
      var d = displays[i];
      if (mx >= d.x && mx <= d.x + d.w && my >= d.y && my <= d.y + d.h) return i;
    }
  } catch (e) { /* mouse position is a nice-to-have, never a reason to fail */ }
  return -1;
}

// ── windows ─────────────────────────────────────────────────────────────────────────
// Collection getters (proc.windows.position()) are two Apple Events per process rather than two
// per window — the difference between roughly a second and several on a busy desktop.
function readOccupancy(se, exclude) {
  var out = [];
  var procs;
  try { procs = se.processes.whose({ visible: true })(); } catch (e) { return out; }
  for (var i = 0; i < procs.length; i++) {
    var name;
    try { name = procs[i].name(); } catch (e) { continue; }
    if (name === exclude) continue;
    var pos, siz;
    try { pos = procs[i].windows.position(); siz = procs[i].windows.size(); } catch (e) { continue; }
    for (var j = 0; j < pos.length; j++) {
      var p = pos[j], s = siz[j];
      if (!p || !s || p.length < 2 || s.length < 2) continue;
      if (s[0] < 120 || s[1] < 120) continue;   // palettes, tooltips, HUDs — not real occupancy
      out.push({ proc: name, x: p[0], y: p[1], w: s[0], h: s[1] });
    }
  }
  return out;
}

// Find the ONE window stagehand is responsible for, by title substring.
//
// `--match` is not a nicety, it is a correctness fix found by running this for real: the first
// version took proc.windows[0] and that is whatever window happens to be frontmost inside the app.
// Chrome had three windows open and Cursor two, so it cheerfully resized one of the USER'S OWN
// windows instead of the tab/file it had just opened. Moving a window nobody asked to move is the
// worst thing this feature can do, so when a match is requested and not found, place NOTHING —
// a window that stays put is a non-event, a hijacked window is not. Bare windows[0] is still
// allowed when no --match is passed at all, which is only the selftest and manual probing.
function findWindow(se, name, match) {
  var needle = match ? String(match).toLowerCase() : null;
  for (var attempt = 0; attempt < 6; attempt++) {
    try {
      var proc = se.processes.byName(name);
      var pos = proc.windows.position();
      var siz = proc.windows.size();
      var nms = [];
      try { nms = proc.windows.name(); } catch (e) { nms = []; }
      var fallback = null;
      for (var j = 0; j < pos.length; j++) {
        if (!siz[j] || siz[j][0] < 120 || siz[j][1] < 120) continue;
        var hit = { ref: proc.windows[j], pos: pos[j], size: siz[j], name: nms[j] || '' };
        if (!needle) { if (!fallback) fallback = hit; continue; }
        if (String(hit.name).toLowerCase().indexOf(needle) !== -1) return hit;
      }
      if (!needle && fallback) return fallback;
    } catch (e) { /* app still launching */ }
    $.NSThread.sleepForTimeInterval(0.35);   // a just-opened app has no window for a moment
  }
  return null;
}

function frontmost(se) {
  try { return se.processes.whose({ frontmost: true })()[0].name(); } catch (e) { return null; }
}

// ── mode: halves ────────────────────────────────────────────────────────────────────
// HALF A DISPLAY, SPLIT ALONG ITS LONG EDGE, ON A RANDOMLY CHOSEN DISPLAY.
//
// This replaced the overlap scorer as the default because the scorer's *output shapes* were bad even
// when its arithmetic was right: on a saturated desk the cheapest slot was whatever odd corner had the
// least covered, so a browser landed in a 1280x705 bottom-left quadrant of a 5K display. Half a screen
// is a shape a person can actually read, and orientation decides the cut — a landscape display splits
// left/right, a portrait display splits top/bottom, which is the only split that yields a usable
// aspect on each.
//
// Random rather than optimised, deliberately: the scorer spent its effort ranking slots that were all
// bad, and the ranking was what made every placement land on the same screen. `taken` keeps the
// randomness honest — a half already assigned to another of stagehand's roles is removed from the
// pool, so "random" never means "on top of the window I opened a moment ago".
//
// The protected window (your terminal) is not banned, only deprioritised: its display is used only
// when nothing else is free. On a desk with one display that is the only option, and covering half a
// screen beats refusing to place anything.
function halvesOf(d) {
  var landscape = d.w >= d.h;
  if (landscape) {
    var hw = Math.floor(d.w / 2);
    return [{ name: 'left-half',  x: d.x,      y: d.y, w: hw, h: d.h },
            { name: 'right-half', x: d.x + hw, y: d.y, w: hw, h: d.h }];
  }
  var hh = Math.floor(d.h / 2);
  return [{ name: 'top-half',    x: d.x, y: d.y,      w: d.w, h: hh },
          { name: 'bottom-half', x: d.x, y: d.y + hh, w: d.w, h: hh }];
}

// THREE TIERS, tried in order:
//   1. a free half of an EXTERNAL display          — the normal case
//   2. a half of an external display that the protected window covers
//   3. a half of the BUILT-IN display              — last resort only
//
// The laptop screen is reserved because that is where the person keeps the things they are using
// themselves: chat, whatever they have open. Reserving it is not the same as banning it, though — on a
// machine with no external display at all, tier 3 is the only tier, and a feature that placed nothing
// there would simply be dead on a laptop. `--all-displays` (config: stagehand.displays: all) opts out.
// STICKINESS matters as much as the choice. Re-rolling the random pick on every call made the single
// browser window hop between halves each time a tab opened — measured: bottom-half, bottom-half, then
// top-half for three consecutive URLs in the SAME window. A browser a person is reading does not
// teleport when a tab is added, so a role that already owns a half keeps it, and randomness only
// decides where a role goes the FIRST time.
function chooseHalf(displays, protectRects, taken, externalsOnly, prefer) {
  var free = [], guardedPool = [], builtinPool = [], preferred = null;
  displays.forEach(function (d, di) {
    halvesOf(d).forEach(function (h) {
      h.display = di;
      h.score = 0;
      if (prefer && prefer === di + ':' + h.name) { preferred = h; return; }
      if (taken.indexOf(di + ':' + h.name) !== -1) return;   // another role already owns this half
      if (externalsOnly && d.builtin) { builtinPool.push(h); return; }
      // Guard the HALVES the protected window actually covers, not the whole display. Guarding the
      // display was why shrinking the terminal to one side changed nothing: the terminal still touched
      // the display, so both halves stayed in the fallback pool and the freed half was never used.
      var guarded = protectRects.some(function (r) { return intersection(r, h) > (h.w * h.h) * 0.2; });
      (guarded ? guardedPool : free).push(h);
    });
  });
  if (preferred) return preferred;
  var from = free.length ? free : (guardedPool.length ? guardedPool : builtinPool);
  if (!from.length) return null;
  return from[Math.floor(Math.random() * from.length)];
}

// TIDY: a maximized protected window is asked to give up half its display.
//
// The terminal filling a whole 5K display means that display can only ever be covered, never shared —
// so the biggest screen on the desk was permanently out of the pool. Shrinking it to one side turns
// that display into two usable halves, and the terminal keeps a half that is still larger than most
// laptop screens.
//
// Only when it really fills the display (>=90% of the usable area), and NEVER in native fullscreen:
// a fullscreen window lives in its own Space, cannot be usefully resized, and fighting the window
// server over it produces flicker rather than space. AXFullScreen is the reliable signal — measured
// false for a merely maximized iTerm sitting at 0,30 2560x1410 with the menu bar still visible.
function tidyProtected(se, procName, displays, side) {
  if (!procName) return null;
  var proc, pos, siz;
  try { proc = se.processes.byName(procName); pos = proc.windows.position(); siz = proc.windows.size(); }
  catch (e) { return null; }
  for (var j = 0; j < pos.length; j++) {
    if (!pos[j] || !siz[j]) continue;
    var r = { x: pos[j][0], y: pos[j][1], w: siz[j][0], h: siz[j][1] };
    for (var di = 0; di < displays.length; di++) {
      var d = displays[di];
      if (d.builtin) continue;   // reserved display — do not rearrange the user's own windows there
      if (intersection(r, d) < d.w * d.h * 0.9) continue;
      try { if (proc.windows[j].attributes.byName('AXFullScreen').value() === true) return 'skipped:fullscreen'; }
      catch (e) { /* attribute absent — treat as not fullscreen */ }
      var halves = halvesOf(d);
      var want = halves.filter(function (h) { return h.name === side + '-half' })[0] || halves[0];
      try {
        for (var pass = 0; pass < 2; pass++) {
          proc.windows[j].size = [want.w, want.h];
          proc.windows[j].position = [want.x, want.y];
        }
      } catch (e) { return 'failed:' + e.message; }
      return procName + '→' + di + ':' + want.name;
    }
  }
  return null;
}

// ── slots and scoring (mode: score) ─────────────────────────────────────────────────
// Halves both ways plus quadrants plus the whole display. Deliberately coarse: the goal is
// "readable and not covering anything", not a tiling window manager.
function candidateSlots(d) {
  var hw = Math.floor(d.w / 2), hh = Math.floor(d.h / 2);
  return [
    { name: 'full',         x: d.x,      y: d.y,      w: d.w, h: d.h },
    { name: 'left-half',    x: d.x,      y: d.y,      w: hw,  h: d.h },
    { name: 'right-half',   x: d.x + hw, y: d.y,      w: hw,  h: d.h },
    { name: 'top-half',     x: d.x,      y: d.y,      w: d.w, h: hh },
    { name: 'bottom-half',  x: d.x,      y: d.y + hh, w: d.w, h: hh },
    { name: 'top-left',     x: d.x,      y: d.y,      w: hw,  h: hh },
    { name: 'top-right',    x: d.x + hw, y: d.y,      w: hw,  h: hh },
    { name: 'bottom-left',  x: d.x,      y: d.y + hh, w: hw,  h: hh },
    { name: 'bottom-right', x: d.x + hw, y: d.y + hh, w: hw,  h: hh }
  ];
}

function intersection(a, b) {
  var x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  var r = Math.min(a.x + a.w, b.x + b.w), t = Math.min(a.y + a.h, b.y + b.h);
  if (r <= x || t <= y) return 0;
  return (r - x) * (t - y);
}

// Score is DIMENSIONLESS — overlap expressed as a fraction of the slot's own area, not raw pixels.
// Raw pixel area was the first version and it was wrong in a way that only showed up on a live
// desktop: a small slot has less area available to overlap, so scoring by absolute overlap
// systematically preferred tiny slots. It parked a browser in a 540x960 quadrant sitting on top of
// Cursor while a free half of a 5K display went unused. As a fraction, "half covered" costs the
// same whether the slot is a quadrant or a whole display, and the size tie-break below then picks
// the biggest of the equally-free slots.
function scoreSlot(slot, occupancy, d, di, protectRects, mouseDi, avoidDisplays) {
  var slotArea = Math.max(1, slot.w * slot.h);
  var score = 0;
  for (var i = 0; i < occupancy.length; i++) score += intersection(slot, occupancy[i]) / slotArea;
  // Covering the window the user is actually typing into is the one unforgivable outcome, so it
  // costs triple on top of the plain overlap already counted above.
  for (var j = 0; j < protectRects.length; j++) score += (intersection(slot, protectRects[j]) / slotArea) * 3;
  // Prefer to leave the display holding the focused app alone even where it looks free — the
  // user's attention is there and a window appearing beside them is still a distraction. Sized to
  // be worth about a third of a slot's area in overlap: enough to lose to a clear display, not
  // enough to push the window onto something it would cover instead.
  if (protectRects.some(function (r) { return intersection(r, d) > 0; })) score += 0.35;
  if (di === mouseDi) score += 0.05;
  // SPREAD. Without this term the placer answers the wrong question. It minimises overlap with EVERY
  // window, and on a desk where each display is already fully covered by the user's own apps that
  // degenerates to "always the display with the smallest windows" — measured here as display 2 chosen
  // on every single placement while displays 0 and 1 sat at 100% coverage from iTerm, Slack and
  // Gather. The ask was that stagehand's windows not cover EACH OTHER, which is a distribution goal
  // and needs stating outright: a display already holding one of stagehand's own windows costs extra,
  // so the editor and the browser end up on different screens even when both screens are equally busy.
  // The magnitude has to DOMINATE, and 0.60 did not. Overlap here is a SUM of per-window fractions,
  // so on a saturated desk a single slot already scores ~2.0 (measured: the built-in display carries
  // Slack and Gather, both at 100%), and a 0.60 nudge changed the number without changing the answer.
  // 10 is far above any reachable overlap sum yet still finite, so a one-display machine — where every
  // display is an avoided display — degrades to "share it" instead of failing.
  if (avoidDisplays && avoidDisplays.indexOf(di) !== -1) score += 10;
  // Anything this small is not a live preview, it is a postage stamp. Only reachable when every
  // larger slot is genuinely worse.
  if (slot.w < 640 || slot.h < 480) score += 0.50;
  return score;
}
