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

export async function alQuery(query, variables = {}, options = {}) {
  const { ttl = 600, retries = 2 } = options;
  const body = JSON.stringify({ query, variables });

  const cached = await readCache(body);
  if (cached) return cached;

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
            "user-agent": "CamAnime/2.12.0 (+https://camanime.onrender.com)",
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

      if (!response.ok) throw new Error(`AniList ${response.status}`);
      const payload = await response.json();
      await writeCache(body, payload, ttl);
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
