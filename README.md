# CamAnime — Free Anime Streaming Website + Native Apps

CamAnime pairs a responsive Flask discovery website with a Flutter Android app and a shared, AniList-backed catalogue. Streaming and downloads are exposed only when configured providers are authorized to distribute the media. Made by **kayefande-droid & co.**

- Website: `https://camanime.onrender.com` (auto-deploys from `main` via Render + `render.yaml`)
- Apps: download from the site's **/download** page or **GitHub Releases** (`v1.0.0+`)

## Features

- **Metadata**: AniList-backed canonical catalogue, anime artwork, search, genres, seasons/relations, and detail pages. AniList does not itself provide playable episode sources.
- **One-click app downloads**: `/get/android` and `/get/windows` start the download immediately (bundled file or GitHub Release asset)
- **Accounts**: Gmail/iCloud/social-style email signup, PBKDF2-hashed passwords, 90-day Bearer tokens, admin seeded via env
- **Community**: comments + replies, likes, stickers, honest anime ratings, read/unread notifications — same forum in app and website
- **Flutter client**: cached posters/catalogue for offline discovery, refresh when returning online, debounced API search, and explicit unavailable state unless authorized playback/download sources are configured.
- **Website**: existing AniList-backed home, search, details, and player routes remain intact; the v1 REST API shares the website normalization and canonical AniList IDs.
- **Admin**: download counts, site clicks, plays, most-watched playlist driving Trending classification
- **SEO**: anime-website Cameroon / free-streaming keywords, sitemap, robots, Google Search Console ready
- **Responsive**: 2-col narrow phones / 3-col wider phones / fluid tablet-desktop, verified 0-overflow across 9 viewports × 9 pages

## App ↔ website link + permanent database

One **SQLite** database (`camanime.db`, or `CAMANIME_DB` env) holds users, tokens, comments, ratings, notifications, events, and counters — it survives restarts (persist the file/volume on your host). Legacy JSON auto-migrates once.

- Website: session login at `/login`
- Native apps: `POST /api/auth/register|login` → Bearer token (`Authorization: Bearer <token>`)
- Community/track endpoints accept **both JSON (apps) and form posts (website)**: `/api/community/comment`, `/api/community/rate`, `/api/track`

## Native apps

| App | Source | Build |
|---|---|---|
| Android APK (Flutter, Material 3, dark anime theme) | `mobile/camanime_app/` | `powershell -ExecutionPolicy Bypass -File tools/build-android.ps1` |
| Windows (.NET 8 + WebView2, ad-block, hidden library) | `windows/CamAnime.Windows/` | `powershell -ExecutionPolicy Bypass -File tools/build-windows.ps1` |

Built binaries ship via **GitHub Releases** (recommended) or `static/downloads/` — the `/download` page and `/get/*` routes pick them up automatically. See `docs/APP_RELEASES.md`.

## Run the website locally

```bash
pip install -r requirements.txt
python app.py  # http://localhost:5000 (dev) — production: gunicorn app:app
```

Environment variables: `CAMANIME_SECRET` (required for stable production sessions), `CAMANIME_DB` (SQLite path), `CAMANIME_ADMIN_EMAIL` and `CAMANIME_ADMIN_PASSWORD` (set both to provision an admin; no hardcoded default admin credentials), `CAMANIME_RELEASE_TAG`. The metadata catalogue is served live/cached from AniList; it is not persisted to SQLite. Render free instances have ephemeral filesystems; attach persistent storage or move `CAMANIME_DB` to a durable database before relying on user/account data across redeploys.

Flutter build: `cd mobile/camanime_app && flutter pub get && flutter build apk --debug` (or `flutter build apk --release --dart-define=CAMANIME_API=https://your-host`). Android API host is configurable through `CAMANIME_API` and the app profile setting.

## Deploy (Render, auto-deploy on push)

Repo ships `render.yaml` blueprint + `Procfile` + `runtime.txt` (Python 3.11.9): build `pip install -r requirements.txt`, start `gunicorn app:app`, health check `/`. Enable **Auto-Deploy** in the Render dashboard; keep bot protection off for Googlebot so Search Console verification passes.

## CamAnime brand assets

- `static/brand/camanime-logo.svg` is the web/vector master; `camanime-logo.png` is the 2400×540 high-resolution raster lockup.
- `static/brand/camanime-icon.svg` is the compact square master. PWA icons, favicon, Apple touch icon, and Android density launcher PNGs are exported from it.
- The Flutter header embeds `mobile/camanime_app/assets/brand/camanime-logo.png`; regenerate/copy it with `cd mobile/camanime_app && dart run tool/generate_brand_assets.dart`.
- Website branding uses the CamAnime logo; the creator mark remains attribution rather than replacing the app/product identity.

## Versioned catalogue API (for app and website)

All catalogue endpoints use AniList IDs as canonical IDs and normalize fields through `format_anime_card`, the same formatter used by website routes. Success JSON uses `status: success`; validation/provider failures use `status: error` and `error.message`.

- `GET /api/v1/health`
- `GET /api/v1/catalog/home` — `catalog.featured`, `trending`, `popular`, `top_rated`, `recently_added`, `movies`, `series`
- `GET /api/v1/anime?q=&genre=&format=&sort=&page=&limit=` — paginated; `limit` 1–50
- `GET /api/v1/search?q=<query>`
- `GET /api/v1/genres`
- `GET /api/v1/genres/<slug>/anime`
- `GET /api/v1/anime/<anilist-id>` — metadata, alternate titles and AniList episode preview metadata
- `GET /api/v1/anime/<anilist-id>/episodes?page=&limit=` — metadata only; explicitly `playable:false` and `download_allowed:false`

The legacy endpoints below remain separate and are not mapped from AniList IDs unless a valid provider mapping exists.

- `GET /api/public/anime/<id>?ep=<n>` — legacy provider bundle (must be audited for authorization before use)
- `POST /api/auth/register|login|logout`, `GET /api/auth/me` — token auth
- `GET/POST /api/community/*` — comments, likes, ratings, notifications
- `GET /api/heaven/*` — AnimeHeaven search/catalog/resolve/season-pack
- `GET /api/download/video` — forced MP4 episode download (login required)

## Provider / deployment status

The existing source includes legacy AnimeHeaven and Anikoto scrapers plus generated VidSrc/VidLink embed URLs. Their presence in source is **not proof of permission, reliability, or a licensed integration**; do not enable them for publication until rights and provider terms are verified. AniList is currently a metadata provider only. No approved playback or offline-download provider is configured in this release.

The Render site was returning HTTP 503 during this audit, so live end-to-end web/API checks were unavailable. Local API contract tests mock the AniList response and do not validate its live upstream availability. SQLite user records persist only when Render is configured with durable storage; the committed free plan has no disk declaration.

## Disclaimer

Metadata and artwork are provided for discovery. Only distribute or play media from providers that explicitly authorize CamAnime to do so; comply with provider terms and local copyright law.
