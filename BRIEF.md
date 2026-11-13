# CamAnime: anime-theme pass — brief

**What it is:** The existing CamAnime streaming site: a Flask + Jinja origin on Render, mirrored by a Cloudflare Worker that renders the same pages from D1/R2.
**For:** People who came to watch anime. The first thing they do is pick a poster and press play; everything else (browse, download, developers) is secondary.
**Success:** Every page reads as an anime site rather than a generic dark streaming template, the phone nav is one tap to anywhere, and the mirror looks and behaves exactly like the origin.

## Scope (v1)

- Pages: home, browse/search, anime details, watch, download, developers, auth (login/register), 404. Home leads; the other pages inherit the same components.
- Nav: on phones and tablets the tabs move into a hamburger drawer with the search field, watchlist and theme control inside it, so nothing is stranded on its own row. From 900px up the tab row stays visible as it is today.
- Hero: one 7500ms clock and one 700ms crossfade, driven by the shared `--ca-cycle` / `--ca-fade` tokens on both hosts.
- Mirror: identical hero (six banner slides, same meta pills, same three actions, same dots and timing), identical nav behaviour, identical poster and card treatment.
- Not in v1: new frameworks, new pages, accounts/auth changes, a CMS, new paid services, the mobile Flutter app.

## Design

- Direction: anime, not a generic dark template. Keep the dark navy base and amber accent that the brand already uses, then push it: diagonal-cut poster frames (clip-path), a thin ink rule and speed-line texture behind section headings, poster cards that lift and tilt slightly on hover with a sakura-pink rim, chrome-style rating badges, and a bolder display weight for titles and the hero headline.
- No literal colours outside `:root`; every new value becomes a token next to the existing ones. Existing legacy literals get replaced as pages are touched, not in one risky sweep.
- Motion: transform and opacity only, with a `prefers-reduced-motion` fallback for every new effect.
- Responsive from 360px up; the container caps and centres so 1920px gets wider gutters rather than wider content.

## Stack

- Unchanged. Flask + Jinja + shared CSS (`base.css`, `redesign.css`, `motion.css`, plus the header layout file) on Render; Cloudflare Worker rendering the same CSS on the mirror. No Tailwind, no component library, no framework migration: the site is live, and this is a styling and markup pass over working routing.

## Content and integrations

- No new content source. AniList stays the catalogue; the trailer action on the mirror uses the real AniList trailer id rather than a link that guesses.

## Constraints and risks

- Render's free instance flaps under bursts; probes are spaced and retried, and a failed probe is reported as a failure, not a pass.
- Both hosts share `/static`, so a stylesheet change ships to both at once; every change is checked on both.
- The mirror's page cache is 30s and the CSS pin is versioned, so a pin bump is part of each deploy.
- Tests that must stay green: `pytest tests` (205) and `npm --prefix cloudflare test` (85).

## Assumptions (please check)

- "More anime like" means the ink-and-amber direction above with anime-specific framing and texture, not a full light pastel or neon redesign.
- "Exactly the same" means the mirror ends up visually and behaviourally identical on the pages people use. The mirror keeps its own data layer (D1/R2); only what a visitor sees is unified.
- Mobile app work stays out of scope.
