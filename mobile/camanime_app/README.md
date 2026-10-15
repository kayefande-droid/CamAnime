# CamAnime Android app (Flutter)

Brand masters: `../../static/brand/camanime-logo.svg` and `../../static/brand/camanime-icon.svg`. Android/PWA PNG sizes are generated from the icon master; the app’s logo is copied into its asset bundle by `dart run tool/generate_brand_assets.dart` (from this directory).

Made by kayefande-droid & co.

## What this is
Flutter client for the CamAnime website's versioned AniList-backed catalogue (`/api/v1/catalog/home`, `/api/v1/search`, `/api/v1/anime/<id>`).
- AniList IDs remain canonical between site and app; cached catalogue JSON and poster artwork support offline discovery.
- Catalogue refreshes on pull-to-refresh and when returning to the foreground (rate-limited to once per minute).
- The legacy web player/provider routes remain server-side; the native app intentionally does not advertise playback or downloads until the backend returns an explicitly authorized source with `download_allowed: true`.
- A local file-library UI remains for existing user files; this release does not claim an online episode download implementation.

## Build on your device
```bash
cd mobile/camanime_app
flutter pub get
# Debug APK
flutter build apk --debug
# Release APK (configure signing before distribution)
flutter build apk --release --dart-define=CAMANIME_API=https://your-host
# output: build/app/outputs/flutter-apk/app-release.apk
# Windows desktop app (on a Windows machine)
flutter config --enable-windows-desktop
flutter build windows --release
# output: build/windows/x64/runner/Release/camanime_app.exe
```

## Link app to website
1. Deploy the Flask site (Procfile: `gunicorn app:app`) with `CAMANIME_SECRET`, an appropriate `CAMANIME_DB`, and optional paired `CAMANIME_ADMIN_EMAIL` / `CAMANIME_ADMIN_PASSWORD` secrets configured in the host environment.
2. In app → You tab → paste website URL (e.g. `https://camanime.example.com`) → Save.
3. In the app's Profile tab, sign in with the same email + password you use on the website
   (`/login`). The app calls `POST /api/auth/login|register` and stores the API token,
   sending it as `Authorization: Bearer <token>` on downloads, comments, ratings and
   notifications — one permanent SQLite user database (`camanime.db`) shared by web and app.
   Downloads still require sign-in (PBKDF2-hashed passwords, admin role for `/admin`).

## Security notes
- No ads SDKs bundled (ad-block by omission); add platform blocklists only from user-controlled settings.
- Never log tokens; `flutter run --release` strips debug banners.
- AniList is used for licensed metadata/artwork only; it is not a streaming or download entitlement.
- Do not configure AnimeHeaven/Anikoto or generated embed sources without explicit permission and documented provider authorization.
- Render free web instances have ephemeral local storage; configure durable storage for SQLite before relying on persistent accounts.

## TikTok/promo
Point the bio link to `https://<your-host>/promo` (flyer slides + tags + Remotion storyboard).
