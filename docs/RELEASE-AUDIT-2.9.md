# CamAnime 2.9 — historical release audit, release inventory and enforcement

This report only records what was actually found and measured on this machine.
Where an artifact was missing it says so.

## Artifacts inspected

| File | versionName | versionCode | Package | SHA/APK state |
| --- | --- | --- | --- | --- |
| `../CamAnime-Review/CamAnime-2.6.1-android.apk` | 2.6.1 | 12 | `com.camanime.app` | present, inspected |
| `../CamAnime-Review/CamAnime-2.6.2-android.apk` | 2.6.2 | 13 | `com.camanime.app` | present, inspected |
| `../CamAnime-Review/CamAnime-2.6.4-android.apk` | 2.6.4 | 15 | `com.camanime.app` | present, inspected |
| `../CamAnime-Review/CamAnime-2.7.0-android.apk` | 2.7.0 | 17 | `com.camanime.app` | present, inspected |
| `mobile/apk/CamAnime-2.8.0.apk` | 2.8.0 | 18 | `com.camanime.app` | present, inspected |
| 2.6.5 | 2.6.5 | 16 | — | **not available anywhere accessible** |

Method: `aapt dump badging` for identity/permissions, plus `lib/arm64-v8a/libapp.so`
extracted and scanned for `/api/admin`, `admin.html`, `SecurityLog`,
`create-admin`. No APK was executed.

## Findings

- 2.6.1 (12), 2.6.2 (13) and 2.6.4 (15) contain `/api/admin` strings in the
  native library: they still carry an administrator API surface and predate the
  owner MFA work. Permissions were the normal set (INTERNET, network state,
  foreground data-sync service, notifications, storage ≤ SDK 28, wake lock,
  boot receiver). 2.6.4 adds `REQUEST_INSTALL_PACKAGES`.
- 2.7.0 (17) and 2.8.0 (18) contain **zero** admin strings — the mobile admin
  surface was removed from the APK, not merely hidden.
- 2.6.5 (16) could not be inspected because no APK exists on this machine or in
  an accessible store. It is blocked by numeric policy, and the inventory marks
  its inspection status `UNAVAILABLE` rather than pretending otherwise.
- The lowest verified release above 2.6.5 is **2.7.0 (17)**, which stays the
  minimum supported build; 2.8.0 is the current release.

## Classification (seeded into `app_releases`)

| Release | Code | Inspected | Status |
| --- | --- | --- | --- |
| 2.6.1 | 12 | yes | BLOCKED |
| 2.6.2 | 13 | yes | BLOCKED |
| 2.6.4 | 15 | yes | BLOCKED |
| 2.6.5 | 16 | no (missing) | BLOCKED |
| 2.7.0 | 17 | yes | SUPPORTED |
| 2.8.0 | 18 | yes | SUPPORTED |

## What the backend enforces

- `app_version.discontinued()` blocks every build ≤ 16 regardless of the
  editable minimum. `before_request` returns `426` for `/api/proxy/`,
  `/api/download/`, `/api/episode-sources` and the rest of the protected API,
  with `status: "update_required"`, `reason: "discontinued"`, both official
  download links (Render and Cloudflare) and the minimum/latest versions.
- `/api/app/version` and `/api/app/ping` stay reachable so an old build learns
  it must update; the app shows **Version Discontinued** plus Update Now,
  official website and Cloudflare mirror buttons.
- Every refusal is written to `blocked_requests` (install id, version, code,
  path, reason) and summarised in the dashboard.
- Release status changes are owner-only; blocking a release newer than 2.6.5
  requires `confirm_block: true` and is written to `admin_audit`.
- Roles are stored server-side and normalized (`admin` → `owner`).
  Owner-only: release status, version policy, role changes, admin creation.
  Developer: read diagnostics, releases, security log. Support: read-only
  admin surfaces. Regular users get `403` on every `/api/admin/` route.
- Push runs record a campaign row with the measured targets/delivered/failed/
  pruned counts; no credentials means `available: 0`, never a claimed delivery.

## Verification performed

- `python -m pytest tests -q` (see the final test run in this session).
- `flutter test` and `flutter analyze` for the app update screen.
- `npm test` in `cloudflare/` for the worker.
- Static APK checks above; the release APK was rebuilt and re-hashed.

## Not verified / open

- No physical Android device was available, so the update screen and downloads
  were exercised by tests, not on hardware.
- FCM delivery could not be executed: no Firebase service account exists in this
  environment. Campaign accounting is tested with the provider unavailable.
- The signed APK was not deployed anywhere; publishing is left to the owner.
- No additional release newer than 2.6.5 was found unsafe, so none was blocked.
