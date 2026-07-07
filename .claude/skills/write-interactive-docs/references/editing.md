# Editing an existing doc (Mode B — partial update)

When the user asks to change a doc that already exists, **edit that file in place.
Don't regenerate it.** A rebuild throws away their wording and tweaks, reshuffles
content, re-rolls the theme, and risks breaking diagrams that already worked. Your job
is the *smallest* change that satisfies the request — everything else stays byte-for-byte.

## The four rules

1. **Smallest diff.** Touch only what was asked. Leave other sections, the theme
   tokens, and the inlined engines exactly as they are.
2. **Keep it one file.** Don't add external files or a second copy of an engine.
3. **A block and its island move together.** Every rich block (diagram, chart,
   comparison, tabs, callout, steps) has a hidden `<script type="application/json"
   class="export-data">` island that the export is rebuilt from. If you change the
   visual, change the island to match — and vice versa — or the export goes stale.
4. **Re-verify.** After any edit, run `scripts/verify-doc.mjs <file>` (see SKILL.md →
   Verify). Re-running is cheap and catches a broken diagram or a stale island.

## How the doc is structured (so you can find things)
- Page root: `<main data-doc data-doc-title="…">`. Section: `<section data-section
  data-section-title="…" data-section-id="…">`. The export engine + the per-section
  export buttons attach themselves on load, so new sections/blocks are picked up
  automatically — no wiring needed.
- Theme lives entirely in the `:root` token block (and `[data-theme="dark"]`). Every
  component reads those tokens, so re-theming is a one-place change.

## Common edits

| Request | Do exactly this |
| --- | --- |
| Fix wording / a table / a list | Edit the HTML in that section. If it sits inside a rich block, update its island too. |
| Restyle / change colours / dark mode | Edit only the `:root` tokens (and `[data-theme]`). Don't touch content. See **theming.md**. |
| Change a diagram | Edit **both** the visible `<pre class="mermaid">` **and** the island `source` — keep them identical and valid Mermaid (see **diagrams.md → the two rules**). |
| Make a diagram interactive (or change its interactivity) | Ensure `diagram-interactions.js` is inlined (add it if missing); add/edit that diagram's island `nodes` / `walkthrough`. Nothing else changes. |
| Add a section | Insert a new `<section data-section data-section-title data-section-id>` with its blocks + islands at the right spot. It auto-wires. |
| Remove a section | Delete the whole `<section>…</section>`. |
| Add/swap a component in a section | Add the block's HTML + author its island **first**, then the visual from the same data (**components.md**). |
| Add/adjust a Thai translation | Set/edit `data-th` on the leaf element. If the doc isn't localized yet, add `data-i18n="en,th"` to `<main>` and inline `i18n.js` (**localization.md**). English (the export source) is untouched. |
| Fix a bug in an engine | Replace the contents of the matching inlined `<script>` with the current asset file (`assets/export-engine.js` / `assets/diagram-interactions.js`). They're already inline-safe (`</script>` escaped). |

## When the existing doc wasn't made by this skill
If it has no token block / no inlined engines (e.g. a hand-written HTML or a plain
export), a true "make it interactive / add export" request is closer to a build than a
patch. Inline the engines and wrap content in `data-section`s as needed — but say so
and confirm scope first, since it's a larger change than the user may expect.
