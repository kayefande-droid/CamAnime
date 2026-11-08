# CamAnime Android APK artifacts

Built APKs from the current `mobile/camanime_app` source tree (Flutter release build, debug-signing config).

| File | Version | SHA-256 |
|---|---|---|
| `CamAnime-2.6.5.apk` | 2.6.5 (versionCode 16) | `85111e8f054e9d1c813a55421c09b599c8e250ba426a2c802368bfbe44216531` |

`CamAnime-2.6.5.apk.sha256` carries the same digest for automated verification. The `CamAnime-Review/` copy is the same build used for review handoff.

## Building from source

From `mobile/camanime_app`:

```bash
flutter build apk --release   --obfuscate   --split-debug-info=D:/tmp/camanime_symbols_265
```

The release APK lands at `build/app/outputs/flutter-apk/app-release.apk`. Dart is
AOT-compiled and obfuscated, and R8 minifies plus shrinks resources, so the
shipped APK carries no readable symbol names. Keep the `--split-debug-info`
folder to symbolicate any crash report; without it those names are gone.

## Notes

- Version is driven by `mobile/camanime_app/pubspec.yaml` (`version: 2.6.5+16`). The version name and code above match that source of truth.
- Only the current version is published here and on the website download page.
