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
New-Item -ItemType Directory -Force -Path "..\..\static\downloads" | Out-Null
Copy-Item $apk "..\..\static\downloads\CamAnime.apk" -Force
Write-Host "== Copied to static\downloads\CamAnime.apk — the website /download direct button is now live. ==" -ForegroundColor Green
Write-Host "Also attach it to a GitHub Release for the fallback link (see docs/APP_RELEASES.md)."
