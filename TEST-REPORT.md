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
