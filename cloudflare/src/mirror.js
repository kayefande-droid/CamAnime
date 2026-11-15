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
 * The Worker's own /api routes are matched before this runs, so
 * /api/episode-sources, /api/proxy/* and /api/download/* still stream and
 * download from Cloudflare. Anything the Worker does not implement (community,
 * schedule, track, login form posts) is answered by the origin here.
 *
 * Fallback order: edge cache (including stale), then null so index.js can
 * render its native page. A dead origin degrades to the old mirror instead of
 * an error page.
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
  const cacheKey = isRead && !hasCookie ? new Request(url.toString(), { method: "GET" }) : null;

  let body;
  if (!isRead) {
    try {
      body = await request.arrayBuffer();
    } catch {
      body = undefined;
    }
  }

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

  let upstream;
  try {
    upstream = await fetch(origin + url.pathname + url.search, {
      method: isRead ? method : method,
      headers,
      body,
      redirect: "manual",
      signal: AbortSignal.timeout(isRead ? 20000 : 15000),
    });
  } catch {
    if (cacheKey && store) {
      try {
        const cached = await store.match(cacheKey);
        if (cached) return staleCopy(cached);
      } catch {
        // fall through to the native page
      }
    }
    return null;
  }

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
  let response;
  if (contentType.includes("text/html")) {
    let text = await upstream.text();
    // The pages are the origin's; only host-bound and CDN-bound URLs change.
    text = text.split(origin).join(url.origin);
    text = rewriteAniListImages(text);
    response = new Response(text, { status: upstream.status, headers: outHeaders });
  } else {
    const empty = upstream.status === 204 || upstream.status === 304;
    response = new Response(empty ? null : upstream.body, {
      status: upstream.status,
      headers: outHeaders,
    });
  }

  const cacheable =
    Boolean(cacheKey) &&
    store &&
    upstream.status === 200 &&
    !upstream.headers.get("set-cookie");
  if (!cacheable) return response;

  const ttl = contentType.includes("text/html") ? 30 : 300;
  const headersForCache = new Headers(response.headers);
  headersForCache.set(
    "cache-control",
    `public, max-age=${ttl}, stale-while-revalidate=${ttl * 6}`,
  );
  const cached = new Response(response.body, { status: 200, headers: headersForCache });
  const write = store.put(cacheKey, cached.clone()).catch(() => {});
  if (ctx && typeof ctx.waitUntil === "function") ctx.waitUntil(write);
  return cached;
}

function staleCopy(cached) {
  const headers = new Headers(cached.headers);
  headers.set("x-camanime-mirror", "onrender-stale");
  return new Response(cached.body, { status: cached.status, headers });
}
