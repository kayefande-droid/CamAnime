/** CamAnime edge worker (camanjme): independent app on Workers + D1 + R2. No Render dependency. */
import { homeGrids, search as catalogSearch, details, watchContext } from "./catalog.js";
import { chrome, homePage, searchGrid, detailsPage, watchPage, loginPage, errorPage, settingsPage, developersPage } from "./pages.js";
import { html, json, parseByteRange } from "./util.js";
import * as api from "./api.js";
import * as auth from "./auth.js";
import * as mobile from "./mobile.js";
import * as developer from "./developer.js";
import * as appapi from "./appapi.js";
import { fcmConfigured } from "./push.js";
import {
  APK_SHA256,
  LATEST_BUILD,
  LATEST_VERSION,
  MIN_SUPPORTED_BUILD,
  releasePolicy,
} from "./release.js";
import { sitemapXml, sitemapResponse, robotsTxt, withSeo } from "./seo.js";

function segments(pathname) {
  return pathname.split("/").filter(Boolean);
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const path = url.pathname;

    // Real static assets (same CSS/JS/icons the Render site serves) via the ASSETS binding.
    // The bundle mounts static/ at the asset root, so /static/css/x.css must be
    // requested as /css/x.css. Without this rewrite every asset 404s.
    if (path.startsWith("/static/")) {
      const assetUrl = new URL(request.url);
      assetUrl.pathname = path.slice("/static".length) || "/";
      try {
        const asset = await env.ASSETS.fetch(new Request(assetUrl.toString(), request));
        // The asset bundle ships max-age=0, must-revalidate, so every page load
        // revalidated all six stylesheets and scripts. Templates pin versions
        // with ?v=, so a pinned URL can be cached for a year; anything without
        // a pin still gets a week instead of a round trip per navigation.
        if (asset.status === 304) return asset;
        const headers = new Headers(asset.headers);
        headers.set(
          "Cache-Control",
          url.searchParams.has("v")
            ? "public, max-age=31536000, immutable"
            : "public, max-age=604800"
        );
        return new Response(asset.body, { status: asset.status, headers });
      } catch {
        return new Response(null, { status: 404 });
      }
    }

    // Same release policy as the Render origin: a build below the supported
    // minimum (2.9.0 / build 19) cannot stream or download here either.
    // Version headers are only a hint, but the enforcement itself is
    // server-side and cannot be skipped by a modified client.
    if (PROTECTED_PREFIXES.some((p) => path.startsWith(p))) {
      const build = clientBuild(request);
      if (build !== null && build < MIN_SUPPORTED_BUILD) {
        return updateRequiredResponse(build, url.origin);
      }
    }

    // APIs first.
    try {
      const handled = await apiRoutes(request, env, url, path);
      if (handled) return handled;
    } catch (err) {
      return json({ error: "Server error", detail: String(err && err.message) }, 500);
    }

    // Health endpoint for uptime checks / Workers Builds verification.
    if (path === "/healthz") return json({
      ok: true,
      app: "camanjme",
      architecture: "workers+d1+r2",
      bindings: { db: Boolean(env.DB), files: Boolean(env.FILES), assets: Boolean(env.ASSETS) },
    });

    // Direct Android APK download served by this Cloudflare deployment itself,
    // so the site has a mirror that does not depend on the Render origin.
    if (path === "/get/android") return serveApk(request, env);

    // SEO endpoints for THIS deployment. Both are built from the request
    // origin, so the Cloudflare sitemap never points at the Render host.
    if (path === "/sitemap.xml") return sitemapResponse(await sitemapXml(url.origin));
    if (path === "/robots.txt") return robotsTxt(url.origin, env.ADMIN_PATH || "");

    // Pages (SSR HTML) — failures render the themed error page.
    try {
      ctx.passThroughOnException();
      const page = await pageRoutes(request, env, ctx, path);
      return await withSeo(page, url);
    } catch (err) {
      const status = /not found/i.test(String(err && err.message)) ? 404 : 500;
      if (status === 500) {
        const fallback = await originFallback(url);
        if (fallback) return fallback;
      }
      const message = status === 404 ? "Page not found." : "Something went wrong on the edge.";
      return html(errorPage(status, message), status);
    }
  },

  /**
   * Cloudflare Cron Trigger (see `triggers.crons` in wrangler.jsonc). Sends the
   * hourly new-episode digest to devices that opted into `new_episodes`, which
   * reaches phones with the app closed or the screen off. Skips silently when
   * nothing aired, during quiet hours, or when FCM is not configured.
   */
  async scheduled(controller, env, ctx) {
    ctx.waitUntil(
      appapi.hourlyDigest(env).catch((err) =>
        console.error(JSON.stringify({ message: "digest failed", error: String(err) })),
      ),
    );
  },
};

const PROTECTED_PREFIXES = [
  "/api/proxy/",
  "/api/download/",
  "/api/episode-sources",
  "/api/v1/stream",
  "/api/v1/catalog",
  "/api/v1/search",
  "/api/v1/genres",
];

function clientBuild(request) {
  const raw = request.headers.get("X-CamAnime-Build");
  if (raw === null || raw === "") return null;
  const value = parseInt(raw, 10);
  return Number.isFinite(value) ? value : null;
}

function updateRequiredResponse(build, origin) {
  return json(releasePolicy(origin, build), 426);
}

const APK_KEY = "downloads/CamAnime.apk";
const APK_TYPE = "application/vnd.android.package-archive";

/**
 * Installer download.
 *
 * R2 (`FILES`) first: the APK is far larger than the 25 MiB per-asset cap of
 * Workers Static Assets, so it is deliberately excluded from the asset bundle
 * by `static/.assetsignore`. Serving it from R2 is what makes this host a real
 * mirror instead of a redirect to Render. Range requests are honoured so the
 * Android download manager can resume a dropped mobile connection.
 */
async function serveApk(request, env) {
  const range = parseByteRange(request.headers.get("range"));
  const wantsHead = request.method === "HEAD";

  if (env.FILES) {
    try {
      const obj = wantsHead
        ? await env.FILES.head(APK_KEY)
        : await env.FILES.get(APK_KEY, range ? { range } : undefined);
      if (obj) {
        const headers = new Headers();
        obj.writeHttpMetadata?.(headers);
        headers.set("content-type", APK_TYPE);
        headers.set("content-disposition", 'attachment; filename="CamAnime.apk"');
        headers.set("accept-ranges", "bytes");
        headers.set("cache-control", "public, max-age=3600");
        headers.set("etag", obj.httpEtag);

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
    } catch {
      // Missing object or R2 hiccup: keep trying the cheaper fallbacks below.
    }
  }

  if (env.ASSETS && !range) {
    try {
      const assetUrl = new URL(request.url);
      assetUrl.pathname = "/downloads/CamAnime.apk";
      const asset = await env.ASSETS.fetch(new Request(assetUrl.toString(), request));
      if (asset.ok) {
        const headers = new Headers(asset.headers);
        headers.set("Content-Type", APK_TYPE);
        headers.set("Content-Disposition", 'attachment; filename="CamAnime.apk"');
        headers.set("Cache-Control", "public, max-age=3600");
        return new Response(asset.body, { status: 200, headers });
      }
    } catch {
      // fall through to the origin fallback below
    }
  }
  return Response.redirect("https://camanime.onrender.com/get/android", 302);
}

const ORIGIN = "https://camanime.onrender.com";

/**
 * Last-resort copy of a page from the Render origin.
 *
 * AniList answers Cloudflare's egress with 403, so a native render of a
 * catalogue page can fail even though the page itself is fine. Rather than
 * showing a 500 to a visitor, fetch the same path from the origin. This is
 * only reached after the native render threw, so the Worker still serves
 * every page it can build itself.
 */
async function originFallback(url) {
  try {
    const res = await fetch(new URL(url.pathname + url.search, ORIGIN), {
      headers: { accept: "text/html", "user-agent": "CamAnime-Edge/2.12.0" },
      signal: AbortSignal.timeout(12000),
      redirect: "follow",
    });
    if (!res.ok) return null;
    if (!(res.headers.get("content-type") || "").includes("text/html")) return null;
    let body = await res.text();
    // Keep the mirror's canonical on the mirror, not on the origin.
    body = body
      .replace(/(<link rel="canonical" href=")https:\/\/camanime\.onrender\.com/g, `$1${url.origin}`)
      .replace(/(<meta property="og:url" content=")https:\/\/camanime\.onrender\.com/g, `$1${url.origin}`);
    return new Response(body, {
      status: 200,
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=120",
        "x-camanime-source": "origin-fallback",
      },
    });
  } catch {
    return null;
  }
}

async function apiRoutes(request, env, url, path) {
  const method = request.method;
  const parts = segments(path);
  const [p0, p1, p2, p3, p4] = parts;

  if (p0 !== "api") return null;

  // The endpoints the Flutter build actually calls. Served here from AniList +
  // D1, so an app pointed at this worker never needs the Render origin.
  const mobileResponse = await mobile.route(env, request, url, parts);
  if (mobileResponse) return mobileResponse;

  // Developer API: free-tier keys (session auth) + the public keyed endpoints.
  if (p1 === "v1" && p2 === "dev" && p3 === "catalog") {
    if (method === "OPTIONS") return developer.preflight();
    return developer.catalog(env, request, url);
  }
  if (p1 === "v1" && p2 === "dev" && p3 === "anime" && p4) {
    if (method === "OPTIONS") return developer.preflight();
    return developer.animeDetail(env, request, url, p4);
  }
  if (p1 === "v1" && p2 === "stream") {
    if (method === "OPTIONS") return developer.preflight();
    return developer.stream(env, request, url, p3, p4);
  }
  if (p1 === "developer" && p2 === "keys") {
    if (method === "GET") return developer.listKeys(env, request);
    if (method === "POST" && !p3) return developer.createKey(env, request);
    if ((method === "DELETE" || method === "POST") && p3) return developer.revokeKey(env, request, p3);
  }

  // App lifecycle: update manifest, remote config, device registry,
  // notification dispatch, releases and usage. Additive to the routes above.
  const appResponse = await appapi.route(env, request, url, parts);
  if (appResponse) return appResponse;

  if (p1 === "auth") {
    if (p2 === "register" && method === "POST") return auth.register(env, request);
    if (p2 === "login" && method === "POST") return auth.login(env, request);
    if (p2 === "logout" && method === "POST") return auth.logout(env, request);
    if (p2 === "me") return auth.me(env, request);
    return json({ error: "Unknown auth route" }, 404);
  }

  if (p1 === "track" && method === "POST") return api.track(env, request);
  if (p1 === "counters") return api.counters(env);

  if (p1 === "anime" && p3 === "comments") return method === "GET"
    ? api.getComments(env, request, p2, p4)
    : api.postComment(env, request, p2, p4);
  if (p1 === "rate" && method === "POST") return api.rate(env, request, p2);
  if (p1 === "ratings" && p2 && !p3) return api.ratingSummary(env, request, p2);

  if (p1 === "history" && method === "GET") return api.historyGet(env, request);
  if (p1 === "history" && method === "POST") return api.historyPost(env, request);
  if (p1 === "notifications" && method === "GET") return api.notifications(env, request);
  if (p1 === "notifications" && method === "POST") return api.notificationsRead(env, request);
  if (p1 === "announcements" && method === "GET") return api.announcements(env);
  if (p1 === "announcements" && method === "POST") return api.announcementPost(env, request);

  if (p1 === "download" && p2 === "list") return api.downloadList(env);
  if (p1 === "download" && p2 === "file") {
    const key = path.replace(/^\/api\/download\/file\//, "");
    return api.downloadFile(env, request, key);
  }
  if (p1 === "admin" && p2 === "upload" && method === "POST") return api.uploadFile(env, request);
  if (p1 === "admin" && p2 === "data") return api.adminData(env, request);

  // Streaming proxy: Range-safe media + HLS playlist rewrite (host-allowlisted).
  if (p1 === "proxy" && p2 === "media") return api.proxyMedia(env, request);
  if (p1 === "proxy" && p2 === "hls") return api.proxyHls(env, request);

  return json({ error: "Unknown API route" }, 404);
}

const store = (() => {
  try {
    return caches && caches.default ? caches.default : null;
  } catch {
    return null;
  }
})();

async function pageCacheGet(request) {
  const cookie = request.headers.get("cookie") || "";
  if (!store || cookie) return null;
  try {
    return await store.match(new Request(request.url, { method: "GET" }));
  } catch {
    return null;
  }
}

function pageCachePut(request, response, ctx) {
  const cookie = request.headers.get("cookie") || "";
  if (!store || cookie || response.status !== 200) return response;
  let write;
  try {
    const headers = new Headers(response.headers);
    // A short stale window: long enough to absorb a burst, short enough that a
    // deploy whose assets changed is picked up within a minute rather than three.
    headers.set("Cache-Control", "public, max-age=30, stale-while-revalidate=15");
    write = store.put(new Request(request.url, { method: "GET" }),
      new Response(response.clone().body, { status: 200, headers })).catch(() => {});
  } catch {
    // A failed write must never cost the visitor their page.
    return response;
  }
  // Never make the visitor wait for the cache write; this response is ready.
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(write);
  return response;
}

async function pageRoutes(request, env, ctx, path) {
  ctx.waitUntil(api.bumpVisit(env).catch(() => {}));

  const user = await auth.currentUser(env, request);
  const url = new URL(request.url);

  if (path === "/") {
    const cached = await pageCacheGet(request);
    if (cached) return cached;
    const grids = await homeGrids();
    return pageCachePut(request, html(homePage(grids, user?.name)), ctx);
  }

  if (path === "/search" || path === "/browse") {
    const q = (url.searchParams.get("q") || "").trim();
    const results = q ? await catalogSearch(q) : [];
    return html(searchGrid(q, results, user?.name));
  }

  const [p0, p1, p2] = segments(path);

  if (p0 === "anime" && p1 && !p2) {
    const cached = await pageCacheGet(request);
    if (cached) return cached;
    const anime = await details(p1);
    if (!anime) throw new Error("anime not found");
    const summary = await (await api.ratingSummary(env, request, p1)).json();
    return pageCachePut(request, html(detailsPage(anime, summary, user)), ctx);
  }

  if (p0 === "watch" && p1 && p2) {
    const ctxAnime = await watchContext(p1, p2);
    return html(watchPage(ctxAnime, user));
  }

  if (path === "/login" || path === "/register") {
    return html(loginPage(user?.name));
  }

  if (path === "/library") {
    const hist = await (await api.historyGet(env, request)).json();
    const rows = (hist.history || []).map((h) => `
      <a class="anime-card" href="/watch/${h.anime_id}/${h.ep}">
        <span class="card-poster-wrap"><img src="${esc(h.image || "/static/icon-512.png")}" alt="" loading="lazy"></span>
        <span class="card-title">${esc(h.title || "Anime " + h.anime_id)}</span>
        <span class="card-format">EP ${h.ep} · ${h.position ? Math.floor(h.position / 60) + " min in" : "not started"}</span>
      </a>`).join("");
    const inner = `
      <h1 class="section-title">My Library</h1>
      ${user ? "" : `<div class="discovery-empty">Sign in to sync your resume points across devices — <a href="/login">sign in</a>.</div>`}
      ${rows ? `<div class="anime-grid">${rows}</div>` : `<p class="discovery-empty">Nothing saved yet.</p>`}`;
    return html(chrome("My Library", "Your CamAnime watchlist and resume points.", user?.name, inner, "library"));
  }

  if (path === "/download") {
    // Report the exact bytes /get/android will hand over, so the page and the
    // downloaded file can never disagree about version, size or name.
    let apkSize = null;
    try {
      if (env.FILES) apkSize = (await env.FILES.head(APK_KEY))?.size ?? null;
    } catch {
      apkSize = null;
    }
    const extras = (await (await api.downloadList(env)).json()).files.filter(
      (f) => f.key !== APK_KEY,
    );
    const sizeLabel = apkSize
      ? `${(apkSize / (1024 * 1024)).toFixed(1)} MB`
      : "size shown by the main site";
    const inner = `
      <h1 class="section-title">Download CamAnime</h1>
      <div class="discovery-empty" style="display:block">
        <p style="margin:0"><strong>CamAnime ${LATEST_VERSION} (build ${LATEST_BUILD})</strong> — Android APK, ${sizeLabel}</p>
        <p style="margin:.75rem 0"><a class="btn-primary" href="/get/android" download>Download CamAnime.apk</a></p>
        <p class="muted" style="margin:0">Checksum (sha256): <code style="word-break:break-all">${APK_SHA256}</code></p>
      </div>
      <p class="muted">${apkSize ? "Served from this deployment's own Cloudflare R2 bucket — no Render involvement." : "This mirror has no copy of its own yet, so the button redirects to the main site."}</p>
      ${extras.length ? `<h2 class="section-title">Other files</h2><ul>${extras.map((f) => `<li style="margin:.5rem 0"><a href="${f.url}" download>${esc(f.name)}</a> — ${(f.size / 1024 / 1024).toFixed(1)} MB</li>`).join("")}</ul>` : ""}
      ${user?.role === "admin" ? `
      <form id="upForm" enctype="multipart/form-data" style="margin-top:1rem">
        <h2 class="section-title">Admin upload</h2>
        <input type="file" name="file" required>
        <button class="btn-primary" type="submit">Upload</button>
      </form>
      <script>
      document.getElementById('upForm').onsubmit = async function (e) {
        e.preventDefault();
        var fd = new FormData(this);
        var res = await fetch('/api/admin/upload', { method: 'POST', body: fd, credentials: 'same-origin' });
        if (res.ok) location.reload(); else alert((await res.json()).error || 'Upload failed');
      };
      </script>` : ""}`;
    return html(chrome("Downloads", "CamAnime downloads on Cloudflare R2.", user?.name, inner, "download"));
  }

  if (path === "/settings") {
    return html(settingsPage(user));
  }

  if (path === "/developers" || path === "/developers/keys") {
    return html(developersPage(user));
  }

  // The dashboard is not public: it renders only on the private path set in
  // the worker's ADMIN_PATH secret. Unset means /admin is a 404 here, matching
  // the Render origin (which uses CAMANIME_ADMIN_PATH).
  const adminPath = String(env.ADMIN_PATH || "").trim();
  if (adminPath && path === adminPath) {
    if (!user || user.role !== "admin") {
      const inner = `<h1 class="section-title">Admin</h1><div class="discovery-empty">Admin account required. <a href="/login">Sign in</a>.</div>`;
      return html(chrome("Admin", "CamAnime admin.", user?.name, inner), user ? 403 : 401);
    }
    const data = await (await api.adminData(env, request)).json();
    const countersData = data.counters || {};
    const [histRows, releaseRows, cfgRow, deviceRow] = await Promise.all([
      env.DB.prepare("SELECT id,title,category,target,status,sent,failed,created FROM notification_log ORDER BY created DESC LIMIT 10").all(),
      env.DB.prepare("SELECT version,build,channel,mandatory,published,created FROM app_releases ORDER BY build DESC LIMIT 10").all(),
      env.DB.prepare("SELECT value FROM remote_config WHERE key = 'app'").first(),
      env.DB.prepare("SELECT COUNT(*) n FROM devices WHERE token != ''").first(),
    ]);
    const pushReady = fcmConfigured(env);
    let cfg = {};
    try { cfg = cfgRow ? JSON.parse(cfgRow.value) : {}; } catch { cfg = {}; }
    const inner = `
      <h1 class="section-title">Admin</h1>
      <div class="stat-strip">
        <div class="stat"><strong>${countersData.player_starts ?? 0}</strong> player starts</div>
        <div class="stat"><strong>${countersData.visits ?? 0}</strong> page visits</div>
        <div class="stat"><strong>${(data.users || []).length}</strong> users</div>
      </div>
      <h2 class="section-title">Publish announcement</h2>
      <form id="annForm">
        <input id="annTitle" placeholder="Title" required style="width:100%;padding:.6rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <textarea id="annBody" rows="3" placeholder="Body" style="width:100%;margin-top:.4rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)"></textarea>
        <button class="btn-primary" type="submit" style="margin-top:.4rem">Publish</button>
      </form>
      <script>
      document.getElementById('annForm').onsubmit = async function (e) {
        e.preventDefault();
        await fetch('/api/announcements', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ title: document.getElementById('annTitle').value, body: document.getElementById('annBody').value }) });
      };
      </script>
      <h2 class="section-title">Push notifications</h2>
      ${pushReady
        ? `<p class="muted">FCM ready — ${deviceRow?.n ?? 0} push-enabled devices.</p>`
        : `<div class="discovery-empty">FCM is not configured on this deployment. Set the <code>FCM_PROJECT_ID</code> variable and the <code>FCM_SERVICE_ACCOUNT</code> secret, then redeploy. Messages are still recorded in the history below.</div>`}
      <form id="pushForm">
        <input id="nTitle" placeholder="Title" required style="width:100%;padding:.6rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <textarea id="nBody" rows="3" placeholder="Message" required style="width:100%;margin-top:.4rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)"></textarea>
        <input id="nImage" placeholder="Image URL (https, optional)" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <input id="nLink" placeholder="Deep link (e.g. /watch/21/1, optional)" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <div style="display:flex;gap:.4rem;flex-wrap:wrap;margin-top:.4rem">
          <select id="nCategory" style="padding:.5rem;border-radius:10px">
            ${appapi.allowedCategories.map((c) => `<option value="${c}">${c}</option>`).join("")}
          </select>
          <select id="nTarget" style="padding:.5rem;border-radius:10px">
            <option value="all">All devices</option>
            <option value="topic">Topic group</option>
            <option value="device">Single device</option>
            <option value="version">App build at least</option>
          </select>
          <input id="nTargetValue" placeholder="topic / install id / build" style="flex:1;min-width:10rem;padding:.5rem;border-radius:10px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        </div>
        <button class="btn-primary" type="submit" style="margin-top:.5rem">Send now</button>
        <p id="pushOut" class="muted" role="status" aria-live="polite"></p>
      </form>
      <script>
      (function () {
        var form = document.getElementById('pushForm');
        if (!form) return;
        form.onsubmit = async function (e) {
          e.preventDefault();
          var out = document.getElementById('pushOut');
          out.textContent = 'Sending…';
          var res = await fetch('/api/v1/notifications/send', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              title: document.getElementById('nTitle').value,
              body: document.getElementById('nBody').value,
              image: document.getElementById('nImage').value,
              deep_link: document.getElementById('nLink').value,
              category: document.getElementById('nCategory').value,
              target: document.getElementById('nTarget').value,
              target_value: document.getElementById('nTargetValue').value
            })
          });
          var data = await res.json().catch(function () { return {}; });
          if (!res.ok) { out.textContent = data.error || ('HTTP ' + res.status); return; }
          out.textContent = 'Audience ' + data.audience + ' · sent ' + data.sent + ' · failed ' + data.failed +
            (data.reason ? ' · ' + data.reason : '');
          if (data.sent > 0) setTimeout(function () { location.reload(); }, 1200);
        };
      })();
      </script>

      <h2 class="section-title">Recent sends</h2>
      <div class="table-scroll"><table><thead><tr><th>Title</th><th>Category</th><th>Target</th><th>Status</th><th>Sent</th></tr></thead>
      <tbody>${(histRows.results || []).map((n) => `<tr><td>${esc(n.title)}</td><td>${esc(n.category)}</td><td>${esc(n.target)}</td><td>${esc(n.status)}</td><td>${n.sent}/${n.sent + n.failed}</td></tr>`).join("") || `<tr><td colspan="5" class="muted">No notifications sent yet.</td></tr>`}</tbody></table></div>

      <h2 class="section-title">App releases</h2>
      <div class="table-scroll"><table><thead><tr><th>Version</th><th>Build</th><th>Channel</th><th>Mandatory</th><th>Published</th></tr></thead>
      <tbody>${(releaseRows.results || []).map((r) => `<tr><td>${esc(r.version)}</td><td>${r.build}</td><td>${esc(r.channel)}</td><td>${r.mandatory ? "yes" : "no"}</td><td>${r.published ? "yes" : "draft"}</td></tr>`).join("") || `<tr><td colspan="5" class="muted">No releases published yet.</td></tr>`}</tbody></table></div>
      <form id="relForm" style="margin-top:.6rem">
        <div style="display:flex;gap:.4rem;flex-wrap:wrap">
          <input id="rVersion" placeholder="2.12.0" required style="padding:.5rem;border-radius:10px">
          <input id="rBuild" type="number" placeholder="Build 23" required style="padding:.5rem;border-radius:10px;width:8rem">
          <select id="rChannel" style="padding:.5rem;border-radius:10px"><option value="stable">stable</option><option value="beta">beta</option></select>
          <input id="rSha" placeholder="sha256 (optional)" style="flex:1;min-width:12rem;padding:.5rem;border-radius:10px">
        </div>
        <textarea id="rNotes" rows="2" placeholder="Release notes" style="width:100%;margin-top:.4rem;border-radius:10px"></textarea>
        <label class="muted" style="display:block;margin-top:.3rem"><input id="rMandatory" type="checkbox"> Mandatory update</label>
        <button class="btn-primary" type="submit" style="margin-top:.4rem">Publish release</button>
        <p id="relOut" class="muted" role="status" aria-live="polite"></p>
      </form>
      <script>
      (function () {
        var form = document.getElementById('relForm');
        if (!form) return;
        form.onsubmit = async function (e) {
          e.preventDefault();
          var out = document.getElementById('relOut');
          out.textContent = 'Publishing…';
          var res = await fetch('/api/v1/releases/publish', {
            method: 'POST', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({
              version: document.getElementById('rVersion').value,
              build: Number(document.getElementById('rBuild').value),
              channel: document.getElementById('rChannel').value,
              sha256: document.getElementById('rSha').value,
              notes: document.getElementById('rNotes').value,
              mandatory: document.getElementById('rMandatory').checked
            })
          });
          var data = await res.json().catch(function () { return {}; });
          out.textContent = res.ok ? 'Published ' + data.version + ' +' + data.build : (data.error || ('HTTP ' + res.status));
          if (res.ok) setTimeout(function () { location.reload(); }, 1200);
        };
      })();
      </script>

      <h2 class="section-title">Remote configuration</h2>
      <form id="cfgForm">
        <label class="muted" style="display:block"><input id="cMaint" type="checkbox" ${cfg.maintenance?.enabled ? "checked" : ""}> Maintenance mode</label>
        <input id="cMaintMsg" placeholder="Maintenance message" value="${esc(cfg.maintenance?.message || "")}" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px">
        <input id="cBanner" placeholder="Banner text" value="${esc(cfg.banner?.text || "")}" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px">
        <input id="cBannerUrl" placeholder="Banner URL" value="${esc(cfg.banner?.url || "")}" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px">
        <input id="cNotice" placeholder="Update notice" value="${esc(cfg.update_notice || "")}" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px">
        <input id="cFeatured" placeholder="Featured anime id" value="${esc(cfg.featured_anime_id || "")}" style="width:100%;margin-top:.4rem;padding:.6rem;border-radius:10px">
        <button class="btn-primary" type="submit" style="margin-top:.4rem">Save configuration</button>
        <p id="cfgOut" class="muted" role="status" aria-live="polite"></p>
      </form>
      <script>
      (function () {
        var form = document.getElementById('cfgForm');
        if (!form) return;
        form.onsubmit = async function (e) {
          e.preventDefault();
          var out = document.getElementById('cfgOut');
          out.textContent = 'Saving…';
          var res = await fetch('/api/v1/app/config', {
            method: 'PUT', credentials: 'same-origin',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ config: {
              maintenance: { enabled: document.getElementById('cMaint').checked, message: document.getElementById('cMaintMsg').value },
              banner: { text: document.getElementById('cBanner').value, url: document.getElementById('cBannerUrl').value },
              update_notice: document.getElementById('cNotice').value,
              featured_anime_id: document.getElementById('cFeatured').value
            } })
          });
          var data = await res.json().catch(function () { return {}; });
          out.textContent = res.ok ? 'Saved' : (data.error || ('HTTP ' + res.status));
        };
      })();
      </script>

      <h2 class="section-title">Users</h2>
      <div class="table-scroll"><table><thead><tr><th>Email</th><th>Name</th><th>Role</th></tr></thead>
      <tbody>${(data.users || []).map((u) => `<tr><td>${esc(u.email)}</td><td>${esc(u.name)}</td><td>${esc(u.role)}</td></tr>`).join("")}</tbody></table></div>`;
    return html(chrome("Admin", "CamAnime admin dashboard.", user.name, inner, "admin"));
  }

  throw new Error("not found");
}

function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
