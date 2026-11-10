# Shorebird OTA setup (CamAnime)

Shorebird ships **Dart-only** code changes over the air to installed apps. Native
changes (Gradle, manifests, plugins, Firebase config) still need a store/APK
release, so Shorebird sits *on top of* the existing Firebase FCM + Cloudflare
APK pipeline and changes neither of them.

## Status

| Step | State |
| --- | --- |
| Project inspected | ✅ Flutter app at `mobile/camanime_app`, no `shorebird.yaml` existed |
| Organization | ✅ `Kayefande-droid` (`organization_id: 62361`) |
| Existing app | ⚠️ None in the organization — app list is empty, so there is nothing to duplicate; one app record must be created (`POST /api/v1/apps` with the CI key still answers `403 organization_permission_denied`, re-checked 2026-11-11) |
| CI token (`SHOREBIRD_TOKEN`) | ✅ Valid — authenticated as role `developer` (release/patch only, cannot manage apps) |
| Personal API key | ❌ Rejected `401 user_unauthorized` — expired, revoked or mistyped; must be reissued (re-checked 2026-11-11) |
| GitHub secrets | ✅ `SHOREBIRD_TOKEN` and `SHOREBIRD_API_KEY` set on `kayefande-droid/CamAnime` (Actions secrets, never committed) |
| CI workflows | ✅ `.github/workflows/shorebird-release.yml`, `.github/workflows/shorebird-patch.yml` (manual `workflow_dispatch`) |
| `shorebird.yaml` | ⛔ Blocked: needs the `app_id` created in the console |
| Android build prerequisites | ✅ AndroidX enabled in `android/gradle.properties` (`android.useAndroidX=true`, `android.enableJetifier=true`) — required because the Flutter embedding, `androidx.work` and the Firebase BoM are all AndroidX |
| First release | ⛔ Not run — needs the app id, and the user's approval |
| Patch delivery test | ⛔ Needs a physical/emulated device with the release build installed |

## Credentials and where they live

Runtime secrets are in `mobile/camanime_app/.shorebird.env` (mode 600, git-ignored
via `**.shorebird.env`). Nothing is hardcoded in source and nothing is echoed in
logs.

```sh
# mobile/camanime_app/.shorebird.env
SHOREBIRD_API_KEY=sb_api_...      # console API key (currently invalid)
SHOREBIRD_CI_TOKEN=sb_api_...     # CI key, also stored as the GitHub Actions secret
```

GitHub Actions secrets on `kayefande-droid/CamAnime`:

| Secret | Used by |
| --- | --- |
| `SHOREBIRD_TOKEN` | both workflows (`shorebird` reads this env var automatically) |
| `SHOREBIRD_API_KEY` | available for scripts; not used by the workflows |

Rotate with:

```sh
gh secret set SHOREBIRD_TOKEN --repo kayefande-droid/CamAnime
```

> Both keys were pasted into chat, so treat them as exposed and rotate them in
> the console once the setup is verified.

## One-time linking (needs an owner/admin)

The CI key has the `developer` role, so it can create releases and patches but
**not** apps. Pick one:

1. **Console (simplest):** https://console.shorebird.dev → *CamAnime* →
   New app, name it `CamAnime`. Copy the `app_id`.
2. **Owner API key:** Account → API Keys → create with full access, then:

```sh
curl -sS -X POST https://api.shorebird.dev/api/v1/apps \
  -H "Authorization: Bearer $OWNER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"display_name":"CamAnime","organization_id":62361}'
```

Then write `mobile/camanime_app/shorebird.yaml` (committed — `app_id` is public
and is what links builds to the app):

```yaml
# yaml-language-server: $schema=https://raw.githubusercontent.com/shorebirdtech/shorebird/main/packages/shorebird_cli/assets/shorebird_yaml.schema.json
app_id: <APP_ID>
```

Verify the link without touching production:

```sh
SHOREBIRD_TOKEN=... shorebird apps list
SHOREBIRD_TOKEN=... shorebird releases list --app-id <APP_ID>
```

## CLI authentication

`shorebird` authenticates from `SHOREBIRD_TOKEN`; no interactive login is needed
in CI.

```sh
export SHOREBIRD_TOKEN="$(grep '^SHOREBIRD_CI_TOKEN=' .shorebird.env | cut -d= -f2-)"
shorebird --version
shorebird apps list
```

Interactive machines can instead run `shorebird login` (OAuth, 15-minute tokens
refreshed by the CLI).

### Windows note

Shorebird has no native Windows build; this host has WSL Ubuntu 2, which is the
supported path (`shorebird` installs under `~/.shorebird` inside WSL, roughly
2.2 GB). Linux CI runners avoid that cost entirely, which is why the workflows
above are the recommended way to produce releases and patches.

## Initial release (approval required)

This uploads Dart artifacts to Shorebird and produces a signed `.aab`/`.apk`.
It does **not** publish to Play or replace the Cloudflare-hosted APK.

```sh
cd mobile/camanime_app
shorebird release android            # or: gh workflow run shorebird-release.yml
```

- Run it once per new `version:` in `pubspec.yaml`; a patch can only target a
  release that already exists on the channel.
- The release version must match `version: 2.11.0+22` in `pubspec.yaml`.
- `--dry-run` builds and validates without uploading.

## Patch publishing (Dart-only)

```sh
cd mobile/camanime_app
shorebird patch android --release-version 2.11.0+22
# or: gh workflow run shorebird-patch.yml -f release-version=2.11.0+22
```

Patches are additive: fix only Dart code that existed in that release. Native,
asset, or plugin changes require a new release. `--dry-run` validates the patch
without publishing it.

## Testing patch delivery

1. Install the **release** build on a device (`adb install -r app-release.apk`).
2. Launch once, confirm the app reports its release version.
3. Publish a patch, then force-quit and relaunch the app; it downloads the patch
   on startup and applies it on the next launch.
4. Confirm the change is visible and `shorebird patches list` shows the install.

Verification needs a device or emulator; this environment has neither, so
delivery is untested.

## What must not change

- Firebase FCM: `android/app/google-services.json`, the Google Services Gradle
  plugin and the `camanime_updates` notification channel stay as they are.
- Cloudflare: `/api/version`, `/api/app/ping`, the R2-backed APK download and
  `version_gate.dart` are untouched. Shorebird does not serve the APK.
- Shorebird patches only Dart code, so the version gate and FCM behaviour do not
  change until a new release is published through the existing channel.
