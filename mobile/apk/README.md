# CamAnime APK builds

Release APKs built from the current `mobile/camanime_app` tree (Flutter 2.8.0,
Dart obfuscation, split debug symbols).

| File | Version | SHA-256 |
| --- | --- | --- |
| `CamAnime-2.8.0.apk` | 2.8.0 (versionCode 18) | `edb044182d9dfc2b4d454230c8a2d111c43698f451fa0e0b6e417dadfdb4654d` |

Size: 53,316,395 bytes. Signed with the same key as every previous CamAnime
build, so older installs update in place and keep their downloads, watchlist
and watch history.

## What this build changes

- **Real quality switching**: picking 720p / 480p / 360p plays a genuine
  ffmpeg re-encode from `/api/stream/transcode`, not a relabelled 1080p file.
  Converted downloads use the same bounded-bitrate ladder.
- **Works for newer seasons too**: when a bundle only resolves one full-size
  source, the app synthesises the real quality ladder for the selected audio,
  so titles like Black Clover S2 still drop pixels and file size.
- **Player**: immersive fullscreen that adapts to the screen, brightness and
  volume sliders, episode chips directly under the video, “More to watch”
  similar-anime rail, and auto-skip intro (first ~90s) / auto-skip outro into
  the next episode — both toggleable.
- **Trailers** open from the detail screen on the website and in the app.
- **Updates**: checks the website on launch/resume (throttled to every six
  hours) plus a manual Settings check, downloads the APK in-app and opens
  Android's installer. Updates never clear the offline library, watchlist or
  watch history; finished files are re-adopted if the queue index is lost.
- **Admin notifications**: publishing an announcement at `/admin` sends the website banner, the app feed and an Android notification. Registered installs get an FCM broadcast when Firebase is configured; otherwise the APK shows the newest unseen announcement as a local notification on next launch.
- Version 2.7.0 and older are refused by the API and the Cloudflare edge.

## Rebuild

```bash
cd mobile/camanime_app
flutter build apk --release --obfuscate --split-debug-info=D:/tmp/camanime_symbols_280
```
