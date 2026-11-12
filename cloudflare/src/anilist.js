/**
 * Shared AniList client for the edge deployment.
 *
 * AniList rate-limits by IP (HTTP 429). A page render used to fire several
 * separate queries, so a handful of visitors could exhaust the budget and every
 * subsequent request failed. This module fixes that at the source:
 *
 *  1. concurrent identical queries share one in-flight request (coalescing);
 *  2. a 429/5xx is retried after the server's Retry-After, not instantly;
 *  3. if retries run out, a previously cached payload is served instead of
 *     failing the page;
 *  4. successful payloads are cached at the edge for a longer window so repeat
 *     views never touch AniList at all.
 *
 * Callers get the raw GraphQL payload (`.data` is the query result), which is
 * the shape the existing catalog code already reads.
 */
const ENDPOINT = "https://graphql.anilist.co";

/** body -> Promise<payload> for requests currently in flight. */
const inFlight = new Map();

/**
 * D1 is the crash-proof layer: Cloudflare egress to AniList is refused with 403
 * often enough that a page render cannot depend on a live call. Every successful
 * payload is stored here and served for 30 days, so a 403 degrades to slightly
 * older catalogue data instead of a 500 page.
 */
let d1 = null;
export function bindStore(env) {
  d1 = env?.DB || null;
}

const D1_DIRECT = 30 * 24 * 60 * 60;

async function readD1(body) {
  if (!d1) return null;
  try {
    const row = await d1
      .prepare("SELECT body FROM edge_cache WHERE key = ?1 AND t > ?2")
      .bind("al:" + body, Math.floor(Date.now() / 1000) - D1_DIRECT)
      .first();
    return row?.body ? JSON.parse(row.body) : null;
  } catch {
    return null;
  }
}

async function writeD1(body, payload) {
  if (!d1) return;
  try {
    await d1
      .prepare(
        "INSERT INTO edge_cache(key, body, t) VALUES (?1, ?2, ?3) " +
          "ON CONFLICT(key) DO UPDATE SET body = excluded.body, t = excluded.t"
      )
      .bind("al:" + body, JSON.stringify(payload), Math.floor(Date.now() / 1000))
      .run();
  } catch {
    // A cache write must never fail the request.
  }
}

export function store() {
  return typeof caches !== "undefined" && caches.default ? caches.default : null;
}

function keyFor(body) {
  return new Request(`https://ca-cache.internal/anilist?${encodeURIComponent(body)}`);
}

async function readCache(body) {
  const cache = store();
  if (!cache) return null;
  try {
    const hit = await cache.match(keyFor(body));
    return hit ? await hit.json() : null;
  } catch {
    return null;
  }
}

async function writeCache(body, payload, ttl) {
  const cache = store();
  if (!cache) return;
  try {
    await cache.put(
      keyFor(body),
      new Response(JSON.stringify(payload), {
        headers: {
          "content-type": "application/json",
          "cache-control": `public, max-age=${ttl}, stale-while-revalidate=3600`,
        },
      })
    );
  } catch {
    // Caching is an optimisation; a failed put must never break the request.
  }
}

function retryDelayMs(response, attempt) {
  const header = Number(response.headers.get("retry-after"));
  if (Number.isFinite(header) && header >= 0) return Math.min(8000, header * 1000);
  return Math.min(8000, 500 * (attempt + 1));
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * AniList reached through the Render origin.
 *
 * Cloudflare's egress is refused with 403 by AniList, which used to take every
 * catalogue page down. The origin runs on a different network, so the same
 * GraphQL body is relayed there and the result is stored like a native fetch.
 */
const ORIGIN = "https://camanime.onrender.com";

async function viaOrigin(body) {
  try {
    const res = await fetch(`${ORIGIN}/api/anilist`, {
      method: "POST",
      headers: {
        "content-type": "application/json",
        accept: "application/json",
        "user-agent": "CamAnime/2.13.0 (+https://camanime.onrender.com)",
      },
      body,
      signal: AbortSignal.timeout(15000),
    });
    if (!res.ok) return null;
    const payload = await res.json();
    return payload && payload.data && Object.keys(payload.data).length ? payload : null;
  } catch {
    return null;
  }
}


export async function alQuery(query, variables = {}, options = {}) {
  const { ttl = 600, retries = 2 } = options;
  const body = JSON.stringify({ query, variables });

  const cached = await readCache(body);
  if (cached) return cached;
  const stored = await readD1(body);
  if (stored) return stored;

  const running = inFlight.get(body);
  if (running) return running;

  const task = (async () => {
    let lastError;
    for (let attempt = 0; attempt <= retries; attempt++) {
      let response;
      try {
        response = await fetch(ENDPOINT, {
          method: "POST",
          headers: {
            "content-type": "application/json",
            accept: "application/json",
            // AniList sits behind its own edge and rejects requests with no
            // identifying agent (the Worker default is blocked), so every
            // catalogue page 500s from Cloudflare even though it works locally.
            "user-agent": "CamAnime/2.13.0 (+https://camanime.onrender.com)",
          },
          body,
        });
      } catch (err) {
        lastError = err;
        if (attempt < retries) {
          await sleep(400 * (attempt + 1));
          continue;
        }
        break;
      }

      if (response.status === 429 || response.status >= 500) {
        lastError = new Error(`AniList ${response.status}`);
        if (attempt < retries) {
          await sleep(retryDelayMs(response, attempt));
          continue;
        }
        // Rate-limited with no retries left: serve stale data when we have it.
        const stale = await readCache(body);
        if (stale) return stale;
        throw lastError;
      }

      if (!response.ok) {
        // 403/401 from Cloudflare egress is a block, not a bad query: serve the
        // stored copy, then the origin relay, rather than failing the page.
        const stale = await readD1(body);
        if (stale) return stale;
        const proxied = await viaOrigin(body);
        if (proxied) {
          await writeCache(body, proxied, ttl);
          await writeD1(body, proxied);
          return proxied;
        }
        throw new Error(`AniList ${response.status}`);
      }
      const payload = await response.json();
      await writeCache(body, payload, ttl);
      await writeD1(body, payload);
      return payload;
    }
    const stale = await readCache(body);
    if (stale) return stale;
    throw lastError instanceof Error ? lastError : new Error("AniList unavailable");
  })();

  inFlight.set(body, task);
  try {
    return await task;
  } finally {
    inFlight.delete(body);
  }
}

/** Convenience for callers that only want the query result. */
export async function alData(query, variables = {}, options = {}) {
  const payload = await alQuery(query, variables, options);
  return payload?.data;
}
