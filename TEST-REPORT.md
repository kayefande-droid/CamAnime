# Test report — stage 8, build 2.17.3 (29)

Re-run on this machine on 15 November 2026 against the local Playwright server
(port 5055, Flask from `.venv/Scripts/python.exe`) plus the two live hosts:
Render origin `https://camanime.onrender.com` and the Cloudflare mirror
`https://camanjme.camanime.workers.dev`.

## Passed

| Suite | Command | Result |
| --- | --- | --- |
| Backend | `python -m pytest tests -q` | 215 passed in 221.7 s |
| Edge worker | `npm --prefix cloudflare test` | 88 passed, 0 failed |
| Journeys | `npx playwright test tests/e2e/journeys.spec.mjs` | 12 passed in 4.8 min |
| Accessibility | `npx playwright test tests/e2e/a11y.spec.mjs` | 12 passed, axe clean |
| Responsive | `npx playwright test tests/e2e/responsive.spec.mjs` | 30 passed, 360–1920 px, no horizontal overflow |
| Link check | `npx linkinator https://camanjme.camanime.workers.dev --recurse` | 854 links, all 200 (watch pages excluded from the crawl, see below) |
| Browser check (mirror) | Convio browser, `/watch/113415/1` at 390 and 1440 | No problems: no console errors, no failed requests, LCP 1.0 s / 1.4 s, CLS 0.00 |
| Browser check (mirror) | Convio browser, `/download` at 1440 | No problems, LCP 1.2 s, CLS 0.00 |
| Browser check (origin) | Convio browser, `/` at 390 | HTTP 200, CLS 0.00, LCP 5.9 s (cold Render dyno) |
| Stream parity | `/api/episode-sources/{113415,195516,21,189123}/1` on the mirror | 9 servers + 9–13 downloads each, all four providers present, active source resolves to the edge HLS proxy |

## Fixed during this pass

1. **Rate pacing blocked the e2e suite, not the site.** Journeys hit 429 because
   the app's own per-IP pacing (`app.py _rate_limited`, `firewall.py
   _rate_exceeded`) is intentionally strict. Both layers now honour
   `CAMANIME_DISABLE_RATE_LIMIT=1`, which `tests/e2e/start-server.mjs` sets for
   the throwaway server only; bans and attack signatures stay live. Covered by
   `tests/test_security.py` and `tests/test_firewall.py`.
2. **J7 could not go stale any more.** It hardcoded a version from an old build;
   it now reads `/healthz` and asserts the page agrees with it.
3. **Error pages leaked template placeholders.** The 500/404 page bypassed
   `withSeo`, so it shipped literal `__CA_CANONICAL__` / `__CA_ORIGIN__` markers
   to crawlers (`/anime/__CA_CANONICAL__` 500s in the first crawl). Every error
   page now goes through `withSeo`.
4. **Uncached catalogue pages 500'd.** AniList refuses Cloudflare egress (403);
   on a cache miss the worker's origin relay got one attempt, so a single blip
   took the page down. The relay is now retried once, and a genuine upstream
   outage returns a 503 with `Retry-After: 60` instead of a bare 500. Verified:
   `/anime/113415`, `/anime/195516`, `/watch/212888/1` went 500 → 200.
5. **Installer links 404'd on the mirror.** `/get/windows` 302s to the release
   asset on the origin; the worker's fallback followed redirects and then
   rejected the non-HTML result. Redirects are now replayed, so the link works.
6. **Artwork 502'd under load.** The edge image proxy had one origin attempt; it
   now retries once before giving up, so a throttled origin no longer blanks a
   whole home page of posters.

## Not run, and why

- **Lighthouse mobile.** Three variants (default, `--preset`-equivalent flags,
  `--throttling-method=provided`, local and live HTTPS) all failed with
  `NO_NAVSTART` — "Something went wrong with recording the trace over your page
  load." The reports it produced had `LCP/CLS/TBT = undefined` and a
  performance score of 0, so no number from them is quoted. Core Web Vitals are
  therefore covered by the browser check's own LCP/CLS readings above, not by
  Lighthouse.
- **Firefox and WebKit.** Neither browser is installed here, so
  `playwright.config.mjs` declares Chromium (installed Chrome channel) only.
  Firefox/Safari-only regressions are unverified.
- **semgrep, osv-scanner, ZAP, hallmark sloplint.** None of these tools exist on
  this host, and the sloplint script is not available in the Convio skill
  library either. Dependency coverage is `pip-audit` (clean) and
  `npm audit --omit=dev` (0 vulnerabilities at the repo root and in
  `cloudflare/`), both re-run on 15 November.
- **A full recursive crawl of `/watch/` pages.** Each watch page links every
  episode of its title, so the crawler asked for ~17 000 URLs and was correctly
  rate-limited by the worker's firewall (429). The crawl above excludes
  `/watch/` and a paced sample of watch pages (`/watch/113415/1`,
  `/watch/113415/12`, `/watch/195516/7`, `/watch/189123/2`, `/watch/21/1`) all
  returned 200 with a clean browser check.

## Still open

- The origin's first-hit LCP is 5.9 s while the Render dyno is cold; the mirror
  serves the same page in 1.2 s. That is a hosting cold-start characteristic,
  not a page defect.
- Pre-existing, non-gating: `node scripts/lint-css.mjs` flags legacy literal
  colours, and `node scripts/check-parity.mjs` flags sitemap entries that only
  the mirror serves.
- `CAMANIME_D1_TOKEN` still has to be set in the Render dashboard by the owner.
