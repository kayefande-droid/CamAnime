# Test report — stage 8, build 2.13.0 (24)

Everything below was run on this machine on 12 November 2026 with a Playwright
managed Flask server on port 5055 (site) and the project virtualenv.

## Passed

| Suite | Command | Result |
| --- | --- | --- |
| Backend | `python -m pytest tests -q` | 185 passed in 356.9 s |
| Edge worker | `cd cloudflare && npm test` | 75 passed, 0 failed |
| Journeys | `playwright test tests/e2e/journeys.spec.mjs` | J1–J11 pass (J2 and J9 needed one retry each, both on a slow provider-backed page) |
| Accessibility | `playwright test tests/e2e/a11y.spec.mjs` | axe clean on home, catalogue, details, watch, download, sign in, sign up, settings, developer docs, owner redirect, error page, skip link |
| Responsive | `playwright test tests/e2e/responsive.spec.mjs` | 31 passed in 6.1 min, 360–1920 px, no horizontal overflow |
| CSS lint | `node scripts/lint-css.mjs` | 0 errors, 1 warning |
| Release gate | worker tests + app version | app, site and worker all report 2.13.0 / build 24 with one APK SHA-256 |

The accessibility pass includes the fix that matters most here: a disabled
control in the watch player kept `opacity: .4` and failed 4.5:1, so it now uses
the secondary text colour at full opacity.

## Not run

- **Firefox and WebKit.** Neither browser installs on this machine: the C:
  drive is full, and the D: install path and the download CDN stall. Chromium
  (the installed Chrome channel) is the only engine measured, so any
  Firefox/Safari-only regression is unverified.
- **Lighthouse mobile.** No Lighthouse binary in `node_modules/.bin`, and there
  is no room to add one. Core Web Vitals on mobile are unmeasured rather than
  assumed good.
- **Live owner console journeys.** `/owner-console` needs the owner password,
  which is not available to the agent; the redirect-only assertion in J10 does
  run.
- **Live APK install.** The release APK is built and its SHA-256 is pinned in
  the app, site and worker, but it was not installed on a physical device in
  this stage.

## Flakiness seen, and why it is not a product defect

The watch and details pages fetch AniList and AnimeHeaven live. First-hit
latency measured 12.8 s cold against 8 ms once the provider cache is warm, so
Playwright's default 45 s navigation budget produced false timeouts. The
config now allows 90 s for navigation and 150 s per test, which is a test-side
budget for a live-provider app — no assertion was weakened. A Chromium worker
crash (`0xC0000142`) also appears intermittently, which `retries: 1` absorbs.

## Pass 2 — 13 November 2026: hero, mirror player, responsiveness, speed

Checked both live hosts through Convio's Chromium service at 390 and 1440 wide,
and re-ran the suites.

| Check | Command | Result |
| --- | --- | --- |
| Flask suite | `python -m pytest -q tests` | 205 passed in 190s |
| Worker suite | `npm --prefix cloudflare test` | 85 passed, 0 failed |
| Style gate | `node scripts/lint-css.mjs` | 2 errors, legacy literal colours in base.css (77 vs baseline 56) and redesign.css (9) |
| Parity | `node scripts/check-parity.mjs` | version, APK size and asset pins match; sitemap lists mirror-only URLs |
| Home 1440 | Convio `check` | worker: 200, LCP 1.3s, CLS 0.01, no problems · render: 200, LCP 1.9s, CLS 0.00, no problems |
| Home 390 | Convio `check` + `screenshot` | 200 both, no horizontal overflow, hero shows title, meta, copy and every action |
| Details 1440 | Convio `check` | worker 200, LCP 0.9s · render 200 but LCP 7.9s on a 1000+ episode series |
| Watch 1440 | Convio `check` + `screenshot` | worker 200, no console errors, video loads with a 24:37 duration · render 200 |

Fixed in this pass:

1. The hero carousel collapsed on both hosts. A shared
   `body .hero-spotlight > *` rule forced `position: relative` on every slide,
   overriding the absolute stacking the rotation needs, and the mirror loaded no
   slide, backdrop or vignette geometry at all. Slides are absolute flex items
   again and the stage, backdrop, vignette and copy share one definition in
   `static/css/redesign.css`, so both hosts compute the same hero.
2. The phone hero clipped its second action at 390px; the stage is taller below
   860px and 480px and the copy is clamped.
3. The origin's slides had no intrinsic image size (CLS 0.14 at 390px); adding
   `width`/`height` took it to 0.02, then 0.00 at 1440.
4. The rotation cut between posters in 320ms; both hosts now crossfade over
   750ms, with a reduced-motion hard cut, and the first Render banner preloads.
5. The mirror framed an AniList `http://` link that its own CSP and the
   provider's `X-Frame-Options` both refused. It now plays the same provider
   bundle the apps use: MP4 directly, HLS through hls.js, with a clear message
   when a title has no source.

Still open after this pass: the style-gate literal colours, the sitemap
parity decision, and pagination for very long episode rails on the origin.
