# CamAnime design system

The look is ink-and-amber: a dark navy page, one amber accent, and manga print
cues — halftone screens, hard-edged poster frames, sticker-cut chips and a
slanted section rule. Everything below lives in the project's own CSS; there is
no component library and no new framework.

## Tokens (declared once in `:root`)

`static/css/base.css` — page, type, shape:

| Token | Value | Used for |
| --- | --- | --- |
| `--ca-font-display` | Bricolage Grotesque → Plus Jakarta Sans → system | headings, hero titles, logo lockups |
| `--ca-font-body` | Plus Jakarta Sans → system | body copy, controls |
| `--ca-font-mono` | ui-monospace → Menlo → Consolas | ratings, counts, API keys, timestamps |
| `--ca-page` | `1440px` | widest content column; wider screens get gutters, not wider text |
| `--ca-gutter` | `clamp(1rem, 3vw, 2rem)` | page padding at every width |
| `--ca-radius-card` | `18px` | cards and panels |
| `--ca-radius-control` | `999px` | pills, chips, search field |
| `--ca-shadow-card` | soft 28px drop | panels |
| `--ca-shadow-lift` | amber-tinted lift | hover on interactive cards |
| `--ca-ring` | 3px amber halo | focus ring on inputs |
| `--ca-focus-ring-color` | `#12CDE8` | `:focus-visible` outline everywhere |
| `--ca-header-glass` | translucent navy | sticky header |
| `--ca-border-subtle` | `rgba(255,255,255,.08)` | hairline dividers and card edges |
| `--ca-input-bg` / `--ca-canvas-ink` | `#181e2e` / `#07080d` | form fields, deepest surface |
| `--ca-hover-wash` | `rgba(255,255,255,.06)` | nav hover, row hover |

`static/css/redesign.css` — the ink layer:

| Token | Value | Used for |
| --- | --- | --- |
| `--ca-ink-line` | `rgba(255,255,255,.22)` | printed-panel edge on cards |
| `--ca-ink-shadow` | `rgba(2,3,7,.92)` | hard offset block behind cards and buttons |
| `--ca-halftone` | `rgba(255,255,255,.07)` | dot screen over hero art |
| `--ca-speed-line` | `rgba(255,255,255,.05)` | radial action lines in the hero |

Accent, canvas and surface colours come from the live theme block, so all eight
themes (midnight, sakura, and the rest) recolour the same tokens — the ink layer
never hard-codes an accent.

`static/css/motion.css` — timing:

| Token | Value | Used for |
| --- | --- | --- |
| `--ca-cycle` | `7500ms` | hero dwell time on both hosts |
| `--ca-fade` | `700ms` | hero crossfade on both hosts |

Both carousels read these at runtime, so the two deployments cannot drift.

## Components

- **Header** (`header-layout.css`) — one shape per breakpoint. Below 900px:
  logo, watchlist, theme and menu on row one, full-width search on row two, tabs
  in the drawer. From 900px: logo and actions on row one, tabs on their own row.
  Every control is at least 44×44px; Escape closes the drawer and returns focus
  to the menu button.
- **Hero** — one clipped box per slide, crossfaded on a 7.5s clock. The ink
  texture (halftone + sunburst) is a single masked layer above the art and below
  the dots, so copy stays clean on the left.
- **Poster card** — printed panel: 1px ink edge, hard offset block, tilts on
  hover and focus, returns to rest under reduced motion and on low-data.
- **Chips** (`tag`, `ep-badge`, `score-badge`, `dl-tag`, `genre-chip`) — sticker
  cut corners, monospace figures for ratings and episode counts.
- **Buttons** — hero and primary/secondary actions are sticker-cut labels with
  the same offset ink block; focus-visible uses the shared ring token.
- **Section rule** — a slanted amber bar under section titles plus a rotated
  square before the title, so rails read as manga chapter breaks.

## Rules that hold on every page

- Colour and type come from the tokens above; no literal hex outside `:root`.
- Motion is transform/opacity only, with a `prefers-reduced-motion` fallback.
- Content is visible without JavaScript; the carousel degrades to the first
  slide.
- No invented stats, ratings or testimonials: every number comes from the
  catalogue API or the deployment's own counters.
- Responsive from 360px up; `overflow-x: clip` on `html` and `body`.
