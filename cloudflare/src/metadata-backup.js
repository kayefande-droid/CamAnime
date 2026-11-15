/**
 * Render-independent metadata backup (Kitsu).
 *
 * AniList's GraphQL endpoint refuses Cloudflare egress (403) often enough that
 * the catalogue must not depend on a single host — and it must not depend on
 * the Render deployment either. Kitsu publishes the same anime with an explicit
 * `anilist/anime` mapping, so every backed-up entry keeps its AniList id and
 * therefore the same `/anime/<id>` and `/watch/<id>/<ep>` links. The mapping is
 * requested inline (`include=mappings`), so one call returns a whole rail.
 *
 * Only fields Kitsu actually publishes are filled. Genres and streaming
 * episodes stay empty rather than invented, and titles without an AniList
 * mapping are skipped so links never point at the wrong show.
 */
import { boundDb } from "./anilist.js";

const BASE = "https://kitsu.io/api/edge";
const UA = "CamAnime/2.18 (+https://camanjme.camanime.workers.dev)";
const MEMO = new Map();
const MEMO_TTL = 10 * 60 * 1000;
const KEEP_SECONDS = 30 * 24 * 60 * 60;

async function kitsu(path) {
  const memo = MEMO.get(path);
  if (memo && Date.now() - memo.at < MEMO_TTL) return memo.data;
  try {
    const res = await fetch(BASE + path, {
      headers: { accept: "application/vnd.api+json", "user-agent": UA },
      signal: AbortSignal.timeout(9000),
    });
    if (!res.ok) return null;
    const data = await res.json();
    MEMO.set(path, { at: Date.now(), data });
    return data;
  } catch {
    return null;
  }
}

async function dbGet(key) {
  const d1 = boundDb();
  if (!d1) return null;
  try {
    const row = await d1
      .prepare("SELECT body FROM edge_cache WHERE key = ?1 AND t > ?2")
      .bind(key, Math.floor(Date.now() / 1000) - KEEP_SECONDS)
      .first();
    return row?.body ? JSON.parse(row.body) : null;
  } catch {
    return null;
  }
}

async function dbPut(key, value) {
  const d1 = boundDb();
  if (!d1) return;
  try {
    await d1
      .prepare(
        "INSERT INTO edge_cache(key, body, t) VALUES (?1, ?2, ?3) " +
          "ON CONFLICT(key) DO UPDATE SET body = excluded.body, t = excluded.t",
      )
      .bind(key, JSON.stringify(value), Math.floor(Date.now() / 1000))
      .run();
  } catch {
    // A cache write must never fail the fallback.
  }
}

/** The AniList id attached to a Kitsu entry, or null when it has none. */
function anilistIdOf(item, included) {
  const relations = item?.relationships?.mappings?.data || [];
  const wanted = new Set(relations.map((rel) => String(rel.id)));
  for (const entry of included || []) {
    if (entry?.type !== "mappings" || !wanted.has(String(entry.id))) continue;
    const attrs = entry.attributes || {};
    if (!String(attrs.externalSite || "").toLowerCase().startsWith("anilist")) continue;
    const id = Number(attrs.externalId);
    if (Number.isFinite(id) && id > 0) return id;
  }
  return null;
}

const FORMATS = { TV: "TV", MOVIE: "MOVIE", OVA: "OVA", ONA: "ONA", SPECIAL: "SPECIAL", MUSIC: "MUSIC" };
const STATUSES = {
  current: "RELEASING",
  finished: "FINISHED",
  tba: "NOT_YET_RELEASED",
  unreleased: "NOT_YET_RELEASED",
  upcoming: "NOT_YET_RELEASED",
};

/** One Kitsu anime record in the AniList shape the pages and app already read. */
export function toMedia(item, anilistId) {
  const attrs = item?.attributes || {};
  const titles = attrs.titles || {};
  const poster = attrs.posterImage || {};
  const cover = attrs.coverImage || {};
  const year = attrs.startDate?.year ?? null;
  const subtype = String(attrs.subtype || "").toUpperCase();
  const score = Number(attrs.averageRating);
  return {
    id: anilistId,
    idMal: null,
    title: {
      english: titles.en || attrs.canonicalTitle || "",
      romaji: titles.en_jp || attrs.canonicalTitle || "",
      native: titles.ja_jp || "",
    },
    coverImage: {
      extraLarge: poster.large || poster.original || "",
      large: poster.large || poster.original || "",
      medium: poster.medium || poster.small || "",
      color: null,
    },
    bannerImage: cover.large || cover.original || null,
    format: FORMATS[subtype] || "TV",
    status: STATUSES[String(attrs.status || "").toLowerCase()] || "FINISHED",
    season: null,
    seasonYear: year,
    episodes: Number.isFinite(Number(attrs.episodeCount)) ? Number(attrs.episodeCount) : null,
    genres: [],
    averageScore: Number.isFinite(score) ? Math.round(score) : null,
    description: attrs.synopsis || "",
    trailer: null,
    synonyms: [],
    streamingEpisodes: [],
    nextAiringEpisode: null,
    metadata_source: "kitsu",
  };
}

/** Usable entries from one Kitsu list payload, paired with their AniList id. */
export function entriesFrom(payload) {
  const included = payload?.included || [];
  const out = [];
  for (const item of payload?.data || []) {
    const anilistId = anilistIdOf(item, included);
    if (!anilistId) continue;
    out.push({
      anilistId,
      kitsuId: String(item?.id || ""),
      media: toMedia(item, anilistId),
    });
  }
  return out;
}

export function animeListFrom(payload) {
  return entriesFrom(payload).map((entry) => entry.media);
}

async function remember(entries) {
  await Promise.all(
    entries.map(async (entry) => {
      await dbPut(`kmap:${entry.anilistId}`, entry.kitsuId);
      await dbPut(`kcard:${entry.anilistId}`, { kitsuId: entry.kitsuId, media: entry.media });
    }),
  );
}

async function loadRail(params, limit) {
  const size = Math.max(1, Math.min(50, limit | 0 || 24));
  const payload = await kitsu(`/anime?${params}&include=mappings&page%5Blimit%5D=${size}`);
  const entries = entriesFrom(payload);
  if (entries.length) await remember(entries);
  return entries.map((entry) => entry.media);
}

const RAILS = {
  trending: ["filter%5Bstatus%5D=current&sort=-userCount", 24],
  airing: ["filter%5Bstatus%5D=current&sort=-averageRating", 18],
  movies: ["filter%5Bsubtype%5D=movie&sort=-userCount", 12],
  popular: ["sort=-userCount", 18],
  top_rated: ["sort=-averageRating", 18],
  recently_added: ["sort=-createdAt", 18],
  series: ["filter%5Bsubtype%5D=TV&sort=-userCount", 12],
};

/** Home rails for the server-rendered pages: trending / airing / movies. */
export async function backupRails() {
  const [trending, airing, movies] = await Promise.all([
    loadRail(...RAILS.trending),
    loadRail(...RAILS.airing),
    loadRail(...RAILS.movies),
  ]);
  if (!trending.length && !airing.length && !movies.length) return null;
  return { trending, airing, movies };
}

/** The six app rails, same keys the Flutter home expects. */
export async function backupCatalogRails() {
  const [trending, popular, topRated, fresh, movies, series] = await Promise.all([
    loadRail(...RAILS.trending),
    loadRail(...RAILS.popular),
    loadRail(...RAILS.top_rated),
    loadRail(...RAILS.recently_added),
    loadRail(...RAILS.movies),
    loadRail(...RAILS.series),
  ]);
  if (!trending.length && !popular.length && !topRated.length) return null;
  return {
    trending,
    popular,
    top_rated: topRated,
    recently_added: fresh,
    movies,
    series,
  };
}

export async function backupSearchMedia(q, limit = 36) {
  const text = String(q || "").trim();
  if (!text) return [];
  const size = Math.max(1, Math.min(50, limit | 0 || 36));
  const payload = await kitsu(
    `/anime?filter%5Btext%5D=${encodeURIComponent(text)}&include=mappings&page%5Blimit%5D=${size}`,
  );
  const entries = entriesFrom(payload);
  if (entries.length) await remember(entries);
  return entries.map((entry) => entry.media);
}

/** Details for an AniList id, from the stored Kitsu card and its mapping. */
export async function backupDetails(id) {
  const row = await dbGet(`kcard:${id}`);
  if (!row?.media) return null;
  if (row.kitsuId) {
    const payload = await kitsu(`/anime/${row.kitsuId}?include=mappings`);
    if (payload?.data) {
      const media = toMedia(payload.data, Number(id));
      await remember([{ anilistId: Number(id), kitsuId: String(row.kitsuId), media }]);
      return media;
    }
  }
  return row.media;
}
