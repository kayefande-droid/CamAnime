# CamAnime 2.8.0 — player, dashboard MFA and update push

Release build `2.8.0` (versionCode 18), minimum supported build unchanged at
`2.7.0` (17), so 2.7.x installs keep working while anything below 2.7.0 is
still refused with HTTP 426.

## Player

- Custom controls replace Chewie: tap the video to show Play/Pause, ±10s, Next
  Episode, a seek bar and a settings sheet; the overlay hides after four
  seconds of playback and stays while paused or finished.
- Next Episode resolves the following episode in the *selected* audio language
  before tearing anything down. It never jumps to another anime, shows a
  spinner while resolving, and reports "not available" with Retry.
- Auto Play Next (default on, also a switch in the player sheet) runs only when
  the episode actually reached its end. Duplicate triggers are guarded, the
  chain is capped at 30 episodes, and a failed resolution leaves the finished
  episode on screen with a retry.
- The mini-player no longer creates a second decoder. The full player hands its
  live controller to the bar and takes the same one back on reopen, so
  Pause/Resume, ±10 seconds and position are the same session in both places.

## Dashboard TOTP MFA

`mfa.py` implements RFC 6238 (SHA-1, 6 digits, 30s, one step of drift) and
RFC 4226 with the standard library only.

- `POST /api/admin/mfa/enroll` → pending secret + `otpauth://` URI
- `POST /api/admin/mfa/confirm` → activates, returns 8 single-use recovery codes
- `GET  /api/admin/mfa` → status (never the secret)
- `POST /api/admin/mfa/disable` → requires a current code

Once enabled, an admin password alone cannot create a session: `/login` renders
a code step and `/api/auth/login` returns `401` with `mfa_required: true` until
the code (or a recovery code) is accepted. A TOTP step can be used only once, so
a captured code cannot be replayed. Set `CAMANIME_ADMIN_MFA_REQUIRED=1` to
refuse admin sign-in entirely until the account enrols. Every enrolment,
activation, disable and policy change lands in the admin audit log.

## Converted (smaller) downloads

`transcode.py` re-encodes the resolved source on the server with ffmpeg, so the
same episode can be saved at a phone-friendly size:

| Saved file | Video | Audio | ~size, 24 min episode |
| --- | --- | --- | --- |
| Original | provider file | provider file | ~365 MB at 1080p |
| 720p | H.264 2000 kbps | AAC 128 kbps | ~360 MB |
| 480p | H.264 1100 kbps | AAC 96 kbps | ~200 MB |
| 360p | H.264 700 kbps | AAC 64 kbps | ~130 MB |

- Every episode bundle now lists 720p/480p/360p converted files for each real
  MP4/HLS source (`downloads[].transcode = true`), so all anime get them, not
  just titles whose provider happens to publish a 360p mirror.
- `GET /api/download/transcode?url=…&height=360` streams a fragmented MP4 to the
  client as ffmpeg produces it: no temporary file, no disk growth, and the
  download starts immediately. Output is capped with `min(height, ih)`, so a
  720p source is never upscaled.
- The watch page exposes this as a **Size: Original / 720p / 480p / 360p**
  selector beside Download, and the app's download sheet shows the converted
  files with their real quality labels.
- Limits: conversion needs the `ffmpeg` binary on the host (`CAMANIME_FFMPEG`
  overrides the path). Without it the endpoint answers 503 with
  `transcode_available: false` and the selector is hidden — no fake smaller
  file is ever advertised. Re-encoding is CPU-bound, so the route is rate
  limited to 6 requests / 10 min and is best on a host with ffmpeg installed
  (a plain Render Python service does not include it).

## Website: Cloudflare APK mirror

- The Cloudflare worker now serves `GET /get/android` from its own `ASSETS`
  binding (same `static/downloads/CamAnime.apk`), with
  `Content-Type: application/vnd.android.package-archive` and attachment
  filename, falling back to the Render `/get/android` when the asset is absent.
- `/download` shows that mirror as a second direct link plus a copyable URL, and
  `/api/version` on the worker advertises `/get/android`.
- Stale 2.7.0 copy on `/promo` is updated to 2.8.0 with the new release notes.

## Discontinued builds (2.6.5 and older)

Builds at or below `2.6.5` (versionCode 16) are retired, independently of the
editable minimum:

- `/api/app/version` and `/api/app/ping` return `required: true` plus
  `policy.discontinued: true`, the discontinued threshold and a distinct
  message, so the app can show **Version Discontinued** instead of the normal
  update prompt.
- Every protected route — `/api/proxy/`, `/api/download/` (including converted
  downloads), `/api/episode-sources`, `/api/v1/` — answers `426` for those
  builds, so streaming and downloading are actually blocked server-side.
- `/api/version` and `/api/app/version` stay reachable: that is how an old build
  learns it must update.

## Updates keep the offline library

- Downloads live in `getApplicationSupportDirectory()/camanime_downloads` and
  the queue index in `queue.json`; Android replaces only the APK on update, so
  both survive.
- On start the manager now re-adopts finished `.mp4`/`.m4v` files that the queue
  does not reference (missing or damaged index, legacy folder). An update, or a
  lost index, therefore cannot look like it wiped saved episodes: the files are
  never moved or deleted by this recovery, only listed again.
- A finished download is written to `queue.json` before it is announced as
  complete, and a reload that lands while `queue.json.tmp` is being renamed
  reads the pending file instead of reporting an empty library. The manifest's
  absolute-path handling was also fixed, so legacy-imported files are no longer
  marked "missing" after a refresh.
- Library tab labels gained `Flexible` + ellipsis after the 430dp phone test
  caught a 0.4px overflow in the empty state.

Final artifact: `mobile/apk/CamAnime-2.8.0.apk` (53,299,463 bytes, versionCode
18), sha256 in `mobile/apk/CamAnime-2.8.0.apk.sha256`.

## Update push (FCM HTTP v1)

`push.py` delivers a real OS notification to devices running a build below the
minimum, including when the app is closed. It signs an RS256 JWT with the
Firebase service account itself, exchanges it for an OAuth2 access token and
calls `POST /v1/projects/<id>/messages:send` per device. Delivered, failed and
pruned counts are measured, never assumed; tokens FCM reports as unregistered
are deleted.

Configuration (one of):

```
FCM_SERVICE_ACCOUNT_JSON='{"project_id": ..., "private_key": ...}'
FCM_SERVICE_ACCOUNT_FILE=/path/firebase-service-account.json
# or place firebase-service-account.json in the project root
```

Device tokens arrive at `POST /api/app/push-token` (and are removed with
`DELETE`), carrying the same install headers the version gate uses. Without
credentials the admin "Flag outdated devices" action still flags devices for
the blocking update screen and reports `push_available: false`, so it never
claims a delivery that did not happen.

**Device-side requirement:** the APK needs a Firebase project
(`google-services.json`) and the FCM token registration call to fully receive
these pushes. That project does not exist yet, so on-device delivery is
unverified; the server transport, token registry and delivery accounting are
covered by tests that run against a local FCM/Google stub.

## Verification performed

- `flutter analyze` → No issues found
- `python -m pytest tests -q` → all tests pass, including new `test_mfa.py`
  (RFC 6238 vectors, replay rejection, recovery codes, web + API login gates)
  and `test_push.py` (signed token exchange, delivery, dead-token pruning,
  admin notify end to end)
- `flutter build apk --release --obfuscate` → `versionCode='18'
  versionName='2.8.0'`

## Not verified here

- No physical Android device: touch behaviour, the mini-player handover and
  autoplay were not exercised on hardware.
- No Firebase project, so no real device ever received a push.
- No browser session drove the new dashboard MFA panel; its endpoints are
  covered by the test client only.
