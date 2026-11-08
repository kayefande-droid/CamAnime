# CamAnime 2.7 — regression and security test report

Executed on 2026-11-08 against the working tree that produced
`mobile/apk/CamAnime-2.7.0.apk`.

## Commands run

| Check | Command | Result |
| --- | --- | --- |
| Dart static analysis | `flutter analyze` (in `mobile/camanime_app`) | No issues found |
| Backend suite | `python -m pytest tests -q` | **120 passed** (108 pre-existing + 12 new version-policy tests) |
| APK identity | `aapt dump badging app-release.apk \| head -n 1` | `versionCode='17' versionName='2.7.0'` |
| Dart obfuscation | `unzip -p APK lib/arm64-v8a/libapp.so \| grep -a <identifier>` | no `AdminPanel` / `adminSync` / `changeAdminPassword` / `AdminPanel` state names |

## Version enforcement (executed with `app.test_client()`)

| Scenario | Expected | Observed |
| --- | --- | --- |
| Supported build 17 on `/api/public/stream/download` | 200 | 200 |
| Unsupported build 16 on the same route | 426 `APP_UPDATE_REQUIRED` | 426 with `force_update`, `download_url`, `X-CamAnime-Min-Build: 17` |
| Unsupported build 16 on `/api/v1/*` | 426 | 426 |
| Same route with no version headers (browser) | 200 | 200 |
| Outdated build on `/api/app/version` | 200 + policy | 200, `required: true` |
| Policy bumped to build 18, then build 17 calls | 426 | 426 |
| Policy change without `confirm_force_update` | 400 | 400 |
| Minimum build newer than latest build | 400 | 400 |
| Lowering latest build through normal save | 400 (use rollback) | 400 |
| Rollback after two changes | previous policy restored | 2.7.1 restored |
| `/api/admin/version-policy` anonymous / user / admin | 403 / 403 / 200 | 403 / 403 / 200 |
| `/api/admin/sync` (removed) | 404 | 404 |
| `notify` with no push transport | honest zero delivery | `push_available: false`, `push_delivered: 0` |

## Functional regression of existing features

Covered by the pre-existing suite, which was re-run unchanged:

- catalogue home/search/genre/anime detail/episode listings (`/api/v1/*`,
  `/api/public/*`)
- episode source resolution and proxy endpoints
- community comments, likes, ratings and notifications
- download probe/HLS/video endpoints and public counters
- auth register/login/me/logout, history sync
- website pages: `/`, `/anime/<id>`, `/watch/<id>/<ep>`, `/download`, `/promo`,
  `/robots.txt`, `/sitemap.xml`
- admin dashboard announce/password/create-admin still 403 for non-admins

No behaviour was changed in those paths beyond the `before_request` gate, which
is inert for requests that do not identify as the app.

## Not tested here (stated, not claimed)

- Installing the APK on a physical device and upgrading over 2.6.5 (no device
  attached to this environment).
- Receiving a push notification: there is no push transport in this project.
- Browsing `/admin` interactively: the dashboard is rendered and its endpoints
  are covered by tests, but the new panel's JavaScript was not exercised in a
  browser.
- MFA for administrators: not implemented.
