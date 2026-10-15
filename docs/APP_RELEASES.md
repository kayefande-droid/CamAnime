# Publishing CamAnime app binaries (direct download links)

The `/download` page shows **direct download buttons** automatically and a copyable absolute URL for the Android APK (`/get/android`):

| File you provide | Button it enables |
|---|---|
| `static/downloads/CamAnime.apk` | Android → Direct download APK (with size + date) |
| `static/downloads/CamAnime-Windows.zip` (or `CamAnime.exe`) | Windows → Direct download Windows app |

If neither file is present, the page falls back to **GitHub Releases** links.

## Option A — serve from the website (fastest)

```bash
# after building on your PC:
cp mobile/camanime_app/build/app/outputs/flutter-apk/app-release.apk static/downloads/CamAnime.apk
# zip the dotnet publish folder, then:
cp CamAnime-Windows.zip static/downloads/
git add static/downloads && git commit -m "Ship app binaries" && git push
```

> Note: files in `static/downloads/` are public. Binaries are intentionally
> NOT committed by CI here — add them from your PC when ready.

## Option B — GitHub Releases (recommended for large files)

1. Build the APK / Windows zip on your PC (see `tools/` scripts).
2. GitHub → repo → Releases → Draft new release → use the app version tag (currently `v1.1.0`) → attach the APK → Publish.
3. The `/get/android` fallback and native update check use `CAMANIME_RELEASE_TAG` (default `v1.1.0`); update it when publishing a later release.

## TikTok bio link

Point your bio to `https://<your-host>/download` (direct buttons) and mention
`/<promo>` for the flyer slides + tags.
