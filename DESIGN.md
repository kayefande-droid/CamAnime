# Design — one token set, one component style, both hosts

The brand predates this work (Sora display, Outfit body, dark surfaces). This
stage did not invent a new identity: it recorded the system that actually ships,
lifted the last literals into tokens, and named the components both hosts share.

## Tokens

Declared once. `base.css` owns the palette, type scale, spacing and elevation;
`redesign.css` adds the handful of surfaces its own layer needs. No rule after
those blocks carries a literal colour.

| Group | Token | Value |
| --- | --- | --- |
| Type | `--ca-font-display` | Sora, Outfit, system-ui |
| Type | `--ca-font-body` | Outfit, system-ui |
| Type | `--ca-font-mono` | ui-monospace stack |
| Layout | `--ca-page` | 1440px |
| Layout | `--ca-gutter` | `clamp(1rem, 3vw, 2rem)` |
| Radius | `--ca-radius-card` | 18px |
| Radius | `--ca-radius-control` | 999px (pills) |
| Radius | `--ca-radius-panel` | 22px (header, panels) |
| Elevation | `--ca-shadow-card` | `0 10px 28px rgba(0,0,0,.34)` |
| Elevation | `--ca-shadow-lift` | accent-tinted lift |
| Elevation | `--ca-ring` | 3px accent focus ring |
| Surface | `--ca-ink-900` | `#0e111a` |
| Surface | `--ca-scrim`, `--ca-scrim-strong` | black veils over artwork |
| Surface | `--ca-sheen`, `--ca-hair-soft`, `--ca-hair`, `--ca-hair-mid`, `--ca-hair-strong`, `--ca-wash` | white 1.2% → 10% hairlines |
| Accent | `--accent`, `--accent-rgb` | brand amber, overridable per surface |
| Motion | timings and easings | single-sourced in `static/css/motion.css`; components reference those properties, never raw milliseconds |

Type scale is fluid: display sizes use `clamp()` against viewport width, body text
never drops below 1rem, and the hero title is capped so a long title wraps rather
than overflows.

## Components

Shared by Render and the worker because both serve this stylesheet:

- **Header** — rounded panel, brand block, search field with inline button, watchlist
  and settings actions, then a nav row. One row above 900 px, two below.
- **Hero** — full-bleed stage, kicker, wrapping display title, meta pills, synopsis
  clamp, up to three actions, slide dots.
- **Catalogue grid** — poster cards with a 2×2 feature tile at the top of each grid.
- **Details dossier** — poster beside a tall panel of facts and actions.
- **Episode rail** — sticky list beside the player above 1100 px, static below.
- **Player bar** — progress with buffered range, time labels, actions.
- **Controls** — 44 px targets on phones, hover, `:focus-visible` (instant, 3:1),
  active and disabled states on every one.
- **Live-schedule tab** — floater that moves to the phone corner so it never covers
  hero copy.

## States

Data regions carry loading (skeleton in its own shape), empty (what belongs here and
the action that fills it), error (what broke and what to do) and full. The admin
console follows the working-screen rules: top bar, dense rows, tables before cards,
accent only on the primary action and state.

## Rules this stage keeps

Every colour and font from a token; no invented figures anywhere on the site; no
eyebrow labels above headings; no middle-dot meta strings; motion on transform and
opacity only, with a reduced-motion fallback and content visible without JS;
`overflow-x: clip` with a capped centred container, checked from 360 px up.

Language labels (sub/dub) are deliberately absent until real track data exists —
that is milestone 6, and guessing there would mislabel Japanese audio as a dub.
