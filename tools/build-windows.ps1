# Builds the CamAnime Windows desktop app (.NET 8 + WebView2) on YOUR Windows PC.
# Prereq: .NET 8 SDK (https://dotnet.microsoft.com/download) — `dotnet --version` must work.
# Run:  powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..\windows\CamAnime.Windows")

dotnet --version
dotnet restore
dotnet publish -c Release -r win-x64 --self-contained true `
  -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true

$exe = Get-ChildItem "bin\Release\*\win-x64\publish\CamAnime.exe" | Select-Object -First 1
Write-Host "== Windows app ready: $($exe.FullName) ==" -ForegroundColor Green
Write-Host "Run it with your site URL:  CamAnime.exe https://your-host"
Write-Host "Zip the publish folder as static\downloads\CamAnime-Windows.zip for the website"
Write-Host "direct-download button, or attach it to a GitHub Release (see docs/APP_RELEASES.md)."
