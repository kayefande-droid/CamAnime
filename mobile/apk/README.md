# CamAnime Android APK artifacts

Built APKs from the current `mobile/camanime_app` source tree (Flutter release build, debug-signing config).

| File | Version | SHA-256 |
|---|---|---|
| `CamAnime-2.6.1.apk` | 2.6.1 (versionCode 12) | `d3d74c07d1412a9675f750a2bc79e570e9a48ffa77541633460943521d1e5f48` |

`CamAnime-2.6.1.apk.sha256` carries the same digest for automated verification. The `CamAnime-Review/` copy is the same build used for review handoff.

## Building from source

From `mobile/camanime_app/android`:

```bash
JAVA_HOME="C:/Users/Admin/.jdks/jbr-21.0.9" \
FLUTTER_BUILD_DIR="D:/tmp/flutter_build_camAnime" \
bash ./gradlew --no-daemon assembleRelease --stacktrace
```

The release APK lands at `build/app/outputs/flutter-apk/app-release.apk`. Replace the artifact in this folder with the built file and regenerate the `.sha256` file.

## Notes

- Version is driven by `mobile/camanime_app/pubspec.yaml` (`version: 2.6.1+12`). The version name and code above match that source of truth.
- This release build uses the debug signing config (`signingConfig = signingConfigs.getByName("debug")`) so it can be installed for review without a release keystore.
