# CamAnime 🍥

**Anime discovery, streaming and offline watching — website + native Android app.**

[![Website](https://img.shields.io/badge/live-camanime.onrender.com-087BFF?style=flat-square)](https://camanime.onrender.com)
[![Mirror](https://img.shields.io/badge/edge-camanjme.camanime.workers.dev-F6820A?style=flat-square)](https://camanjme.camanime.workers.dev)
[![Android](https://img.shields.io/badge/Android-2.8.0-3DDC84?style=flat-square&logo=android&logoColor=white)](https://camanime.onrender.com/get/android)

CamAnime pairs a fast Flask catalogue with a Flutter app that feels like a first-class streaming client: one tap to play, real quality control, downloads that survive updates, and a player built for binge-watching. Metadata comes from AniList; playback and downloads use only the providers configured by the operator.

---

## ✨ What makes it different

| | |
|---|---|
| 🎚️ **Real quality, real pixels** | 720p / 480p / 360p are genuine ffmpeg re-encodes with bounded bitrate — for streaming *and* downloads. No relabelled 1080p file pretending to be 360p. |
| 📱 **Player that disappears** | Immersive fullscreen that adapts to the screen, drag-free brightness and volume, playback speed, resume position, and a mini-player that keeps the episode alive while you browse. |
| ⏭️ **Binge mode** | Episodes selectable directly under the video, a “More to watch” rail of similar anime underneath, auto-play next, and intro/outro skipping (both toggleable). |
| 📥 **Offline that stays offline** | Partial-play while downloading, resume-safe queue, recovered library after an index failure, and updates that **never touch your downloads, watchlist or history**. |
| 🔄 **Updates in-app** | The app checks the website for a newer build on launch/resume, downloads the APK, verifies it and hands it to Android’s installer. One confirmation, no browser hunt. |
| 🎬 **Trailers everywhere** | Official YouTube trailers on the website and in the app whenever AniList supplies one. |
| 🔐 **Server-side authority** | Roles (`owner` / `developer` / `support`) are enforced by the backend, never by hidden UI. Old builds are refused by both Render and the Cloudflare edge. |

## 🧱 Stack

- **Backend** — Flask, SQLite, Jinja templates, gunicorn (`app.py`)
- **Website** — responsive dark-first UI, AniList catalogue, HLS/mp4 player, downloads
- **Android** — Flutter 3, Material 3, `video_player`, native bridges for downloads, PiP, brightness and the in-app updater
- **Edge** — Cloudflare Worker front door (`cloudflare/`) with a hard minimum-build gate
- **Quality pipeline** — on-demand `ffmpeg` fragmented MP4 (`transcode.py`), never stored on disk

## 🚀 Quick start

```bash
pip install -r requirements.txt
python app.py            # http://localhost:5000  (production: gunicorn app:app)
```

```bash
cd mobile/camanime_app
flutter pub get
flutter build apk --release --dart-define=CAMANIME_API=https://your-host
```

## 🔌 API surface

- `GET /api/v1/catalog/home` · `/api/v1/anime/<id>` · `/api/v1/anime?q=` — AniList-backed catalogue
- `GET /api/public/anime/<id>?ep=<n>&audio=sub|dub` — playable bundle for the apps
- `GET /api/stream/transcode?url=&height=720|480|360` — inline, genuinely re-encoded stream
- `GET /api/download/transcode?url=&height=` — the same ladder as a saved file
- `POST /api/auth/register|login` — PBKDF2 passwords, Bearer sessions
- `GET /api/version` — release policy consumed by the update checker
- `/api/admin/*` — role-guarded operations (owner, developer, support)

## 🛡️ Operations & privacy

Deployment uses **Render** for the Flask origin and **Cloudflare Workers** for the edge; both deploy from `main`. The application needs no store listing and no third-party OAuth.

Owner-only runbooks, release-signing procedures, provider notes and incident steps live in `docs/private/` and are intentionally **git-ignored**. Do not commit signing keys, `.env` files, service-account JSON, or admin credentials — `.gitignore` already blocks the usual suspects.

Environment variables the host expects: `CAMANIME_SECRET`, `CAMANIME_DB` (optional SQLite path), `CAMANIME_ADMIN_EMAIL` + `CAMANIME_ADMIN_PASSWORD` (set together to provision the first owner), and `CAMANIME_FFMPEG` (optional binary path). Render’s build downloads a static `ffmpeg`; if that download fails the API reports conversion as unavailable rather than promising a quality it cannot produce.

## ⚖️ License & disclaimer

© 2026 kayefande-droid. All rights reserved — see `LICENSE`.

Metadata and artwork are provided for discovery. CamAnime does not bundle or claim rights to any anime. Stream or download only media that the configured providers are authorized to distribute, and follow provider terms and local copyright law.
