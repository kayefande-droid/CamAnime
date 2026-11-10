/**
 * App lifecycle API: update manifest, remote configuration, device registry,
 * notification dispatch and release management.
 *
 * Every route here is additive — `/api/v1/catalog`, `/api/v1/search`,
 * `/api/v1/stream` and the rest of the existing contract are untouched.
 *
 * Public reads (update, config, version, releases) are cacheable and CORS-open.
 * Writes and admin reads require an admin session cookie; nothing here accepts
 * a key from a query string.
 */
import { json } from "./util.js";
import { currentUser, requireAdmin } from "./auth.js";
import { alData } from "./anilist.js";
import {
  APK_SHA256,
  LATEST_BUILD,
  LATEST_VERSION,
  MIN_SUPPORTED_BUILD,
  MIN_SUPPORTED_VERSION,
  RELEASE_NOTES,
  downloadUrls,
} from "./release.js";
import { buildMessage, fcmConfigured, sendToTokens } from "./push.js";

const now = () => Math.floor(Date.now() / 1000);

const TOPICS = [
  "all",
  "new_anime",
  "new_episodes",
  "dubbed",
  "subbed",
  "app_updates",
  "maintenance",
  "announcements",
];

const CATEGORIES = ["new_anime", "new_episodes", "dubbed", "subbed", "app_updates", "maintenance", "announcement"];

const CHANNELS = ["stable", "beta"];

/** Admin-editable configuration, merged over these safe defaults. */
export const DEFAULT_CONFIG = {
  maintenance: { enabled: false, message: "" },
  banner: { text: "", url: "", tone: "info" },
  featured_anime_id: "",
  min_supported_build: MIN_SUPPORTED_BUILD,
  recommended_build: LATEST_BUILD,
  update_notice: "",
  announcement: "",
  features: {
    streaming: true,
    downloads: true,
    offline_library: true,
    comments: true,
    trailer: true,
  },
};

const CORS = { "access-control-allow-origin": "*" };

function plainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/** Recursive merge that only accepts keys already present in `defaults`. */
export function mergeConfig(defaults, stored) {
  if (!plainObject(stored)) return structuredClone(defaults);
  const out = structuredClone(defaults);
  for (const [key, value] of Object.entries(stored)) {
    if (!(key in out)) continue;
    if (plainObject(out[key]) && plainObject(value)) {
      out[key] = mergeConfig(out[key], value);
    } else if (typeof value === typeof out[key] || out[key] === null) {
      out[key] = value;
    }
  }
  return out;
}

async function readBody(request) {
  const type = (request.headers.get("content-type") || "").toLowerCase();
  try {
    if (type.includes("application/json")) return await request.json();
    if (type.includes("form")) return Object.fromEntries((await request.formData()).entries());
    const text = await request.text();
    return text ? JSON.parse(text) : {};
  } catch {
    return {};
  }
}

async function audit(env, user, action, detail = "") {
  try {
    await env.DB.prepare(
      "INSERT INTO admin_audit (t, email, action, detail) VALUES (?1, ?2, ?3, ?4)",
    )
      .bind(now(), user?.email || "", action, String(detail).slice(0, 300))
      .run();
  } catch {
    // Auditing must never fail the action it records.
  }
}

/* ── per-isolate cheap rate limit (Cloudflare WAF rules remain the real guard) ── */
const hits = new Map();
function rateLimited(key, limit, windowSeconds) {
  const t = now();
  const bucket = hits.get(key);
  if (!bucket || t - bucket.start >= windowSeconds) {
    hits.set(key, { start: t, count: 1 });
    if (hits.size > 5000) hits.clear();
    return false;
  }
  bucket.count += 1;
  return bucket.count > limit;
}

function clientIp(request) {
  return request.headers.get("cf-connecting-ip") || "unknown";
}

/* ── update manifest ── */

export async function latestRelease(env, channel) {
  try {
    return await env.DB.prepare(
      "SELECT * FROM app_releases WHERE channel = ?1 AND published = 1 ORDER BY build DESC LIMIT 1",
    )
      .bind(channel)
      .first();
  } catch {
    return null;
  }
}

/**
 * GET /api/v1/app/update
 * Query: build (installed), channel, platform.
 */
export async function updateManifest(env, request, url) {
  const channel = CHANNELS.includes(String(url.searchParams.get("channel") || ""))
    ? String(url.searchParams.get("channel"))
    : "stable";
  const build = parseInt(url.searchParams.get("build") || request.headers.get("X-CamAnime-Build") || "", 10);
  const row = await latestRelease(env, channel);
  const urls = downloadUrls(url.origin);

  const latestBuild = row?.build ?? LATEST_BUILD;
  const version = row?.version ?? "2.11.0";
  const minBuild = row?.min_supported_build ?? MIN_SUPPORTED_BUILD;
  const known = Number.isFinite(build);

  const manifest = {
    api: "camanime-update",
    version: 1,
    channel,
    version_name: version,
    version_code: latestBuild,
    released: row?.released ?? 0,
    apk_url: row?.apk_url || urls.primary,
    apk_key: row?.apk_key || "",
    size: row?.size ?? 0,
    sha256: row?.sha256 || "",
    min_supported_build: minBuild,
    mandatory: Boolean(row?.mandatory),
    notes: row?.notes || RELEASE_NOTES,
    compatibility: row?.compatibility || "Android 7.0+",
    download_urls: urls,
    update_available: known ? latestBuild > build : false,
    update_required: known ? build < minBuild : false,
  };
  return json(manifest, 200, { ...CORS, "cache-control": "public, max-age=60" });
}

/** GET /api/v1/app/version — versioned alias of /api/version. */
export async function versionInfo(url) {
  const app = downloadUrls(url.origin);
  return json(
    {
      api: "camanime-version",
      version: 1,
      app_version: LATEST_VERSION,
      version_code: LATEST_BUILD,
      latest_version: LATEST_VERSION,
      latest_version_code: LATEST_BUILD,
      minimum_supported_version: MIN_SUPPORTED_VERSION,
      minimum_supported_version_code: MIN_SUPPORTED_BUILD,
      apk_url: app.cloudflare,
      download_url: "/get/android",
      sha256: APK_SHA256,
      whats_new: RELEASE_NOTES,
      platform: "cloudflare-workers",
      architecture: "workers+d1+r2",
    },
    200,
    { ...CORS, "cache-control": "public, max-age=60" },
  );
}

/* ── remote configuration ── */

export async function getConfig(env) {
  let stored = null;
  let updated = 0;
  try {
    const row = await env.DB.prepare("SELECT value, updated FROM remote_config WHERE key = 'app'").first();
    if (row) {
      updated = row.updated || 0;
      stored = JSON.parse(row.value);
    }
  } catch {
    stored = null;
  }
  return json(
    { config: mergeConfig(DEFAULT_CONFIG, stored), updated, source: stored ? "remote" : "defaults" },
    200,
    { ...CORS, "cache-control": "public, max-age=60" },
  );
}

export async function putConfig(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const body = await readBody(request);
  const incoming = plainObject(body?.config) ? body.config : body;
  const merged = mergeConfig(DEFAULT_CONFIG, incoming);
  const t = now();
  await env.DB.prepare(
    "INSERT INTO remote_config (key, value, updated, updated_by) VALUES ('app', ?1, ?2, ?3) " +
      "ON CONFLICT(key) DO UPDATE SET value = ?1, updated = ?2, updated_by = ?3",
  )
    .bind(JSON.stringify(merged), t, user.email)
    .run();
  await audit(env, user, "config.update", Object.keys(incoming || {}).join(","));
  return json({ ok: true, config: merged, updated: t });
}

/* ── device registry ── */

export async function registerDevice(env, request) {
  if (rateLimited(`reg:${clientIp(request)}`, 60, 60)) {
    return json({ error: "Too many registrations. Retry shortly." }, 429);
  }
  const body = await readBody(request);
  const installId = String(body.install_id || "").trim();
  if (!/^[A-Za-z0-9_-]{8,64}$/.test(installId)) {
    return json({ error: "install_id must be 8-64 chars (A-Z, 0-9, _ or -)." }, 400);
  }

  const token = String(body.token || "").trim();
  if (token.length > 4096) return json({ error: "token too long" }, 400);

  const appVersion = String(body.app_version || "").slice(0, 24);
  const appBuild = Math.max(0, parseInt(body.app_build, 10) || 0);
  const androidVersion = String(body.android_version || "").slice(0, 32);
  const language = String(body.language || "").slice(0, 16);
  const topics = Array.isArray(body.topics)
    ? body.topics.filter((t) => TOPICS.includes(String(t))).slice(0, TOPICS.length)
    : ["all"];
  const prefs = plainObject(body.prefs) ? body.prefs : {};

  const t = now();
  await env.DB.prepare(
    "INSERT INTO devices (install_id, token, platform, app_version, app_build, android_version, language, prefs, topics, created, updated) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?10) " +
      "ON CONFLICT(install_id) DO UPDATE SET token = ?2, platform = ?3, app_version = ?4, app_build = ?5, " +
      "android_version = ?6, language = ?7, prefs = ?8, topics = ?9, updated = ?10",
  )
    .bind(
      installId,
      token,
      String(body.platform || "android").slice(0, 16),
      appVersion,
      appBuild,
      androidVersion,
      language,
      JSON.stringify(prefs),
      JSON.stringify(topics),
      t,
    )
    .run();

  return json({ ok: true, install_id: installId, topics, push_configured: fcmConfigured(env), updated: t });
}

export async function unregisterDevice(env, request) {
  const body = await readBody(request);
  const installId = String(body.install_id || "").trim();
  if (!installId) return json({ error: "install_id required" }, 400);
  // Keep the row (history/preferences) but stop delivering to this install.
  await env.DB.prepare("UPDATE devices SET token = '', updated = ?1 WHERE install_id = ?2")
    .bind(now(), installId)
    .run();
  return json({ ok: true });
}

async function audience(env, target, targetValue) {
  const fresh = now() - 90 * 86400;
  if (target === "device") {
    const row = await env.DB.prepare(
      "SELECT token FROM devices WHERE install_id = ?1 AND token != ''",
    )
      .bind(String(targetValue || ""))
      .first();
    return row?.token ? [row.token] : [];
  }
  if (target === "version") {
    const min = Math.max(0, parseInt(targetValue, 10) || 0);
    const rows = await env.DB.prepare(
      "SELECT token FROM devices WHERE token != '' AND updated >= ?1 AND app_build >= ?2",
    )
      .bind(fresh, min)
      .all();
    return (rows.results || []).map((r) => r.token);
  }
  if (target === "topic") {
    const topic = String(targetValue || "all");
    const rows = await env.DB.prepare(
      "SELECT token, topics FROM devices WHERE token != '' AND updated >= ?1",
    )
      .bind(fresh)
      .all();
    return (rows.results || [])
      .filter((r) => {
        try {
          return JSON.parse(r.topics || "[]").includes(topic);
        } catch {
          return false;
        }
      })
      .map((r) => r.token);
  }
  const rows = await env.DB.prepare(
    "SELECT token FROM devices WHERE token != '' AND updated >= ?1",
  )
    .bind(fresh)
    .all();
  return (rows.results || []).map((r) => r.token);
}

async function pruneDead(env, tokens) {
  if (!tokens.length) return;
  for (let i = 0; i < tokens.length; i += 40) {
    const batch = tokens.slice(i, i + 40);
    const marks = batch.map(() => "?").join(",");
    await env.DB.prepare(`UPDATE devices SET token = '' WHERE token IN (${marks})`)
      .bind(...batch)
      .run()
      .catch(() => {});
  }
}

/* ── notifications ── */

export async function sendNotification(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  if (rateLimited(`send:${user.email}`, 20, 60)) {
    return json({ error: "Too many sends. Wait a minute." }, 429);
  }

  const body = await readBody(request);
  const title = String(body.title || "").trim().slice(0, 120);
  const text = String(body.body || body.message || "").trim().slice(0, 500);
  if (!title || !text) return json({ error: "title and body are required" }, 400);

  const target = ["all", "topic", "device", "version"].includes(String(body.target))
    ? String(body.target)
    : "all";
  const targetValue = String(body.target_value || (target === "topic" ? "all" : "")).slice(0, 64);
  const category = CATEGORIES.includes(String(body.category)) ? String(body.category) : "announcement";
  const channel = CHANNELS.includes(String(body.channel)) ? String(body.channel) : "stable";
  const image = String(body.image || "").trim();
  if (image && !/^https:\/\//i.test(image)) return json({ error: "image must be an https URL" }, 400);

  const deepLink = String(body.deep_link || "").slice(0, 300);
  const action = String(body.action || "").slice(0, 40);
  const id = crypto.randomUUID();
  const t = now();

  const result = await deliverNotification(
    env,
    { id, title, body: text, image, action, deep_link: deepLink, category, target, target_value: targetValue, channel },
    user.email,
  );
  if (result.error) return json({ error: result.error }, 500);

  await audit(env, user, "notifications.send", `${category}/${target}:${result.sent} sent`);
  return json({ ok: true, ...result }, 200);
}

/**
 * Resolve the audience, send through FCM, prune dead tokens and write the log
 * row. Shared by manual sends and the hourly digest so both behave identically.
 */
async function deliverNotification(env, n, author) {
  let tokens = [];
  try {
    tokens = await audience(env, n.target, n.target_value);
  } catch (err) {
    return { error: "Device lookup failed.", detail: String(err.message).slice(0, 120) };
  }

  const message = buildMessage(n);
  let result = { configured: fcmConfigured(env), attempted: 0, sent: 0, failed: 0, dead: [], errors: [], reason: undefined };
  if (fcmConfigured(env)) {
    result = await sendToTokens(env, tokens, message);
    await pruneDead(env, result.dead || []);
  } else {
    result.attempted = tokens.length;
    result.reason = "FCM is not configured on this deployment.";
  }

  const status = fcmConfigured(env)
    ? (result.failed > 0 && result.sent === 0 ? "failed" : "sent")
    : "not_configured";
  await env.DB.prepare(
    "INSERT INTO notification_log (id,title,body,image,action,deep_link,category,target,target_value,channel,status,scheduled_at,sent,failed,error,author,created) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,0,?12,?13,?14,?15,?16)",
  )
    .bind(
      n.id, n.title, n.body, n.image || "", n.action || "", n.deep_link || "", n.category, n.target,
      n.target_value || "", n.channel || "stable", status, result.sent, result.failed,
      (result.errors?.[0]?.reason || result.reason || "").slice(0, 200), author, now(),
    )
    .run();

  return {
    id: n.id,
    status,
    configured: result.configured,
    audience: tokens.length,
    sent: result.sent,
    failed: result.failed,
    pruned: (result.dead || []).length,
    errors: result.errors || [],
    reason: result.reason,
  };
}

export async function notificationHistory(env, request) {
  const { denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const rows = await env.DB.prepare(
    "SELECT id,title,body,category,target,target_value,status,sent,failed,error,author,created FROM notification_log ORDER BY created DESC LIMIT 50",
  ).all();
  return json({ history: rows.results || [], push_configured: fcmConfigured(env) }, 200, { "cache-control": "no-store" });
}

export async function cancelNotification(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const body = await readBody(request);
  const id = String(body.id || "").trim();
  if (!id) return json({ error: "id required" }, 400);
  const res = await env.DB.prepare(
    "UPDATE notification_log SET status = 'cancelled' WHERE id = ?1 AND status = 'scheduled'",
  )
    .bind(id)
    .run();
  await audit(env, user, "notifications.cancel", id);
  return json({ ok: true, cancelled: res.meta?.changes || 0 });
}

/* ── releases ── */

export async function listReleases(env, request, url) {
  const isAdmin = Boolean((await currentUser(env, request))?.role === "admin");
  const channel = CHANNELS.includes(String(url.searchParams.get("channel") || ""))
    ? String(url.searchParams.get("channel"))
    : "";
  const rows = await env.DB.prepare(
    "SELECT version,channel,build,released,apk_key,size,sha256,min_supported_build,mandatory,notes,compatibility,published,created " +
      "FROM app_releases WHERE (?1 = '' OR channel = ?1) AND (published = 1 OR ?2 = 1) ORDER BY build DESC LIMIT 50",
  )
    .bind(channel, isAdmin ? 1 : 0)
    .all();
  return json({ releases: rows.results || [], channels: CHANNELS }, 200, { ...CORS, "cache-control": "public, max-age=60" });
}

export async function publishRelease(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const body = await readBody(request);

  const version = String(body.version || "").trim();
  const build = parseInt(body.build, 10);
  if (!/^\d+\.\d+\.\d+$/.test(version)) return json({ error: "version must look like 2.12.0" }, 400);
  if (!Number.isFinite(build) || build <= 0) return json({ error: "build must be a positive integer" }, 400);

  const channel = CHANNELS.includes(String(body.channel)) ? String(body.channel) : "stable";
  const sha256 = String(body.sha256 || "").trim().toLowerCase();
  if (sha256 && !/^[0-9a-f]{64}$/.test(sha256)) return json({ error: "sha256 must be 64 hex chars" }, 400);

  const t = now();
  await env.DB.prepare(
    "INSERT INTO app_releases (version,channel,build,released,apk_key,apk_url,size,sha256,min_supported_build,mandatory,notes,compatibility,published,created) " +
      "VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14) " +
      "ON CONFLICT(version,channel) DO UPDATE SET build=?3, released=?4, apk_key=?5, apk_url=?6, size=?7, sha256=?8, " +
      "min_supported_build=?9, mandatory=?10, notes=?11, compatibility=?12, published=?13",
  )
    .bind(
      version,
      channel,
      build,
      parseInt(body.released, 10) || t,
      String(body.apk_key || "").slice(0, 200),
      String(body.apk_url || "").slice(0, 400),
      Math.max(0, parseInt(body.size, 10) || 0),
      sha256,
      Math.max(0, parseInt(body.min_supported_build, 10) || MIN_SUPPORTED_BUILD),
      body.mandatory ? 1 : 0,
      String(body.notes || "").slice(0, 2000),
      String(body.compatibility || "").slice(0, 200),
      body.published === false ? 0 : 1,
      t,
    )
    .run();
  await audit(env, user, "releases.publish", `${channel}/${version}+${build}`);
  return json({ ok: true, version, channel, build });
}

/* ── quota / usage monitor ── */

export async function usageSummary(env, request) {
  const { denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const dayAgo = now() - 86400;
  const monthAgo = now() - 30 * 86400;

  const [devices, withToken, notif24, notif30, releases, counters] = await Promise.all([
    env.DB.prepare("SELECT COUNT(*) n FROM devices").first(),
    env.DB.prepare("SELECT COUNT(*) n FROM devices WHERE token != ''").first(),
    env.DB.prepare("SELECT COALESCE(SUM(sent),0) s FROM notification_log WHERE created >= ?1").bind(dayAgo).first(),
    env.DB.prepare("SELECT COALESCE(SUM(sent),0) s FROM notification_log WHERE created >= ?1").bind(monthAgo).first(),
    env.DB.prepare("SELECT COUNT(*) n FROM app_releases").first(),
    env.DB.prepare("SELECT key, value FROM counters").all(),
  ]);

  return json(
    {
      devices: { total: devices?.n ?? 0, push_enabled: withToken?.n ?? 0 },
      notifications: { last_24h: notif24?.s ?? 0, last_30d: notif30?.s ?? 0 },
      releases: releases?.n ?? 0,
      counters: Object.fromEntries((counters.results || []).map((r) => [r.key, r.value])),
      push_configured: fcmConfigured(env),
      r2_configured: Boolean(env.FILES),
      notes: [
        "FCM has no published request quota on the free Spark plan; delivery is best-effort.",
        "Workers free tier: 100,000 requests/day. D1 free tier: 5M rows read, 100k rows written per day.",
        "R2 free tier: 10 GB-month storage, 1M Class A and 10M Class B operations per month (once activated).",
      ],
    },
    200,
    { "cache-control": "no-store" },
  );
}

/* ── hourly new-episode digest (Cloudflare Cron Trigger) ── */

/**
 * Admin-editable digest settings. Hourly by default, but a run is skipped
 * whenever nothing has aired, so the app is never spammed with empty notices.
 */
export const DIGEST_DEFAULTS = {
  enabled: true,
  topic: "new_episodes",
  max_items: 5,
  min_interval_minutes: 55,
  // 02:00-05:59 UTC: no push at 3am local for most of the audience.
  quiet_hours_utc: [2, 3, 4, 5],
};

export async function digestConfig(env) {
  try {
    const row = await env.DB.prepare(
      "SELECT value FROM remote_config WHERE key = 'digest'",
    ).first();
    if (row) return mergeConfig(DIGEST_DEFAULTS, JSON.parse(row.value));
  } catch {
    // Fall through to defaults.
  }
  return { ...DIGEST_DEFAULTS };
}

const AIRING_QUERY = `query($from:Int,$to:Int){
  Page(perPage:24){
    airingSchedules(airingAt_greater:$from,airingAt_lesser:$to,sort:TIME_DESC){
      episode
      airingAt
      media { id isAdult title { english romaji } coverImage { large } }
    }
  }
}`;

/** AniList airing rows -> digest items (adult titles and blanks dropped). */
export function buildDigestItems(data, max = 5) {
  return (data?.Page?.airingSchedules || [])
    .filter((s) => s?.media && !s.media.isAdult && s.episode)
    .map((s) => ({
      id: String(s.media.id),
      episode: Number(s.episode),
      title: s.media.title?.english || s.media.title?.romaji || "Anime",
      image: s.media.coverImage?.large || "",
    }))
    .slice(0, Math.max(1, max));
}

/** Title/body for a list of digest items. */
export function digestMessage(items) {
  if (!items.length) return null;
  const title = items.length === 1
    ? `${items[0].title} EP ${items[0].episode} is out`
    : `${items.length} new episodes just aired`;
  const body = items.map((i) => `${i.title} EP ${i.episode}`).join(" · ").slice(0, 480);
  return { title, body };
}

/**
 * Cron entry point. Called by the Worker's `scheduled` handler every hour.
 * Never throws; every skip reason is reported in the returned object so the
 * Worker log explains why nothing was sent.
 */
export async function hourlyDigest(env, options = {}) {
  const nowMs = options.nowMs ?? Date.now();
  const cfg = await digestConfig(env);
  if (!cfg.enabled) return { skipped: "disabled" };

  const hour = new Date(nowMs).getUTCHours();
  if ((cfg.quiet_hours_utc || []).includes(hour)) return { skipped: "quiet_hours" };

  // Without FCM a run can only write a dead log row, so skip it entirely.
  if (!fcmConfigured(env)) return { skipped: "fcm_not_configured" };

  const now = Math.floor(nowMs / 1000);
  try {
    const last = await env.DB.prepare(
      "SELECT created FROM notification_log WHERE category = 'new_episodes' AND author = 'cron' ORDER BY created DESC LIMIT 1",
    ).first();
    if (last && now - last.created < (cfg.min_interval_minutes || 55) * 60) {
      return { skipped: "too_soon" };
    }
  } catch {
    // A missing log table must not stop the first run.
  }

  let data;
  try {
    data = await alData(AIRING_QUERY, { from: now - 3600, to: now });
  } catch {
    return { skipped: "anilist_unavailable" };
  }

  const items = buildDigestItems(data, cfg.max_items);
  const message = digestMessage(items);
  if (!message) return { skipped: "nothing_airing" };

  const result = await deliverNotification(
    env,
    {
      id: crypto.randomUUID(),
      title: message.title,
      body: message.body,
      image: items[0].image,
      action: "",
      deep_link: `/watch/${items[0].id}/${items[0].episode}`,
      category: "new_episodes",
      target: "topic",
      target_value: cfg.topic || "new_episodes",
      channel: "stable",
    },
    "cron",
  );
  return { skipped: null, items: items.length, ...result };
}

/* ── router ── */

/**
 * Returns a Response for `/api/v1/app/*`, `/api/v1/devices/*`,
 * `/api/v1/notifications/*` and `/api/v1/releases*`, else null.
 */
export async function route(env, request, url, parts) {
  // NOT "p1 = api/v1/releases" — parts are [api, v1, releases, publish], so
  // releases lives at p2 once the /api/v1 prefix is present.
  const [, p1, p2, p3] = parts;
  const method = request.method;

  if (p1 === "releases") {
    if (method === "GET") return listReleases(env, request, url);
    if (method === "POST") return publishRelease(env, request);
    if (method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    return null;
  }

  if (p1 !== "v1") return null;

  if (p2 === "releases") {
    if (method === "GET") return listReleases(env, request, url);
    if (method === "POST") return publishRelease(env, request);
    if (method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    return null;
  }

  if (p2 === "app") {
    if (method === "GET" && p3 === "update") return updateManifest(env, request, url);
    if (method === "GET" && p3 === "version") return versionInfo(url);
    if (method === "GET" && p3 === "config") return getConfig(env);
    if ((method === "POST" || method === "PUT") && p3 === "config") return putConfig(env, request);
    if (method === "GET" && p3 === "usage") return usageSummary(env, request);
    return null;
  }

  if (p2 === "devices") {
    if (method === "POST" && p3 === "register") return registerDevice(env, request);
    if (method === "POST" && p3 === "unregister") return unregisterDevice(env, request);
    return null;
  }

  if (p2 === "notifications") {
    if (method === "GET" && p3 === "history") return notificationHistory(env, request);
    if (method === "POST" && p3 === "send") return sendNotification(env, request);
    if (method === "POST" && p3 === "cancel") return cancelNotification(env, request);
    return null;
  }

  return null;
}

export const allowedTopics = TOPICS;
export const allowedCategories = CATEGORIES;
