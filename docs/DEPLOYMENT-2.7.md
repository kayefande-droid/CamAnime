# CamAnime 2.7 — deployment and rollback

## What ships

1. Backend: `app.py`, `app_version.py`, `camanime_platform.py`, `templates/admin.html`.
2. App: `mobile/camanime_app` sources + `mobile/apk/CamAnime-2.7.0.apk`.
3. Website: `static/downloads/CamAnime.apk` (served by `/get/android`),
   `templates/promo.html` and `cloudflare/src/mobile.js` version strings.

## Backend deploy (Render)

1. Push the commit; Render rebuilds from `requirements.txt` (no new Python
   dependency was added).
2. Schema is created lazily on first use: `version_policy`, `app_installs`,
   `admin_audit`. No manual migration is required, and an existing
   `camanime.db` keeps its data.
3. On a **fresh** database with no `CAMANIME_DEFAULT_ADMIN_PASSWORD`, the
   bootstrap writes `admin_bootstrap.txt` next to the SQLite file and logs the
   path. Sign in with those credentials, change the password, delete the file.
4. Confirm the deploy:

```bash
curl -s https://camanime.onrender.com/api/app/version | python -m json.tool
# policy.latest_version == "2.7.0", minimum_supported_version_code == 17
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'X-CamAnime-Version: 2.6.5' -H 'X-CamAnime-Build: 16' \
  https://camanime.onrender.com/api/v1/catalog/home   # -> 426
```

## Publishing a release from the dashboard

`/admin` → **Application version policy**:

- Set latest version + build code, minimum supported version + build code,
  official download URL, message and notes.
- Ticking **Force update** requires the confirmation dialog; the server also
  rejects `force_update` without `confirm_force_update`.
- **Flag outdated devices** marks every install below the minimum so the
  dashboard can count them. No push transport is configured, so it reports
  `push_available: false` and delivers nothing; those devices get the blocking
  update screen on their next request.
- **Roll back** restores the policy from before the last change. Every change is
  written to `admin_audit` and shown in the audit table.

## APK distribution

`/get/android` serves `static/downloads/CamAnime.apk`. The in-app updater and
the update screen both read their URL from the policy's `download_url`, so
changing the download host is a dashboard edit, not an app release.

## Signing — read before changing anything

All CamAnime builds so far are signed with the Android debug keystore, and
2.7.0 continues that so users can install over 2.6.x without uninstalling.
A private keystore is not configured for the build. Do **not** switch signing
keys inside a normal release: Android will refuse the update and every user must
uninstall (losing `Downloads/`, the in-app library and history). If you move to
a private key, announce a clean-install release first.

## Rollback

Version policy: use **Roll back** in the dashboard (audited), or POST
`/api/admin/version-policy` with the previous numbers. Lowering the latest build
code deliberately requires the rollback action, not a normal save.

Backend code: redeploy the previous commit. The version tables are additive, so
an older backend simply ignores them; the null-policy case falls back to
`APP_VERSION`/`/api/version` as before.

App: the previous APK remains valid; publish it as a new build code only if it
must supersede 2.7.0, otherwise re-point `download_url` at the old artifact.

## Verification checklist after deploy

- [ ] `/api/app/version` returns 2.7.0 / 17.
- [ ] Old build headers get 426; current build headers get 200.
- [ ] Plain browser requests to `/api/v1/catalog/home` still get 200.
- [ ] `/admin` loads as administrator, shows policy + audit, and 403s for a
      normal user.
- [ ] Streaming, downloads, comments and history work in the 2.7.0 APK.
- [ ] `sha256sum static/downloads/CamAnime.apk` matches
      `mobile/apk/CamAnime-2.7.0.apk.sha256`.
