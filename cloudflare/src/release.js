/**
 * Release policy — the one place these numbers live.
 *
 * Both the page/entry router (index.js) and the Android API (mobile.js) read
 * from here, so the update gate and the version endpoint can never disagree
 * again (they previously drifted: 2.9.0 vs 2.10.0 vs 2.11.0 in three files).
 *
 * Keep LATEST_* in step with `mobile/camanime_app/pubspec.yaml` and
 * `lib/core/version_gate.dart`.
 */
export const LATEST_VERSION = "2.14.0";
export const LATEST_BUILD = 27;

/** Builds below this cannot stream or download. */
export const MIN_SUPPORTED_VERSION = "2.9.0";
export const MIN_SUPPORTED_BUILD = 19;

/** Builds at or below this are retired outright. */
export const DISCONTINUED_VERSION = "2.7.0";
export const DISCONTINUED_BUILD = 17;

/** SHA-256 of the APK published at /get/android (static/downloads/CamAnime.apk). */
export const APK_SHA256 =
  "a7c5ec7ce93e67e59d7e9599c29ab329a24b8e3b6cb45a1ab46b229ad5387e86";

/** Download filename shown to users, so saved APKs are never ambiguous. */
export const APK_FILENAME = `CamAnime-${LATEST_VERSION}-build${LATEST_BUILD}.apk`;

export const RELEASE_NOTES =
  "Build 27: install fix (v2/v3 signing), version-stamped download filename, "
  "home redesign, sub/dub switching, device-delete, poster persistence, "
  "background notifications.";

export const RENDER_ORIGIN = "https://camanime.onrender.com";
export const WORKER_ORIGIN = "https://camanjme.camanime.workers.dev";

/**
 * Download links for the deployment answering this request.
 *
 * `cloudflare` is this worker's own mirror (R2, then the asset bundle, then a
 * Render redirect as a last resort); `render` stays documented as the
 * independent second host.
 */
export function downloadUrls(origin) {
  let base = String(origin || "").trim().replace(/\/+$/, "");
  if (!/^https?:\/\/[^/]+$/i.test(base)) base = WORKER_ORIGIN;
  return {
    render: `${RENDER_ORIGIN}/get/android`,
    cloudflare: `${base}/get/android`,
    primary: `${base}/get/android`,
  };
}

/**
 * The policy object the Android version gate parses
 * (`lib/core/version_gate.dart` → VersionPolicy.fromJson).
 */
export function releasePolicy(origin, build = null) {
  const urls = downloadUrls(origin);
  const known = Number.isFinite(build);
  const retired = known && build <= DISCONTINUED_BUILD;
  const unsupported = known && build < MIN_SUPPORTED_BUILD;
  return {
    status: "update_required",
    code: "APP_UPDATE_REQUIRED",
    reason: retired ? "discontinued" : unsupported ? "unsupported" : "ok",
    force_update: retired || unsupported,
    latest_version: LATEST_VERSION,
    latest_version_code: LATEST_BUILD,
    minimum_supported_version: MIN_SUPPORTED_VERSION,
    minimum_supported_version_code: MIN_SUPPORTED_BUILD,
    discontinued_at_or_below_version: DISCONTINUED_VERSION,
    discontinued_at_or_below_version_code: DISCONTINUED_BUILD,
    discontinued: retired,
    download_url: urls.primary,
    download_urls: urls,
    sha256: APK_SHA256,
    release_notes: RELEASE_NOTES,
    message: retired
      ? "CamAnime 2.7.0 and older are discontinued and can no longer stream "
        + "or download anime. Install the current CamAnime from the official "
        + "website to continue."
      : "Your CamAnime version is no longer supported. Please update from the "
        + "official website to continue.",
  };
}

/** True when a reported build must be refused. */
export function buildIsBlocked(build) {
  return Number.isFinite(build) && build < MIN_SUPPORTED_BUILD;
}
