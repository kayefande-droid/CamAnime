# CamAnime — independent Cloudflare deployment (worker `camanjme`)

This folder is a **self-contained CamAnime application for Cloudflare**: Workers (edge
server code) + D1 (own database) + R2 (own file storage) + the repository's real
static assets. It shares **only the GitHub repository** with the Render deployment —
no request, fetch, database or file ever crosses between the two.

```
cloudflare/
  wrangler.jsonc        worker name camanjme; D1 + R2 + ASSETS bindings
  package.json          deploy/dev/test scripts (wrangler 4, no uv/pywrangler)
  schema.sql            full D1 schema (same tables as the Render SQLite database)
  migrations/0001_init.sql   wrangler d1 migrations entry
  src/index.js          worker entry + router (pages + APIs)
  src/pages.js          SSR HTML (same branding/classes as the Render templates)
  src/catalog.js        AniList GraphQL home/search/details/watch data (edge-cached)
  src/api.js            community, library, admin, downloads, streaming proxy (Range)
  src/auth.js           registration/login/sessions on D1 (PBKDF2-SHA256, WebCrypto)
  src/util.js           escaping, cookies, PBKDF2 hashing, responses
  test/smoke.test.mjs   node --test suite for the framework-free units
```

## Dashboard configuration (manual, one-time)

1. **D1** — `wrangler d1 create camanime` → copy the printed `database_id` into
   `wrangler.jsonc` (`d1_databases[0].database_id`).
2. **R2** — create a bucket named `camanime-files` (the `FILES` binding), or change
   the bucket name in `wrangler.jsonc` to one you have.
3. **Workers Builds → GitHub** — connect repo `kayefande-droid/CamAnime`, then set:
   - Root directory: `/cloudflare`
   - Build command: `npx wrangler deploy` (or `npm install` then `npm run deploy`)
   - Production branch: `main`
   The old proxy root directory `/cloudflare-worker` is retired (see below); either
   delete its Workers Builds connection or point it at `/cloudflare`.
4. **Secret** — set an admin user directly in D1 (register via /login, then
   `wrangler d1 execute camanime --remote --command "UPDATE users SET role='admin' WHERE email='you@example.com'"`).
5. Optional env var: `wrangler secret put CAMANIME_RELEASE_TAG` for the footer badge.

## Commands

```bash
cd cloudflare
npm install                 # wrangler 4
npm run dev                 # local dev (miniflare, local D1/R2 simulators)
npm run db:init:local       # create tables locally
npm run db:init             # create tables in the remote D1 database
npm test                    # node --test test/ (no Cloudflare account needed)
npx wrangler deploy         # deploy this app to production
```

Pushes to `main` deploy automatically through Workers Builds once the GitHub
connection from step 3 is in place. Preview deployments get their own isolated
URL; production D1/R2 are only touched by the `main` branch.

## How the parity with Render works, and the honest limits

| Feature | Status on Cloudflare |
| --- | --- |
| Catalogue, search, details, episode lists | ✅ same public AniList GraphQL the Flask app uses, edge-cached 10 min |
| Static assets (CSS/JS/icons/manifest) | ✅ literally the same files from the repo (ASSETS binding) |
| 8 themes, data saver, quality control | ✅ same `site.js`/`sync.css`, same localStorage keys |
| Registration / login / sessions | ✅ D1-backed, PBKDF2-SHA256 (WebCrypto), HttpOnly Secure cookie; **independent user DB** — accounts are not shared with Render |
| Comments, ratings, notifications, announcements, history/library | ✅ D1 tables mirroring `camanime_platform.py` |
| Downloads (APK + admin uploads) | ✅ R2 `FILES` bucket, admin-gated upload, attachment download route |
| Admin dashboard + announcements | ✅ role-gated pages/API on D1 |
| Player start / visit counters | ✅ `events` + `counters` tables on D1 |
| Video playback | ⚠️ embed-mode playback via AniList `streamingEpisodes` works; the scraped HD server extraction in `streaming_providers.py` (AnimePaHe/AGA-style HTML scraping with BeautifulSoup) is **not ported** — Cloudflare Workers has no BeautifulSoup/threading parity, so until a ported extractor proves out in deployment, playback uses the AniList-listed sources |
| `/api/proxy/media` + `/api/proxy/hls` | ✅ implemented with Range pass-through and HLS playlist rewriting, host-allowlisted against SSRF — **must be exercised live on the deployed worker** before it can be called proven |
| Python-only dependencies | ❌ none exist here by design; nothing imports from `app.py` |

`/healthz` returns the deployment identity to make "is this the Cloudflare app or
Render?" instantly verifiable. No code path in `cloudflare/` mentions
`camanime.onrender.com`; nothing proxies or falls back to it.
