# CamAnime native app (Flutter) — Android APK + Windows

Made by kayefande-droid & co.

## What this is
Flutter client for the CamAnime website API (`/api/public/anime/<id>`, `/api/heaven/*`, community + ratings endpoints).
- Hidden in-app download library (`getApplicationSupportDirectory()/camanime_library`); files never leave the app until the user taps **Save to device** (per episode; loop for seasons).
- Theme background switch (light/dark), username + website API link, resume markers in `SharedPreferences`.
- Bookmarks/resume sync key: `resume_<animeId>`, watchlist JSON under `camanime_watchlist`.

## Build on your device
```bash
cd mobile/camanime_app
flutter pub get
# Android APK (needs Android SDK)
flutter build apk --release
# output: build/app/outputs/flutter-apk/app-release.apk
# Windows desktop app (on a Windows machine)
flutter config --enable-windows-desktop
flutter build windows --release
# output: build/windows/x64/runner/Release/camanime_app.exe
```

## Link app to website
1. Deploy the Flask site (Procfile: `gunicorn app:app`).
2. In app → You tab → paste website URL (e.g. `https://camanime.example.com`) → Save.
3. In the app's You tab, sign in with the same email + password you use on the website
   (`/login`). The app calls `POST /api/auth/login|register` and stores the API token,
   sending it as `Authorization: Bearer <token>` on downloads, comments, ratings and
   notifications — one permanent SQLite user database (`camanime.db`) shared by web and app.
   Downloads still require sign-in (PBKDF2-hashed passwords, admin role for `/admin`).

## Security notes
- No ads SDKs bundled (ad-block by omission); add platform blocklists only from user-controlled settings.
- Never log tokens; `flutter run --release` strips debug banners.
- "Block hacking from Crunchyroll or anyone" is not something a client can enforce: the app only calls CamAnime's own API + AniList metadata, never third-party private endpoints.

## TikTok/promo
Point the bio link to `https://<your-host>/promo` (flyer slides + tags + Remotion storyboard).
