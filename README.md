# CamAnime — Free Anime Streaming Website + Native Apps

Watch anime online free in 1080p SUB/DUB. Free streaming website for Cameroon and worldwide fans, with **native Android + Windows apps** linked to the same account system. Made by **kayefande-droid & co.**

- Website: `https://camanime.onrender.com` (auto-deploys from `main` via Render + `render.yaml`)
- Apps: download from the site's **/download** page or **GitHub Releases** (`v1.0.0+`)

## Features

- **Streaming**: AnimeHeaven direct MP4 + Anikoto/MegaPlay 1080p HLS (SUB/DUB), multi-subtitles, skip-times, Kiwi/Pahe download links, YouTube trailers
- **One-click app downloads**: `/get/android` and `/get/windows` start the download immediately (bundled file or GitHub Release asset)
- **Accounts**: Gmail/iCloud/social-style email signup, PBKDF2-hashed passwords, 90-day Bearer tokens, admin seeded via env
- **Community**: comments + replies, likes, stickers, honest anime ratings, read/unread notifications — same forum in app and website
- **Library**: hidden in-app downloads, export only via per-episode/season **Save to device**; bookmarks, resume-where-you-left-off, watchlist
- **Discovery**: trending/popular/top-rated rails, genre search, simulcast + classics schedule, recommendations, related anime
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

Env: `CAMANIME_SECRET`, `CAMANIME_DB`, `CAMANIME_ADMIN_EMAIL`, `CAMANIME_ADMIN_PASSWORD`, `CAMANIME_RELEASE_TAG`.

## Deploy (Render, auto-deploy on push)

Repo ships `render.yaml` blueprint + `Procfile` + `runtime.txt` (Python 3.11.9): build `pip install -r requirements.txt`, start `gunicorn app:app`, health check `/`. Enable **Auto-Deploy** in the Render dashboard; keep bot protection off for Googlebot so Search Console verification passes.

## API (for apps and integrations)

- `GET /api/public/anime/<id>?ep=<n>` — episode streaming bundle (servers, quality, subs)
- `POST /api/auth/register|login|logout`, `GET /api/auth/me` — token auth
- `GET/POST /api/community/*` — comments, likes, ratings, notifications
- `GET /api/heaven/*` — AnimeHeaven search/catalog/resolve/season-pack
- `GET /api/download/video` — forced MP4 episode download (login required)

## Disclaimer

CamAnime aggregates publicly available streams for discovery; it does not host video. Comply with local copyright law.
