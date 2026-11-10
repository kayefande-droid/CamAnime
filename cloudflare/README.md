# CamAnime — independent Cloudflare deployment (worker `camanjme`)

This folder is a **self-contained CamAnime application for Cloudflare**: Workers (edge
server code) + D1 (own database) + R2 (own file storage) + the repository's real
static assets. It shares **only the GitHub repository** with the Render deployment —
no request, fetch, database or file ever crosses between the two.

```
cloudflare/
  wrangler.jsonc        worker name camanjme; D1 + R2 + ASSETS bindings
  package.json          deploy/dev/test scripts (wrangler 4, no uv/pywrangler)
  schema.sql            full D1 schema (Render tables + devices/releases/config/audit)
  migrations/0001_init.sql   wrangler d1 migrations entry
  src/index.js          worker entry + router (pages + APIs)
  src/release.js        release policy: latest/minimum/discontinued build, APK SHA-256
  src/appapi.js         update manifest, remote config, devices, notifications, releases
  src/push.js           FCM HTTP v1 sender (service-account JWT, no Admin SDK)
  src/pages.js          SSR HTML (same branding/classes as the Render templates)
  src/catalog.js        AniList GraphQL home/search/details/watch data (edge-cached)
  src/api.js            community, library, admin, downloads, streaming proxy (Range)
  src/auth.js           registration/login/sessions on D1 (PBKDF2-SHA256, WebCrypto)
  src/util.js           escaping, cookies, PBKDF2 hashing, responses
  test/smoke.test.mjs   node --test suite for the framework-free units
  scripts/preflight.mjs fails a deploy while wrangler.jsonc still holds placeholders
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
6. **APK mirror (optional but recommended)** — `/get/android` serves the installer
   from R2 so this host is a real mirror rather than a redirect. The APK is
   deliberately excluded from the asset bundle (`static/.assetsignore`) because
   Workers Static Assets caps a single file at 25 MiB and the APK is ~51 MiB.
   ```bash
   npx wrangler r2 object put camanime-files/downloads/CamAnime.apk \
     --file=../static/downloads/CamAnime.apk --content-type=application/vnd.android.package-archive
   ```
   Without the object, `/get/android` still works: it falls back to the asset
   bundle and then to a 302 to the Render origin.

## Commands

```bash
cd cloudflare
npm install                 # wrangler 4
npm run dev                 # local dev (miniflare, local D1/R2 simulators)
npm run db:init:local       # create tables locally
npm run db:init             # create tables in the remote D1 database
npm test                    # node --test test/ (no Cloudflare account needed)
npm run check               # config preflight: D1 id, R2 bucket, assets dir
npm run deploy              # preflight, then wrangler deploy to production
```

`npm run deploy` runs `scripts/preflight.mjs` first. It fails on purpose while
`wrangler.jsonc` still contains `REPLACE_WITH_D1_DATABASE_ID`, because
`wrangler deploy --dry-run` accepts that placeholder and only the real deploy
fails — which is how this Worker ended up never replacing the retired proxy.

## Current production state (2026-11-10)

`https://camanjme.camanime.workers.dev` is still answering as the **retired
Render proxy**, not as this app. Verified read-only:

```
$ curl -sI https://camanjme.camanime.workers.dev/healthz
… x-render-origin-server: gunicorn

$ curl -s https://camanjme.camanime.workers.dev/healthz
{"status":"ok","version":"2.10.0"}     # Flask shape, not this worker's
                                         # {"ok":true,"app":"camanjme",…}
```

Three things have to be true before the new Worker can take over, and none of
them can be done from a checkout without Cloudflare credentials:

1. `wrangler.jsonc` holds a real `d1_databases[0].database_id` (see step 1).
2. The `camanime-files` R2 bucket exists in the account (see step 2).
3. Workers Builds → GitHub points Root directory at `/cloudflare` on `main`;
   the old `/cloudflare-worker` connection only deploys the proxy.

After deploying, this is the check that proves which app answered:

```bash
curl -s https://camanjme.camanime.workers.dev/healthz
# {"ok":true,"app":"camanjme","architecture":"workers+d1+r2","bindings":{…}}
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
| Downloads (APK + admin uploads) | ✅ R2 `FILES` bucket, admin-gated upload, attachment download route; `/get/android` streams from R2 with HTTP Range (resume) and falls back to assets → Render 302 |
| App update check + version gate | ✅ `/api/version` (app_updater fields: `app_version`, `apk_url`, `sha256`, `whats_new`) and `/api/app/ping` (the endpoint `version_gate.dart` actually polls: 200 `{required,policy}` or 426 `policy`) — both read `src/release.js` |
| Release manifest, remote config, devices, notifications, releases | ✅ `/api/v1/app/*`, `/api/v1/devices/*`, `/api/v1/notifications/*`, `/api/v1/releases` — see `docs/app-updates.md` |
| Hourly push digest (app closed / screen off) | ✅ Cron Trigger `0 * * * *` → `scheduled` → `hourlyDigest()`; sends only when an episode actually aired, respects quiet hours and a 55-minute floor |
| FCM delivery | ⚠️ code complete (`src/push.js`, HTTP v1 + service-account JWT); needs `FCM_PROJECT_ID` + `FCM_SERVICE_ACCOUNT` on the Worker |
| Admin dashboard + announcements | ✅ role-gated pages/API on D1 |
| Player start / visit counters | ✅ `events` + `counters` tables on D1 |
| Video playback | ⚠️ embed-mode playback via AniList `streamingEpisodes` works; the scraped HD server extraction in `streaming_providers.py` (AnimePaHe/AGA-style HTML scraping with BeautifulSoup) is **not ported** — Cloudflare Workers has no BeautifulSoup/threading parity, so until a ported extractor proves out in deployment, playback uses the AniList-listed sources |
| `/api/proxy/media` + `/api/proxy/hls` | ✅ implemented with Range pass-through and HLS playlist rewriting, host-allowlisted against SSRF — **must be exercised live on the deployed worker** before it can be called proven |
| Python-only dependencies | ❌ none exist here by design; nothing imports from `app.py` |

`/healthz` returns the deployment identity to make "is this the Cloudflare app or
Render?" instantly verifiable. No code path in `cloudflare/` mentions
`camanime.onrender.com`; nothing proxies or falls back to it.
