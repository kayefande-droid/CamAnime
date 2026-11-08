# CamAnime 2.7 — security audit

Scope: the Android client (`mobile/camanime_app`), the Flask backend (`app.py`,
`camanime_platform.py`, `app_version.py`), the private dashboard
(`templates/admin.html`) and the release build configuration.

This report only lists checks that were actually run on this machine. Anything
untested is stated as untested.

## 1. Administration is gone from the APK

| Before | After |
| --- | --- |
| `AdminPanel` widget with live activity, announcement publishing and admin password change | Deleted (`lib/main.dart`) |
| `Api.adminSync()` calling `/api/admin/sync` | Deleted |
| `Api.changeAdminPassword()` calling `/api/admin/password` | Deleted |
| Account card read the user's role and rendered admin tools for `role == "admin"` | Role is no longer read; the app does not care |

Verification: `flutter analyze` reports **No issues found**; the shipped
`libapp.so` contains no `AdminPanel`, `adminSync`, `changeAdminPassword` or
`/api/admin` strings (checked with `grep -a` against the extracted library in
the 2.7.0 build step).

Administration now lives only at `/admin` on the server, behind a session or
Bearer token whose database row has `role = 'admin'`.

## 2. Administrative endpoints

All `/api/admin/*` routes call `_require_admin()` and return **403** otherwise.
Verified with `app.test_client()`:

- anonymous → 403
- ordinary user Bearer token → 403
- administrator Bearer token → 200

Removed: `/api/admin/sync`. It returned the SQLite path, the seeded admin
address, the environment admin address and whether `CAMANIME_SECRET` was set to
any administrator session. Nothing needs it, and the dashboard no longer calls
it. A test asserts it now returns 404.

## 3. No shipped administrator password

`camanime_platform.DEFAULT_ADMIN_PASSWORD` used to fall back to a literal string
in source, so a fresh deployment had a publicly known admin password. It is now
environment-only. When no password is configured on a fresh database, the
first-run bootstrap generates `secrets.token_urlsafe(12)`, writes
`admin_bootstrap.txt` (mode `0600`) next to the SQLite file and prints the path,
never the password.

## 4. Server-enforced minimum version

`app_version.py` holds one policy row: `latest_version`,
`latest_version_code`, `minimum_supported_version`,
`minimum_supported_version_code`, `force_update`, `download_url`,
`release_notes`, `update_message`, `release_enabled`.

`app.py` registers a `before_request` gate over streaming, download resolution,
proxy, community, history and catalogue routes. Requests that identify
themselves as the app (`X-CamAnime-Version` / `X-CamAnime-Build`, sent by
`VersionGate.headers()` on every `Api` call) with a build below the minimum get:

```json
{"code":"APP_UPDATE_REQUIRED","force_update":true,"latest_version":"2.7.0",
 "latest_version_code":17,"minimum_supported_version":"2.7.0",
 "minimum_supported_version_code":17,
 "download_url":"https://camanime.onrender.com/get/android",
 "message":"…","release_notes":"…"}
```

with HTTP **426**, `X-CamAnime-Min-Build: 17` and `Cache-Control: no-store`.

Verified: build 16 → 426 on `/api/public/stream/download` and `/api/v1/*`;
build 17 → 200; the same request with no version headers (a browser) → 200;
`/api/app/version` stays reachable from build 16 so an old client can still
learn how to update.

Known limitation: enforcement is keyed on the app identifying itself. A custom
client that omits the headers is treated as a browser because the public website
shares those routes. Closing that gap requires app-only signed requests (e.g.
mTLS or a Play Integrity check plus a server-verified attestation), which is not
implemented here.

## 5. Android build hardening

- Dart AOT obfuscation + `--split-debug-info` (symbols kept out of git).
- R8 minification **and** `isShrinkResources = true`.
- `android:allowBackup="false"`, `android:fullBackupContent="false"` so local
  prefs, tokens and downloaded files are not swept into cloud backups.
- `res/xml/network_security_config.xml` with `cleartextTrafficPermitted="false"`;
  the manifest references it. Media and API traffic must be HTTPS.
- Exported components: only `MainActivity` (launcher). `FileProvider` and
  `DownloadKeepAliveService` are `exported="false"`.
- `proguard-rules.pro` keeps WorkManager/Room/startup classes that are reached
  reflectively, so shrinking does not break background downloads.

## 6. Signing

The release build still uses the Android **debug keystore**
(`~/.android/debug.keystore`) because that is what every CamAnime APK to date
has been signed with. Introducing a private release key now would change the
signature and force every existing user to uninstall first, losing their
library and downloads. A private keystore was found at
`Desktop/Projects/Kaya signing backup/kaya-release.jks`, but its alias and
passwords are unknown, so it was **not** used and no replacement key was
generated.

Action for the owner: move to a private release key only at a version where a
one-time uninstall is acceptable, then keep the keystore and passwords outside
the repository.

## 7. Still open (honest list)

- **MFA for administrators**: not implemented. No TOTP dependency is present and
  no authenticator enrolment flow exists. Recommended next step: `pyotp` +
  `qrcode`, a `totp_secret` column, and a verification step on `/login` for
  `role='admin'`.
- **Push notifications**: the project has no Firebase project, no `google-
  services.json` and no device-token table. The admin "flag outdated devices"
  action records targets and reports `push_available: false`,
  `push_delivered: 0` rather than claiming delivery. Outdated devices still get
  the blocking update screen on their next request.
- **Identity-aware gateway / IP allowlist** for `/admin` and `/api/admin/*`: not
  configured in this repo; it belongs to the hosting layer (Render/Vercel
  settings or a Cloudflare Access policy).
- **Certificate pinning**: not enabled; the network security config only forbids
  cleartext.
- **Coverage of the version header**: `Api`-based calls send it (downloads,
  player, community, auth). Catalogue calls that build URLs directly may omit
  it; those are also blocked in practice because the app's own UI is gated at
  launch, but the header should be added to those call sites as follow-up.
