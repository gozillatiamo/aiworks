# Theming — match the project, never plain black & white

The doc should *feel* like it came from the project it documents. A FinTech repo
gets deep, trustworthy blues; a kids' app gets playful brights; a pet-health app
gets warm, calm greens/teals. The reader should sense the brand before
reading a word. Plain black text on white is a failure state — always derive or
generate a real palette.

## Step 1 — detect the project's existing style (preferred)

Spend a minute looking; reuse beats inventing. Look, in order, for:

| Source | Where to look |
| --- | --- |
| Design tokens | `tokens.json`, `*.tokens.json`, `design-tokens*`, Style Dictionary, `theme.json` |
| CSS variables | `:root { --color-… }` in any `.css`/`.scss`; `theme.css`, `variables.scss` |
| Tailwind | `tailwind.config.{js,ts}` → `theme.extend.colors` |
| Flutter | `lib/**/theme*.dart`, `ColorScheme`, `ThemeData`, `Color(0xFF…)`, `app_theme.dart` |
| iOS / Android | `Assets.xcassets/*.colorset`, `colors.xml`, Material `colorPrimary` |
| Brand assets | logo SVG/PNG fill colours, `manifest.json` `theme_color`, favicon |
| Marketing | a README banner, a docs site, `<meta name="theme-color">` |
| Figma | if the Figma MCP is available, `get_variable_defs` for color/typography tokens |

Pull out: **primary**, an **accent/secondary**, neutral **surface/background/
text/border**, and any **semantic** colours (success/warning/danger). Note the
**font** family if the project declares one, and the overall **vibe** (rounded vs
sharp, dense vs airy, serious vs playful).

For a Flutter app in this workspace: the app theme usually lives in the app repo
(`codegraph explore … -p <app-repo>`, or read `lib/**/theme*.dart`). Match the
product's actual vibe — don't default to corporate grey.

## Step 2 — map detected values onto the template tokens

The template exposes one token block in `:root`. Fill it from what you found:

```css
:root{
  --color-primary: <brand primary>;
  --color-accent:  <secondary / highlight; also marks "recommended">;
  --color-bg:      <app background, usually a near-white tint of the brand>;
  --color-surface: #ffffff;             /* cards, tables */
  --color-surface-2: <subtle fill>;     /* code, table head */
  --color-text:    <near-black, slightly toward brand hue>;
  --color-muted:   <60% text>;
  --color-border:  <low-contrast divider>;
  --font-sans:     <project UI font, else Inter>;
}
```
Tips:
- Tint neutrals toward the brand hue (e.g. a hint of teal in the greys) — that's
  what makes it read as *themed* rather than default.
- Keep one primary + one accent. More than two "loud" colours looks noisy.
- Provide a `[data-theme="dark"]` block (template has one) when the project is
  dark-first or the content suits it.

## Step 3 — if nothing exists, generate a fitting palette

Choose by **content domain + mood**, then build a coherent set. Don't grab random
hues — pick one brand hue, derive an accent ~150–180° away (or an analogous
neighbour for a calmer feel), and build neutrals tinted toward the brand.

Starting points (adapt, don't copy blindly):

| Domain / mood | Primary | Accent |
| --- | --- | --- |
| Health / care / calm | teal `#0e9f8e` | coral `#ff7a59` |
| FinTech / trust | indigo `#3a4ed5` | mint `#2bd4a8` |
| Developer / infra | slate-blue `#5b6ee1` | amber `#f59e0b` |
| Creative / playful | violet `#7c5cff` | lime `#a3e635` |
| Enterprise / serious | navy `#1f3a8a` | steel `#64748b` |

## Accessibility (non-negotiable)
- Body text ≥ **4.5:1** against its background; large text ≥ 3:1.
- Never carry meaning by colour alone — pair status colours with an icon/label
  (the callout/comparison components already do this).
- Honour `prefers-reduced-motion` for any animated reveal.

## Consistency checklist
- One token block; every component reads tokens (no hard-coded hex in the body).
- Mermaid is themed from the same tokens (template wires `themeVariables`).
- Charts pull `--color-primary`/`--color-accent` for series colours.
- Radius, shadow, and font are uniform across cards, tables, callouts.
