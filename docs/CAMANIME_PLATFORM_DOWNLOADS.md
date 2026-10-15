# CamAnime-native downloads + synced admin — clear process

All downloads come **directly from your CamAnime platform** (same Flask backend
the website uses). Only host content you own or are licensed to distribute.

## 1. First-run admin (changeable, admin-only tools)

1. Deploy with env:
   - `CAMANIME_SECRET` — required for stable sessions (generate: `python tools/admin-sync.py --generate-secret`)
   - `CAMANIME_DB` — SQLite path (persist the file/volume on Render)
   - Optional: `CAMANIME_ADMIN_EMAIL` + `CAMANIME_ADMIN_PASSWORD` to seed a custom admin
2. First boot with an empty DB creates:
   - email `admin@camanime.local`
   - password `CamAnime123!` (or `CAMANIME_DEFAULT_ADMIN_PASSWORD` if set)
3. Sign in at `/login`, open `/admin`, use **Admin account tools**:
   - Change my admin password (needs current password, min 8 chars, logs you out everywhere)
   - Reset user password (admin-only)
   - Create admin (admin-only)
   - Sync status panel calls `GET /api/admin/sync`
4. Verify from CLI:
   ```bash
   python tools/admin-sync.py --base https://your-host --email admin@camanime.local --password 'new-password'
   ```

## 2. Web + app share one account (synced secret key)

- Web: session cookie at `/login`
- App (You tab → save host → Profile tab → same email + password):
  - `POST /api/auth/register|login` → `{"token": "..."}` (90 days)
  - App sends `Authorization: Bearer <token>` on downloads, comments, ratings, admin sync
- Admin check from app/tools:
  - `GET /api/admin/sync` with Bearer token → secret/db/version status
  - `POST /api/admin/password` `{current_password, new_password}` or `{target_email, new_password}`
  - `POST /api/admin/create-admin` `{email, name, password}`

## 3. Downloads directly from CamAnime

### A. App binaries (no login)
- Page `/download` shows copyable link + direct button
- `GET /get/android` → `CamAnime.apk` (bundled file or GitHub Release, `Content-Disposition: attachment`)
- `GET /get/windows` → Windows zip
- `GET /api/version` → `{app_version, apk_url, windows_url}` for the Updates tab

### B. Platform files (login + ownership/license required)
- `GET /api/download/video?url=<owned-file-url>&title=<name>` with session or Bearer token
  - Streams through CamAnime with `Content-Disposition: attachment; filename="<title>.mp4"`
  - Supports `Range` for resume/seek
- `GET /api/proxy/video?url=<owned-file-url>` for in-app/website `<video>` streaming (Range supported)
- `GET /api/proxy/subtitle?url=<owned-vtt-url>` for captions (SRT auto-converted to VTT)
- App flow:
  1. Sign in in Profile tab (token saved on device)
  2. Detail screen → authorized source with `download_allowed: true`
  3. Downloads tab → progress → saved to `camanime_library/`
  4. My Library tab → Save to device Downloads (nothing leaves the app until you tap Save)

Do not point these endpoints at third-party sites you have no distribution
rights for. If a title needs licensing, clear that first, then host/whitelist
only your authorized file hosts.
