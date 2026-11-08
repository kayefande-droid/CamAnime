/**
 * Developer streaming API (free tier).
 *
 * One provider is exposed: AnimeHeaven direct MP4, resolved through the same
 * extractor the site's player uses (providers.js). Streams are handed back as
 * absolute proxy URLs so a third-party site can embed them without knowing
 * about rotating provider hosts or Referer rules.
 *
 * Nothing here invents a URL: when the extractor resolves no file the endpoint
 * answers 404 with a message instead of a fake stream.
 */
import { json, sha256Hex, randomToken } from "./util.js";
import { alData } from "./anilist.js";
import { currentUser } from "./auth.js";
import { episodeBundle } from "./providers.js";
import { animeDetails } from "./mobile.js";

export const PROVIDER = "animeheaven";
export const PROVIDER_LABEL = "AnimeHeaven (direct MP4)";
export const DAILY_LIMIT = 1000;
export const MAX_KEYS = 3;
const KEY_PREFIX = "ca_live_";

export const CORS = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "x-api-key, authorization, content-type",
  "access-control-allow-methods": "GET, OPTIONS",
  "access-control-expose-headers": "x-ratelimit-limit, x-ratelimit-remaining",
};

const today = () => new Date().toISOString().slice(0, 10);

/** POST /api/developer/keys — create a key for the signed-in user. */
export async function createKey(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in to create an API key." }, 401);

  const body = await request.json().catch(() => ({}));
  const name = (String(body.name || "").trim() || "My site").slice(0, 40);

  const active = await env.DB.prepare(
    "SELECT COUNT(*) AS n FROM api_keys WHERE email = ?1 AND revoked = 0"
  ).bind(user.email).first();
  if ((active?.n ?? 0) >= MAX_KEYS) {
    return json({ error: `The free tier keeps ${MAX_KEYS} active keys. Revoke one first.` }, 429);
  }

  const key = KEY_PREFIX + randomToken(24);
  const id = crypto.randomUUID();
  const created = Date.now();
  await env.DB.prepare(
    "INSERT INTO api_keys (id, email, name, prefix, key_hash, plan, created, last_used, revoked) VALUES (?1, ?2, ?3, ?4, ?5, 'free', ?6, 0, 0)"
  ).bind(id, user.email, name, key.slice(0, 14), await sha256Hex(key), created).run();

  return json({
    ok: true,
    id,
    name,
    key,
    created,
    provider: PROVIDER,
    daily_limit: DAILY_LIMIT,
    note: "Copy this key now — it is stored hashed and cannot be shown again.",
  }, 201);
}

/** GET /api/developer/keys — list the caller's keys (never the secret). */
export async function listKeys(env, request) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in to manage API keys." }, 401);
  const rows = await env.DB.prepare(
    "SELECT id, name, prefix, plan, created, last_used, revoked FROM api_keys WHERE email = ?1 ORDER BY created DESC LIMIT 20"
  ).bind(user.email).all();
  const usage = await env.DB.prepare(
    "SELECT key_id, calls FROM api_usage WHERE day = ?1 AND key_id IN (SELECT id FROM api_keys WHERE email = ?2)"
  ).bind(today(), user.email).all();
  const calls = Object.fromEntries((usage.results || []).map((r) => [r.key_id, r.calls]));
  return json({
    keys: (rows.results || []).map((k) => ({ ...k, calls_today: calls[k.id] || 0 })),
    daily_limit: DAILY_LIMIT,
    max_keys: MAX_KEYS,
    provider: PROVIDER,
  });
}

/** DELETE /api/developer/keys/:id — revoke without deleting history. */
export async function revokeKey(env, request, id) {
  const user = await currentUser(env, request);
  if (!user) return json({ error: "Sign in to manage API keys." }, 401);
  const row = await env.DB.prepare("SELECT id FROM api_keys WHERE id = ?1 AND email = ?2")
    .bind(String(id || ""), user.email).first();
  if (!row) return json({ error: "Key not found." }, 404);
  await env.DB.prepare("UPDATE api_keys SET revoked = 1 WHERE id = ?1").bind(row.id).run();
  return json({ ok: true, id: row.id });
}

function keyFromRequest(request, url) {
  const header = (request.headers.get("x-api-key") || "").trim();
  if (header) return header;
  const auth = request.headers.get("authorization") || "";
  if (/^bearer\s+/i.test(auth)) return auth.replace(/^bearer\s+/i, "").trim();
  return (url.searchParams.get("key") || "").trim();
}

/**
 * GET /api/v1/stream/:animeId/:ep  (x-api-key)
 * The public, cross-origin endpoint developers embed.
 */
export async function stream(env, request, url, animeId, epRaw) {
  const key = keyFromRequest(request, url);
  if (!key) {
    return json({
      error: "Missing API key. Send it as the x-api-key header.",
      docs: url.origin + "/developers",
      create_key: url.origin + "/developers#keys",
    }, 401, CORS);
  }

  const row = await env.DB.prepare(
    "SELECT id, revoked FROM api_keys WHERE key_hash = ?1"
  ).bind(await sha256Hex(key)).first();
  if (!row || row.revoked) {
    return json({ error: "Invalid or revoked API key." }, 403, CORS);
  }

  const day = today();
  await env.DB.prepare(
    "INSERT INTO api_usage (key_id, day, calls) VALUES (?1, ?2, 1) ON CONFLICT(key_id, day) DO UPDATE SET calls = calls + 1"
  ).bind(row.id, day).run();
  const usage = await env.DB.prepare("SELECT calls FROM api_usage WHERE key_id = ?1 AND day = ?2")
    .bind(row.id, day).first();
  const calls = usage?.calls ?? 1;
  if (calls > DAILY_LIMIT) {
    return json({
      error: `Daily free-tier limit of ${DAILY_LIMIT} calls reached.`,
      calls_today: calls,
      daily_limit: DAILY_LIMIT,
    }, 429, CORS);
  }

  const ep = Math.max(1, parseInt(epRaw, 10) || 1);
  const audio = (url.searchParams.get("audio") || "sub").toLowerCase() === "dub" ? "dub" : "sub";

  let anime;
  try {
    anime = await animeDetails(animeId);
  } catch {
    anime = null;
  }
  if (!anime) return json({ error: "Anime not found on AniList." }, 404, CORS);

  let bundle;
  try {
    bundle = await episodeBundle({
      anilistId: Number(animeId) || 0,
      epNum: ep,
      titles: [anime.title, anime.romaji, anime.native].filter(Boolean),
      malId: anime.mal_id || null,
      preferredAudio: audio,
    });
  } catch {
    return json({ error: "The provider could not be reached. Retry shortly." }, 502, CORS);
  }

  const sources = (bundle?.servers || [])
    .filter((s) => s.provider === PROVIDER && s.playback_mode === "mp4" && s.stream_url);

  if (!sources.length) {
    return json({
      error: "No source for this episode yet.",
      anime: { id: String(anime.id), title: anime.title },
      episode: ep,
      provider: PROVIDER,
      hint: "The provider list is live; a title that has no file on it answers 404 rather than a dead link.",
    }, 404, CORS);
  }

  const absolute = (p) => {
    try {
      return new URL(p, url.origin).href;
    } catch {
      return p;
    }
  };

  await env.DB.prepare("UPDATE api_keys SET last_used = ?1 WHERE id = ?2").bind(Date.now(), row.id).run();

  const headers = {
    ...CORS,
    "x-ratelimit-limit": String(DAILY_LIMIT),
    "x-ratelimit-remaining": String(Math.max(0, DAILY_LIMIT - calls)),
  };
  return json({
    api: "camanime-stream",
    version: 1,
    provider: PROVIDER,
    provider_label: PROVIDER_LABEL,
    anime: { id: String(anime.id), title: anime.title, image: anime.image, episodes: anime.episodes ?? null },
    episode: ep,
    audio,
    streams: sources.map((s, i) => ({
      id: s.id || `stream-${i + 1}`,
      label: s.name || `Mirror ${i + 1}`,
      type: "video/mp4",
      quality: s.quality || "Source",
      url: absolute(s.stream_url),
    })),
    usage: { calls_today: calls, daily_limit: DAILY_LIMIT },
    attribution: "Powered by CamAnime — https://camanime.onrender.com",
    docs: url.origin + "/developers",
  }, 200, headers);
}

/** OPTIONS preflight for the public endpoint. */
export function preflight() {
  return new Response(null, { status: 204, headers: CORS });
}

export const SORTS = {
  popular: "POPULARITY_DESC",
  trending: "TRENDING_DESC",
  rating: "SCORE_DESC",
  recent: "START_DATE_DESC",
  alphabetical: "TITLE_ROMAJI",
};

export const FORMATS = ["TV", "TV_SHORT", "MOVIE", "OVA", "ONA", "SPECIAL"];

/**
 * Validates the caller's key and books the call against the daily quota.
 * Returns { id, calls } on success or { response } when the request is done.
 */
async function consumeKey(env, request, url) {
  const key = keyFromRequest(request, url);
  if (!key) {
    return { response: json({
      error: "Missing API key. Send it as the x-api-key header.",
      docs: url.origin + "/developers",
      create_key: url.origin + "/developers#keys",
    }, 401, CORS) };
  }
  const row = await env.DB.prepare(
    "SELECT id, revoked FROM api_keys WHERE key_hash = ?1"
  ).bind(await sha256Hex(key)).first();
  if (!row || row.revoked) {
    return { response: json({ error: "Invalid or revoked API key." }, 403, CORS) };
  }
  const day = today();
  await env.DB.prepare(
    "INSERT INTO api_usage (key_id, day, calls) VALUES (?1, ?2, 1) ON CONFLICT(key_id, day) DO UPDATE SET calls = calls + 1"
  ).bind(row.id, day).run();
  const usage = await env.DB.prepare(
    "SELECT calls FROM api_usage WHERE key_id = ?1 AND day = ?2"
  ).bind(row.id, day).first();
  const calls = usage?.calls ?? 1;
  if (calls > DAILY_LIMIT) {
    return { response: json({
      error: `Daily free-tier limit of ${DAILY_LIMIT} calls reached.`,
      calls_today: calls,
      daily_limit: DAILY_LIMIT,
    }, 429, CORS) };
  }
  await env.DB.prepare("UPDATE api_keys SET last_used = ?1 WHERE id = ?2")
    .bind(Date.now(), row.id).run();
  return { id: row.id, calls };
}

function card(media) {
  const title = media.title || {};
  const cover = media.coverImage || {};
  return {
    id: String(media.id || ""),
    idMal: media.idMal ?? null,
    title: title.english || title.romaji || title.native || "",
    title_romaji: title.romaji || "",
    image: cover.large || cover.medium || "",
    episodes: media.episodes ?? null,
    score: media.averageScore ?? null,
    format: media.format ?? null,
    year: media.seasonYear ?? null,
  };
}

const LIST_QUERY = `
query($page:Int,$perPage:Int,$sort:[MediaSort],$search:String,$format:MediaFormat,$genre:String){
  Page(page:$page,perPage:$perPage){
    pageInfo{hasNextPage total}
    media(type:ANIME,sort:$sort,search:$search,format:$format,genre:$genre,isAdult:false){
      id idMal format seasonYear episodes averageScore
      title{romaji english native}
      coverImage{large medium}
    }
  }
}`;

const DETAIL_QUERY = `
query($id:Int){
  Media(id:$id,type:ANIME){
    id idMal format seasonYear episodes duration averageScore status genres
    description(asHtml:false)
    title{romaji english native}
    coverImage{large medium extraLarge}
    bannerImage
    studios(isMain:true){nodes{name}}
  }
}`;

/** GET /api/v1/anime — catalogue, filters and search in one keyed call. */
export async function catalog(env, request, url) {
  const guard = await consumeKey(env, request, url);
  if (guard.response) return guard.response;

  const q = (url.searchParams.get("q") || url.searchParams.get("search") || "").trim().slice(0, 100);
  const genre = (url.searchParams.get("genre") || "").trim();
  const format = (url.searchParams.get("format") || "").trim().toUpperCase();
  const sortKey = (url.searchParams.get("sort") || "popular").trim().toLowerCase();
  const page = Math.min(1000, Math.max(1, parseInt(url.searchParams.get("page") || "1", 10) || 1));
  const perPage = Math.min(50, Math.max(1, parseInt(url.searchParams.get("perPage") || "24", 10) || 24));

  if (!SORTS[sortKey]) {
    return json({ error: "Unsupported sort.", allowed: Object.keys(SORTS) }, 400, CORS);
  }
  if (format && !FORMATS.includes(format)) {
    return json({ error: "Unsupported format.", allowed: FORMATS }, 400, CORS);
  }

  const variables = { page, perPage, sort: [SORTS[sortKey]] };
  if (q) variables.search = q;
  if (genre) variables.genre = genre;
  if (format) variables.format = format;

  let data;
  try {
    data = await alData(LIST_QUERY, variables);
  } catch {
    return json({ error: "The catalogue provider is unavailable." }, 502, CORS);
  }
  const rows = (data?.Page?.media || []).filter(Boolean).map(card);
  return json({
    api: "camanime-catalog",
    version: 1,
    query: { q, genre, format, sort: sortKey },
    results: rows,
    page,
    perPage,
    has_next_page: Boolean(data?.Page?.pageInfo?.hasNextPage),
    usage: { calls_today: guard.calls, daily_limit: DAILY_LIMIT },
    attribution: "Powered by CamAnime",
  }, 200, {
    ...CORS,
    "x-ratelimit-limit": String(DAILY_LIMIT),
    "x-ratelimit-remaining": String(Math.max(0, DAILY_LIMIT - guard.calls)),
  });
}

/** GET /api/v1/anime/:id — one title with its playable episode list. */
export async function animeDetail(env, request, url, animeId) {
  const guard = await consumeKey(env, request, url);
  if (guard.response) return guard.response;

  let data;
  try {
    data = await alData(DETAIL_QUERY, { id: Number(animeId) });
  } catch {
    return json({ error: "The catalogue provider is unavailable." }, 502, CORS);
  }
  const media = data?.Media;
  if (!media) return json({ error: "Anime not found." }, 404, CORS);

  const total = Number(media.episodes || 0);
  const base = url.origin + "/api/v1/stream/" + animeId + "/";
  const anime = {
    ...card(media),
    description: media.description || "",
    status: media.status ?? null,
    genres: media.genres || [],
    duration: media.duration ?? null,
    banner: media.bannerImage || "",
    studios: (media.studios?.nodes || []).map((n) => n?.name).filter(Boolean),
    episode_list: Array.from({ length: total }, (_, i) => ({
      episode: i + 1,
      stream: base + (i + 1),
    })),
  };
  return json({
    api: "camanime-anime",
    version: 1,
    anime,
    usage: { calls_today: guard.calls, daily_limit: DAILY_LIMIT },
    attribution: "Powered by CamAnime",
  }, 200, CORS);
}
