#!/usr/bin/env bash
# Builds the CamAnime Android APK on your own machine (Linux, macOS, or WSL).
# Prereqs: Flutter SDK (https://docs.flutter.dev/get-started/install) + Android SDK
#          (installed automatically by Android Studio, or via tools/install_flutter_android.sh).
set -euo pipefail
cd "$(dirname "$0")/../mobile/camanime_app"

export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
export ANDROID_HOME="${ANDROID_HOME:-$ANDROID_SDK_ROOT}"

flutter --version
flutter pub get

# Generate the native android/ folder on first run (safe to re-run).
if [ ! -d android ]; then
  flutter create --platforms=android --project-name camanime_app .
fi

flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
echo "== APK ready: $APK =="
ls -lh "$APK"
echo "Copy it as static/downloads/CamAnime.apk to enable the website's direct-download button,"
echo "or attach it to a GitHub Release (see docs/APP_RELEASES.md)."
