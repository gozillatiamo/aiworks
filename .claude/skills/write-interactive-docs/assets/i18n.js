/*
 * Interactive Docs — Localization Engine (English ⇄ Thai, display-only)
 * ---------------------------------------------------------------------
 * Adds a floating language chip that switches the VISIBLE page between English
 * (the default) and Thai. Thai is a DISPLAY overlay only:
 *   • every export island stays English, and
 *   • this engine forces English while ANY export runs,
 * so the exported Markdown/JSON is ALWAYS English — Thai never leaks into the file an
 * AI reads. That is the contract this engine exists to keep.
 *
 * ── Opt-in ─────────────────────────────────────────────────────────────────
 * Does nothing unless the page root opts in:  <main data-doc data-i18n="en,th">
 * (presence enables it; the value is informational — only en+th are supported).
 *
 * ── Authoring the Thai view ─────────────────────────────────────────────────
 * Add data-th="<thai text>" to LEAF readable elements: h1–h6, p, li, figcaption,
 * td, th, .callout-title and its text line, .kpi .l, tab buttons, comparison h4/li.
 * The English text stays the element's normal content (and the export source).
 *   • Do NOT put data-th on a container, on an element that holds an export-data
 *     island, or on injected UI — the swap replaces the element's content.
 *   • An element with no data-th simply stays English in the Thai view (graceful
 *     partial translation).
 *   • Code blocks and diagram/chart source are NOT translated — they're the export
 *     source and technical; leave them English in both views.
 *
 * INLINE this whole file in a <script> tag AFTER export-engine.js (it wraps
 * window.WID's export entry points to force English). It self-injects its CSS.
 */
(function () {
  "use strict";

  var root = document.querySelector("[data-doc][data-i18n]");
  if (!root) return; // not a localized doc — do nothing.

  var lang = "en"; // default is English
  var chip = null;

  /* --------------------------- translation swap -------------------------- */
  function nodes() { return [].slice.call(root.querySelectorAll("[data-th]")); }

  function capture() {
    // Remember the English innerHTML once (so inline <strong>/<code> survive a round trip).
    nodes().forEach(function (el) { if (el.__en == null) el.__en = el.innerHTML; });
  }

  function apply(l) {
    nodes().forEach(function (el) {
      if (l === "th") {
        var th = el.getAttribute("data-th");
        if (th != null && th !== "") el.textContent = th; // swap to Thai (else keep English)
      } else if (el.__en != null) {
        el.innerHTML = el.__en; // restore English + its inline markup
      }
    });
    root.setAttribute("lang", l);
    if (document.documentElement) document.documentElement.setAttribute("lang", l);
  }

  function setLang(l) {
    l = l === "th" ? "th" : "en";
    if (l === lang) return;
    lang = l;
    apply(lang);
    updateChip();
  }

  // Run fn with English forced, then restore the current language. Synchronous, so
  // the DOM never repaints mid-swap — no visible flicker.
  function withEnglish(fn) {
    if (lang === "en") return fn();
    apply("en");
    try { return fn(); }
    finally { apply(lang); }
  }

  /* ---- wrap the export engine so every export is English-only ------------ */
  function wrapWID() {
    var WID = window.WID;
    if (!WID) return;
    ["exportPage", "exportSection", "pageModel"].forEach(function (k) {
      if (typeof WID[k] !== "function" || WID[k].__wid_i18n) return;
      var orig = WID[k];
      var wrapped = function () { var a = arguments; return withEnglish(function () { return orig.apply(WID, a); }); };
      wrapped.__wid_i18n = true;
      WID[k] = wrapped;
    });
  }

  /* ------------------------------ the chip ------------------------------- */
  function buildChip() {
    injectCSS();
    chip = document.createElement("div");
    chip.className = "wid-lang";
    chip.setAttribute("role", "group");
    chip.setAttribute("aria-label", "Language / ภาษา");
    chip.innerHTML =
      '<span class="wid-lang-globe" aria-hidden="true">🌐</span>' +
      '<button type="button" data-lang="en">EN</button>' +
      '<span class="wid-lang-sep" aria-hidden="true">／</span>' +
      '<button type="button" data-lang="th">ไทย</button>';
    chip.querySelectorAll("button").forEach(function (b) {
      b.addEventListener("click", function () { setLang(b.getAttribute("data-lang")); });
    });
    document.body.appendChild(chip);
    updateChip();
  }

  function updateChip() {
    if (!chip) return;
    chip.querySelectorAll("button").forEach(function (b) {
      var on = b.getAttribute("data-lang") === lang;
      b.setAttribute("aria-pressed", on ? "true" : "false");
      b.classList.toggle("is-on", on);
    });
  }

  function injectCSS() {
    if (document.getElementById("wid-lang-css")) return;
    var css = `
    .wid-lang{position:fixed; left:16px; bottom:16px; z-index:70; display:flex; align-items:center; gap:4px;
      background:var(--color-surface,#fff); border:1px solid var(--color-border,rgba(127,127,127,.3));
      border-radius:999px; padding:5px 10px; box-shadow:var(--shadow,0 2px 8px rgba(0,0,0,.12))}
    .wid-lang-globe{font-size:14px; line-height:1}
    .wid-lang-sep{color:var(--color-muted,#889); opacity:.55}
    .wid-lang button{font:inherit; font-size:13px; font-weight:600; cursor:pointer; border:none; background:none;
      color:var(--color-muted,#778); border-radius:999px; padding:2px 9px; line-height:1.4}
    .wid-lang button.is-on{color:#fff; background:var(--color-primary,#2f6df0)}
    .wid-lang button:not(.is-on):hover{color:var(--color-primary,#2f6df0)}
    /* Thai view: prefer a Thai-capable face; keep code/diagrams monospaced + English. */
    [data-doc][lang="th"]{font-family:var(--font-thai, var(--font-sans, system-ui))}
    [data-doc][lang="th"] code, [data-doc][lang="th"] pre, [data-doc][lang="th"] .mermaid{
      font-family:var(--font-mono, ui-monospace, monospace)}
    `;
    var s = document.createElement("style");
    s.id = "wid-lang-css";
    s.textContent = css;
    document.head.appendChild(s);
  }

  /* ------------------------------- wire up ------------------------------- */
  function init() {
    capture();
    apply("en"); // default English + set lang attribute
    buildChip();
    wrapWID();
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", init);
  else init();

  window.WIDi18n = { setLang: setLang, withEnglish: withEnglish, get lang() { return lang; } };
})();
