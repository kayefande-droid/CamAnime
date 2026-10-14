#!/usr/bin/env bash
# Installs Flutter SDK + Android command-line tools into $HOME (no root needed).
# Repeatable: safe to re-run; skips steps already done.
set -euo pipefail

FLUTTER_CHANNEL="${FLUTTER_CHANNEL:-stable}"
FLUTTER_DIR="${FLUTTER_DIR:-$HOME/flutter}"
SDK_DIR="${ANDROID_SDK_ROOT:-$HOME/android-sdk}"
CMDLINE_ZIP="$HOME/cmdline-tools.zip"
CMDLINE_URL="https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip"

echo "== Flutter SDK =="
if [ ! -x "$FLUTTER_DIR/bin/flutter" ]; then
  VERSION=$(curl -fsSL "https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json" \
    | python3 -c 'import json,sys;d=json.load(sys.stdin);c=d["current_release"]["'"$FLUTTER_CHANNEL"'"];print([r["archive"] for r in d["releases"] if r["hash"]==c][0])')
  echo "downloading $VERSION"
  curl -fL --retry 3 -o "$HOME/flutter.tar.xz" "https://storage.googleapis.com/flutter_infra_release/releases/$VERSION"
  mkdir -p "$(dirname "$FLUTTER_DIR")"
  tar -xf "$HOME/flutter.tar.xz" -C "$(dirname "$FLUTTER_DIR")"
  rm -f "$HOME/flutter.tar.xz"
else
  echo "already present"
fi
git config --global --add safe.directory "$FLUTTER_DIR" || true
export PATH="$FLUTTER_DIR/bin:$PATH"
flutter --version
flutter config --no-analytics >/dev/null 2>&1 || true
flutter precache --android --no-ios --no-linux --no-web >/dev/null 2>&1 || true

echo "== Android command-line tools =="
if [ ! -x "$SDK_DIR/cmdline-tools/latest/bin/sdkmanager" ]; then
  mkdir -p "$SDK_DIR/cmdline-tools"
  curl -fL --retry 3 -o "$CMDLINE_ZIP" "$CMDLINE_URL"
  unzip -q -o "$CMDLINE_ZIP" -d "$SDK_DIR/cmdline-tools"
  rm -f "$CMDLINE_ZIP"
  mv "$SDK_DIR/cmdline-tools/cmdline-tools" "$SDK_DIR/cmdline-tools/latest" 2>/dev/null || true
else
  echo "already present"
fi
export ANDROID_SDK_ROOT="$SDK_DIR"
export ANDROID_HOME="$SDK_DIR"
export PATH="$SDK_DIR/cmdline-tools/latest/bin:$SDK_DIR/platform-tools:$PATH"

yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install "platform-tools" "platforms;android-34" "build-tools;34.0.0" "cmdline-tools;latest" >/dev/null

flutter config --android-sdk "$SDK_DIR" >/dev/null
flutter doctor -v || true
echo "== done. Add to your shell: export PATH=\"$FLUTTER_DIR/bin:$SDK_DIR/platform-tools:\$PATH\" =="
