/**
 * Mobile app API, served entirely by this worker.
 *
 * The Flutter build calls /api/v1/* and /api/episode-sources/*; those routes
 * exist on the Flask/Render deployment. Serving them here means an app pointed
 * at this worker never needs the Render origin at all.
 *
 * Everything below is AniList GraphQL + this deployment's own D1/R2. There is
 * no fetch to camanime.onrender.com anywhere in this file, and no fallback to
 * it if a lookup fails.
 */
import { json } from "./util.js";
import { getComments } from "./api.js";
import { alQuery } from "./anilist.js";
import { episodeBundle } from "./providers.js";
import { route as mediaRoute } from "./media.js";
import {
  APK_SHA256,
  LATEST_BUILD,
  LATEST_VERSION,
  MIN_SUPPORTED_BUILD,
  MIN_SUPPORTED_VERSION,
  RELEASE_NOTES,
  buildIsBlocked,
  downloadUrls,
  releasePolicy,
} from "./release.js";

const CARD_FIELDS = `
  id
  title { romaji english native }
  coverImage { extraLarge large medium color }
  bannerImage
  format
  status
  season
  seasonYear
  episodes
  genres
  averageScore
  description
  trailer { id site }
`;

/** Query result only; coalescing, 429 retries and caching live in anilist.js. */
const al = async (query, variables = {}) =>
  (await alQuery(query, variables, { ttl: 900 })).data;

function stripHtml(value) {
  return String(value || "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&quot;/g, '"')
    .replace(/&#039;/g, "'")
    .replace(/&amp;/g, "&")
    .trim();
}

/** One AniList media object -> the card shape the app renders. */
export function card(m) {
  const t = m?.title || {};
  const trailer =
    String(m?.trailer?.site || "").toLowerCase() === "youtube" &&
    /^[A-Za-z0-9_-]{11}$/.test(String(m?.trailer?.id || ""))
      ? String(m.trailer.id)
      : "";
  return {
    id: String(m?.id ?? ""),
    title: t.english || t.romaji || t.native || "Untitled",
    romaji: t.romaji || "",
    native: t.native || "",
    image: m?.coverImage?.extraLarge || m?.coverImage?.large || m?.coverImage?.medium || "",
    banner: m?.bannerImage || "",
    format: m?.format || "",
    status: m?.status || "",
    season: m?.season || "",
    year: m?.seasonYear ?? null,
    episodes: m?.episodes ?? null,
    genres: m?.genres || [],
    score: m?.averageScore ?? null,
    synopsis: stripHtml(m?.description),
    trailer_id: trailer,
  };
}

/**
 * All six home rails in ONE request. Six parallel queries per launch was the
 * main source of AniList 429s from the app; one aliased document is one hit
 * on the rate limit and one cache entry.
 */
export async function catalogHome() {
  const data = await al(`query{
    trending: Page(perPage:24){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){${CARD_FIELDS}}}
    popular: Page(perPage:18){media(type:ANIME,sort:POPULARITY_DESC,isAdult:false){${CARD_FIELDS}}}
    topRated: Page(perPage:18){media(type:ANIME,sort:SCORE_DESC,isAdult:false){${CARD_FIELDS}}}
    fresh: Page(perPage:18){media(type:ANIME,sort:ID_DESC,isAdult:false){${CARD_FIELDS}}}
    movies: Page(perPage:12){media(type:ANIME,sort:POPULARITY_DESC,format:MOVIE,isAdult:false){${CARD_FIELDS}}}
    series: Page(perPage:12){media(type:ANIME,sort:POPULARITY_DESC,format:TV,isAdult:false){${CARD_FIELDS}}}
  }`);
  const pick = (rows) => (rows?.media || []).map(card);
  const trendingRows = pick(data?.trending);
  return {
    trending: trendingRows,
    popular: pick(data?.popular),
    top_rated: pick(data?.topRated),
    recently_added: pick(data?.fresh),
    movies: pick(data?.movies),
    series: pick(data?.series),
    featured: trendingRows[0] || null,
  };
}

export async function search(q, limit = 36) {
  const data = await al(
    `query($s:String){Page(perPage:${Math.max(1, Math.min(50, limit | 0 || 36))}){media(type:ANIME,search:$s,isAdult:false,sort:SEARCH_MATCH){${CARD_FIELDS}}}}`,
    { s: q }
  );
  return (data?.Page?.media || []).map(card);
}

export async function animeDetails(id) {
  const data = await al(
    `query($id:Int){Media(id:$id,type:ANIME){idMal ${CARD_FIELDS}
      streamingEpisodes { title thumbnail url site }
      nextAiringEpisode { episode airingAt }
      relations { edges { relationType node { id type title{romaji english} coverImage{large} format episodes } } }
    }}`,
    { id: Number(id) || 0 }
  );
  const m = data?.Media;
  if (!m) return null;
  const base = card(m);
  const seasons = (m.relations?.edges || [])
    .filter((e) => e?.node?.type === "ANIME")
    .map((e) => ({
      id: String(e.node.id),
      title: e.node.title?.english || e.node.title?.romaji || "Untitled",
      image: e.node.coverImage?.large || "",
      relation: e.relationType || "",
      episodes: e.node.episodes ?? null,
      format: e.node.format || "",
    }));
  return {
    ...base,
    mal_id: m.idMal ?? null,
    title_romaji: base.romaji,
    seasons,
    next_airing: m.nextAiringEpisode || null,
    streaming_metadata: (m.streamingEpisodes || []).map((se, i) => ({
      episode: i + 1,
      title: se.title || `Episode ${i + 1}`,
      image: se.thumbnail || "",
      site: se.site || "",
      url: se.url || "",
    })),
  };
}

/**
 * Episode sources: the ported AnimeHeaven/Anikoto/Kiwi extractors run here, in
 * this worker, and every returned mp4/HLS URL is proxied so the CDN's Referer
 * checks pass. If no extractor resolves a real file, official AniList episode
 * pages are offered instead — a URL is never invented.
 */
export async function episodeSources(id, ep, audio = "sub") {
  const anime = await animeDetails(id);
  if (!anime) return null;

  const n = Math.max(1, ep | 0);
  const titles = [anime.title, anime.romaji, anime.native].filter(Boolean);
  const bundle = await episodeBundle({
    anilistId: Number(id) || 0,
    epNum: n,
    titles: titles.length ? titles : [`Anime ${id}`],
    malId: anime.mal_id || null,
    preferredAudio: audio,
  });

  const playable = bundle.servers.some(
    (server) => server.playback_mode === "mp4" || server.playback_mode === "hls"
  );

  if (!playable) {
    const rows = anime.streaming_metadata || [];
    const current = rows[n - 1];
    if (current && current.url) {
      bundle.servers.push({
        id: "anilist-official",
        name: current.site || "Official stream",
        provider: "anilist",
        audio,
        playback_mode: "iframe",
        stream_url: current.url,
        quality: "",
        subtitles: [],
        badge: "OFFICIAL",
      });
      bundle.active_server = bundle.active_server || bundle.servers[bundle.servers.length - 1];
    }
  }

  bundle.audio = audio;
  bundle.extraction = playable ? "scraper" : "fallback";
  return bundle;
}

export async function trailerFor(animeId, title) {
  if (animeId) {
    const anime = await animeDetails(animeId);
    if (anime?.trailer_id) return { youtube_id: anime.trailer_id, source: "anilist" };
  }
  if (!title) return { youtube_id: "", source: "none" };
  const data = await al(
    `query($s:String){Page(perPage:1){media(type:ANIME,search:$s,isAdult:false){trailer{id site}}}}`,
    { s: title }
  );
  const t = data?.Page?.media?.[0]?.trailer;
  const id =
    t && String(t.site).toLowerCase() === "youtube" &&
    /^[A-Za-z0-9_-]{11}$/.test(String(t.id || ""))
      ? String(t.id)
      : "";
  return { youtube_id: id, source: id ? "anilist-search" : "none" };
}

export async function genres() {
  const data = await al(`query{GenreCollection}`);
  return Array.isArray(data?.GenreCollection) ? data.GenreCollection : [];
}

export async function genreAnime(slug, limit = 36) {
  const data = await al(
    `query($g:String){Page(perPage:${Math.max(1, Math.min(50, limit | 0 || 36))}){media(type:ANIME,genre:$g,isAdult:false,sort:POPULARITY_DESC){${CARD_FIELDS}}}}`,
    { g: String(slug) }
  );
  return (data?.Page?.media || []).map(card);
}

/**
 * Router for the app's endpoints. Returns a Response, or null when the path
 * is not part of the mobile surface.
 */
export async function route(env, request, url, parts) {
  const [p0, p1, p2, p3] = parts;
  if (p0 !== "api" || request.method !== "GET") return null;

  if (p1 === "proxy" || p1 === "download") {
    const media = await mediaRoute(request, url, parts);
    if (media) return media;
  }

  if (p1 === "version") {
    // Shape read by lib/core/app_updater.dart: app_version, apk_url, sha256,
    // whats_new. apk_url must live on this worker's own host — the updater
    // rejects a URL whose host differs from the configured API host.
    const app = downloadUrls(url.origin);
    return json({
      app_version: LATEST_VERSION,
      version_code: LATEST_BUILD,
      latest_version: LATEST_VERSION,
      latest_version_code: LATEST_BUILD,
      minimum_supported_version: MIN_SUPPORTED_VERSION,
      minimum_supported_version_code: MIN_SUPPORTED_BUILD,
      apk_url: app.cloudflare,
      sha256: APK_SHA256,
      whats_new: RELEASE_NOTES,
      platform: "cloudflare-workers",
      download_url: "/get/android",
      architecture: "workers+d1+r2",
    }, 200, { "cache-control": "public, max-age=60" });
  }

  // Version gate polled at launch and on resume by lib/core/version_gate.dart.
  // 200 { required, policy } when the build is allowed; 426 { ...policy }
  // when it must be refused. No binding is touched, so this answers even when
  // D1 or R2 is degraded.
  if (p1 === "app" && p2 === "ping") {
    const build = parseInt(request.headers.get("X-CamAnime-Build") || "", 10);
    const policy = releasePolicy(url.origin, build);
    const blocked = buildIsBlocked(build);
    return json(
      blocked ? policy : { required: false, policy },
      blocked ? 426 : 200,
      { "cache-control": "no-store" },
    );
  }

  if (p1 === "v1" && p2 === "catalog" && p3 === "home") {
    return json({ catalog: await catalogHome(), offline: false });
  }

  if (p1 === "v1" && p2 === "search") {
    const q = (url.searchParams.get("q") || "").trim();
    const limit = parseInt(url.searchParams.get("limit") || "36", 10);
    if (!q) return json({ results: [] });
    return json({ results: await search(q, limit), query: q });
  }

  if (p1 === "v1" && p2 === "genres" && p3) {
    const limit = parseInt(url.searchParams.get("limit") || "36", 10);
    return json({ results: await genreAnime(decodeURIComponent(p3), limit) });
  }

  if (p1 === "v1" && p2 === "genres") {
    return json({ genres: await genres() });
  }

  if (p1 === "anime" && p2 && !p3) {
    const anime = await animeDetails(p2);
    if (!anime) return json({ error: "Anime not found" }, 404);
    return json({ anime });
  }

  if (p1 === "episode-sources" && p2) {
    const bundle = await episodeSources(
      p2,
      parseInt(p3 || "1", 10),
      (url.searchParams.get("audio") || "sub").toLowerCase() === "dub" ? "dub" : "sub"
    );
    if (!bundle) return json({ error: "Anime not found" }, 404);
    return json(bundle);
  }

  if (p1 === "trailer") {
    return json(
      await trailerFor(
        (url.searchParams.get("anime_id") || "").trim(),
        (url.searchParams.get("title") || "").trim()
      )
    );
  }

  if (p1 === "community" && p2 === "comments") {
    const animeId = (url.searchParams.get("anime_id") || "").trim();
    return getComments(env, request, animeId, url.searchParams.get("ep") || "");
  }

  return null;
}
