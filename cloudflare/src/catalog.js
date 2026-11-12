/** AniList catalog: home grids, search, details, episodes. Public GraphQL, cached at the edge. */
import { alQuery } from "./anilist.js";

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
`;

/**
 * The whole home page in ONE GraphQL request. Three separate queries meant
 * three rate-limit hits per visitor; aliasing them into a single document
 * keeps the same data for a third of the budget.
 */
export async function homeGrids() {
  const payload = await alQuery(
    `query{
      trending: Page(perPage:24){media(type:ANIME,sort:TRENDING_DESC,isAdult:false){${CARD_FIELDS}}}
      airing: Page(perPage:18){media(type:ANIME,sort:SCORE_DESC,status:RELEASING,isAdult:false){${CARD_FIELDS}}}
      movies: Page(perPage:12){media(type:ANIME,sort:POPULARITY_DESC,format:MOVIE,isAdult:false){${CARD_FIELDS}}}
    }`,
    {},
    { ttl: 900 }
  );
  const data = payload.data;
  return {
    trending: data.trending.media,
    airing: data.airing.media,
    movies: data.movies.media,
  };
}

export async function search(q) {
  const data = await alQuery(
    `query($s:String){Page(perPage:36){media(type:ANIME,search:$s,isAdult:false,sort:SEARCH_MATCH){${CARD_FIELDS}}}}`,
    { s: q }
  );
  return data.data.Page.media;
}

export async function details(id) {
  const data = await alQuery(
    `query($id:Int){Media(id:$id,type:ANIME){${CARD_FIELDS}
      streamingEpisodes { title thumbnail url site }
      nextAiringEpisode { episode airingAt }
    }}`,
    { id }
  );
  return data.data.Media;
}

/** Watch page context: anime + episode list + current episode. */
export async function watchContext(id, epNum) {
  const data = await alQuery(
    `query($id:Int){Media(id:$id,type:ANIME){id title{romaji english}
      episodes
      coverImage{large}
      streamingEpisodes { title thumbnail url site }
    }}`,
    { id }
  );
  const m = data.data.Media;
  const eps = (m.streamingEpisodes || []).map((se, i) => ({
    n: i + 1, title: se.title, url: se.url, site: se.site, thumbnail: se.thumbnail,
  }));
  const ep = eps[Math.max(0, Math.min((epNum | 0) - 1, eps.length - 1))] || null;
  return { anime: m, episodes: eps, current: ep, epNum };
}

/**
 * The same card anatomy the Render templates render, using the shared
 * stylesheet classes: poster with badges, hover actions, and a body link.
 * Nothing here invents data — a missing score or year simply omits the chip.
 */
export function card({ coverImage, title, id, averageScore, format, seasonYear, status }) {
  const name = title.english || title.romaji || title.native || "Untitled";
  const img = coverImage?.extraLarge || coverImage?.large || coverImage?.medium || "";
  const rating = averageScore ? (averageScore / 10).toFixed(1) : "";
  const meta = [format || "TV", seasonYear || status || "Anime"];
  return `<div class="anime-card">
    <div class="card-poster-wrap">
      ${rating ? `<div class="card-badges-top"><span class="score-badge">★ ${rating}</span></div>` : ""}
      <img src="${esc(img)}" alt="${esc(name)} poster" loading="lazy" decoding="async" referrerpolicy="no-referrer" onerror="this.onerror=null;this.src='/static/brand/camanime-icon.svg'">
      <div class="card-hover-actions"><div class="card-action-row">
        <a class="card-btn-play" href="/anime/${id}"><i class="fas fa-circle-info" aria-hidden="true"></i> Episode details</a>
      </div></div>
    </div>
    <a class="card-body" href="/anime/${id}" style="text-decoration:none;">
      <div class="card-title">${esc(name)}</div>
      <div class="card-submeta"><span>${esc(meta[0])}</span><span>${esc(meta[1])}</span></div>
    </a>
  </div>`;
}

// esc is imported lazily-free here to avoid a cycle: define inline
function esc(s) {
  return String(s ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}
