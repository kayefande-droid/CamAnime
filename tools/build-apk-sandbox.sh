#!/usr/bin/env bash
# Builds the release APK inside this Linux sandbox (Flutter SDK must exist at ~/flutter).
# Java is bootstrapped from Eclipse Temurin (no root needed).
set -euo pipefail

export FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
export SDK_DIR="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
export JAVA_DIR="${JAVA_DIR:-$HOME/java17}"

echo "== Java =="
if ! command -v java >/dev/null 2>&1; then
  if [ ! -x "$JAVA_DIR/bin/java" ]; then
    echo "downloading Temurin JRE 17"
    mkdir -p "$JAVA_DIR"
    curl -fL --retry 3 -o /tmp/jre.tar.gz \
      "https://github.com/adoptium/temurin17-binaries/releases/download/jdk-17.0.13%2B11/OpenJDK17U-jre_x64_linux_hotspot_17.0.13_11.tar.gz"
    tar -xzf /tmp/jre.tar.gz -C "$JAVA_DIR" --strip-components=1
    rm -f /tmp/jre.tar.gz
  fi
  export JAVA_HOME="$JAVA_DIR"
  export PATH="$JAVA_DIR/bin:$PATH"
fi
java -version 2>&1 | head -2

export PATH="$FLUTTER_DIR/bin:$PATH"
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_HOME="$SDK_DIR"
export PATH="$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:$PATH"

echo "== Android packages =="
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" "cmdline-tools;latest" >/dev/null
flutter config --android-sdk "$SDK_DIR" >/dev/null
flutter doctor -v || true

echo "== App build =="
cd "$(dirname "$0")/../mobile/camanime_app"
flutter pub get
if [ ! -d android ]; then
  flutter create --platforms=android --project-name camanime_app .
fi
flutter build apk --release

APK="build/app/outputs/flutter-apk/app-release.apk"
ls -lh "$APK"
mkdir -p ../../static/downloads
cp "$APK" ../../static/downloads/CamAnime.apk
echo "== APK copied to static/downloads/CamAnime.apk =="
ls -lh ../../static/downloads/
