# CamAnime for Windows (.NET 8 + WebView2)

Native Windows shell for the CamAnime website. Made by kayefande-droid &amp; co.

- Opens your site (defaults to `http://localhost:3000`, override with `CamAnime.exe https://your-host` or the `CAMANIME_URL` env var).
- Downloads route into a **hidden in-app library** (`%LocalAppData%\CamAnime\Library`) — use **Library → Save to device** to export.
- Basic ad/tracker host blocking is built into the WebView2 layer.

## Build on your Windows PC

```powershell
# one command from the repo root:
powershell -ExecutionPolicy Bypass -File tools\build-windows.ps1
```

Manual equivalent:

```powershell
cd windows\CamAnime.Windows
dotnet restore
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

Run: `bin\Release\net8.0-windows\win-x64\publish\CamAnime.exe https://your-host`

## Ship it on the website

Zip the `publish` folder as `CamAnime-Windows.zip`, then either drop it in
`static/downloads/` (the `/download` page auto-detects it) or attach it to a
GitHub Release — see `docs/APP_RELEASES.md`.
