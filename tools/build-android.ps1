# Builds the CamAnime Android APK on YOUR Windows PC.
# Prereqs: Flutter SDK (https://docs.flutter.dev/get-started/install/windows/mobile)
#          + Android Studio (installs the Android SDK + licenses).
# Run:  powershell -ExecutionPolicy Bypass -File tools\build-android.ps1
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\mobile\camanime_app")

flutter --version
flutter pub get

if (-not (Test-Path "android")) {
  flutter create --platforms=android --project-name camanime_app .
}

flutter build apk --release

$apk = "build\app\outputs\flutter-apk\app-release.apk"
Write-Host "== APK ready: $apk ==" -ForegroundColor Green
Get-Item $apk | Format-List Name, @{n="MB";e={[math]::Round($_.Length/1MB,1)}}, LastWriteTime
Write-Host "Copy it as static\downloads\CamAnime.apk for the website direct-download button,"
Write-Host "or attach it to a GitHub Release (see docs/APP_RELEASES.md)."
