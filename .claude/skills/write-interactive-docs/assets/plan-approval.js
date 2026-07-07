/*
 * Interactive Docs — Plan Approval Engine (self-contained, no deps)
 * ----------------------------------------------------------------------
 * Turns a *plan* doc into a review-and-approve surface for a human, and keeps the
 * Implementation Plan in sync with their decisions in REAL TIME — so the Markdown a
 * later phase executes reflects what the human actually decided, not the first draft.
 *
 * It is ONLY for PLAN docs awaiting human approval (planning.auto_approve = false).
 * It activates ITSELF only when the page root opts in:
 *
 *   <main data-doc
 *         data-plan-approval="pending"                          <- presence = enable; value pending|approved
 *         data-plan-md="agent_logs/development-planner/FM-12-app-plan.md"  <- the AUTHORITATIVE markdown
 *         data-plan-cmd="/dev-cycle FM-12 --approve-plan">      <- the command to re-run once approved
 *
 * INLINE this whole file in a <script> tag (it injects its own CSS), AFTER
 * export-engine.js — it leans on window.WID for the Markdown serialization, so the
 * approved download is the very same Markdown export every other button produces.
 *
 * ── Why a separate engine, and the contract it enforces ────────────────────
 * The HTML is for a human to READ and DECIDE in. It is NEVER what a later phase
 * executes — `--approve-plan` (and every downstream step) reads the MARKDOWN file at
 * data-plan-md. So the human's decisions are worthless unless they flow back into
 * that Markdown. This engine closes that loop:
 *
 *   1. Each section gets a lightweight Decision control — "accept as proposed", pick
 *      an option (pick-one via radios, or pick-many via checkboxes when the
 *      decision-data island sets "type":"multi"), auto-derived from a comparison in
 *      the section or a decision-data island you author, or write a free-text
 *      modification. A section containing a UI preview becomes a "comments" box so the
 *      human can note adjustments to the design.
 *   2. Every change is written LIVE into the Implementation Plan island's `decisions`
 *      array (the export single-source-of-truth) and mirrored in a visible
 *      "Human decisions" block — so the plan reflects the human's intent in real time.
 *   3. "✅ Approve & download plan" serializes the CURRENT plan (decisions included)
 *      to Markdown and downloads it under the data-plan-md BASENAME, then tells the
 *      human exactly where to drop it and which command to re-run. Because a browser
 *      cannot silently overwrite a file on disk, the human/agent replaces the
 *      authoritative .md with the download — a one-line, explicit step.
 *
 * Decision controls are pure UI (div/label/select/textarea/button) the export engine
 * ignores, so they never leak into the exported Markdown — only the island's
 * `decisions` field does.
 */
(function () {
  "use strict";

  var root = document.querySelector("[data-doc][data-plan-approval]");
  if (!root) return; // not a plan awaiting approval — do nothing.

  var REDUCED = typeof matchMedia === "function" &&
    matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ------------------------------- styles -------------------------------- */
  function injectCSS() {
    if (document.getElementById("wid-plan-css")) return;
    var css = `
    .wid-decision{margin:18px 0 4px; border:1px dashed var(--color-border,rgba(127,127,127,.4)); border-radius:12px;
      background:color-mix(in srgb, var(--color-accent,#14b8a6) 5%, var(--color-surface,#fff))}
    .wid-decision.is-modified{border-style:solid; border-color:var(--color-accent,#14b8a6)}
    .wid-decision-head{display:flex; align-items:center; gap:8px; width:100%; text-align:left; cursor:pointer;
      font:inherit; font-size:14px; color:var(--color-text,#222); background:none; border:none; padding:10px 14px}
    .wid-decision-status{margin-left:auto; font-size:12px; font-weight:600; color:var(--color-muted,#667);
      border:1px solid var(--color-border,rgba(127,127,127,.3)); border-radius:999px; padding:1px 10px}
    .wid-decision.is-modified .wid-decision-status{color:var(--color-accent,#0e9f8e);
      border-color:var(--color-accent,#14b8a6)}
    .wid-decision-caret{transition:${REDUCED ? "none" : "transform .15s"}}
    .wid-decision[open] .wid-decision-caret{transform:rotate(180deg)}
    .wid-decision-body{padding:0 14px 14px; display:grid; gap:10px}
    .wid-decision-q{font-size:13px; color:var(--color-muted,#667)}
    .wid-decision-opts{display:grid; gap:6px}
    .wid-decision-opts label{display:flex; gap:8px; align-items:flex-start; font-size:14px; cursor:pointer}
    .wid-decision-note{font:inherit; font-size:14px; width:100%; min-height:54px; resize:vertical; padding:8px 10px;
      border:1px solid var(--color-border,rgba(127,127,127,.3)); border-radius:8px; background:var(--color-surface,#fff);
      color:var(--color-text,#222)}
    .wid-decision-actions{display:flex; gap:8px}
    .wid-decision-reset{font:inherit; font-size:12px; cursor:pointer; color:var(--color-muted,#667);
      background:none; border:none; padding:2px 0; text-decoration:underline}

    .wid-plan-decisions{margin:4px 0 16px; border-left:3px solid var(--color-accent,#14b8a6);
      background:color-mix(in srgb, var(--color-accent,#14b8a6) 7%, var(--color-surface,#fff));
      border-radius:0 10px 10px 0; padding:12px 16px}
    .wid-plan-decisions h4{margin:0 0 6px; font-size:14px}
    .wid-plan-decisions ul{margin:0; padding-left:18px; font-size:14px}
    .wid-plan-decisions li{margin:4px 0}
    .wid-plan-decisions .none{color:var(--color-muted,#667); font-size:14px; margin:0}

    .wid-plan-approve{margin-top:18px; padding:16px; border-radius:12px; border:1px solid var(--color-border,rgba(127,127,127,.3));
      background:var(--color-surface,#fff); box-shadow:var(--shadow,0 1px 2px rgba(0,0,0,.08))}
    .wid-plan-approve .status{font-size:14px; color:var(--color-muted,#667); margin-bottom:10px}
    .wid-plan-approve.is-approved{border-color:var(--c-success,#22c55e);
      background:color-mix(in srgb, var(--c-success,#22c55e) 8%, var(--color-surface,#fff))}
    .wid-approve-btn{font:inherit; font-size:15px; font-weight:600; cursor:pointer; color:#fff;
      background:var(--color-accent,#14b8a6); border:none; border-radius:10px; padding:10px 18px}
    .wid-approve-btn:hover{filter:brightness(1.05)}
    .wid-plan-approve .next{margin-top:12px; font-size:13.5px; line-height:1.6; color:var(--color-text,#222)}
    .wid-plan-approve .next code{font-family:var(--font-mono,monospace); font-size:.92em;
      background:var(--color-surface-2,#eee); padding:2px 6px; border-radius:6px}
    .wid-plan-approve .reopen{font:inherit; font-size:12px; cursor:pointer; color:var(--color-muted,#667);
      background:none; border:none; text-decoration:underline; margin-top:8px}
    `;
    var s = document.createElement("style");
    s.id = "wid-plan-css";
    s.textContent = css;
    document.head.appendChild(s);
  }

  /* ------------------------------- helpers ------------------------------- */
  function islandOf(host, cls) {
    var el = host.querySelector(":scope > script." + cls);
    if (!el) return null;
    try { return JSON.parse(el.textContent); } catch (e) { return null; }
  }
  function writeIsland(host, cls, obj) {
    var el = host.querySelector(":scope > script." + cls);
    if (el) el.textContent = JSON.stringify(obj, null, 2);
  }
  function basename(p) {
    return (p || "plan.md").split(/[\\/]/).pop() || "plan.md";
  }
  function download(name, content) {
    var blob = new Blob([content], { type: "text/markdown" });
    var url = URL.createObjectURL(blob);
    var a = document.createElement("a");
    a.href = url; a.download = name;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(function () { URL.revokeObjectURL(url); }, 1000);
  }

  /* ---- find the Implementation Plan section + its steps island ---------- */
  function findPlan() {
    var byId = root.querySelector('[data-section][data-section-id="implementation-plan"]');
    var candidates = byId ? [byId] : [...root.querySelectorAll('[data-section][data-block="steps"]')];
    for (var i = 0; i < candidates.length; i++) {
      var sec = candidates[i];
      var host = sec.matches('[data-block="steps"]') ? sec : sec.querySelector('[data-block="steps"]');
      if (!host) continue;
      var data = islandOf(host, "export-data");
      if (data && data.type === "steps") return { section: sec, host: host, data: data };
    }
    return null;
  }

  var plan = findPlan();
  if (!plan) return; // a doc with no Implementation Plan is not a plan — nothing to approve.

  injectCSS();

  var planMdPath = root.getAttribute("data-plan-md") || basename(document.title) + ".md";
  var reRunCmd = root.getAttribute("data-plan-cmd") || "";
  var decisions = {}; // sectionId -> {sectionTitle, question, choice, note, modified}

  /* ---- inject a Decision control on every reviewable section ------------ */
  function optionsForSection(sec) {
    // A UI preview turns this section's control into a comments/feedback box.
    var preview = !!(sec.matches('[data-block="preview"]') || sec.querySelector('[data-block="preview"]'));
    // 1) an explicit decision-data island wins.
    var dd = islandOf(sec, "decision-data") ||
      (sec.querySelector('[data-block] > script.decision-data') &&
        islandOf(sec.querySelector("[data-block]"), "decision-data"));
    if (dd) {
      var multi = dd.type === "multi" || dd.multi === true; // pick-many (checkboxes) vs pick-one (radios)
      return {
        question: dd.question || (preview ? "Any changes to this UI?" : "How should this be handled?"),
        options: dd.options || [],
        def: dd.default != null ? dd.default : (multi ? [] : ""),
        multi: multi, feedback: preview
      };
    }
    // 2) else derive from a comparison block in the section (always pick-one).
    var cmp = sec.matches('[data-block="comparison"]') ? sec : sec.querySelector('[data-block="comparison"]');
    if (cmp) {
      var c = islandOf(cmp, "export-data");
      if (c && c.options) return { question: c.title || "Which option do you choose?", options: c.options, def: c.recommended || "", multi: false, feedback: preview };
    }
    return {
      question: preview ? "Any changes to this UI? Add comments below." : "Accept this section as proposed, or modify it?",
      options: [], def: "", multi: false, feedback: preview
    };
  }

  function buildDecision(sec) {
    var id = sec.getAttribute("data-section-id") || "s" + Math.abs(hash(sec.getAttribute("data-section-title") || ""));
    var title = sec.getAttribute("data-section-title") ||
      (sec.querySelector("h2,h3") && sec.querySelector("h2,h3").textContent.trim()) || "Section";
    var spec = optionsForSection(sec);
    var defArr = Array.isArray(spec.def) ? spec.def : [];
    function isProposed(o) { return spec.multi ? defArr.indexOf(o) >= 0 : o === spec.def; }
    decisions[id] = {
      sectionTitle: title, question: spec.question,
      choice: "", choices: spec.multi ? defArr.slice() : [], defaults: spec.multi ? defArr.slice() : [],
      note: "", modified: false, multi: !!spec.multi, feedback: !!spec.feedback
    };

    var wrap = document.createElement("details");
    wrap.className = "wid-decision";
    wrap.setAttribute("data-decision-for", id);

    var head = document.createElement("summary");
    head.className = "wid-decision-head";
    head.innerHTML = '<span>' + (spec.feedback ? "💬" : "🤔") + '</span>' +
      '<span class="wid-decision-label">' + (spec.feedback ? "Your feedback" : "Your decision") + '</span>' +
      '<span class="wid-decision-status">' + (spec.feedback ? "No comments" : "Accepted as proposed") + '</span>' +
      '<span class="wid-decision-caret">▾</span>';
    wrap.appendChild(head);

    var body = document.createElement("div");
    body.className = "wid-decision-body";
    var q = document.createElement("div");
    q.className = "wid-decision-q";
    q.textContent = spec.question;
    body.appendChild(q);

    var radioName = "wid-dec-" + id;
    if (spec.options.length) {
      var opts = document.createElement("div");
      opts.className = "wid-decision-opts";
      spec.options.forEach(function (o) {
        var lab = document.createElement("label");
        var inp = document.createElement("input");
        inp.type = spec.multi ? "checkbox" : "radio";
        if (!spec.multi) inp.name = radioName;
        inp.value = o;
        if (isProposed(o)) inp.checked = true;
        lab.appendChild(inp);
        lab.appendChild(document.createTextNode(o + (isProposed(o) ? "  (proposed)" : "")));
        opts.appendChild(lab);
        if (spec.multi) inp.addEventListener("change", function () { onToggle(id, o, inp.checked); });
        else inp.addEventListener("change", function () { onChoice(id, o, spec.def); });
      });
      body.appendChild(opts);
    }

    var note = document.createElement("textarea");
    note.className = "wid-decision-note";
    note.placeholder = spec.feedback
      ? "Comments — what to adjust in this UI: layout, copy, colours, spacing…"
      : "Modify the approach, refine the wording, or leave a note for whoever implements this…";
    note.addEventListener("input", function () { onNote(id, note.value); });
    body.appendChild(note);

    var actions = document.createElement("div");
    actions.className = "wid-decision-actions";
    var reset = document.createElement("button");
    reset.type = "button"; reset.className = "wid-decision-reset"; reset.textContent = "Reset to proposed";
    reset.addEventListener("click", function () {
      note.value = "";
      if (spec.multi) {
        wrap.querySelectorAll("input[type=checkbox]").forEach(function (cb) { cb.checked = isProposed(cb.value); });
        decisions[id].choices = defArr.slice();
      } else {
        var checked = wrap.querySelector('input[type=radio][value="' + cssEsc(spec.def) + '"]');
        if (checked) checked.checked = true;
        decisions[id].choice = "";
      }
      decisions[id].note = ""; recompute(id); sync();
    });
    actions.appendChild(reset);
    body.appendChild(actions);

    wrap.appendChild(body);
    sec.appendChild(wrap);
  }

  function onChoice(id, value, def) {
    decisions[id].choice = (value === def) ? "" : value; // pick-one: record only a DEVIATION from the proposal
    recompute(id);
    sync();
  }
  function onToggle(id, value, checked) { // pick-many: keep the current selection set
    var arr = decisions[id].choices, i = arr.indexOf(value);
    if (checked && i < 0) arr.push(value);
    if (!checked && i >= 0) arr.splice(i, 1);
    recompute(id);
    sync();
  }
  function onNote(id, value) {
    decisions[id].note = value.trim();
    recompute(id);
    sync();
  }
  function sameSet(a, b) {
    if (a.length !== b.length) return false;
    var sb = b.slice().sort();
    return a.slice().sort().every(function (x, i) { return x === sb[i]; });
  }
  function recompute(id) {
    var d = decisions[id];
    var changed = d.multi ? !sameSet(d.choices, d.defaults) : !!d.choice;
    d.modified = !!(changed || d.note);
  }

  /* ---- write decisions into the plan island + the visible mirror -------- */
  function activeDecisions() {
    return Object.keys(decisions).map(function (id) {
      var d = decisions[id];
      if (!d.modified) return null;
      return { section: d.sectionTitle, choice: d.choice || "",
        choices: d.multi ? d.choices.slice() : [], note: d.note || "", feedback: !!d.feedback };
    }).filter(Boolean);
  }

  function sync() {
    var list = activeDecisions();
    // 1) island = export source of truth.
    plan.data.decisions = list;
    writeIsland(plan.host, "export-data", plan.data);
    // 2) visible mirror inside the plan section.
    renderMirror(list);
    // 3) per-control status pills.
    root.querySelectorAll(".wid-decision").forEach(function (w) {
      var id = w.getAttribute("data-decision-for");
      var d = decisions[id];
      var pill = w.querySelector(".wid-decision-status");
      w.classList.toggle("is-modified", !!(d && d.modified));
      if (!pill) return;
      if (!d || !d.modified) pill.textContent = d && d.feedback ? "No comments" : "Accepted as proposed";
      else if (d.multi && d.choices.length) pill.textContent = "Chose " + d.choices.length;
      else if (d.choice) pill.textContent = "Chose: " + d.choice;
      else pill.textContent = d.feedback ? "Commented" : "Modified";
    });
  }

  function renderMirror(list) {
    var box = plan.section.querySelector(".wid-plan-decisions");
    if (!box) {
      box = document.createElement("div");
      box.className = "wid-plan-decisions";
      var h = plan.section.querySelector("h2, h3");
      if (h && h.nextSibling) plan.section.insertBefore(box, h.nextSibling);
      else plan.section.insertBefore(box, plan.section.firstChild);
    }
    if (!list.length) {
      box.innerHTML = '<h4>🧑‍⚖️ Human decisions</h4><p class="none">No changes yet — every section accepted as proposed. ' +
        'Pick an option or write a note on any section above and it appears here, and in the exported plan, instantly.</p>';
      return;
    }
    var items = list.map(function (d) {
      var head;
      if (d.choices && d.choices.length) head = "chose <strong>" + d.choices.map(esc).join("</strong>, <strong>") + "</strong>";
      else if (d.choice) head = "chose <strong>" + esc(d.choice) + "</strong>";
      else head = d.feedback ? "commented" : "modified";
      var note = d.note ? " — " + esc(d.note) : "";
      return "<li><strong>" + esc(d.section) + "</strong> — " + head + note + "</li>";
    }).join("");
    box.innerHTML = '<h4>🧑‍⚖️ Human decisions (live)</h4><ul>' + items + "</ul>";
  }

  /* ---- the approve toolbar ---------------------------------------------- */
  function buildApprove() {
    var bar = document.createElement("div");
    bar.className = "wid-plan-approve";
    bar.innerHTML =
      '<div class="status">⏸️ This plan is awaiting your approval. Review each section, record any decisions, ' +
      'then approve to export the final plan for the next phase.</div>' +
      '<button type="button" class="wid-approve-btn">✅ Approve &amp; download plan (.md)</button>';
    bar.querySelector(".wid-approve-btn").addEventListener("click", approve);
    plan.section.appendChild(bar);
    return bar;
  }

  function approve() {
    sync(); // make sure the island has the very latest decisions
    var md = (window.WID && window.WID.pageMd)
      ? window.WID.pageMd(window.WID.pageModel())
      : null;
    if (!md) { alert("Export engine not found — make sure export-engine.js is inlined before this script."); return; }
    var name = basename(planMdPath);
    download(name, md);
    root.setAttribute("data-plan-approval", "approved");
    var bar = plan.section.querySelector(".wid-plan-approve");
    bar.classList.add("is-approved");
    bar.innerHTML =
      '<div class="status">✅ Plan approved and exported.</div>' +
      '<div class="next">Downloaded <code>' + esc(name) + '</code>. To put your approved plan into the pipeline:' +
      '<br>1. Replace the authoritative plan markdown <code>' + esc(planMdPath) + '</code> with the file you just downloaded.' +
      (reRunCmd ? '<br>2. Re-run <code>' + esc(reRunCmd) + '</code> — it reads that markdown, not this page.' : '') +
      '</div>' +
      '<button type="button" class="reopen">↩ Re-open for edits</button>';
    bar.querySelector(".reopen").addEventListener("click", function () {
      root.setAttribute("data-plan-approval", "pending");
      bar.classList.remove("is-approved");
      bar.remove();
      buildApprove();
    });
  }

  /* ---- small utils ------------------------------------------------------ */
  function esc(s) { return String(s).replace(/[&<>]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;" }[c]; }); }
  function cssEsc(s) { return String(s).replace(/["\\]/g, "\\$&"); }
  function hash(s) { var h = 0; for (var i = 0; i < s.length; i++) { h = (h << 5) - h + s.charCodeAt(i); h |= 0; } return h; }

  /* ------------------------------- wire up ------------------------------- */
  function init() {
    root.querySelectorAll("[data-section]").forEach(function (sec) {
      if (sec === plan.section) return;       // the plan section gets the mirror + approve, not a decision control
      if (sec.closest("[data-section]") !== sec) return; // top-level sections only
      buildDecision(sec);
    });
    buildApprove();
    sync();
    if (root.getAttribute("data-plan-approval") === "approved") {
      // authored as already-approved (rare) — collapse the toolbar to its done state.
      approve();
    }
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  window.WIDPlan = { decisions: decisions, approve: approve, planMdPath: planMdPath };
})();
