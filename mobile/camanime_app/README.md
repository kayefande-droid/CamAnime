# CamAnime Flutter App

<div align="center">
  <img src="https://raw.githubusercontent.com/kayefande-droid/CamAnime/main/static/brand/camanime-logo.svg" width="120" alt="CamAnime Logo"/>
</div>

### A modern anime streaming companion for Android (Flutter)

<div align="center">
  <img src="https://raw.githubusercontent.com/kayefande-droid/CamAnime/main/static/brand/camanime-icon.svg" width="80" alt="CamAnime Icon"/>
</div>

> Made with ❤️ by kayefande-droid & co.

<hr/>

## 📱 What is CamAnime?

CamAnime is an Android Flutter application that serves as an **offline catalogue companion** for the CamAnime website. It provides:

- 📚 **AniList-backed catalogue** - Browse anime with canonical IDs between site and app
- 💾 **Offline file library** - Manage your existing downloaded episodes
- 🔄 **Live OTA updates** - Automatic update notifications with 2-minute grace period
- 📊 **Version tracking** - Stay on top of new releases

<hr/>

## 🛠️ Build on Your Device

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

## 🔗 Link App to Website

1. Deploy the Flask site (Procfile: `gunicorn app:app`) with `CAMANIME_SECRET`, an appropriate `CAMANIME_DB`, and optional paired `CAMANIME_ADMIN_EMAIL` / `CAMANIME_ADMIN_PASSWORD` secrets configured in the host environment.
2. In app → **You** tab → paste website URL (e.g. `https://camanime.example.com`) → Save.
3. In the app's **Profile** tab, sign in with the same email + password you use on the website (`/login`). The app calls `POST /api/auth/login|register` and stores the API token, sending it as `Authorization: Bearer <token>` on downloads, comments, ratings and notifications — one permanent SQLite user database (`camanime.db`) shared by web and app. Downloads still require sign-in (PBKDF2-hashed passwords, admin role for `/admin`).

## 🔒 Security Notes

- No ads SDKs bundled (ad-block by omission); add platform blocklists only from user-controlled settings.
- Never log tokens; `flutter run --release` strips debug banners.
- AniList is used for licensed metadata/artwork only; it is not a streaming or download entitlement.
- Do not configure AnimeHeaven/Anikoto or generated embed sources without explicit permission and documented provider authorization.
- Render free web instances have ephemeral local storage; configure durable storage for SQLite before relying on persistent accounts.

## 📣 TikTok/Promo

Point the bio link to `https://<your-host>/promo` (flyer slides + tags + Remotion storyboard).
