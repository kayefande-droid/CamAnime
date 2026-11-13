# CamAnime anime-theme pass — build plan

Existing repo, existing stack: Flask + Jinja + shared CSS on Render, Cloudflare Worker rendering the same stylesheet and a D1/R2 catalogue on the mirror. No scaffold, no migration, no new dependency. Everything below is a change to `templates/`, `static/css/` and `cloudflare/src/pages.js`, shipped to both hosts.

## Milestone 0 — baseline (before any styling)

- [ ] Photograph home, details, watch, browse, download, developers, login at 390 and 1440 on both hosts. Verify: seven folders of screenshots, kept out of the diff (`.local-shots/`).
- [ ] Record current test state: `pytest tests` and `npm --prefix cloudflare test`. Verify: both green before I touch anything (205 / 85 known).

## Milestone 1 — anime design system (shared CSS only, no markup change)

- [ ] Add the new tokens in one `:root` block in `redesign.css`: ink rule, cut angle, sakura rim, chrome badge gradient, speed-line pattern, display tracking. Verify: no new literal colour outside `:root` (`node scripts/lint-css.mjs` must not go up from its current count).
- [ ] Build the components the pages will reuse: `.poster-frame` (diagonal cut corner), `.poster-card` hover lift/tilt with sakura rim, `.section-head` with speed-line rule, `.badge-rating` chrome pill, `.rail` scroll snapping. Verify: a scratch page renders each component; hover, focus-visible, active states present.
- [ ] Every new effect gets a `prefers-reduced-motion` fallback and animates transform/opacity only. Verify: grep the new rules for `transition: all` (must be none) and load with reduced motion emulated.

## Milestone 2 — navigation for every width

- [ ] Below 900px: tabs, search, watchlist and theme live in the hamburger drawer; the search row keeps the search button; the theme gear no longer sits on its own row. Verify: screenshots at 360, 390, 430, 768.
- [ ] At and above 900px: the tab row stays visible, no overflow, active item marked. Verify: screenshots at 900, 1024, 1280, 1440, 1920.
- [ ] Drawer behaviour: opens/closes, Escape closes, focus returns to the toggle, links are ≥44px tall. Verify: Playwright taps each width; horizontal overflow zero at every width.

## Milestone 3 — home page

- [ ] Hero: anime framing (angled bottom edge, ink rule, chrome rating), the same three actions, dots readable on a bright poster. Verify: 390 and 1440 screenshots, both hosts; rotation still 7500ms/700ms.
- [ ] Poster rails and section headers restyled with the new components; card hover works with keyboard focus too. Verify: tab through the rail, focus ring visible.
- [ ] Home weight stays sane: hero images keep the eager-first/next-prefetch trade-off. Verify: `check` reports page weight not above today's 4.9 MB.

## Milestone 4 — the other pages

- [ ] Details, watch, download, get/android, get/windows, developers, login, settings, error page. Each gets the section heads, poster frames, buttons and table/list rhythm from Milestone 1. Verify: 390 and 1440 screenshot per page, no console errors, no overflow.

## Milestone 5 — mirror parity

- [ ] Mirror hero matches the origin exactly: six banner slides, same meta pills, same three actions (third uses the real AniList trailer id), same dots, same timing. Verify: side-by-side 390/1440 screenshots; DOM sample of slide count and duration.
- [ ] Mirror nav drawer and card/poster classes match the origin. Verify: same Playwright width sweep against the mirror.
- [ ] Bump the CSS pin in the mirror and every template, deploy, confirm both hosts serve the new pin. Verify: `curl` the pin on both hosts.

## Milestone 6 — content and SEO (checkpoint: call `next_stage`)

## Milestone 7 — security review (checkpoint: call `next_stage`)

## Milestone 8 — test thoroughly (checkpoint: call `next_stage`)

- [ ] `pytest tests`, `npm --prefix cloudflare test`, the width sweep on both hosts, and `check` at 390/768/1440.

## Milestone 9 — ship (checkpoint: call `next_stage`)

- [ ] Commit, push, `wrangler deploy`, update README ship section and TEST-REPORT with what was verified and what was not.

## Notes

- One milestone at a time, each ending verifiable and committed before the next starts.
- Scaffold stage is skipped deliberately: the project already exists and the brief forbids a framework migration.
