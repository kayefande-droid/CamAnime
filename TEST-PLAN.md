# Test plan — CamAnime

Stage 8 of the Convio pipeline. What is proved, on which browser, and how.
Billing is absent by decision, so there is no checkout journey to test.

## Where the tests run

| Layer | Target | Why |
| --- | --- | --- |
| Unit / integration (pytest, node --test) | local process, throwaway SQLite | fast, repeatable, no production state |
| End-to-end (Playwright) | local Flask on `127.0.0.1:3000` with its own `CAMANIME_DB` | same `app.py`, templates and `/static` tree Render runs; sign-ups must never touch production |
| Read-only page checks, Lighthouse, sloplint | live Render **and** the Cloudflare mirror | the two hosts are the product |
| Console and failed-request checks | both live hosts, every key page | a 404 poster or a failed XHR is a bug even when the page looks right |

Local server env (`tests/e2e/start-server.mjs`): `CAMANIME_DB=.e2e/e2e.db`,
`CAMANIME_SECRET=e2e-only`, `CAMANIME_COOKIE_SECURE=0` (cookies are `Secure` in
production, so plain-HTTP localhost would silently drop the session),
`CAMANIME_ADMIN_EMAIL` / `CAMANIME_ADMIN_PASSWORD` set to a throwaway owner.

## Roles

- **Guest** — browse, search, details, watch, comment, rate, download.
- **Member** — everything a guest can do, plus history/resume, watchlist, settings.
- **Owner** — the single admin at `ADMIN_PATH` (`/owner-console` unless overridden) and `/api/admin/*`.

## Journeys

Each journey lists the happy path, the edge cases, and what "correct" means.

### J1 Browse the catalogue (guest)
Home loads, the hero and at least one catalogue row render, a poster card opens
the details page.
*Edge:* JS disabled — cards are still in the HTML; a provider outage — the
fallback lists or the labelled error state render instead of a blank grid.
*Correct:* no horizontal overflow, no console error, every card links to a real id.

### J2 Search (guest)
`/search?q=<title>` returns matching cards; the query survives a reload.
*Edge:* nonsense query (`zzzqqq123`) shows the empty state, not an error; a very
long query is capped at 100 characters rather than 500-ing.
*Correct:* results page is shareable, the term is echoed, back button works.

### J3 Details page (guest)
`/anime/<id>` shows title, synopsis, poster and the episode rail; "watch" opens
episode 1.
*Edge:* unknown id → the 404 page, not a stack trace.
*Correct:* poster has non-zero natural size, rail lists episodes in order.

### J4 Play an episode (guest)
`/watch/<id>/<ep>` loads, `/api/episode-sources/<id>/<ep>` resolves at least one
source, pressing play advances `currentTime`.
*Edge:* a source that 403s → the player shows its error strip and offers the next
server; the trailer/audio notice appears only when it applies.
*Correct:* the video element becomes visible, duration is finite, no autoplay
with sound.

### J5 Post a comment (guest)
Name + text post to `/api/community/comment`; the comment appears without a reload
and survives a reload; a like increments once.
*Edge:* empty text rejected with a visible message; text over 600 chars is cut,
not stored whole; a sticker outside the allowlist is rejected server-side.
*Correct:* the stored sticker is one the client sent from the allowlist, and it is
escaped in the DOM (no `onerror=` injection).

### J6 Rate an episode (guest)
Clicking a score posts to `/api/community/rate` and the average updates.
*Edge:* a second click from the same client does not double-count the same rater.

### J7 Download the APK (guest)
`/download` shows version `2.12.0` (build `23`); the download control resolves to
the APK and `/get/android` redirects to it.
*Edge:* Render and the mirror serve byte-identical APKs of the same length.

### J8 Sign up and sign in (member)
`/login?mode=signup` creates an account, `/api/auth/me` returns it, the header
shows the account, sign-out clears the session.
*Edge:* wrong password → inline error, no session; duplicate email → clear
message; password under 6 characters → the field's own validation; a signed-out
visit to `/settings` redirects to login with `next=`.

### J9 Resume watching (member)
The watch page posts progress to `/api/history`; reloading the same episode shows
the resume note and seeks to the saved point; `/api/history/remove` clears it.
*Edge:* a signed-out POST returns 401 (never 200 with no owner); a second account
cannot read or delete the first account's rows.

### J10 Permission boundaries
- Guest on `ADMIN_PATH` → redirect to login; `/api/admin/users` → 401.
- Member (not owner) on `ADMIN_PATH` → redirect, `/api/admin/*` → 403.
- Owner on `ADMIN_PATH` → 200, the dashboard renders with its regions in a
  loading/empty/full state.
- The SSRF guard: `/api/proxy/hls?url=http://10.0.0.5/x.m3u8` → 400 on both hosts.

### J11 Error and failure states
404 page for unknown routes and ids; the API returns JSON errors, not HTML;
expired/forged session cookie behaves as signed-out; the offline player error
strip shows a retry.

## Cross-cutting

1. **Accessibility** — `@axe-core/playwright` on `/`, `/search`, `/anime/<id>`,
   `/watch/<id>/<ep>`, `/download`, `/login`, `/settings`, `ADMIN_PATH`.
   Fail on `serious` and `critical` only; record the rest. Keyboard pass: Tab
   reaches every control, focus is visible, Esc closes the schedule drawer, no
   focus traps, every input has a label.
2. **Responsive** — 360, 390, 768, 1024, 1440, 1920 on every key page: no
   horizontal scroll (`scrollWidth <= clientWidth`), no element wider than the
   viewport, tap targets ≥ 44 px on the two smallest widths.
3. **Performance** — Lighthouse mobile on the live Render home, details and watch
   pages. Target LCP < 2.5 s, CLS < 0.1, TBT < 200 ms, accessibility ≥ 95.
4. **Links** — crawl both hosts for broken internal links and assets.
5. **Generated-design lint** — hallmark `sloplint` on the live pages; fix Floor
   failures, keep Reflex findings only with a written reason.
6. **Cross-browser** — Chromium, Firefox and WebKit. Chromium runs through the
   installed Chrome (`channel: "chrome"`).

## Known constraints for this run

- The machine's system disk is full (0 free of 238 GB outside this repo), so
  Playwright cannot download its Firefox and WebKit builds. Chromium-family is
  covered through the installed Chrome; Firefox and WebKit are recorded as not
  run rather than claimed.
- Production sign-ups are not used: member journeys run against the local server.
  The live hosts are exercised read-only plus the failure probes.
- `/owner-console` on both live hosts needs the real owner's password, which is
  not available here, so the owner journeys run locally with a throwaway owner.

## How to re-run

```bash
# unit + integration
PYTHONIOENCODING=utf-8 ./.venv/Scripts/python.exe -m pytest tests -q
npm --prefix cloudflare test

# end-to-end, accessibility, responsive
npx playwright test --project=chromium
npx playwright test --project=chromium tests/e2e/a11y.spec.mjs
npx playwright test --project=chromium tests/e2e/responsive.spec.mjs

# quality gates
node scripts/lint-css.mjs
node scripts/check-parity.mjs
npx lighthouse https://camanime.onrender.com/ --preset=desktop --quiet
npx linkinator https://camanime.onrender.com --recurse --skip "mailto|google|firebase"
```
