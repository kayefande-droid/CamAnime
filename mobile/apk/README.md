# CamAnime Android APK artifacts

Built APKs from the current `mobile/camanime_app` source tree (Flutter 2.7.0, release build).

| File | Version | SHA-256 |
|---|---|---|
| `CamAnime-2.7.0.apk` | 2.7.0 (versionCode 17) | `2c94dce964f4cedf2072864cff527d5b4070e5dd62416fa6f7d306c4359917e9` |

Only the current version is published here and on the website download page.

## What 2.7.0 changes

- **No administration in the app.** Admin screens, admin service calls, role
  sniffing and privileged tokens are gone; administration lives at `/admin` on
  the website only.
- **Mandatory update enforcement.** The server rejects protected API calls from
  builds below the minimum with HTTP 426, and the app shows a blocking update
  screen with a retry state and the official download link.
- **Hardened build.** Dart obfuscation with private debug symbols, R8
  minification and resource shrinking, HTTPS-only network security config,
  backups disabled.

## Building from source

```bash
flutter build apk --release   --obfuscate   --split-debug-info=D:/tmp/camanime_symbols_270
```

Keep the split-debug-info folder privately: it maps obfuscated frames back to
source and is not committed. Release signing intentionally continues the
existing CamAnime debug keystore so 2.6.x users can update in place; switching
keys would force every user to uninstall.
