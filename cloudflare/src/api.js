/** CamAnime edge API: community, library/history, counters, announcements, admin, downloads, streaming proxy. */
import { json, parseByteRange } from "./util.js";
import { currentUser, requireAdmin } from "./auth.js";

const time = () => Math.floor(Date.now() / 1000);

async function readJson(request) {
  try {
    return await request.json();
  } catch {
    return {};
  }
}

export async function bumpVisit(env) {
  try {
    await env.DB.prepare(
      "INSERT INTO counters (key,value) VALUES ('visits',1) ON CONFLICT(key) DO UPDATE SET value = value + 1"
    ).run();
  } catch {}
}

/* ── play/use tracking (public counter = real player starts) ── */
export async function track(env, request) {
  const form = request.method === "POST" ? Object.fromEntries((await request.formData().catch(() => new FormData())).entries()) : {};
  const kind = String(form.kind || "visit");
  const animeId = String(form.anime_id || "");
  const ep = String(form.ep || "");
  await env.DB.prepare("INSERT INTO events (t, kind, anime_id, ep) VALUES (?1, ?2, ?3, ?4)")
    .bind(time(), kind, animeId, ep).run();
  if (kind === "play") {
    await env.DB.prepare(
      "INSERT INTO counters (key,value) VALUES ('player_starts',1) ON CONFLICT(key) DO UPDATE SET value = value + 1"
    ).run();
  }
  return json({ ok: true });
}

export async function counters(env) {
  const rows = await env.DB.prepare("SELECT key, value FROM counters").all();
  return json(Object.fromEntries(rows.results.map((r) => [r.key, r.value])));
}

/* ── community: comments + ratings ── */
export async function getComments(env, request, animeId, ep) {
  const rows = await env.DB.prepare(
    "SELECT id, anime_id, ep, email, username, text, parent, sticker, likes, liked_by, t FROM comments WHERE anime_id = ?1 AND ep = ?2 ORDER BY t DESC LIMIT 200"
  ).bind(String(animeId), String(ep)).all();
  const user = await currentUser(env, request);
  const mine = user ? rows.results.filter((r) => r.email === user.email) : [];
  return json({ comments: rows.results, mine: mine.map((r) => r.id), user: user ? { name: user.name } : null });
}

export async function postComment(env, request, animeId, ep) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in to comment." }, 401);
  const body = await readJson(request);
  const anon = body.guest_name && String(body.guest_name).trim() ? String(body.guest_name).trim().slice(0, 24) : user.name;
  const id = crypto.randomUUID();
  await env.DB.prepare(
    "INSERT INTO comments (id, anime_id, ep, email, username, text, parent, sticker, likes, liked_by, t) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,0,'[]',?9)"
  ).bind(id, String(animeId), String(ep), user.email, anon, String(body.text || "").slice(0, 1000),
    String(body.parent || ""), String(body.sticker || ""), time()).run();
  return json({ ok: true, id });
}

export async function rate(env, request, animeId) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in to rate." }, 401);
  const body = await readJson(request);
  const score = Math.max(1, Math.min(10, parseInt(body.score, 10) || 0));
  await env.DB.prepare(
    "INSERT INTO ratings (anime_id, email, score, t) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(anime_id, email) DO UPDATE SET score = ?3, t = ?4"
  ).bind(String(animeId), user.email, score, time()).run();
  const avg = await env.DB.prepare("SELECT AVG(score) a, COUNT(*) n FROM ratings WHERE anime_id = ?1").bind(String(animeId)).first();
  return json({ ok: true, average: Math.round((avg?.a ?? 0) * 10) / 10, count: avg?.n ?? 0, score });
}

export async function ratingSummary(env, request, animeId) {
  const avg = await env.DB.prepare("SELECT AVG(score) a, COUNT(*) n FROM ratings WHERE anime_id = ?1").bind(String(animeId)).first();
  const user = await currentUser(env, request);
  let mine = null;
  if (user) {
    const row = await env.DB.prepare("SELECT score FROM ratings WHERE anime_id = ?1 AND email = ?2").bind(String(animeId), user.email).first();
    mine = row ? row.score : null;
  }
  return json({ average: Math.round((avg?.a ?? 0) * 10) / 10, count: avg?.n ?? 0, mine });
}

/* ── library: history (server-side resume across devices) ── */
export async function historyGet(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ history: [] });
  const rows = await env.DB.prepare(
    "SELECT anime_id, ep, position, duration, title, image, t FROM user_history WHERE email = ?1 ORDER BY t DESC LIMIT 120"
  ).bind(user.email).all();
  return json({ history: rows.results });
}

export async function historyPost(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in for cross-device resume." }, 401);
  const body = await readJson(request);
  const animeId = parseInt(body.anime_id, 10);
  if (!animeId) return json({ error: "anime_id required" }, 400);
  const ep = Math.max(1, parseInt(body.ep, 10) || 1);
  const position = Number(body.position) || 0;
  const duration = Number(body.duration) || 0;
  const title = String(body.title || "");
  const image = String(body.image || "");
  const t = time();
  await env.DB.prepare(
    "INSERT INTO user_history (email,anime_id,ep,position,duration,title,image,t) VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " +
    "ON CONFLICT(email, anime_id) DO UPDATE SET ep = ?3, position = ?4, duration = ?5, title = ?6, image = ?7, t = ?8"
  ).bind(user.email, animeId, ep, position, duration, title, image, t).run();
  return json({ ok: true });
}

/* ── notifications + announcements ── */
export async function notifications(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ notifications: [] });
  const rows = await env.DB.prepare(
    "SELECT id, text, read, t FROM notifications WHERE email = ?1 ORDER BY t DESC LIMIT 50"
  ).bind(user.email).all();
  return json({ notifications: rows.results });
}

export async function notificationsRead(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in first." }, 401);
  await env.DB.prepare("UPDATE notifications SET read = 1 WHERE email = ?1").bind(user.email).run();
  return json({ ok: true });
}

export async function announcements(env) {
  const rows = await env.DB.prepare("SELECT id, title, body, author, t FROM announcements ORDER BY t DESC LIMIT 20").all();
  return json({ announcements: rows.results });
}

/* ── admin: dashboard data + announcement publish + R2 upload ── */
export async function adminData(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const [users, events, countRows] = await Promise.all([
    env.DB.prepare("SELECT email, name, role, created FROM users ORDER BY created DESC LIMIT 100").all(),
    env.DB.prepare("SELECT kind, COUNT(*) n FROM events GROUP BY kind ORDER BY n DESC").all(),
    env.DB.prepare("SELECT key, value FROM counters").all(),
  ]);
  return json({
    users: users.results,
    events: events.results,
    counters: Object.fromEntries(countRows.results.map((r) => [r.key, r.value])),
    actor: user.email,
  });
}

export async function announcementPost(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  const body = await readJson(request);
  const id = crypto.randomUUID();
  const t = time();
  await env.DB.prepare("INSERT INTO announcements (id, title, body, author, t) VALUES (?1, ?2, ?3, ?4, ?5)")
    .bind(id, String(body.title || "").slice(0, 120), String(body.body || "").slice(0, 2000), user.name, t).run();
  await env.DB.prepare("INSERT INTO notifications (id, email, text, read, t) SELECT ?1, email, ?2, 0, ?3 FROM users")
    .bind(crypto.randomUUID(), `Announcement: ${String(body.title || "")}`.slice(0, 200), t).run();
  return json({ ok: true, id });
}

export async function uploadFile(env, request) {
  const { user, denied } = await requireAdmin(env, request);
  if (denied) return json({ error: "Admin only." }, 403);
  if (!env.FILES) return json({ error: "R2 binding FILES not configured." }, 503);
  try {
    const fd = await request.formData();
    const file = fd.get("file");
    if (!file || typeof file === "string") return json({ error: "file field required" }, 400);
    const name = String(fd.get("name") || file.name || crypto.randomUUID())
      .replace(/[^\w.\- ]/g, "_").slice(0, 80);
    await env.FILES.put(`downloads/${name}`, file.stream(), {
      httpMetadata: { contentType: file.type || "application/octet-stream" },
    });
    return json({ ok: true, key: `downloads/${name}` });
  } catch {
    return json({ error: "Upload failed." }, 500);
  }
}

/* ── downloads: R2-backed file library (APK / admin-uploaded files) ── */
export async function downloadList(env) {
  if (!env.FILES) return json({ files: [] });
  const obj = await env.FILES.list({ prefix: "downloads/" });
  return json({
    files: obj.objects.map((o) => ({
      key: o.key,
      name: o.key.replace(/^downloads\//, ""),
      size: o.size,
      uploaded: o.uploaded,
      url: `/api/download/file/${encodeURIComponent(o.key)}`,
    })),
  });
}

/** Only objects under this prefix are publicly downloadable. */
const DOWNLOAD_PREFIX = "downloads/";

/**
 * Public file download (APK and admin uploads).
 *
 * Keys are confined to `downloads/` so a guessed name cannot reach any other
 * object in the bucket, and Range requests are served as 206 so the Android
 * download manager can resume on a mobile connection.
 */
export async function downloadFile(env, request, key) {
  if (!env.FILES) return new Response("R2 storage binding not configured.", { status: 503 });

  let safeKey;
  try {
    safeKey = decodeURIComponent(String(key || "")).replace(/^\/+/, "");
  } catch {
    return new Response("Not found.", { status: 404 });
  }
  if (!safeKey.startsWith(DOWNLOAD_PREFIX) || safeKey.includes("..")) {
    return new Response("Not found.", { status: 404 });
  }

  const wantsHead = request.method === "HEAD";
  const range = parseByteRange(request.headers.get("range"));
  let obj = null;
  try {
    obj = wantsHead
      ? await env.FILES.head(safeKey)
      : await env.FILES.get(safeKey, range ? { range } : undefined);
  } catch {
    obj = null;
  }
  if (!obj) return new Response("Not found.", { status: 404 });

  const headers = new Headers();
  obj.writeHttpMetadata?.(headers);
  headers.set("etag", obj.httpEtag);
  headers.set("accept-ranges", "bytes");
  headers.set(
    "content-disposition",
    `attachment; filename="${safeKey.replace(DOWNLOAD_PREFIX, "").replace(/"/g, "")}"`,
  );

  const ranged = range && obj.range;
  if (ranged) {
    const start = obj.range.offset;
    const length = obj.range.length;
    headers.set("content-range", `bytes ${start}-${start + length - 1}/${obj.size}`);
    headers.set("content-length", String(length));
  } else {
    headers.set("content-length", String(obj.size));
  }

  return new Response(wantsHead ? null : obj.body, {
    status: ranged ? 206 : 200,
    headers,
  });
}

/* ── streaming proxy with Range support + SSRF host allowlist (no Render dependency) ── */
// Hosts this deployment is allowed to fetch for the app. Matched on label
// boundaries (`h === suffix || h.endsWith("." + suffix)`), never as a raw
// suffix: the previous regex let `evil-anilist.co` or `notr2.dev` through.
const PROXY_HOSTS = [
  "anilist.co",
  "r2.dev",
  "megaplay.buzz",
  "vidlink.pro",
  "vidsrc.cc",
  "animeheaven.me",
  "nekostream.site",
  "anikoto.net",
];

function hostAllowed(hostname) {
  const host = String(hostname || "").toLowerCase().replace(/\.$/, "");
  if (!host) return false;
  return PROXY_HOSTS.some((suffix) => host === suffix || host.endsWith(`.${suffix}`));
}

function proxyTarget(urlText) {
  let u;
  try {
    u = new URL(urlText);
  } catch {
    return null;
  }
  if (u.protocol !== "https:") return null; // SSRF guard
  if (u.username || u.password) return null; // never forward embedded credentials
  if (!hostAllowed(u.hostname)) return null;
  return u;
}

const PROXY_TIMEOUT_MS = 20000;

function methodNotAllowed() {
  return new Response("Method not allowed.", {
    status: 405,
    headers: { allow: "GET, HEAD", "access-control-allow-origin": "*" },
  });
}

export async function proxyMedia(env, request) {
  if (request.method !== "GET" && request.method !== "HEAD") return methodNotAllowed();
  const url = new URL(request.url);
  const target = proxyTarget(url.searchParams.get("u") || "");
  if (!target) return new Response("Blocked: proxy target host not allowed.", { status: 403 });
  const headers = new Headers();
  for (const h of ["range", "if-none-match", "if-modified-since"]) {
    if (request.headers.get(h)) headers.set(h, request.headers.get(h));
  }
  const upstream = await fetch(target.toString(), {
    headers,
    signal: AbortSignal.timeout(PROXY_TIMEOUT_MS),
  });
  const out = new Headers();
  for (const h of ["content-type", "content-length", "content-range", "accept-ranges", "etag", "last-modified", "cache-control"]) {
    if (upstream.headers.get(h)) out.set(h, upstream.headers.get(h));
  }
  if (!out.has("accept-ranges")) out.set("accept-ranges", "bytes"); // seeks keep working
  out.set("access-control-allow-origin", "*"); // developer API streams are embedded cross-origin
  return new Response(request.method === "HEAD" ? null : upstream.body, {
    status: upstream.status,
    headers: out,
  });
}

/** HLS playlist rewriter: segments/HLS URLs go back through /api/proxy/media. */
export async function proxyHls(env, request) {
  if (request.method !== "GET" && request.method !== "HEAD") return methodNotAllowed();
  const url = new URL(request.url);
  const target = proxyTarget(url.searchParams.get("u") || "");
  if (!target) return new Response("Blocked: proxy target host not allowed.", { status: 403 });
  const res = await fetch(target.toString(), { signal: AbortSignal.timeout(PROXY_TIMEOUT_MS) });
  const type = (res.headers.get("content-type") || "").toLowerCase();
  if (!/mpegurl|text\/plain/.test(type)) {
    const headers = new Headers();
    for (const h of ["content-type", "content-range"]) {
      if (res.headers.get(h)) headers.set(h, res.headers.get(h));
    }
    headers.set("accept-ranges", "bytes");
    headers.set("access-control-allow-origin", "*");
    return new Response(request.method === "HEAD" ? null : res.body, {
      status: res.status,
      headers,
    });
  }
  const text = await res.text();
  const baseDir = target.href.slice(0, target.href.lastIndexOf("/") + 1);
  // Nested playlists must come back through the rewriter, or their own
  // relative segment URIs break; everything else is a byte-range fetch.
  const proxied = (raw) => {
    const abs = new URL(raw, baseDir).href;
    const kind = /\.m3u8(\?|$)|mpegurl/i.test(abs) ? "hls" : "media";
    return `/api/proxy/${kind}?u=${encodeURIComponent(abs)}`;
  };
  const out = text.split("\n").map((line) => line.trim()).map((line) => {
    if (!line || line.startsWith("#")) {
      // rewrite every URI="" attribute back through the proxy
      return line.replace(/URI="([^"]+)"/g, (_m, u) => `URI="${proxied(u)}"`);
    }
    return proxied(line);
  });
  return new Response(out.join("\n"), {
    status: 200,
    headers: { "content-type": "application/vnd.apple.mpegurl", "cache-control": "no-store", "access-control-allow-origin": "*" },
  });
}
