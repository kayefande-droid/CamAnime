# CamAnime — notifications, remote config and APK releases

Everything below is implemented in the repository and runs on the existing
Cloudflare Worker (`cloudflare/`) and the existing Flutter app. The external
accounts are the only parts that need manual activation; each section states
exactly what is missing.

## What exists now

### Worker API (all additive — existing routes untouched)

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/api/v1/app/update?build=22&channel=stable` | public | APK release manifest |
| GET | `/api/v1/app/version` | public | version numbers + APK URL + SHA-256 |
| GET | `/api/v1/app/config` | public | remote configuration (safe defaults) |
| PUT | `/api/v1/app/config` | admin | save remote configuration |
| GET | `/api/v1/app/usage` | admin | devices, sends, quota notes |
| POST | `/api/v1/devices/register` | public | upsert install + FCM token + topics |
| POST | `/api/v1/devices/unregister` | public | stop delivery for one install |
| POST | `/api/v1/notifications/send` | admin | send immediately |
| GET | `/api/v1/notifications/history` | admin | last 50 sends |
| POST | `/api/v1/notifications/cancel` | admin | cancel a scheduled send |
| — | Cron `0 * * * *` | — | hourly new-episode digest (see below) |
| GET | `/api/v1/releases?channel=stable` | public | published releases |
| POST | `/api/v1/releases/publish` | admin | publish/update a release |
| GET | `/api/version` | public | updater metadata (`app_version`, `apk_url`, `sha256`, `whats_new`) |
| GET | `/api/app/ping` | public | version gate polled by the app (200 / 426) |

Admin routes use the existing D1 session cookie (`ca_session`) and require
`users.role = 'admin'`. No key is ever accepted from a query string.

### Hourly notification scheduler (works with the app closed)

A Cloudflare **Cron Trigger** (`"0 * * * *"` in `wrangler.jsonc`) calls the
Worker's `scheduled` handler, which runs `hourlyDigest()`:

1. reads the `digest` settings from `remote_config` (defaults below),
2. skips quiet hours (02:00-05:59 UTC by default) and anything less than 55
   minutes after the previous automatic send,
3. asks AniList for episodes that aired in the last hour, then sends **only if
   something actually aired** — no empty "check the app" spam,
4. pushes to devices subscribed to the `new_episodes` topic through FCM, which
   arrives on phones with the app closed or the screen off.

Defaults (`DIGEST_DEFAULTS` in `src/appapi.js`):

```json
{ "enabled": true, "topic": "new_episodes", "max_items": 5,
  "min_interval_minutes": 55, "quiet_hours_utc": [2, 3, 4, 5] }
```

Override any of those by storing a `digest` row in `remote_config`. Until FCM is
configured the job returns `{ "skipped": "fcm_not_configured" }` without making
a single outbound request.

### Dashboard

The existing private admin page (`ADMIN_PATH`) now also contains:

- a **push composer** (title, message, image, deep link, category, target),
- **recent sends** with delivered/failed counts,
- **app releases** table plus a publish form,
- **remote configuration** (maintenance mode, banner, update notice, featured id).

Set `ADMIN_PATH` (e.g. `/panel`) as a Worker variable to expose it; empty means
404, matching the Render origin's `CAMANIME_ADMIN_PATH` policy.

### Data (D1, migration `0003_app_updates`)

`devices`, `notification_log`, `app_releases`, `remote_config`, `admin_audit`.

### Flutter

| File | Role |
| --- | --- |
| `lib/core/push.dart` | FCM init, permission, token refresh, device registration, topic opt-in/out, notification tap → `pendingLink` |
| `lib/core/app_config.dart` | `RemoteConfig` (safe defaults + refresh) and `UpdateManifest.fetch()` |
| `lib/main.dart` | starts both services, refreshes config on resume, opens `/watch/<id>/<ep>` or `/anime/<id>` on tap |

A build without Firebase configuration logs a line and stays fully usable; the
server just sees no push token for that install.

## Manual steps still required

### 1. Firebase (client done, server key still needed)

The **client** side is committed: `android/app/google-services.json`
(project `camanime-9f457`, package `com.camanime.app`), the Google Services
plugin `4.5.0`, Firebase BoM `35.1.0`, and `FirebaseBoot.init()` awaited before
`runApp()`. Messaging, Analytics and the optional Auth/Firestore layers are all
wired. What is still missing is the **server** side, which needs a private key
that must never live in the APK:

1. Cloudflare → Worker `camanjme` → Settings → Variables:
   - `FCM_PROJECT_ID` = the project id (not secret)
5. Cloudflare → Worker secrets:
   - `FCM_SERVICE_ACCOUNT` = the full service-account JSON (Project settings →
     Service accounts → Generate new private key)
   Never commit that file. The worker only reads it, signs a JWT, and never
   returns or logs it.
6. Verify: send a test from the dashboard. With a device registered the
   response reports `sent >= 1`; without FCM configured it reports
   `status: "not_configured"` and still records the send.

### 2. Cloudflare R2 (blocking for the APK mirror)

`GET /api/v1/app/update` and `/get/android` work today through the asset bundle
and the Render redirect. R2 raises the storage and lets the worker serve the
51 MB APK itself with HTTP Range.

1. Enable R2 in the dashboard (the API answers *"Please enable R2 through the
   Cloudflare Dashboard"* until then).
2. Create the bucket and restore the binding:
   ```jsonc
   "r2_buckets": [{ "binding": "FILES", "bucket_name": "camanime-files" }]
   ```
3. Upload the APK:
   ```bash
   npx wrangler r2 object put camanime-files/downloads/CamAnime.apk \
     --file=../static/downloads/CamAnime.apk \
     --content-type=application/vnd.android.package-archive
   ```
4. The SHA-256 in `cloudflare/src/release.js` must match that file, or the
   in-app updater will (correctly) refuse the download.

### 3. Shorebird (Dart-only OTA)

See [`shorebird.md`](shorebird.md) for the current, detailed state. Short
version: the CI token is valid and the GitHub workflows exist, but the app record
still has to be created in the console before `shorebird.yaml` can be written.
Shorebird patches only Dart code; native
Kotlin, plugins, permissions and the Flutter engine still need a full APK.

```bash
curl --proto '=https' --tlsv1.2 https://raw.githubusercontent.com/shorebirdtech/install/main/install.sh -sSf | bash
shorebird login                 # opens the official OAuth page
cd mobile/camanime_app
shorebird init                  # writes shorebird.yaml
shorebird release android       # first full release
shorebird patch android         # Dart-only patch afterwards
```

Use `shorebird patch android --staging` (or a percentage rollout in the
dashboard) before promoting a patch to everyone.

### 4. Cloudflare deploy

The published worker is still the retired Render proxy. Before deploying:

- the API token in use is **read-only** (D1 create answers *Authentication
  error*, R2 is disabled) — a token with **Workers Scripts: Edit** and
  **D1: Edit** is required;
- `wrangler.jsonc` needs the real `database_id` from `wrangler d1 create camanime`;
- then `npm run deploy` (its preflight refuses a placeholder id).

## Quota notes

| Service | Free allowance | What happens at the limit |
| --- | --- | --- |
| Workers | 100,000 requests/day | 429 from Cloudflare; the app keeps its cached catalogue |
| D1 | 5M rows read, 100k rows written/day | writes fail; reads and streaming continue |
| FCM | no published request quota (Spark) | delivery is best-effort; failures are logged |
| R2 | 10 GB-month, 1M Class A / 10M Class B ops | downloads fall back to Render |

Nothing here enables a paid plan automatically.

## Rollback

- Backend: `git checkout -- cloudflare/` and redeploy; migration 0003 only adds
  tables, so it is safe to leave in place.
- App: install the previous APK; nothing in this change alters the signing key,
  the package id or any existing API contract.
