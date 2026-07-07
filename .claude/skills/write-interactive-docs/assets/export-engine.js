/*
 * Interactive Docs — Export Engine (self-contained, no dependencies)
 * --------------------------------------------------------------------
 * Gives any generated doc two superpowers, both AI-friendly:
 *   • Export to Markdown   (clean prose an LLM can read as a prompt)
 *   • Export to JSON        (a structured tree an LLM can parse)
 * …at two scopes:
 *   • the WHOLE page
 *   • a SINGLE section
 * …via two actions:
 *   • download a file
 *   • copy to clipboard (great for pasting straight into another prompt)
 *
 * INLINE this whole file inside a <script> tag in the generated .html so the
 * doc stays a single shareable file. Do NOT link it as an external src.
 *
 * ── How it reads the document ──────────────────────────────────────────────
 * The page root:      <main data-doc data-doc-title="My Doc">
 * Each section:       <section class="doc-section" data-section
 *                              data-section-title="Overview" data-section-id="overview">
 *
 * Standard HTML inside a section converts automatically:
 *   h1–h6, p, ul/ol/li (nested ok), table, pre>code, blockquote, hr,
 *   a, img, strong/b, em/i, code.
 *
 * Rich components (diagrams, charts, comparisons, tabs, callouts, UI previews) can't
 * be reverse-engineered from their pixels, so each one carries a canonical export
 * representation in a hidden JSON island — the single source of truth for export.
 * A plain-prose block can carry one too (data-block="prose"), so the visible copy can
 * read plainly for a person while the island holds the fuller version an AI reads:
 *
 *   <figure data-block="diagram">
 *     ...visual...
 *     <script type="application/json" class="export-data">
 *       {"type":"diagram","diagramType":"flowchart","title":"Auth flow",
 *        "source":"graph TD; A-->B"}
 *     <\/script>
 *   </figure>
 *
 * If a block has an export-data island, the engine trusts it and ignores the
 * visual DOM for that block. See renderBlockMd()/normalizeBlock() for the
 * per-type schemas. Authoring tip: write the island FIRST, then build the
 * visual from the same data, so the two never drift apart.
 */
(function () {
  "use strict";

  /* ----------------------------- helpers ---------------------------------- */

  const slug = (s) =>
    (s || "section")
      .toLowerCase()
      .replace(/[^\w]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "section";

  const txt = (el) => (el.textContent || "").replace(/\s+/g, " ").trim();

  function toast(msg) {
    let t = document.querySelector(".wid-toast");
    if (!t) {
      t = document.createElement("div");
      t.className = "wid-toast";
      document.body.appendChild(t);
    }
    t.textContent = msg;
    t.classList.add("is-on");
    clearTimeout(t._timer);
    t._timer = setTimeout(() => t.classList.remove("is-on"), 1600);
  }

  function download(name, mime, content) {
    const blob = new Blob([content], { type: mime });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = name;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text);
      toast("Copied to clipboard");
    } catch (e) {
      // Fallback for non-secure contexts / older browsers
      const ta = document.createElement("textarea");
      ta.value = text;
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      try { document.execCommand("copy"); toast("Copied to clipboard"); }
      catch (_) { toast("Copy failed — select & copy manually"); }
      ta.remove();
    }
  }

  /* ----------------- inline (bold / italic / code / link) ----------------- */

  function inlineMd(node) {
    let out = "";
    node.childNodes.forEach((n) => {
      if (n.nodeType === 3) {
        out += n.nodeValue.replace(/\s+/g, " ");
      } else if (n.nodeType === 1) {
        const tag = n.tagName.toLowerCase();
        const inner = inlineMd(n);
        if (tag === "strong" || tag === "b") out += `**${inner.trim()}**`;
        else if (tag === "em" || tag === "i") out += `*${inner.trim()}*`;
        else if (tag === "code") out += "`" + txt(n) + "`";
        else if (tag === "a") out += `[${inner.trim()}](${n.getAttribute("href") || ""})`;
        else if (tag === "br") out += "  \n";
        else if (tag === "img")
          out += `![${n.getAttribute("alt") || ""}](${n.getAttribute("src") || ""})`;
        else out += inner;
      }
    });
    return out;
  }

  function listMd(listEl, depth) {
    const ordered = listEl.tagName.toLowerCase() === "ol";
    let i = 1, lines = [];
    [...listEl.children].forEach((li) => {
      if (li.tagName.toLowerCase() !== "li") return;
      const sub = li.querySelector(":scope > ul, :scope > ol");
      const own = [...li.childNodes]
        .filter((c) => !(c.nodeType === 1 && /^(ul|ol)$/i.test(c.tagName)))
        .map((c) => (c.nodeType === 1 ? inlineMd(c) : (c.nodeValue || "")))
        .join("")
        .replace(/\s+/g, " ")
        .trim();
      const bullet = ordered ? `${i++}.` : "-";
      lines.push(`${"  ".repeat(depth)}${bullet} ${own}`);
      if (sub) lines.push(listMd(sub, depth + 1));
    });
    return lines.join("\n");
  }

  function tableMd(tableEl) {
    const rows = [...tableEl.querySelectorAll("tr")].map((tr) =>
      [...tr.children].map((c) => inlineMd(c).trim().replace(/\|/g, "\\|"))
    );
    if (!rows.length) return "";
    const head = rows[0];
    const body = rows.slice(1);
    const sep = head.map(() => "---");
    const fmt = (r) => `| ${r.join(" | ")} |`;
    return [fmt(head), fmt(sep), ...body.map(fmt)].join("\n");
  }

  /* ----------------------- rich-block markdown ---------------------------- */

  function renderBlockMd(b) {
    switch (b.type) {
      case "diagram": {
        const parts = [];
        if (b.title) parts.push(`**${b.title}**`);
        parts.push("```mermaid\n" + (b.source || "").trim() + "\n```");
        // Interactive node info (detail / navigation / link) so the export keeps
        // what a reader would discover by clicking the diagram.
        if (b.nodes && typeof b.nodes === "object") {
          const rows = Object.keys(b.nodes).map((k) => {
            const v = b.nodes[k] || {};
            if (!(v.detail || v.section || v.url)) return null;
            const dest = v.section ? ` _(→ ${v.section})_` : v.url ? ` _(→ ${v.url})_` : "";
            return `- **${v.label || k}**${dest}${v.detail ? " — " + v.detail : ""}`;
          }).filter(Boolean);
          if (rows.length) parts.push("_Nodes:_\n" + rows.join("\n"));
        }
        return parts.join("\n\n");
      }

      case "chart": {
        const lines = [];
        if (b.title) lines.push(`**${b.title}**  _(chart: ${b.chartType || "bar"})_\n`);
        const ds = b.datasets || [];
        const head = ["", ...ds.map((d) => d.label || "value")];
        lines.push(`| ${head.join(" | ")} |`);
        lines.push(`| ${head.map(() => "---").join(" | ")} |`);
        (b.labels || []).forEach((lab, i) => {
          lines.push(`| ${lab} | ${ds.map((d) => (d.data || [])[i] ?? "").join(" | ")} |`);
        });
        return lines.join("\n");
      }

      case "comparison": {
        const lines = [];
        if (b.title) lines.push(`**${b.title}**\n`);
        const opts = b.options || [];
        lines.push(`| Criterion | ${opts.join(" | ")} |`);
        lines.push(`| ${["---", ...opts.map(() => "---")].join(" | ")} |`);
        (b.criteria || []).forEach((c) => {
          lines.push(`| ${c.name} | ${(c.values || []).join(" | ")} |`);
        });
        if (b.recommended) lines.push(`\n✅ **Recommended: ${b.recommended}**`);
        if (b.rationale) lines.push(`\n${b.rationale}`);
        return lines.join("\n");
      }

      case "tabs":
        return (b.tabs || [])
          .map((t) => `##### ${t.label}\n\n${(t.md || "").trim()}`)
          .join("\n\n");

      case "callout": {
        const icon = { info: "ℹ️", tip: "💡", warning: "⚠️", danger: "🛑", success: "✅" }[b.variant] || "ℹ️";
        const label = (b.variant || "note").toUpperCase();
        const body = (b.md || "").trim().split("\n").map((l) => `> ${l}`).join("\n");
        return `> ${icon} **${label}**\n${body}`;
      }

      case "steps": {
        const parts = [];
        // Human decisions (from the plan-approval engine) lead, so an implementer
        // reading the Markdown sees what the human changed before the original steps.
        if (Array.isArray(b.decisions) && b.decisions.length) {
          parts.push("**🧑‍⚖️ Human decisions (approved):**");
          parts.push(b.decisions.map((d) => {
            const where = d.section ? `**${d.section}** — ` : "";
            let head;
            if (Array.isArray(d.choices) && d.choices.length) head = "chose " + d.choices.map((c) => `**${c}**`).join(", ");
            else if (d.choice) head = `chose **${d.choice}**`;
            else head = d.feedback ? "commented" : "modified";
            const note = d.note ? ` — ${d.note}` : "";
            return `- ${where}${head}${note}`;
          }).join("\n"));
        }
        parts.push((b.steps || []).map((s, i) => `${i + 1}. **${s.title || ""}** ${s.md || ""}`.trim()).join("\n"));
        return parts.join("\n\n");
      }

      case "kpis":
        return (b.items || []).map((k) => `- **${k.value}** — ${k.label}`).join("\n");

      case "preview": {
        // A rendered UI mockup on the page; the export carries what an AI needs to
        // rebuild it — a description and the mockup markup (or an image reference).
        const lines = [];
        if (b.title) lines.push(`**${b.title}**  _(UI preview)_`);
        if (b.description) lines.push(b.description);
        if (b.html) lines.push("```html\n" + String(b.html).trim() + "\n```");
        else if (b.image) lines.push(`![${b.title || "preview"}](${b.image})`);
        return lines.join("\n\n");
      }

      default:
        // Unknown rich type: dump its markdown field, else JSON.
        return b.md || "```json\n" + JSON.stringify(b, null, 2) + "\n```";
    }
  }

  /* ------------- walk a section's DOM into ordered blocks ----------------- */

  function blockFromIsland(host) {
    const island = host.querySelector(":scope > script.export-data");
    if (!island) return null;
    try { return JSON.parse(island.textContent); }
    catch (e) { return null; }
  }

  // Returns array of {type, ...} block objects in document order.
  function readBlocks(scope) {
    const blocks = [];
    const walk = (node) => {
      [...node.children].forEach((el) => {
        const tag = el.tagName.toLowerCase();
        // A rich block declares itself with data-block + an export-data island.
        if (el.hasAttribute("data-block")) {
          const island = blockFromIsland(el);
          if (island) { blocks.push(island); return; }
        }
        if (/^h[1-6]$/.test(tag)) {
          blocks.push({ type: "heading", level: +tag[1], text: inlineMd(el).trim() });
        } else if (tag === "p") {
          const t = inlineMd(el).trim();
          if (t) blocks.push({ type: "prose", md: t });
        } else if (tag === "ul" || tag === "ol") {
          blocks.push({ type: "list", ordered: tag === "ol", md: listMd(el, 0) });
        } else if (tag === "table") {
          blocks.push({ type: "table", md: tableMd(el) });
        } else if (tag === "pre") {
          const code = el.querySelector("code");
          const lang = (code && (code.getAttribute("data-lang") ||
            (code.className.match(/language-([\w-]+)/) || [])[1])) || "";
          blocks.push({ type: "code", lang, text: (code || el).textContent.replace(/\s+$/, "") });
        } else if (tag === "blockquote") {
          blocks.push({ type: "quote", md: inlineMd(el).trim() });
        } else if (tag === "hr") {
          blocks.push({ type: "rule" });
        } else if (tag === "figure" || tag === "figcaption" || tag === "div" || tag === "section") {
          // containers without an island: descend
          walk(el);
        }
      });
    };
    walk(scope);
    return blocks;
  }

  function blockToMd(b) {
    switch (b.type) {
      case "heading": return `${"#".repeat(b.level)} ${b.text}`;
      case "prose": return b.md;
      case "list": return b.md;
      case "table": return b.md;
      case "code": return "```" + (b.lang || "") + "\n" + b.text + "\n```";
      case "quote": return b.md.split("\n").map((l) => `> ${l}`).join("\n");
      case "rule": return "---";
      default: return renderBlockMd(b);
    }
  }

  /* ----------------------------- assemble --------------------------------- */

  function sectionModel(sectionEl) {
    const title =
      sectionEl.getAttribute("data-section-title") ||
      txt(sectionEl.querySelector("h1,h2,h3")) ||
      "Section";
    const id = sectionEl.getAttribute("data-section-id") || slug(title);
    // Defensive: a section may itself be tagged as a single rich block
    // (e.g. <section data-block="comparison">). Trust its island if so.
    const ownIsland = sectionEl.hasAttribute("data-block") ? blockFromIsland(sectionEl) : null;
    return { id, title, blocks: ownIsland ? [ownIsland] : readBlocks(sectionEl) };
  }

  function pageModel() {
    const root = document.querySelector("[data-doc]") || document.body;
    return {
      title: root.getAttribute("data-doc-title") || document.title || "Document",
      generatedFor: root.getAttribute("data-doc-project") || null,
      sections: [...root.querySelectorAll("[data-section]")].map(sectionModel),
    };
  }

  function sectionMd(model) {
    const lines = [];
    // If the section has no leading heading block, synthesize one from its title
    // so the title is never lost — and never doubled when an <h2> already exists.
    if (!(model.blocks[0] && model.blocks[0].type === "heading")) {
      lines.push(`## ${model.title}`);
    }
    model.blocks.forEach((b) => { lines.push(blockToMd(b)); });
    return lines.join("\n\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
  }

  function pageMd(model) {
    const out = [`# ${model.title}`];
    if (model.generatedFor) out.push(`_Generated for: ${model.generatedFor}_`);
    model.sections.forEach((s) => out.push(sectionMd(s)));
    return out.join("\n\n").replace(/\n{3,}/g, "\n\n").trim() + "\n";
  }

  /* ------------------------------ exports --------------------------------- */

  function exportPage(fmt, action) {
    const model = pageModel();
    const base = slug(model.title);
    if (fmt === "json") {
      const s = JSON.stringify(model, null, 2);
      action === "copy" ? copy(s) : download(`${base}.json`, "application/json", s);
    } else {
      const s = pageMd(model);
      action === "copy" ? copy(s) : download(`${base}.md`, "text/markdown", s);
    }
  }

  function exportSection(sectionEl, fmt, action) {
    const model = sectionModel(sectionEl);
    const base = slug(model.title);
    if (fmt === "json") {
      const s = JSON.stringify(model, null, 2);
      action === "copy" ? copy(s) : download(`${base}.json`, "application/json", s);
    } else {
      const s = sectionMd(model); // sectionMd already emits the title
      action === "copy" ? copy(s) : download(`${base}.md`, "text/markdown", s);
    }
  }

  /* --------------------------- wire the UI -------------------------------- */

  function btn(label, title, onClick) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "wid-btn";
    b.textContent = label;
    b.title = title;
    b.addEventListener("click", onClick);
    return b;
  }

  function buildSectionControls(sectionEl) {
    if (sectionEl.querySelector(":scope > .wid-section-tools")) return;
    const bar = document.createElement("div");
    bar.className = "wid-section-tools";
    bar.setAttribute("aria-label", "Export this section");
    bar.append(
      btn("⧉ MD", "Copy this section as Markdown", () => exportSection(sectionEl, "md", "copy")),
      btn("↓ MD", "Download this section as Markdown", () => exportSection(sectionEl, "md", "download")),
      btn("↓ JSON", "Download this section as JSON", () => exportSection(sectionEl, "json", "download"))
    );
    sectionEl.prepend(bar);
  }

  function buildGlobalToolbar() {
    // Honour an author-provided toolbar if present (buttons with data-wid-action),
    // otherwise inject a floating one.
    const declared = document.querySelectorAll("[data-wid-action]");
    if (declared.length) {
      declared.forEach((el) => {
        const [scope, fmt, action] = (el.getAttribute("data-wid-action") || "").split(":");
        el.addEventListener("click", () =>
          scope === "page"
            ? exportPage(fmt, action || "download")
            : exportSection(el.closest("[data-section]"), fmt, action || "download")
        );
      });
      return;
    }
    const bar = document.createElement("div");
    bar.className = "wid-toolbar";
    bar.setAttribute("role", "toolbar");
    bar.setAttribute("aria-label", "Export document");
    const lab = document.createElement("span");
    lab.className = "wid-toolbar-label";
    lab.textContent = "Export page:";
    bar.append(
      lab,
      btn("⧉ MD", "Copy whole page as Markdown", () => exportPage("md", "copy")),
      btn("↓ MD", "Download whole page as Markdown", () => exportPage("md", "download")),
      btn("↓ JSON", "Download whole page as JSON", () => exportPage("json", "download"))
    );
    document.body.appendChild(bar);
  }

  function init() {
    buildGlobalToolbar();
    document.querySelectorAll("[data-section]").forEach(buildSectionControls);
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }

  // Expose for programmatic use / debugging.
  window.WID = { exportPage, exportSection, pageModel, pageMd };
})();
