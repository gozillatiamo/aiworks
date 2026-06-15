# Motion & Animation (mandatory)

Motion is a core part of the app's brand, not a finishing touch. **Nothing ships static.** Every page, every action, every transition, and every crucial branding element must be animated. A screen with no motion is treated as an incomplete feature.

## The rule

| Surface | Must animate |
| --- | --- |
| **Every page** | Entrance/exit (route transition) + meaningful content reveal (stagger key elements in, don't pop). |
| **Every action** | Tap/press feedback, toggles, submit, success/failure — the user always sees the UI respond. |
| **Every transition** | State changes (loading ↔ data ↔ error), list add/remove/reorder, step-to-step in flows like the Add Pet wizard. |
| **Crucial branding** | Logo, app icon/iconic marks, and the mascot animate on appearance and on interaction — never a frozen image. |

If you add a widget, screen, or state and can't point to its animation, it isn't done.

## How (Flutter conventions for this app)

- **Prefer implicit animations** for state-driven UI: `AnimatedContainer`, `AnimatedOpacity`, `AnimatedAlign`, `AnimatedSwitcher`, `TweenAnimationBuilder`. Reach for explicit `AnimationController` only when you need orchestration, looping, or custom painting (e.g. the brand-logo draw-on in `step1_welcome_step.dart` — match that idiom for branding).
- **Page transitions:** define them once and reuse. Use a shared `PageTransitionsTheme` (or a `PageRouteBuilder` factory in `core/`) so every route animates consistently — don't hand-roll a different transition per screen.
- **State transitions:** wrap `AsyncValue.when()` loading/data/error output in an `AnimatedSwitcher` so states cross-fade instead of snapping.
- **Lists:** use `AnimatedList` / `SliverAnimatedList` (or animated `ReorderableListView`) so inserts, removals, and reorders animate.
- **Actions:** every interactive element gives feedback — scale/opacity on press, an animated state change on result. No instant, motionless jumps.
- **Branding:** logo/mascot get an entrance animation and respond to interaction (e.g. tap-to-replay, as the welcome logo already does). Lottie/Rive is acceptable for the mascot if richer motion is needed; keep assets in `assets/` per the asset conventions.
- **Lifecycle:** always `dispose()` controllers; schedule first frames with `addPostFrameCallback`; keep timers framework-tracked (no stray `Timer`s).

## Motion tokens (consistency)

Centralize durations and curves in `core/` (e.g. `core/theme`) and reference them everywhere — don't scatter magic numbers:

- **Durations:** micro/feedback ~120–200ms · standard transitions ~250–350ms · expressive/branding ~400–900ms.
- **Curves:** `Curves.easeInOutCubic` for transitions, `Curves.easeOut` for entrances; a springy curve for playful branding moments.
- Reuse the same tokens across features so the whole app feels like one product.

## Guardrails

- **Respect reduced motion.** Honor the OS setting via `MediaQuery.of(context).disableAnimations` (and `WidgetsBindingObserver`/accessibility flags). When on, drop to near-instant cross-fades — keep state legible, never trap motion-sensitive users in long animations.
- **Performance:** target a smooth 60/120fps. No jank — animate cheap properties (opacity, transform) over expensive layout where possible; profile heavy screens. Motion must never delay the user's ability to act (don't gate input behind a long intro).
- **Tasteful, not gratuitous:** animated ≠ slow or distracting. Default to quick, purposeful motion; reserve longer expressive animations for branding moments.
- **Widget size:** per repo guardrails, split animation-heavy widgets >150 lines into smaller reusable pieces.

## Checklist (per feature/screen)

- [ ] Page has an entrance/exit transition (via the shared route transition).
- [ ] Key content animates in (reveal/stagger), doesn't pop.
- [ ] Every interactive element has press/result feedback.
- [ ] loading ↔ data ↔ error states cross-fade (`AnimatedSwitcher`).
- [ ] List changes animate (`AnimatedList`/reorderable).
- [ ] Any logo/icon/mascot on the screen is animated (entrance + interaction).
- [ ] Durations/curves pulled from `core/` motion tokens — no magic numbers.
- [ ] Reduced-motion path verified; controllers disposed; no jank.
- [ ] Builds and runs on Android **and** iOS without crashing (animations wired per spec; live 60fps verification is covered by the performance gate / the E2E automation suite).
