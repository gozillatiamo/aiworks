/*
 * Interactive Docs — Diagram Interaction Engine (self-contained, no deps)
 * ----------------------------------------------------------------------
 * Turns every static Mermaid diagram into something the reader can EXPLORE,
 * not just look at. Auto-applied to each `figure.diagram` once Mermaid renders:
 *
 *   • Zoom & pan + reset + fullscreen   — big diagrams become legible
 *   • Hover spotlight                    — hovering a node dims the rest
 *   • Clickable nodes                    — a node can jump to a section,
 *                                          open a detail drawer, or open a URL
 *   • Guided walkthrough (optional)      — ◀ ▶ step through a flow node-by-node
 *
 * INLINE this whole file in a <script> tag (it injects its own CSS), AFTER the
 * Mermaid <script>. It waits for Mermaid to finish via a MutationObserver, so it
 * doesn't matter whether Mermaid runs on load or you call mermaid.run() yourself.
 *
 * ── Diagram types supported ─────────────────────────────────────────────────
 * flowchart, stateDiagram-v2, erDiagram, classDiagram, and mindmap all share one
 * Mermaid node renderer, so `nodes`/`walkthrough` work identically across all five
 * with zero extra code. sequenceDiagram (actors), gantt (tasks), and gitGraph
 * (commits) use their own renderers — each has a dedicated finder below
 * (collectSequenceActors / collectGanttTasks / collectGitCommits) so the same
 * `nodes`/`walkthrough` island authoring works there too. pie/journey/quadrantChart
 * stay zoom-and-pan only (see diagrams.md for why). Full picks-and-gotchas per type
 * live in references/diagrams.md — this file is the mechanism, not the guide.
 *
 * ── Where the interactivity comes from ─────────────────────────────────────
 * Zoom/pan/hover/fullscreen need NO authoring — they apply to every diagram.
 * Click actions + walkthrough are declared in the diagram's export-data island,
 * keyed by each node's id OR its visible label (whichever is handier):
 *
 *   <figure class="diagram" data-block="diagram">
 *     <pre class="mermaid">flowchart LR
 *       U[Pet owner] --> A[App] --> DB[(Local DB)]</pre>
 *     <script type="application/json" class="export-data">
 *       {"type":"diagram","diagramType":"flowchart","title":"Save flow",
 *        "source":"flowchart LR\n U[Pet owner] --> A[App] --> DB[(Local DB)]",
 *        "nodes":{
 *          "Pet owner":{"detail":"The person using the app to log a meal."},
 *          "App":{"section":"architecture","detail":"The offline-first Flutter client."},
 *          "Local DB":{"url":"https://isar.dev","detail":"Isar — the on-device store."}
 *        },
 *        "walkthrough":["Pet owner","App","Local DB"]}
 *     <\/script>
 *   </figure>
 *
 * Per-node config (all optional): { section, url, detail, label }
 *   • section  → click scrolls to [data-section-id="…"] and pulses it
 *   • url      → click opens the link in a new tab
 *   • detail   → click opens a side drawer rendering this markdown
 *   • label    → friendly title for the drawer + the Markdown export
 * `walkthrough` is an ordered list of node keys for the ◀ ▶ guided tour.
 *
 * The island stays the single source of truth: the export engine reads the same
 * `nodes`/detail into the Markdown/JSON export, so the interactive content isn't
 * lost when the doc is handed to an AI.
 *
 * For Mermaid-native click directives (advanced), set securityLevel:"loose" and
 * use `click X call widGo("section-id")` / `click X "https://…"`. The handlers
 * widGo() and widInfo() are exposed globally for that path.
 */
(function () {
  "use strict";

  var REDUCED = typeof matchMedia === "function" &&
    matchMedia("(prefers-reduced-motion: reduce)").matches;

  /* ----------------------------- styles ---------------------------------- */
  function injectCSS() {
    if (document.getElementById("wid-dgm-css")) return;
    var css = `
    /* touch-action:auto — DON'T claim any gesture. The browser then sends a two-finger
       trackpad scroll up the normal scroll chain (the page scrolls); pinch still arrives
       as a ctrl+wheel we handle for zoom; mouse drag-to-pan uses pointer events, which
       touch-action never gates. (Claiming pan-x/pan-y made the browser try to scroll
       this non-scrollable box and ate the gesture, so the page didn't move.) */
    .wid-dgm-viewport{position:relative; overflow:clip; height:100%; max-height:72vh; border-radius:12px;
      background:var(--color-surface-2,rgba(127,127,127,.06)); cursor:grab; touch-action:auto; user-select:none}
    .wid-dgm-viewport.is-panning{cursor:grabbing}
    .wid-dgm-viewport > .mermaid{margin:0}
    .wid-dgm-viewport > .mermaid > svg{transform-origin:0 0; will-change:transform; max-width:none!important; height:auto}
    .wid-dgm-tools{position:absolute; top:8px; right:8px; z-index:3; display:flex; gap:4px; align-items:center}
    .wid-dgm-tools button{font:inherit; font-size:13px; line-height:1; cursor:pointer; width:30px; height:30px;
      display:grid; place-items:center; border:1px solid var(--color-border,rgba(127,127,127,.3));
      background:var(--color-surface,#fff); color:var(--color-text,#222); border-radius:8px; box-shadow:0 1px 2px rgba(0,0,0,.12)}
    .wid-dgm-tools button:hover{border-color:var(--color-primary,#3a6df0); color:var(--color-primary,#3a6df0)}
    .wid-dgm-walk{display:flex; gap:4px; align-items:center; margin-right:6px;
      background:var(--color-surface,#fff); border:1px solid var(--color-border,rgba(127,127,127,.3));
      border-radius:999px; padding:2px 4px; box-shadow:0 1px 2px rgba(0,0,0,.12)}
    .wid-dgm-walk .lbl{font-size:12px; color:var(--color-muted,#667); padding:0 4px; min-width:54px; text-align:center}
    .wid-dgm-hint{position:absolute; left:10px; bottom:8px; z-index:3; font-size:11px; color:var(--color-muted,#778);
      background:var(--color-surface,#fff); border:1px solid var(--color-border,rgba(127,127,127,.25));
      border-radius:999px; padding:2px 9px; opacity:.85; pointer-events:none}
    /* hover spotlight (wid-hot) + persistent click selection (wid-sel) — "wid-item" is OUR
       marker (added by collectAll(), not Mermaid's), so it applies uniformly whether the
       underlying element is a flowchart/state/ER/class/mindmap <g class="node">, a sequence
       actor group, a gantt <rect>, or a gitGraph <circle>. Both stay full-opacity while the
       rest of the diagram is dimmed. */
    .wid-dim .wid-item{opacity:.3; transition:${REDUCED ? "none" : "opacity .15s"}}
    .wid-dim .wid-item.wid-hot, .wid-dim .wid-item.wid-sel{opacity:1}
    .wid-dim .edgePaths,.wid-dim .edgeLabels,.wid-dim .relation,.wid-dim .messageLine0,.wid-dim .messageLine1{opacity:.18}
    .wid-item.wid-act{cursor:pointer}
    .wid-item.wid-act:focus{outline:none}
    /* self-OR-descendant: a gantt/gitGraph item IS the shape; a flowchart/sequence item WRAPS one */
    .wid-item.wid-act:hover, .wid-item.wid-act:hover :is(rect,circle,polygon,path,ellipse){stroke-width:2.4px}
    .wid-item.wid-hot, .wid-item.wid-hot :is(rect,circle,polygon,path,ellipse){filter:drop-shadow(0 0 6px var(--color-accent,#22c3d6))}
    /* the clicked/selected node — a stronger, distinct (primary-colour) highlight that persists */
    .wid-item.wid-sel, .wid-item.wid-sel :is(rect,circle,polygon,path,ellipse){filter:drop-shadow(0 0 8px var(--color-primary,#7c6cff)); stroke:var(--color-primary,#7c6cff); stroke-width:2.6px}
    /* section pulse when a node navigates to it */
    @keyframes wid-flash{0%{box-shadow:0 0 0 0 var(--color-accent,#22c3d6)}100%{box-shadow:0 0 0 8px transparent}}
    .wid-flash{animation:${REDUCED ? "none" : "wid-flash 1.1s ease-out"}; border-radius:12px}
    /* fullscreen */
    /* Fullscreen: a large centred MODAL that keeps a margin (not edge-to-edge). Explicit
       width/height via calc (rather than relying on inset to stretch the box) guarantees a
       full-size stage in every browser; the .mermaid inside is height:100% so the diagram
       stage fills the panel even for a short diagram — align-items:center keeps the svg from
       being flex-stretched (which would distort it and break fit's measurement); fit() then
       scales-to-contain and centres the diagram within. */
    .wid-dgm-viewport.is-fs{position:fixed; top:14px; left:14px; width:calc(100vw - 28px);
      height:calc(100vh - 28px); max-height:none; z-index:80; border-radius:12px;
      box-shadow:0 20px 80px rgba(0,0,0,.5)}
    .wid-dgm-viewport.is-fs > .mermaid{height:100%; align-items:center}
    /* detail drawer */
    .wid-dgm-panel{position:fixed; top:0; right:0; height:100%; width:min(420px,92vw); z-index:90;
      background:var(--color-surface,#fff); color:var(--color-text,#222);
      border-left:1px solid var(--color-border,rgba(127,127,127,.3)); box-shadow:-12px 0 40px rgba(0,0,0,.25);
      transform:translateX(102%); transition:${REDUCED ? "none" : "transform .22s ease"}; display:flex; flex-direction:column}
    .wid-dgm-panel.is-open{transform:none}
    .wid-dgm-panel header{display:flex; align-items:center; justify-content:space-between; gap:10px;
      padding:16px 18px; border-bottom:1px solid var(--color-border,rgba(127,127,127,.25))}
    .wid-dgm-panel header h3{margin:0; font-size:18px}
    .wid-dgm-panel header button{border:none; background:none; font-size:22px; cursor:pointer; color:var(--color-muted,#667); line-height:1}
    .wid-dgm-panel .body{padding:16px 18px; overflow:auto; line-height:1.6}
    .wid-dgm-panel .body code{font-family:ui-monospace,monospace; font-size:.9em;
      background:var(--color-surface-2,rgba(127,127,127,.12)); padding:1px 5px; border-radius:5px}
    .wid-dgm-panel .body a{color:var(--color-primary,#3a6df0)}
    /* the scrim is purely a subtle visual dim — it must NEVER capture clicks, so the
       diagram stays interactive while the drawer is open (non-modal). A light tint only. */
    .wid-dgm-scrim{position:fixed; inset:0; z-index:89; background:rgba(0,0,0,.08); opacity:0; pointer-events:none;
      transition:${REDUCED ? "none" : "opacity .2s"}}
    .wid-dgm-scrim.is-open{opacity:1}
    `;
    var s = document.createElement("style");
    s.id = "wid-dgm-css"; s.textContent = css;
    document.head.appendChild(s);
  }

  /* --------------------- tiny markdown for the drawer --------------------- */
  function mdInline(s) {
    return s
      .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
      .replace(/(^|[^*])\*([^*]+)\*/g, "$1<em>$2</em>")
      .replace(/\[([^\]]+)\]\(([^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');
  }
  function mdToHtml(md) {
    var lines = String(md || "").split("\n"), html = [], list = false;
    lines.forEach(function (ln) {
      if (/^\s*[-*]\s+/.test(ln)) {
        if (!list) { html.push("<ul>"); list = true; }
        html.push("<li>" + mdInline(ln.replace(/^\s*[-*]\s+/, "")) + "</li>");
      } else {
        if (list) { html.push("</ul>"); list = false; }
        if (ln.trim() === "") html.push("");
        else html.push("<p>" + mdInline(ln) + "</p>");
      }
    });
    if (list) html.push("</ul>");
    return html.join("\n");
  }

  /* ----------------------------- drawer ----------------------------------- */
  var panel, scrim;
  function ensurePanel() {
    if (panel) return;
    scrim = document.createElement("div"); scrim.className = "wid-dgm-scrim";
    panel = document.createElement("div"); panel.className = "wid-dgm-panel";
    panel.setAttribute("role", "dialog"); panel.setAttribute("aria-label", "Diagram detail");
    panel.innerHTML = '<header><h3></h3><button aria-label="Close" title="Close">×</button></header><div class="body"></div>';
    document.body.append(scrim, panel);
    var close = closePanel;
    panel.querySelector("button").addEventListener("click", close);
    scrim.addEventListener("click", close);
    document.addEventListener("keydown", function (e) { if (e.key === "Escape") close(); });
    // Non-modal: the drawer doesn't block the diagram, so you can click NODE → NODE and
    // the drawer (and the highlight) just follow along. A click on genuinely empty space
    // (not a node, the panel, or a toolbar) closes it.
    document.addEventListener("click", function (e) {
      if (!panel.classList.contains("is-open")) return;
      var t = e.target;
      if (t.closest && (t.closest(".wid-dgm-panel") || t.closest("g.node") || t.closest(".wid-dgm-tools"))) return;
      close();
    });
  }
  function openPanel(title, md) {
    ensurePanel();
    panel.querySelector("h3").textContent = title || "Detail";
    panel.querySelector(".body").innerHTML = mdToHtml(md);
    panel.classList.add("is-open"); scrim.classList.add("is-open");
  }
  // Each diagram registers a callback here so closing the drawer also clears its
  // selection spotlight (the drawer is a singleton, so it can't reach figure state directly).
  var onPanelClose = [];
  function closePanel() {
    if (panel) { panel.classList.remove("is-open"); scrim.classList.remove("is-open"); }
    onPanelClose.forEach(function (f) { try { f(); } catch (_) {} });
  }

  /* ------------------------- navigation handler --------------------------- */
  function widGo(sectionId) {
    var el = document.querySelector('[data-section-id="' + sectionId + '"]') ||
             document.getElementById(sectionId);
    if (!el) return;
    try { el.scrollIntoView({ behavior: REDUCED ? "auto" : "smooth", block: "start" }); } catch (_) {}
    el.classList.remove("wid-flash"); void el.offsetWidth; el.classList.add("wid-flash");
  }
  // Registry so Mermaid-native `click X call widInfo("key")` can find detail text.
  var registry = {};
  function widInfo(key) {
    var cfg = registry[key];
    if (cfg) openPanel(cfg.label || key, cfg.detail || "");
  }

  /* --------------------------- node helpers ------------------------------- */
  function nodeText(g) { return (g.textContent || "").replace(/\s+/g, " ").trim(); }
  // flowchart / stateDiagram-v2 / erDiagram / classDiagram / mindmap all share Mermaid's
  // common node renderer, so their items already carry a "node" class token — nodeKeys()
  // below handles that whole family for free. sequenceDiagram, gantt, and gitGraph use
  // their OWN renderers with no "node" class at all, so each gets its own finder here.
  function collectSequenceActors(svg) {
    // each participant draws TWO boxes (top + bottom of its lifeline); both wire to the
    // same key — either box firing the same click is harmless, not a bug.
    return [].slice.call(svg.querySelectorAll("text.actor-box")).map(function (t) {
      return { g: t.closest("g") || t.parentNode, keys: [nodeText(t)] };
    });
  }
  function collectGanttTasks(svg) {
    // a task bar's id is its internal alias (e.g. "a1"); the human-readable name is a
    // sibling <text>, rendered in the same task order — zip them positionally.
    var bars = [].slice.call(svg.querySelectorAll("rect.task"));
    var labels = [].slice.call(svg.querySelectorAll("text[class*='taskText']"));
    return bars.map(function (r, i) { return { g: r, keys: [nodeText(labels[i] || r)] }; });
  }
  function collectGitCommits(svg) {
    // a commit's class carries its `id:"…"` verbatim when the author gave one; a bare
    // `commit` gets an auto hash instead, which isn't a meaningful key (see diagrams.md).
    return [].slice.call(svg.querySelectorAll("circle[class*='commit']")).map(function (c) {
      var custom = (c.getAttribute("class") || "").split(/\s+/).filter(function (t) {
        return t && t !== "commit" && !/^commit\d+$/.test(t) && !/^\d+-[0-9a-f]+$/.test(t);
      });
      return { g: c, keys: custom.length ? custom : [nodeText(c)] };
    });
  }
  // The single collector every diagram type funnels through. Marks every item with
  // "wid-item" — the one CSS hook hover/select/dim styling keys off, regardless of
  // whether the underlying element is a Mermaid "node" <g>, a bare <rect>, or a <circle>.
  function collectAll(svg) {
    var items = [].map.call(svg.querySelectorAll("g.node"), function (g) { return { g: g, keys: nodeKeys(g) }; })
      .concat(collectSequenceActors(svg), collectGanttTasks(svg), collectGitCommits(svg))
      .filter(function (o) { return o.g && o.keys[0]; });
    items.forEach(function (o) { o.g.classList.add("wid-item"); });
    return items;
  }
  // Resolve every key a node could be matched by. Mermaid v11 ids look like
  // "<renderId>-flowchart-<NODEID>-<index>" (the renderId contains digits, and
  // there is NO data-id), so naive parsing fails — we try several strategies and
  // also fall back to the visible label, so islands can be keyed by id OR label.
  function nodeKeys(g) {
    var keys = [];
    var di = g.getAttribute("data-id"); if (di) keys.push(di);          // future-proof
    var id = g.id || "";
    if (id) {
      var noIdx = id.replace(/-\d+$/, "");                              // drop trailing -<index>
      var last = noIdx.match(/([A-Za-z0-9_]+)$/);                       // the NODEID (common: alnum/underscore)
      if (last) keys.push(last[1]);
      var typed = noIdx.match(/-(?:flowchart(?:-v2)?|stateDiagram(?:-v2)?|state|classDiagram|class|er|mindmap|sequence)-(.+)$/);
      if (typed) keys.push(typed[1]);                                   // node ids containing dashes
    }
    var t = nodeText(g); if (t) keys.push(t);                           // match by visible label too
    return keys.filter(function (k, i, a) { return k && a.indexOf(k) === i; });
  }

  function wireNode(g, key, cfg) {
    g.classList.add("wid-act");
    g.setAttribute("tabindex", "0");
    g.setAttribute("role", "button");
    var verb = cfg.section ? "Go to section" : cfg.url ? "Open link" : "Show detail";
    g.setAttribute("aria-label", (cfg.label || key) + " — " + verb);
    registry[key] = cfg;
    var act = function (e) {
      var vp = g.closest(".wid-dgm-viewport");
      if (vp && vp._panned) return;           // a drag, not a click
      if (e) e.preventDefault();
      if (cfg.section) widGo(cfg.section);
      else if (cfg.url) window.open(cfg.url, "_blank", "noopener");
      else if (cfg.detail) openPanel(cfg.label || key, cfg.detail);
    };
    g.addEventListener("click", act);
    g.addEventListener("keydown", function (e) {
      if (e.key === "Enter" || e.key === " ") act(e);
    });
  }

  /* ------------------------------ enhance --------------------------------- */
  function readIsland(fig) {
    var s = fig.querySelector(":scope > script.export-data");
    if (!s) return null;
    try { return JSON.parse(s.textContent); } catch (e) { return null; }
  }

  function enhance(fig) {
    if (fig.__widDgm) return true;
    var mer = fig.querySelector(".mermaid");
    var svg = mer && mer.querySelector("svg");
    if (!svg) return false;            // Mermaid hasn't inserted the SVG yet
    // Mermaid renders ASYNC and flips data-processed="true" a beat BEFORE the node
    // <g> elements are actually queryable — so that flag is NOT a safe "ready" signal
    // for wiring (enhancing on it grabs a node-less SVG, wires nothing, and the
    // __widDgm guard then blocks the retry). Instead: if this diagram declares
    // interactive nodes, wait until those node elements truly exist (the observer
    // re-fires as Mermaid inserts them); otherwise just wait for any rendered content.
    var island = readIsland(fig);
    var wantsNodes = !!(island && (island.nodes || (island.walkthrough && island.walkthrough.length)));
    var items = collectAll(svg);
    if (wantsNodes) { if (!items.length) return false; }
    else if (mer.getAttribute("data-processed") !== "true" && !svg.querySelector("g")) return false;
    fig.__widDgm = true;

    /* wrap for zoom/pan */
    var vp = document.createElement("div");
    vp.className = "wid-dgm-viewport";
    mer.parentNode.insertBefore(vp, mer);
    vp.appendChild(mer);

    var st = { s: 1, x: 0, y: 0 };
    var apply = function () { svg.style.transform = "translate(" + st.x + "px," + st.y + "px) scale(" + st.s + ")"; };
    // Wide bounds: a big/tall diagram must be allowed to shrink well below the old 0.4
    // floor — otherwise "fit to fullscreen" can't contain it and zoom-out hits a wall.
    var clamp = function (v) { return Math.max(0.1, Math.min(8, v)); };
    // Fit the diagram to fill the viewport (contain), centred — used in fullscreen so a
    // small/short diagram scales up and sits in the middle instead of tiny in the corner.
    function fit() {
      var prev = svg.style.transform; svg.style.transform = "none";
      var sr = svg.getBoundingClientRect(), r = vp.getBoundingClientRect();
      var sw = sr.width, sh = sr.height;
      if (!sw || !sh) { svg.style.transform = prev; return; }
      // The svg's untransformed top-left does NOT necessarily coincide with the viewport's
      // top-left: an inline svg carries a line-box gap above it, and a centred .mermaid
      // offsets it horizontally. Measure that real offset (with transform off) so the
      // centring below lands the diagram dead-centre instead of ~16px down-and-right —
      // the "small diagram doesn't fill / sits off in fullscreen" bug.
      var off = { x: sr.left - r.left, y: sr.top - r.top };
      var pad = 32;
      st.s = clamp(Math.min((r.width - pad) / sw, (r.height - pad) / sh));
      st.x = (r.width - sw * st.s) / 2 - off.x;
      st.y = (r.height - sh * st.s) / 2 - off.y;
      apply();
    }
    var reset = function () {
      if (vp.classList.contains("is-fs")) { fit(); return; }  // in fullscreen, "reset" means fit
      st.s = 1; st.x = 0; st.y = 0; apply();
    };
    // Zoom about a fixed point (cx,cy in viewport coords) so that point stays put.
    var zoomAt = function (ns, cx, cy) {
      ns = clamp(ns);
      st.x = cx - (cx - st.x) * (ns / st.s);
      st.y = cy - (cy - st.y) * (ns / st.s);
      st.s = ns; apply();
    };
    // The +/- buttons zoom about the viewport CENTRE, so the diagram stays centred.
    var zoomCenter = function (mult) { var r = vp.getBoundingClientRect(); zoomAt(st.s * mult, r.width / 2, r.height / 2); };

    /* pan — capture the pointer ONLY once it actually moves past a threshold. Capturing
       on pointerdown (as before) makes the browser retarget the follow-up `click` to the
       viewport, so a plain click never reaches a node or a toolbar button — interaction
       silently dies for real mouse/touch users (synthetic dispatch is unaffected, which
       is why tests missed it). Deferring capture keeps a click a click. */
    var drag = null;
    vp.addEventListener("pointerdown", function (e) {
      if (e.target.closest && e.target.closest(".wid-dgm-tools")) return; // don't pan from the toolbar
      drag = { x: e.clientX, y: e.clientY, ox: st.x, oy: st.y, id: e.pointerId, capturing: false };
      vp._panned = false;
    });
    vp.addEventListener("pointermove", function (e) {
      if (!drag) return;
      var dx = e.clientX - drag.x, dy = e.clientY - drag.y;
      if (!drag.capturing && Math.abs(dx) + Math.abs(dy) > 4) {
        drag.capturing = true; vp._panned = true; vp.classList.add("is-panning");
        try { vp.setPointerCapture(drag.id); } catch (_) {}
      }
      if (!drag.capturing) return;        // below the threshold → still a potential click
      st.x = drag.ox + dx; st.y = drag.oy + dy; apply();
    });
    var endDrag = function () { drag = null; vp.classList.remove("is-panning"); };
    vp.addEventListener("pointerup", endDrag);
    vp.addEventListener("pointercancel", endDrag);
    vp.addEventListener("pointerleave", endDrag);

    /* Trackpad / mouse wheel — we intercept exactly ONE gesture: a PINCH, to zoom the
       diagram. The trick that makes both scroll AND pinch-zoom work on a Mac trackpad is
       that the browser delivers them as different wheel events:
         • a PINCH (two fingers apart/together) arrives as wheel with ctrlKey === true;
         • a plain two-finger up/down SWIPE arrives as wheel with ctrlKey === false.
       So we gate on ctrlKey:
         • ctrlKey  → pinch → zoom the diagram about the cursor, and preventDefault so the
                      browser doesn't page-zoom on top of us;
         • no ctrl  → ordinary scroll → do NOTHING (never preventDefault) → the page scrolls
                      natively. Not claiming the plain wheel is what keeps two-finger scroll
                      working — the earlier "scroll doesn't work" bug was from claiming it.
       passive:false is required for preventDefault() to take effect on the pinch. */
    vp.addEventListener("wheel", function (e) {
      if (!e.ctrlKey) return;                          // two-finger scroll → leave it to the page
      e.preventDefault();
      var r = vp.getBoundingClientRect();
      var factor = Math.exp(-e.deltaY * 0.01);         // deltaY<0 pinch-apart → in; >0 pinch-together → out
      zoomAt(st.s * factor, e.clientX - r.left, e.clientY - r.top);  // zoom about the cursor
    }, { passive: false });

    /* toolbar */
    var tools = document.createElement("div");
    tools.className = "wid-dgm-tools";
    function tbtn(txt, title, fn) {
      var b = document.createElement("button"); b.type = "button"; b.textContent = txt;
      b.title = title; b.setAttribute("aria-label", title);
      b.addEventListener("click", fn); return b;
    }

    /* walkthrough (optional) — `island` already read above; `items` from the readiness gate */
    var gNodes = items;
    var find = function (key) {
      return gNodes.filter(function (o) { return o.keys.indexOf(key) >= 0; })[0];
    };

    /* persistent click-selection spotlight — the focus follows clicks AND the walkthrough,
       so clicking a node moves the highlight to it (the drawer info already updates). The
       page dims while a node is selected OR hovered; selection clears on a background
       click or when the detail drawer closes. */
    var selected = null, hovering = null;
    var dim = function () { svg.classList[(selected || hovering) ? "add" : "remove"]("wid-dim"); };
    var selectNode = function (g) { if (selected && selected !== g) selected.classList.remove("wid-sel"); selected = g || null; if (g) g.classList.add("wid-sel"); dim(); };
    var clearSelect = function () { if (selected) selected.classList.remove("wid-sel"); selected = null; dim(); };
    onPanelClose.push(clearSelect);
    vp.addEventListener("click", function (e) {
      if (vp._panned) return;
      if (e.target.closest && (e.target.closest("g.node") || e.target.closest(".wid-dgm-tools"))) return;
      clearSelect();                                   // clicked empty space → deselect
    });

    /* node click actions from the island (+ move the selection spotlight to the clicked node) */
    if (island && island.nodes) {
      Object.keys(island.nodes).forEach(function (key) {
        var hit = find(key);
        if (!hit) return;
        wireNode(hit.g, key, island.nodes[key]);
        hit.g.addEventListener("click", function () { if (!vp._panned) selectNode(hit.g); });
      });
    }

    var walk = island && Array.isArray(island.walkthrough) ? island.walkthrough : null;
    if (walk && walk.length) {
      var idx = -1;
      var box = document.createElement("div"); box.className = "wid-dgm-walk";
      var lbl = document.createElement("span"); lbl.className = "lbl";
      var step = function (i) {
        idx = (i + walk.length) % walk.length;
        var hit = find(walk[idx]); var cfg = island.nodes && island.nodes[walk[idx]];
        if (hit) selectNode(hit.g);                    // reuse the selection spotlight
        lbl.textContent = (idx + 1) + " / " + walk.length;
        if (cfg && cfg.detail) openPanel((cfg && cfg.label) || walk[idx], cfg.detail);
      };
      var stop = function () { clearSelect(); idx = -1; lbl.textContent = "Tour"; closePanel(); };
      box.append(
        tbtn("◀", "Previous step", function () { step(idx <= 0 ? walk.length - 1 : idx - 1); }),
        lbl,
        tbtn("▶", "Next step / start tour", function () { step(idx + 1); })
      );
      lbl.textContent = "Tour";
      tools.appendChild(box);
      box.appendChild(tbtn("✕", "End tour", stop));
    }

    /* hover spotlight — transient; doesn't clear a click-selection (dim stays if selected) */
    gNodes.forEach(function (o) {
      o.g.addEventListener("mouseenter", function () { hovering = o.g; o.g.classList.add("wid-hot"); dim(); });
      o.g.addEventListener("mouseleave", function () { hovering = null; o.g.classList.remove("wid-hot"); dim(); });
    });

    tools.append(
      tbtn("＋", "Zoom in", function () { zoomCenter(1.2); }),
      tbtn("－", "Zoom out", function () { zoomCenter(0.8); }),
      tbtn("⟲", "Reset view", reset),
      tbtn("⤢", "Fullscreen", function () { vp.classList.toggle("is-fs"); reset(); })
    );
    vp.appendChild(tools);

    var hint = document.createElement("div");
    hint.className = "wid-dgm-hint";
    hint.textContent = (island && island.nodes ? "click nodes · " : "") + "drag to pan · pinch or +/− to zoom";
    vp.appendChild(hint);

    return true;
  }

  /* ----------------------- wait for Mermaid render ------------------------ */
  function scan() {
    var figs = document.querySelectorAll("figure.diagram, .wid-diagram, [data-block='diagram']");
    var pending = false;
    figs.forEach(function (f) { if (!enhance(f)) pending = true; });
    return pending;
  }

  function start() {
    injectCSS();
    // Mermaid renders async AND can replace the rendered subtree a tick after it first
    // appears (the replacement keeps our wid-* classes but drops the JS click/hover
    // listeners) — so enhancing on the first mutation wires elements that are then
    // thrown away. Instead, DEBOUNCE: only enhance after the DOM has been quiet for a
    // beat, so we wire the final, stable nodes. Re-scan on childList changes and on the
    // data-processed flag flip (a node-less diagram emits only the attribute when done).
    var timer = null, obs = null;
    var settle = function () { if (!scan() && obs) obs.disconnect(); };
    var schedule = function () { clearTimeout(timer); timer = setTimeout(settle, 250); };
    obs = new MutationObserver(schedule);
    obs.observe(document.body, {
      childList: true, subtree: true, attributes: true, attributeFilter: ["data-processed"],
    });
    schedule();                                   // also handles an already-rendered page
    setTimeout(function () { if (obs) obs.disconnect(); }, 15000);  // safety net
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();

  window.widGo = window.widGo || widGo;
  window.widInfo = window.widInfo || widInfo;
  window.WIDDiagram = { enhance: enhance, openPanel: openPanel, go: widGo };
})();
