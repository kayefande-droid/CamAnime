# CamAnime Android APK artifacts

Built APKs from the current `mobile/camanime_app` source tree (Flutter release build, debug-signing config).

| File | Version | SHA-256 |
|---|---|---|
| `CamAnime-2.6.4.apk` | 2.6.4 (versionCode 15) | `855f54f7a79835122055b5706104ae7cb2dbd05495c500368b714312ce74d34f` |

`CamAnime-2.6.4.apk.sha256` carries the same digest for automated verification. The `CamAnime-Review/` copy is the same build used for review handoff.

## Building from source

From `mobile/camanime_app/android`:

```bash
JAVA_HOME="C:/Users/Admin/.jdks/jbr-21.0.9" \
FLUTTER_BUILD_DIR="D:/tmp/flutter_build_camAnime" \
bash ./gradlew --no-daemon assembleRelease --stacktrace
```

The release APK lands at `build/app/outputs/flutter-apk/app-release.apk`. Replace the artifact in this folder with the built file and regenerate the `.sha256` file.

## Notes

- Version is driven by `mobile/camanime_app/pubspec.yaml` (`version: 2.6.4+15`). The version name and code above match that source of truth.
- This release build uses the debug signing config (`signingConfig = signingConfigs.getByName("debug")`) so it can be installed for review without a release keystore.
