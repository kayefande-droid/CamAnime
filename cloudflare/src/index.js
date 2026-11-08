/** CamAnime edge worker (camanjme): independent app on Workers + D1 + R2. No Render dependency. */
import { homeGrids, search as catalogSearch, details, watchContext } from "./catalog.js";
import { chrome, homePage, searchGrid, detailsPage, watchPage, loginPage, errorPage, settingsPage, developersPage } from "./pages.js";
import { html, json } from "./util.js";
import * as api from "./api.js";
import * as auth from "./auth.js";
import * as mobile from "./mobile.js";
import * as developer from "./developer.js";

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
        return await env.ASSETS.fetch(new Request(assetUrl.toString(), request));
      } catch {
        return new Response(null, { status: 404 });
      }
    }

    // Same release policy as the Render origin: a build at or below 2.6.5
    // cannot stream or download here either. Version headers are only a hint,
    // but the enforcement itself is server-side and cannot be skipped by a
    // modified client.
    if (PROTECTED_PREFIXES.some((p) => path.startsWith(p))) {
      const build = clientBuild(request);
      if (build !== null && build < MIN_SUPPORTED_BUILD) {
        return updateRequiredResponse(build);
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

    // Pages (SSR HTML) — failures render the themed error page.
    try {
      ctx.passThroughOnException();
      return await pageRoutes(request, env, ctx, path);
    } catch (err) {
      const status = /not found/i.test(String(err && err.message)) ? 404 : 500;
      const message = status === 404 ? "Page not found." : "Something went wrong on the edge.";
      return html(errorPage(status, message), status);
    }
  },
};

const MIN_SUPPORTED_BUILD = 19; // 2.9.0 — mandatory genuine-quality release
const DISCONTINUED_BUILD = 16; // 2.6.5
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

const APK_SHA256 = "2FE16785184AE1C7B6BA0060E60A60A268F5E8D43F7A32C09CC5BB54E2B8B9D3";

function updateRequiredResponse(build) {
  const retired = build <= DISCONTINUED_BUILD;
  return json({
    status: "update_required",
    code: "APP_UPDATE_REQUIRED",
    reason: retired ? "discontinued" : "unsupported",
    force_update: true,
    latest_version: "2.9.0",
    latest_version_code: 19,
    minimum_supported_version: "2.9.0",
    minimum_supported_version_code: MIN_SUPPORTED_BUILD,
    discontinued_at_or_below_version: "2.6.5",
    discontinued_at_or_below_version_code: DISCONTINUED_BUILD,
    download_url: "https://camanime.onrender.com/get/android",
    download_urls: {
      render: "https://camanime.onrender.com/get/android",
      cloudflare: "https://camanjme.camanime.workers.dev/get/android",
    },
    sha256: APK_SHA256,
    message: retired
      ? "CamAnime 2.6.5 and older are discontinued and can no longer stream "
        + "or download anime. Install the current CamAnime from the official "
        + "website to continue."
      : "Your CamAnime version is no longer supported. Please update from the "
        + "official website to continue.",
  }, 426);
}

async function serveApk(request, env) {
  if (env.ASSETS) {
    try {
      const assetUrl = new URL(request.url);
      assetUrl.pathname = "/downloads/CamAnime.apk";
      const asset = await env.ASSETS.fetch(new Request(assetUrl.toString(), request));
      if (asset.ok) {
        const headers = new Headers(asset.headers);
        headers.set("Content-Type", "application/vnd.android.package-archive");
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

async function pageRoutes(request, env, ctx, path) {
  ctx.waitUntil(api.bumpVisit(env).catch(() => {}));

  const user = await auth.currentUser(env, request);
  const url = new URL(request.url);

  if (path === "/") {
    const grids = await homeGrids();
    return html(homePage(grids, user?.name));
  }

  if (path === "/search" || path === "/browse") {
    const q = (url.searchParams.get("q") || "").trim();
    const results = q ? await catalogSearch(q) : [];
    return html(searchGrid(q, results, user?.name));
  }

  const [p0, p1, p2] = segments(path);

  if (p0 === "anime" && p1 && !p2) {
    const anime = await details(p1);
    if (!anime) throw new Error("anime not found");
    const summary = await (await api.ratingSummary(env, request, p1)).json();
    return html(detailsPage(anime, summary, user));
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
    const files = (await (await api.downloadList(env)).json()).files;
    const inner = `
      <h1 class="section-title">Downloads (R2)</h1>
      <p class="muted">Served from this deployment's own Cloudflare R2 bucket — no Render involvement.</p>
      ${files.length ? `<ul>${files.map((f) => `<li style="margin:.5rem 0"><a href="${f.url}" download>${esc(f.name)}</a> — ${(f.size / 1024 / 1024).toFixed(1)} MB</li>`).join("")}</ul>`
        : `<div class="discovery-empty">No files uploaded yet.</div>`}
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
