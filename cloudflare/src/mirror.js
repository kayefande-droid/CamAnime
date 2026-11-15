/**
 * Transparent mirror of the Render origin.
 *
 * The Cloudflare deployment is meant to be an exact duplicate of
 * camanime.onrender.com: the same HTML, stylesheets, scripts, animations,
 * pages, account flows and season rails. Rebuilding all of that by hand drifts
 * the moment the origin changes, so this module forwards page, asset and
 * non-streaming API requests to the origin and returns its bytes with only the
 * host-specific bits rewritten (canonical/og:url, absolute links, cookies).
 *
 * Speed comes from never letting a visitor wait for the origin once a page has
 * been fetched: every anonymous GET is stored at the edge and served straight
 * from there, while a background revalidation refreshes it. A cold fetch gets
 * a fixed budget, and if the origin is slower than that the native page is
 * served for that one visit while the cache fills in the background.
 *
 * The Worker's own /api routes are matched before this runs, so
 * /api/episode-sources, /api/proxy/* and /api/download/* still stream and
 * download from Cloudflare. Anything the Worker does not implement (community,
 * schedule, track, login form posts) is answered by the origin here.
 */

import { rewriteAniListImages } from "./media.js";

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
  "content-encoding",
  "content-length",
]);

const FORWARDED_HEADERS = [
  "accept",
  "accept-language",
  "cookie",
  "content-type",
  "x-csrf-token",
  "x-requested-with",
  "range",
  "if-none-match",
  "if-modified-since",
];

/** Where a warmed cache entry is keyed when no custom domain is configured. */
const DEFAULT_SITE = "https://camanjme.camanime.workers.dev";

/** Page HTML is cheap to keep and refreshed in the background. */
const HTML_KEEP_SECONDS = 6 * 60 * 60;
const HTML_REVALIDATE_AFTER_SECONDS = 120;
/** Everything else (proxied JSON, images) stays a day. */
const OTHER_KEEP_SECONDS = 24 * 60 * 60;
const OTHER_REVALIDATE_AFTER_SECONDS = 3600;

/** A visitor never waits longer than this for a cold page. */
const COLD_BUDGET_MS = 9000;

/* Per-visitor pages: they carry CSRF tokens or account state, so a shared
 * cached copy would sign the wrong person in or replay a stale token. */
const UNCACHEABLE = [
  /^\/login/,
  /^\/register/,
  /^\/settings/,
  /^\/library/,
  /^\/admin/,
  /^\/developers/,
  /^\/api\/auth/,
  /^\/api\/me/,
];

const store = (() => {
  try {
    return caches && caches.default ? caches.default : null;
  } catch {
    return null;
  }
})();

/** Parsed MIRROR_ORIGIN, or "" when mirroring is switched off/downright invalid. */
export function mirrorOrigin(env) {
  const raw = String(env.MIRROR_ORIGIN || "").trim().replace(/\/+$/, "");
  if (!raw) return "";
  try {
    const parsed = new URL(raw);
    return parsed.protocol === "https:" ? parsed.origin : "";
  } catch {
    return "";
  }
}

function siteOrigin(env) {
  const configured = String(env.PUBLIC_ORIGIN || "").trim().replace(/\/+$/, "");
  try {
    if (configured && new URL(configured).protocol === "https:") return configured;
  } catch {
    // fall through to the deployed hostname
  }
  return DEFAULT_SITE;
}

function cacheablePath(pathname) {
  return !UNCACHEABLE.some((pattern) => pattern.test(pathname));
}

function fetchOrigin(origin, request, url, method, body, timeoutMs) {
  const headers = new Headers();
  for (const name of FORWARDED_HEADERS) {
    const value = request.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("user-agent", request.headers.get("user-agent") || "CamAnime-Mirror/1.0");
  // The origin rate-limits per client IP; without this every visitor would
  // share Cloudflare's egress address and trip its firewall together.
  const clientIp = request.headers.get("cf-connecting-ip");
  if (clientIp) headers.set("x-forwarded-for", clientIp);
  headers.set("x-forwarded-proto", "https");
  headers.set("x-forwarded-host", url.host);
  // CSRF checks compare Origin/Referer with the origin's own host, so present
  // the request as if it had been made on camanime.onrender.com.
  const requestOrigin = request.headers.get("origin");
  if (requestOrigin) headers.set("origin", origin);
  const referer = request.headers.get("referer");
  if (referer) headers.set("referer", referer.split(url.origin).join(origin));

  return fetch(origin + url.pathname + url.search, {
    method,
    headers,
    body,
    redirect: "manual",
    signal: AbortSignal.timeout(timeoutMs),
  });
}

/** Resolve with null instead of making the visitor wait past `ms`. */
function withBudget(promise, ms) {
  let timer;
  const deadline = new Promise((resolve) => {
    timer = setTimeout(() => resolve(null), ms);
  });
  return Promise.race([promise.catch(() => null), deadline]).finally(() => clearTimeout(timer));
}

/** Turn the origin's bytes into this worker's response. */
async function buildResponse(upstream, origin, url) {
  if ([301, 302, 303, 307, 308].includes(upstream.status)) {
    const location = upstream.headers.get("location");
    if (location) {
      let target = location;
      try {
        target = new URL(location, origin).toString().split(origin).join(url.origin);
      } catch {
        target = location;
      }
      return Response.redirect(target, upstream.status);
    }
  }

  const outHeaders = new Headers();
  for (const [name, value] of upstream.headers) {
    const lower = name.toLowerCase();
    if (lower === "set-cookie" || HOP_BY_HOP.has(lower)) continue;
    outHeaders.set(name, value);
  }
  // Copy cookies one by one: joining them into a single header corrupts the
  // Expires date and logs everyone out on the way back.
  const setCookies = upstream.headers.getSetCookie
    ? upstream.headers.getSetCookie()
    : upstream.headers.get("set-cookie")
      ? [upstream.headers.get("set-cookie")]
      : [];
  for (const cookie of setCookies) {
    // A Domain= for the Render hostname is rejected by the browser on
    // workers.dev, and the cookie would be silently dropped.
    outHeaders.append("set-cookie", cookie.replace(/;\s*Domain=[^;]+/i, ""));
  }
  outHeaders.set("x-camanime-mirror", "onrender");

  const contentType = upstream.headers.get("content-type") || "";
  if (contentType.includes("text/html")) {
    let text = await upstream.text();
    // The pages are the origin's; only host-bound and CDN-bound URLs change.
    text = text.split(origin).join(url.origin);
    text = rewriteAniListImages(text);
    return new Response(text, { status: upstream.status, headers: outHeaders });
  }
  const empty = upstream.status === 204 || upstream.status === 304;
  return new Response(empty ? null : upstream.body, {
    status: upstream.status,
    headers: outHeaders,
  });
}

function cachedAt(response) {
  const value = Number(response.headers.get("x-camanime-cached-at"));
  return Number.isFinite(value) && value > 0 ? value : 0;
}

/** A browser copy: always revalidates, so signing in never shows a stale bar. */
function browserCopy(cached) {
  const headers = new Headers(cached.headers);
  headers.set("x-camanime-mirror", "onrender");
  headers.set("cache-control", "public, max-age=0, must-revalidate");
  return new Response(cached.body, { status: cached.status, headers });
}

async function storeInCache(cacheKey, response) {
  if (!store) return;
  const headers = new Headers(response.headers);
  const html = (headers.get("content-type") || "").includes("text/html");
  headers.set("x-camanime-cached-at", String(Date.now()));
  headers.set(
    "cache-control",
    `public, max-age=${html ? HTML_KEEP_SECONDS : OTHER_KEEP_SECONDS}`,
  );
  await store.put(
    cacheKey,
    new Response(response.body, { status: response.status, headers }),
  );
}

/** Re-fetch a cached page after the stale interval without blocking anyone. */
async function refresh(env, origin, request, url, cacheKey, method) {
  try {
    const upstream = await fetchOrigin(origin, request, url, method, undefined, 20000);
    if (!upstream || upstream.status !== 200 || upstream.headers.get("set-cookie")) return;
    const built = await buildResponse(upstream, origin, url);
    if (!built || built.status !== 200) return;
    await storeInCache(cacheKey, built);
  } catch {
    // Keeping the old copy is the correct outcome when a refresh fails.
  }
}

/**
 * Fetch `url` from the origin and return it as this worker's response.
 * Returns null when mirroring is disabled or the origin cannot be reached, so
 * the caller can fall back to the native renderer.
 */
export async function mirror(request, env, url, ctx) {
  const origin = mirrorOrigin(env);
  if (!origin) return null;

  const method = request.method.toUpperCase();
  const isRead = method === "GET" || method === "HEAD";
  const hasCookie = Boolean(request.headers.get("cookie"));
  const cacheKey =
    isRead && !hasCookie && store && cacheablePath(url.pathname)
      ? new Request(url.toString(), { method: "GET" })
      : null;

  // Warm copy first: this is what makes a page open instantly, including the
  // watch page whose origin render is the slowest thing on the site.
  if (cacheKey) {
    let cached = null;
    try {
      cached = await store.match(cacheKey);
    } catch {
      cached = null;
    }
    if (cached) {
      const html = (cached.headers.get("content-type") || "").includes("text/html");
      const storedAt = cachedAt(cached);
      const revalidateAfter =
        (html ? HTML_REVALIDATE_AFTER_SECONDS : OTHER_REVALIDATE_AFTER_SECONDS) * 1000;
      if (ctx && typeof ctx.waitUntil === "function" && (!storedAt || Date.now() - storedAt > revalidateAfter)) {
        ctx.waitUntil(refresh(env, origin, request, url, cacheKey, method));
      }
      return browserCopy(cached);
    }
  }

  let body;
  if (!isRead) {
    try {
      body = await request.arrayBuffer();
    } catch {
      body = undefined;
    }
  }

  let upstream;
  try {
    const pending = fetchOrigin(origin, request, url, method, body, isRead ? 20000 : 15000);
    if (cacheKey) {
      upstream = await withBudget(pending, COLD_BUDGET_MS);
      if (!upstream) {
        // Slow origin: answer this visit from the native page, keep fetching so
        // the next visit (and every visitor after it) gets the exact copy.
        if (ctx && typeof ctx.waitUntil === "function") {
          ctx.waitUntil(refresh(env, origin, request, url, cacheKey, method));
        }
        return null;
      }
    } else {
      upstream = await pending;
    }
  } catch {
    if (cacheKey) {
      try {
        const stale = await store.match(cacheKey);
        if (stale) return browserCopy(stale);
      } catch {
        // fall through to the native page
      }
    }
    return null;
  }

  const response = await buildResponse(upstream, origin, url);
  if (!response) return null;

  const cacheable =
    Boolean(cacheKey) &&
    upstream.status === 200 &&
    !upstream.headers.get("set-cookie");
  if (!cacheable) return response;

  const stored = storeInCache(cacheKey, response.clone()).catch(() => {});
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(stored);
  return browserCopy(response);
}

/**
 * Fill the edge cache for a list of paths (used by the cron).
 *
 * The five-minute cron already keeps the origin awake; this makes the busiest
 * pages warm before a visitor asks for them, so the first person after a
 * deploy is not the one paying the origin's render time.
 */
export async function warmMirror(env, paths, ctx) {
  const origin = mirrorOrigin(env);
  if (!origin || !store) return 0;
  const site = siteOrigin(env);
  let warmed = 0;
  await Promise.all(
    (paths || []).map(async (path) => {
      try {
        const url = new URL(path, site);
        if (!cacheablePath(url.pathname)) return;
        const request = new Request(url.toString(), {
          headers: { accept: "text/html", "user-agent": "CamAnime-Warm/1.0" },
        });
        const upstream = await fetchOrigin(origin, request, url, "GET", undefined, 20000);
        if (!upstream || upstream.status !== 200 || upstream.headers.get("set-cookie")) return;
        const built = await buildResponse(upstream, origin, url);
        if (!built) return;
        await storeInCache(new Request(url.toString(), { method: "GET" }), built);
        warmed += 1;
      } catch {
        // A path that cannot be warmed is fetched on demand instead.
      }
    }),
  );
  return warmed;
}
