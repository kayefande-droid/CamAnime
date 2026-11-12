/**
 * Port of streaming_providers.py to Cloudflare Workers.
 *
 * Providers:
 *  - AnimeHeaven: /fastsearch.php, /anime.php?<id>, /gate.php with Cookie key=<ep>
 *    -> direct MP4 mirrors.
 *  - Anikoto + MegaPlay: /filter, /watch/<slug>, /ajax/episode/list,
 *    /ajax/server/list, /ajax/server -> 1080p HLS, decrypted with AES-256-CBC
 *    (WebCrypto replaces the `cryptography` package), plus subtitles and
 *    intro/outro marks.
 *  - Kiwi mapper (mapper.nekostream.site) -> 360/720/1080 direct downloads.
 *
 * Behaviour is kept deliberately close to the Python original: same title
 * scoring thresholds, same rejection of low-confidence matches, same
 * "never invent a URL" rule. HTML is parsed with targeted regexes because
 * BeautifulSoup has no Worker equivalent.
 */

const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

const UA_POOL = [
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36",
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:127.0) Gecko/20100101 Firefox/127.0",
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15",
];
/** A fresh browser identity per request: one constant UA is the easiest scrape
 *  to fingerprint, and the client hints make the navigation look like a real
 *  desktop visit rather than a fetch from a server. */
function pickUA() {
  return UA_POOL[Math.floor(Math.random() * UA_POOL.length)];
}

export const HEAVEN_BASE = "https://animeheaven.me";
export const ANIKOTO_BASE = "https://anikoto.net";
export const KIWI_BASE = "https://mapper.nekostream.site";

const TYPE_INDICATOR_WORDS = new Set([
  "ova", "ona", "special", "specials", "movie", "film",
  "recap", "picture", "pv", "season", "part", "cour", "saga",
]);

// ---------------------------------------------------------------------------
// Title matching (identical scores to the Python implementation)
// ---------------------------------------------------------------------------
export function normalizeTitle(title) {
  return String(title || "").toLowerCase().replace(/[^a-z0-9]/g, "");
}

function significantWords(s) {
  return String(s || "")
    .toLowerCase()
    .replace(/[^a-z0-9\s]/g, " ")
    .split(/\s+/)
    .filter((w) => w.length >= 2);
}

function addsUnrequestedTypeIndicator(query, candidateTitle) {
  const q = new Set(significantWords(query));
  return significantWords(candidateTitle).some(
    (w) => TYPE_INDICATOR_WORDS.has(w) && !q.has(w)
  );
}

function scoreTitleSingle(query, candidate) {
  const needle = normalizeTitle(query);
  const hay = normalizeTitle(candidate);
  if (!needle || !hay) return 0;
  if (hay === needle) return 100;

  const ratio = Math.min(needle.length, hay.length) / Math.max(needle.length, hay.length);
  const queryIsLonger = needle.length > hay.length;
  const missingWords = queryIsLonger
    ? significantWords(query).length - significantWords(candidate).length
    : 0;
  const spinoffMarker =
    !queryIsLonger && addsUnrequestedTypeIndicator(query, candidate);

  if (hay.startsWith(needle) || needle.startsWith(hay)) {
    if (queryIsLonger && missingWords >= 2) return Math.trunc(ratio * 35);
    if (spinoffMarker) return Math.trunc(ratio * 40);
    return ratio >= 0.6 ? 85 : Math.trunc(ratio * 65);
  }
  if (hay.includes(needle) || needle.includes(hay)) {
    if (queryIsLonger && missingWords >= 2) return Math.trunc(ratio * 30);
    if (spinoffMarker) return Math.trunc(ratio * 35);
    return ratio >= 0.6 ? 68 : Math.trunc(ratio * 50);
  }
  let matches = 0;
  for (const ch of needle) if (hay.includes(ch)) matches += 1;
  return Math.trunc((matches / Math.max(needle.length, 1)) * 40);
}

export function scoreTitle(query, candidate) {
  const needle = normalizeTitle(query);
  const hay = normalizeTitle(candidate);
  if (!needle || !hay) return 0;
  if (hay === needle) return 100;
  const parts = String(candidate)
    .split(",")
    .map((p) => p.trim())
    .filter(Boolean);
  if (parts.length > 1) {
    return Math.max(...parts.map((p) => scoreTitleSingle(query, p)));
  }
  return scoreTitleSingle(query, candidate);
}

export function generateTitleVariants(titles) {
  const variants = [];
  const push = (v) => {
    const c = String(v || "").trim();
    if (c.length >= 2 && !variants.includes(c)) variants.push(c);
  };
  for (const raw of titles || []) {
    if (!raw) continue;
    const t = String(raw).trim();
    const noPoss = t.replace(/[’']s\b/gi, "");
    const noApos = t.replace(/[’']/g, "");
    const firstCut = (s) => String(s).split(/[:(|-]/)[0].trim();
    const words = noApos.split(/\s+/).filter(Boolean);
    [
      t,
      noPoss,
      noApos,
      t.replace(/\+/g, " "),
      firstCut(t),
      firstCut(noPoss),
      words.slice(0, 3).join(" "),
      words.slice(0, 2).join(" "),
      words[0] || "",
    ].forEach(push);
  }
  return variants;
}

// ---------------------------------------------------------------------------
// Tiny HTML helpers (replacement for BeautifulSoup selectors)
// ---------------------------------------------------------------------------
function decodeEntities(s) {
  return String(s || "")
    .replace(/&#x([0-9a-f]+);/gi, (_, h) => String.fromCharCode(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(parseInt(d, 10)))
    .replace(/&quot;/g, '"')
    .replace(/&#0?39;/g, "'")
    .replace(/&apos;/g, "'")
    .replace(/&nbsp;/g, " ")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&");
}

function textOf(html) {
  return decodeEntities(String(html || "").replace(/<[^>]+>/g, " "))
    .replace(/\s+/g, " ")
    .trim();
}

function attr(tag, name) {
  const m = new RegExp(`\\b${name}\\s*=\\s*("([^"]*)"|'([^']*)')`, "i").exec(tag || "");
  return m ? decodeEntities(m[2] !== undefined ? m[2] : m[3]) : "";
}

function imgIn(html) {
  const m = /<img\b[^>]*>/i.exec(html || "");
  if (!m) return { src: "", alt: "" };
  return { src: attr(m[0], "src") || attr(m[0], "data-src"), alt: attr(m[0], "alt") };
}

function absUrl(base, pathOrUrl) {
  if (!pathOrUrl) return "";
  try {
    return new URL(pathOrUrl, `${base}/`).toString();
  } catch {
    return "";
  }
}

function unescapeJsString(value) {
  return String(value).replace(/\\(x[0-9a-f]{2}|u[0-9a-f]{4}|.)/gi, (_, esc) => {
    if (esc[0] === "x" || esc[0] === "X") return String.fromCharCode(parseInt(esc.slice(1), 16));
    if (esc[0] === "u" || esc[0] === "U") return String.fromCharCode(parseInt(esc.slice(1), 16));
    const map = { n: "\n", r: "\r", t: "\t", b: "\b", f: "\f", "0": "\0" };
    return map[esc] ?? esc;
  });
}

// ---------------------------------------------------------------------------
// Cache: per-isolate TTL map (Workers isolates are short-lived, this only
// removes duplicate upstream hits inside one burst of traffic)
// ---------------------------------------------------------------------------
const memoryCache = new Map();
const CACHE_MAX = 240;

function cacheGet(key) {
  const entry = memoryCache.get(key);
  if (!entry) return null;
  if (Date.now() > entry.expires) {
    memoryCache.delete(key);
    return null;
  }
  return entry.value;
}

function cacheSet(key, value, ttlMs) {
  if (memoryCache.size >= CACHE_MAX) {
    const oldest = memoryCache.keys().next().value;
    if (oldest !== undefined) memoryCache.delete(oldest);
  }
  memoryCache.set(key, { value, expires: Date.now() + ttlMs });
}

const MINUTE = 60_000;

async function getText(url, { headers = {}, timeout = 12_000, cookie } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const res = await fetch(url, {
      headers: {
        "user-agent": UA,
        accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "accept-language": "en-US,en;q=0.9",
        ...(cookie ? { cookie } : {}),
        ...headers,
      },
      redirect: "follow",
      signal: controller.signal,
    });
    const text = await res.text();
    return { ok: res.ok, status: res.status, text, url: res.url };
  } catch (err) {
    return { ok: false, status: 0, text: "", error: String(err && err.message) };
  } finally {
    clearTimeout(timer);
  }
}

async function getJson(url, options) {
  const res = await getText(url, options);
  if (!res.ok) return null;
  try {
    return JSON.parse(res.text);
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// AnimeHeaven
// ---------------------------------------------------------------------------
export function parseHeavenSearch(html) {
  const out = [];
  const seen = new Set();
  // AnimeHeaven emits single-quoted attributes (href='/anime.php?abc'), so both
  // quote styles must be accepted here.
  const re =
    /<a\b[^>]*href\s*=\s*(["'])([^"']*anime\.php\?([^"'&#]+)[^"']*)\1[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html || ""))) {
    const [, , href, rawId, inner] = m;
    const id = decodeURIComponent(rawId).trim();
    if (!id || seen.has(id)) continue;
    const fast = /<[^>]*class=["'][^"']*fastname[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i.exec(inner);
    const img = imgIn(inner);
    const title = fast ? textOf(fast[1]) : img.alt || textOf(inner);
    if (!title) continue;
    seen.add(id);
    out.push({
      id,
      title,
      url: absUrl(HEAVEN_BASE, href),
      image: adminSafeImage(absUrl(HEAVEN_BASE, img.src)),
      provider: "animeheaven",
    });
  }
  return out;
}

function adminSafeImage(url) {
  return /^https?:\/\//i.test(url || "") ? url : "";
}

export async function heavenSearch(query) {
  const q = String(query || "").trim();
  if (!q) return [];
  const key = `heaven_search_${q.toLowerCase()}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const res = await getText(
    `${HEAVEN_BASE}/fastsearch.php?xhr=1&s=${encodeURIComponent(q)}`,
    { headers: { referer: `${HEAVEN_BASE}/`, "x-requested-with": "XMLHttpRequest" } }
  );
  if (!res.ok) return [];
  const rows = parseHeavenSearch(res.text);
  cacheSet(key, rows, 15 * MINUTE);
  return rows;
}

export async function heavenFindBestId(titles) {
  const list = (titles || []).filter(Boolean);
  if (!list.length) return null;
  const variants = generateTitleVariants(list);
  const all = new Map();
  for (const variant of variants) {
    const res = await heavenSearch(variant);
    for (const item of res) all.set(item.id, item);
    const confident = res.some((item) =>
      Math.max(...list.map((t) => scoreTitle(t, item.title))) >= 85
    );
    if (confident) break;
  }
  if (!all.size) return null;
  let best = { score: -1, item: null };
  for (const item of all.values()) {
    const score = Math.max(0, ...list.map((t) => scoreTitle(t, item.title)));
    if (score > best.score) best = { score, item };
  }
  return best.score >= 55 ? best.item.id : null;
}

export function parseHeavenEpisodes(html) {
  const episodes = [];
  const seen = new Set();
  const anchorRe = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = anchorRe.exec(html || ""))) {
    const attrs = m[1];
    const inner = m[2];
    const text = textOf(inner);
    const hay = `${attrs} ${text}`;
    if (!/gate[ha]\s*\(|gate\.php|episode/i.test(hay)) continue;

    const keyMatch =
      /gate[ha]\s*\(\s*['"]([^'"]+)['"]/i.exec(attrs) ||
      /gate[ha]\s*\(\s*([^,)\s]+)/i.exec(attrs) ||
      /[?&](?:key|id)=([^&#"']+)/i.exec(attrs);
    if (!keyMatch) continue;
    let key = keyMatch[1].trim();
    try {
      key = decodeURIComponent(key);
    } catch {
      /* keep raw */
    }
    if (!key || seen.has(key)) continue;

    const watch2 = /<[^>]*class=["'][^"']*watch2[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i.exec(inner);
    let rawNum = watch2 ? textOf(watch2[1]) : "";
    if (!rawNum) {
      const num = /episode\s*([0-9]+(?:\.[0-9]+)?)/i.exec(text) || /^([0-9]+(?:\.[0-9]+)?)$/.exec(text);
      if (num) rawNum = num[1];
    }
    const num = Number(String(rawNum).replace(/^0+(?=\d)/, ""));
    if (!Number.isFinite(num)) continue;

    seen.add(key);
    episodes.push({ id: key, key, num, title: `Episode ${rawNum}` });
  }
  episodes.sort((a, b) => a.num - b.num);
  return episodes;
}

export async function heavenAnimeInfo(siteId) {
  const key = `heaven_info_${siteId}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  if (cacheGet("heaven_page_blocked")) return null;
  const res = await getText(`${HEAVEN_BASE}/anime.php?${encodeURIComponent(siteId)}`, {
    headers: { referer: `${HEAVEN_BASE}/` },
  });
  if (!res.ok) return null;
  // Cloudflare stamps every Worker subrequest with Cf-Worker, and
  // animeheaven.me answers that with a 14-byte stub ("AnimeHeaven.Me") instead
  // of the anime page. The header cannot be stripped from inside a Worker, so
  // remember the block briefly and skip the doomed fetch rather than paying for
  // it on every episode request. Anikoto/MegaPlay then serves the episode.
  if (!res.text || res.text.length < 512 || !/infotitle/i.test(res.text)) {
    cacheSet("heaven_page_blocked", 1, 5 * MINUTE);
    return null;
  }
  const poster = /<img\b[^>]*class=["'][^"']*posterimg[^"']*["'][^>]*>/i.exec(res.text);
  const info = {
    site_id: siteId,
    title: firstText(res.text, "infotitle") || "Unknown",
    title_jp: firstText(res.text, "infotitlejp"),
    description: firstText(res.text, "infodes"),
    image: poster ? absUrl(HEAVEN_BASE, attr(poster[0], "src")) : "",
    episodes: parseHeavenEpisodes(res.text),
    url: `${HEAVEN_BASE}/anime.php?${siteId}`,
  };
  cacheSet(key, info, 15 * MINUTE);
  return info;
}

function firstText(html, className) {
  const m = new RegExp(
    `<[^>]*class=["'][^"']*${className}[^"']*["'][^>]*>([\\s\\S]*?)</[^>]+>`,
    "i"
  ).exec(html || "");
  return m ? textOf(m[1]) : "";
}

export function parseGateSources(html) {
  const urls = [];
  const srcRe = /<source\b[^>]*src\s*=\s*"([^"]+)"/gi;
  let m;
  while ((m = srcRe.exec(html || ""))) {
    const u = decodeEntities(m[1]).trim();
    if (/^https?:/i.test(u) && !urls.includes(u)) urls.push(u);
  }
  if (!urls.length) {
    const rawRe = /https?:\/\/[^\s"']+?\.mp4[^\s"']*/gi;
    while ((m = rawRe.exec(html || ""))) {
      const u = decodeEntities(m[0]);
      if (!urls.includes(u)) urls.push(u);
    }
  }
  return urls;
}

/** Total byte size for a direct media URL, or null when unknown.
 *  The gate page mixes the episode with ~600 KB promo stubs on the ct/ck
 *  mirrors; they advertise video/mp4 and only fail once played. A one-byte
 *  range answers the total cheaply, and Cloudflare egress is sometimes refused,
 *  so an unknown answer is retried through the Render origin. */
async function mediaTotalSize(url) {
  try {
    const res = await fetch(url, {
      headers: { "user-agent": UA, referer: `${HEAVEN_BASE}/`, range: "bytes=0-0" },
      redirect: "follow",
      signal: AbortSignal.timeout(3000),
    });
    const range = res.headers.get("content-range") || "";
    const m = /\/(\d+)\s*$/.exec(range);
    if (m) return Number(m[1]);
    const len = res.headers.get("content-length");
    if (len) return Number(len);
  } catch {
    // fall through to the origin probe
  }
  try {
    const res = await fetch(
      `https://camanime.onrender.com/api/media/size?u=${encodeURIComponent(url)}`,
      { signal: AbortSignal.timeout(4000) },
    );
    if (!res.ok) return null;
    const data = await res.json();
    return Number.isFinite(data?.size) ? data.size : null;
  } catch {
    return null;
  }
}

export async function heavenStreamSources(episodeKey, refererSiteId) {
  const key = `heaven_stream_${episodeKey}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const referer = refererSiteId
    ? `${HEAVEN_BASE}/anime.php?${refererSiteId}`
    : `${HEAVEN_BASE}/`;
  const res = await getText(`${HEAVEN_BASE}/gate.php`, {
    headers: {
      "user-agent": pickUA(),
      "accept-language": "en-US,en;q=0.9",
      "sec-ch-ua": '"Chromium";v="126", "Google Chrome";v="126", "Not.A/Brand";v="24"',
      "sec-ch-ua-mobile": "?0",
      "sec-ch-ua-platform": '"Windows"',
      "upgrade-insecure-requests": "1",
      referer,
      origin: HEAVEN_BASE,
      "sec-fetch-dest": "document",
      "sec-fetch-mode": "navigate",
      "sec-fetch-site": "same-origin",
      "cache-control": "no-cache",
    },
    cookie: `key=${episodeKey}`,
    timeout: 15_000,
  });
  if (!res.ok) return { sources: [], provider: "animeheaven", error: `gate ${res.status}` };
  if (/watch\s+episode\s+on\s+animeheaven\.me/i.test(res.text)) {
    return { sources: [], provider: "animeheaven", error: "placeholder player" };
  }
  // ct/ck are the promo hosts: every file observed there is a ~3.7s clip of the
  // episode token, advertised as video/mp4. Dropping the host is deterministic
  // where a size probe (often refused from Cloudflare) is not.
  const urls = parseGateSources(res.text).filter((u) => {
    const host = safeHost(u).toLowerCase();
    return !host.startsWith("ct.") && !host.startsWith("ck.");
  });
  const sizes = await Promise.all(urls.map((u) => mediaTotalSize(u)));
  // A stub must never be offered as the only mp4: the real HLS servers are
  // listed alongside it, and a 3-second clip reads as a broken player. The
  // mirror host names rotate (ct, ck, cy...), so only the measured size counts.
  // A measured stub is dropped outright. When Cloudflare cannot measure a file
  // at all the mirror is still offered, but flagged unverified so the player
  // never makes it the default source ahead of a server that resolved.
  const kept = urls
    .map((url, i) => ({ url, size: sizes[i] }))
    .filter(({ size }) => size == null || size >= 2 * 1024 * 1024);
  const sources = kept.map(({ url, size }, idx) => {
    const host = safeHost(url);
    return {
      url,
      quality: "Source MP4",
      label: idx === 0 ? "Direct MP4 (Primary CDN)" : `Direct MP4 (${host.split(".")[0].toUpperCase()} Mirror)`,
      isM3u8: false,
      isMp4: true,
      referer: `${HEAVEN_BASE}/`,
      unverified: size == null,
    };
  });
  const out = {
    sources,
    subtitles: [],
    provider: "animeheaven",
    episode_id: episodeKey,
    referer: `${HEAVEN_BASE}/`,
  };
  if (sources.length) cacheSet(key, out, 15 * MINUTE);
  return out;
}

function safeHost(url) {
  try {
    return new URL(url).hostname;
  } catch {
    return "";
  }
}

// ---------------------------------------------------------------------------
// Anikoto + MegaPlay
// ---------------------------------------------------------------------------
const hasLetters = (s) => /[a-z]/i.test(String(s || ""));

/** A poster anchor's text is episode counts ("1180 1158 TV"); the .name anchor
 * or the image alt carries the real title, so keep the better of the two. */
function betterTitle(current, candidate) {
  if (!hasLetters(current) && hasLetters(candidate)) return candidate;
  if (!hasLetters(current) && candidate) return candidate;
  return current;
}

export function parseAnikotoSearch(html, base = ANIKOTO_BASE) {
  const out = [];
  const seen = new Map();
  const re = /<a\b[^>]*href\s*=\s*(["'])([^"']*\/watch\/[^"']+)\1[^>]*>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html || ""))) {
    let slug = m[2].replace(/^https?:\/\/[^/]+/, "").replace(/^\/watch\//, "");
    slug = slug.replace(/\/ep-\d+.*$/, "").replace(/^\/+|\/+$/g, "");
    if (!slug) continue;
    const inner = m[3];
    const nameEl = /<[^>]*class=["'][^"']*(?:name|d-title)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i.exec(inner);
    const img = imgIn(inner);
    const title = (nameEl ? textOf(nameEl[1]) : "") || img.alt || textOf(inner);
    if (!title) continue;
    const existing = seen.get(slug);
    if (existing !== undefined) {
      out[existing].title = betterTitle(out[existing].title, title);
      continue;
    }
    seen.set(slug, out.length);
    out.push({
      id: slug,
      slug,
      title,
      image: adminSafeImage(img.src),
      provider: "anikoto",
    });
  }
  return out;
}

export async function anikotoSearch(query) {
  const q = String(query || "").trim();
  if (!q) return [];
  const key = `anikoto_search_${q.toLowerCase()}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const res = await getText(`${ANIKOTO_BASE}/filter?keyword=${encodeURIComponent(q)}`, {
    headers: { referer: `${ANIKOTO_BASE}/` },
  });
  if (!res.ok) return [];
  const rows = parseAnikotoSearch(res.text);
  cacheSet(key, rows, 15 * MINUTE);
  return rows;
}

export async function anikotoFindBestSlug(titles) {
  const list = (titles || []).filter(Boolean);
  if (!list.length) return null;
  const all = new Map();
  for (const variant of generateTitleVariants(list)) {
    const res = await anikotoSearch(variant);
    for (const item of res) all.set(item.slug, item);
    const confident = res.some((item) =>
      Math.max(...list.map((t) => scoreTitle(t, item.title))) >= 85
    );
    if (confident) break;
  }
  if (!all.size) return null;
  let best = { score: -1, item: null };
  for (const item of all.values()) {
    const score = Math.max(0, ...list.map((t) => scoreTitle(t, item.title)));
    if (score > best.score) best = { score, item };
  }
  return best.score >= 50 ? best.item.slug : null;
}

export function parseAnikotoEpisodes(html) {
  const episodes = [];
  const seen = new Set();
  const re = /<a\b([^>]*)>([\s\S]*?)<\/a>/gi;
  let m;
  while ((m = re.exec(html || ""))) {
    const attrs = m[1];
    const inner = m[2];
    let rawNum = attr(attrs, "data-num");
    if (!rawNum) {
      const numEl = /<[^>]*class=["'][^"']*(?:number|d-title)[^"']*["'][^>]*>([\s\S]*?)<\/[^>]+>/i.exec(inner);
      rawNum = numEl ? textOf(numEl[1]) : "";
    }
    const num = Number(rawNum);
    if (!rawNum || !Number.isFinite(num) || seen.has(num)) continue;
    seen.add(num);
    episodes.push({
      num,
      title: attr(attrs, "title") || `Episode ${rawNum}`,
      data_ids: attr(attrs, "data-ids") || attr(attrs, "data-id"),
      data_mal: attr(attrs, "data-mal"),
      data_timestamp: attr(attrs, "data-timestamp"),
      has_sub: attr(attrs, "data-sub") === "1",
      has_dub: attr(attrs, "data-dub") === "1",
    });
  }
  episodes.sort((a, b) => a.num - b.num);
  return episodes;
}

export async function anikotoEpisodes(slug) {
  const key = `anikoto_eps_${slug}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const page = await getText(`${ANIKOTO_BASE}/watch/${slug}`, {
    headers: { referer: `${ANIKOTO_BASE}/` },
  });
  if (!page.ok) return [];
  let episodes = parseAnikotoEpisodes(page.text);
  const animeId = /id="watch-main"[^>]*data-id="([^"]+)"/i.exec(page.text);
  if (!episodes.length && animeId) {
    const ajax = await getJson(`${ANIKOTO_BASE}/ajax/episode/list/${animeId[1]}`, {
      headers: {
        "x-requested-with": "XMLHttpRequest",
        referer: `${ANIKOTO_BASE}/watch/${slug}`,
      },
    });
    if (ajax && typeof ajax.result === "string") {
      episodes = parseAnikotoEpisodes(ajax.result);
    }
  }
  if (episodes.length) cacheSet(key, episodes, 15 * MINUTE);
  return episodes;
}

export function parseAnikotoServers(html) {
  const servers = [];
  // Items are grouped under <div class="type">...sub/dub...</div>; walk the
  // markup in order so each item inherits the audio type of its group.
  const chunks = String(html || "").split(/<div[^>]*class=["'][^"']*type[^"']*["'][^>]*>/i);
  const headType = (chunk) => {
    const t = textOf(chunk).toLowerCase();
    if (t.includes("dub")) return "dub";
    if (t.includes("raw")) return "raw";
    return "sub";
  };
  const first = chunks.shift() || "";
  const groups = [{ type: headType(first), html: first }];
  for (const chunk of chunks) groups.push({ type: headType(chunk), html: chunk });

  for (const group of groups) {
    const itemRe = /<li\b([^>]*data-link-id="[^"]*"[^>]*)>([\s\S]*?)<\/li>/gi;
    let m;
    while ((m = itemRe.exec(group.html))) {
      const attrs = m[1];
      const linkId = attr(attrs, "data-link-id");
      if (!linkId) continue;
      const name = textOf(m[2]) || "Server";
      servers.push({
        name,
        type: group.type,
        link_id: linkId,
        sv_id: attr(attrs, "data-sv-id"),
      });
    }
  }
  return servers;
}

export async function anikotoServers(slug, epNum, dataIds) {
  if (!dataIds) return [];
  const key = `anikoto_servers_${slug}_${epNum}_${dataIds.slice(0, 24)}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const res = await getText(
    `${ANIKOTO_BASE}/ajax/server/list?servers=${encodeURIComponent(dataIds)}`,
    {
      headers: {
        "x-requested-with": "XMLHttpRequest",
        referer: `${ANIKOTO_BASE}/watch/${slug}/ep-${epNum}`,
      },
    }
  );
  if (!res.ok) return [];
  let htmlText = res.text;
  try {
    const parsed = JSON.parse(res.text);
    if (parsed && typeof parsed.result === "string") htmlText = parsed.result;
  } catch {
    /* plain HTML */
  }
  const rows = parseAnikotoServers(htmlText).map((s) => ({
    ...s,
    slug,
    ep_num: epNum,
  }));
  if (rows.length) cacheSet(key, rows, 15 * MINUTE);
  return rows;
}

function base64UrlToBytes(input) {
  const cleaned = String(input || "").replace(/-/g, "+").replace(/_/g, "/");
  const padded = cleaned + "=".repeat((4 - (cleaned.length % 4)) % 4);
  const bin = atob(padded);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i += 1) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

function stripPkcs7(bytes) {
  if (!bytes.length) return null;
  const pad = bytes[bytes.length - 1];
  if (pad < 1 || pad > 16) return null;
  for (let i = bytes.length - pad; i < bytes.length; i += 1) {
    if (bytes[i] !== pad) return null;
  }
  return bytes.slice(0, bytes.length - pad);
}

/**
 * MegaPlay packs the HLS URL as AES-CBC(base64url(json)). The Python code
 * brute-forces the key/iv pairs harvested from the player script; WebCrypto
 * decrypts with the same key material (padded to 32 bytes) and IV.
 */
export async function decryptMegaplayEnc(encB64, keys, ivs) {
  if (!encB64 || !keys?.length || !ivs?.length) return null;
  let encBytes;
  try {
    encBytes = base64UrlToBytes(encB64);
  } catch {
    return null;
  }
  if (!encBytes.length || encBytes.length % 16 !== 0) return null;

  for (const rawKey of keys) {
    const keyBytes = new Uint8Array(32);
    keyBytes.set(rawKey.slice(0, 32));
    let key;
    try {
      key = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-CBC" }, false, [
        "decrypt",
      ]);
    } catch {
      continue;
    }
    for (const iv of ivs) {
      let plain;
      try {
        plain = new Uint8Array(
          await crypto.subtle.decrypt({ name: "AES-CBC", iv }, key, encBytes)
        );
      } catch {
        continue;
      }
      // WebCrypto's AES-CBC already removes PKCS#7, so try the plaintext as-is
      // first and only fall back to an explicit unpad for implementations that
      // return the padded blocks.
      for (const bytes of [plain, stripPkcs7(plain)]) {
        if (!bytes) continue;
        try {
          const data = JSON.parse(new TextDecoder().decode(bytes));
          const nested =
            data?.sources && !Array.isArray(data.sources) && typeof data.sources === "object"
              ? data.sources.file
              : null;
          const src = data?.file || data?.url || nested;
          if (typeof src === "string" && src.startsWith("http")) return src;
        } catch {
          continue;
        }
      }
    }
  }
  return null;
}

export function parseMegaplayScript(script) {
  const raw = [];
  const re = /(["'])((?:\\.|(?!\1).){1,64})\1/g;
  let m;
  while ((m = re.exec(script || ""))) raw.push(m[2]);
  const candidates = [];
  for (const value of raw) {
    const decoded = unescapeJsString(value);
    if (!candidates.includes(decoded)) candidates.push(decoded);
  }
  const encoder = new TextEncoder();
  return {
    keys: candidates.map((c) => encoder.encode(c)).filter((b) => b.length > 0 && b.length <= 32),
    ivs: candidates.map((c) => encoder.encode(c)).filter((b) => b.length === 16),
  };
}

export async function megaplayKeys(host, html, referer) {
  const key = `megaplay_keys_${host}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const scriptUrls = [];
  const re = /<script[^>]+src=["']([^"']+)["']/gi;
  let m;
  while ((m = re.exec(html || ""))) scriptUrls.push(absUrl(`https://${host}/`, m[1]));
  for (const src of scriptUrls) {
    const res = await getText(src, { headers: { referer }, timeout: 8000 });
    if (!res.ok) continue;
    if (res.text.includes("getSources") && res.text.includes("AES-CBC")) {
      const parsed = parseMegaplayScript(res.text);
      cacheSet(key, parsed, 30 * MINUTE);
      return parsed;
    }
  }
  return { keys: [], ivs: [] };
}

export async function resolveAnikotoServer(server) {
  if (!server?.link_id) return null;
  const key = `anikoto_stream_${server.link_id}_${server.sv_id || ""}`;
  const hit = cacheGet(key);
  if (hit) return hit;

  const params = new URLSearchParams({ get: server.link_id });
  if (server.sv_id) params.set("sv", server.sv_id);
  const epReferer = `${ANIKOTO_BASE}/watch/${server.slug}/ep-${server.ep_num}`;
  const payload = await getJson(`${ANIKOTO_BASE}/ajax/server?${params}`, {
    headers: { "x-requested-with": "XMLHttpRequest", referer: epReferer },
  });
  const result = payload?.result;
  const embedUrl = result?.url;
  if (!embedUrl) return null;

  const normalized = embedUrl
    .replace("vidwish.live", "megaplay.buzz")
    .replace("megacloud.bloggy.click", "megaplay.buzz");
  const host = safeHost(normalized);
  if (!host) return null;
  const embedReferer = `https://${host}/`;

  const page = await getText(normalized, {
    headers: { referer: `${ANIKOTO_BASE}/` },
    timeout: 15_000,
  });
  if (!page.ok) {
    return {
      embed_url: embedUrl,
      m3u8: null,
      subtitles: [],
      server: server.name,
      type: server.type,
      referer: embedReferer,
    };
  }
  const fileMatch =
    /<title>File\s+(\d+)/i.exec(page.text) || /data-id=["'](\d+)["']/.exec(page.text);
  if (!fileMatch) {
    return {
      embed_url: embedUrl,
      m3u8: null,
      subtitles: [],
      server: server.name,
      type: server.type,
      referer: embedReferer,
    };
  }

  const src = await getJson(`https://${host}/stream/getSources?id=${fileMatch[1]}`, {
    headers: {
      "x-requested-with": "XMLHttpRequest",
      referer: normalized,
    },
  });
  if (!src) return null;

  const subtitles = (Array.isArray(src.tracks) ? src.tracks : [])
    .filter((t) => t?.file && (t.kind === "captions" || t.kind === "subtitles" || !t.kind))
    .map((t) => ({ url: t.file, lang: t.label || "English", default: Boolean(t.default) }));

  let m3u8 = null;
  if (src.sources && !Array.isArray(src.sources) && typeof src.sources === "object") {
    m3u8 = src.sources.file || null;
  } else if (Array.isArray(src.sources) && src.sources.length) {
    m3u8 = src.sources[0]?.file || null;
  }
  if (!m3u8 && src.enc) {
    const { keys, ivs } = await megaplayKeys(host, page.text, embedReferer);
    m3u8 = await decryptMegaplayEnc(src.enc, keys, ivs);
  }

  const out = {
    embed_url: embedUrl,
    m3u8,
    subtitles,
    intro: src.intro || result?.skip_data?.intro || null,
    outro: src.outro || result?.skip_data?.outro || null,
    server: server.name || "HD-1",
    type: server.type || "sub",
    referer: embedReferer,
  };
  if (m3u8 || embedUrl) cacheSet(key, out, 15 * MINUTE);
  return out;
}

export async function kiwiDownloads(malId, epNum, timestamp) {
  if (!malId || !timestamp) return {};
  const key = `kiwi_dl_${malId}_${epNum}`;
  const hit = cacheGet(key);
  if (hit) return hit;
  const data = await getJson(`${KIWI_BASE}/api/mal/${malId}/${epNum}/${timestamp}`, {
    headers: { referer: `${ANIKOTO_BASE}/`, origin: ANIKOTO_BASE },
    timeout: 9000,
  });
  if (!data) return {};
  const kiwi = data.Kiwi || {};
  const out = {};
  for (const audio of ["sub", "dub"]) {
    const map = kiwi?.[audio]?.download;
    if (map && typeof map === "object") {
      const clean = {};
      for (const [quality, url] of Object.entries(map)) {
        if (typeof url === "string" && url.startsWith("http")) clean[quality] = url;
      }
      if (Object.keys(clean).length) out[audio] = clean;
    }
  }
  cacheSet(key, out, 15 * MINUTE);
  return out;
}

// ---------------------------------------------------------------------------
// Bundle assembly (mirrors StreamingManager.get_full_episode_bundle)
// ---------------------------------------------------------------------------
const proxy = (path, params) => {
  const query = new URLSearchParams(params).toString();
  return `${path}?${query}`;
};

export async function episodeBundle({
  anilistId,
  epNum,
  titles,
  malId = null,
  preferredAudio = "sub",
  heavenOverride = null,
}) {
  const list = (titles || []).filter(Boolean);
  const audioPref = preferredAudio === "dub" ? "dub" : "sub";
  const episode = Math.max(1, Number(epNum) || 1);

  const [heavenId, anikotoSlug] = await Promise.all([
    heavenOverride || heavenFindBestId(list),
    anikotoFindBestSlug(list),
  ]);

  const servers = [];
  const downloads = [];
  let heavenEpKey = null;

  if (heavenId) {
    const info = await heavenAnimeInfo(heavenId);
    const target = info?.episodes?.find((e) => Math.round(e.num) === episode);
    if (target) {
      heavenEpKey = target.key;
      const resolved = await heavenStreamSources(target.key, heavenId);
      // The player page mixes the episode file with unrelated promo sources on
      // other hosts (ax.animeheaven.me). Files carrying this episode's key are
      // the real mirrors, so they are offered first.
      const carriesKey = (s) =>
        s.url.includes(target.key) || s.url.includes(encodeURIComponent(target.key));
      const ordered = [...resolved.sources].sort(
        (a, b) => Number(!carriesKey(a)) - Number(!carriesKey(b))
      );
      ordered.forEach((src, idx) => {
        const referer = src.referer || `${HEAVEN_BASE}/`;
        servers.push({
          id: `heaven-mp4-${idx + 1}`,
          name: `AnimeHeaven ${idx === 0 ? "Primary" : `Mirror ${idx + 1}`}`,
          provider: "animeheaven",
          audio: "sub",
          playback_mode: "mp4",
          stream_url: proxy("/api/proxy/video", { url: src.url, ref: referer }),
          raw_url: src.url,
          download_url: proxy("/api/download/video", {
            url: src.url,
            title: `${list[0] || "Anime"} - Ep ${episode}`,
            ref: referer,
          }),
          quality: "Source MP4",
          subtitles: [],
          badge: "DIRECT MP4",
        });
        if (idx === 0) {
          downloads.push({
            label: `Episode ${episode} Direct MP4 (AnimeHeaven High-Speed)`,
            quality: "Source MP4",
            audio: "SUB",
            url: proxy("/api/download/video", {
              url: src.url,
              title: `${list[0] || "Anime"} - Ep ${episode}`,
              ref: referer,
            }),
            direct: true,
            provider: "AnimeHeaven",
          });
        }
      });
    }
  }

  if (anikotoSlug) {
    const eps = await anikotoEpisodes(anikotoSlug);
    const ep = eps.find((e) => Math.round(e.num) === episode);
    if (ep) {
      const list_ = await anikotoServers(anikotoSlug, episode, ep.data_ids);
      const resolvedPerAudio = { sub: 0, dub: 0 };
      for (const srv of list_) {
        const audio = srv.type;
        if (!(audio in resolvedPerAudio)) continue;
        if (resolvedPerAudio[audio] >= 2) continue;
        const stream = await resolveAnikotoServer(srv);
        if (!stream) continue;
        resolvedPerAudio[audio] += 1;
        const subs = (stream.subtitles || []).map((s) => ({
          lang: s.lang,
          url: proxy("/api/proxy/subtitle", { url: s.url, ref: stream.referer }),
          default: Boolean(s.default),
        }));
        if (stream.m3u8) {
          servers.push({
            id: `anikoto-${audio}-${String(srv.name).toLowerCase()}-${resolvedPerAudio[audio]}`,
            name: `CamStream ${srv.name} (${audio.toUpperCase()})`,
            provider: "anikoto",
            audio,
            playback_mode: "hls",
            stream_url: proxy("/api/proxy/hls", { url: stream.m3u8, ref: stream.referer }),
            raw_url: stream.m3u8,
            download_url: proxy("/api/download/hls", {
              url: stream.m3u8,
              title: `${list[0] || "Anime"} - Ep ${episode} ${audio.toUpperCase()}`,
              ref: stream.referer,
            }),
            embed_url: stream.embed_url,
            quality: "HLS source",
            subtitles: subs,
            intro: stream.intro,
            outro: stream.outro,
            badge: `HLS ${audio.toUpperCase()}`,
          });
          downloads.push({
            label: `Episode ${episode} ${audio.toUpperCase()} (single file)`,
            quality: "HLS source (TS)",
            audio: audio.toUpperCase(),
            url: proxy("/api/download/hls", {
              url: stream.m3u8,
              title: `${list[0] || "Anime"} - Ep ${episode} ${audio.toUpperCase()}`,
              ref: stream.referer,
            }),
            direct: true,
            provider: `CamStream ${srv.name}`,
          });
        } else if (stream.embed_url) {
          servers.push({
            id: `anikoto-embed-${audio}-${String(srv.name).toLowerCase()}`,
            name: `${srv.name} Embed (${audio.toUpperCase()})`,
            provider: "anikoto",
            audio,
            playback_mode: "iframe",
            stream_url: stream.embed_url,
            quality: "HD Embed",
            subtitles: [],
            badge: `EMBED ${audio.toUpperCase()}`,
          });
        }
      }

      const effMal = ep.data_mal || (malId ? String(malId) : "");
      if (effMal && ep.data_timestamp) {
        const kiwi = await kiwiDownloads(effMal, episode, ep.data_timestamp);
        for (const [audioKey, qualityMap] of Object.entries(kiwi)) {
          for (const [quality, link] of Object.entries(qualityMap)) {
            downloads.push({
              label: `Episode ${episode} (${audioKey.toUpperCase()} · ${quality})`,
              quality,
              audio: audioKey.toUpperCase(),
              url: link,
              direct: false,
              provider: "AnimePahe / Kiwi Mirror",
            });
          }
        }
      }
    }
  }

  const audioAvailability = {
    sub: servers.some((s) => s.audio === "sub"),
    dub: servers.some((s) => s.audio === "dub"),
  };

  const reserved = Number(anilistId) >= 900_000_000;
  const malEmbedId = malId || (reserved ? null : anilistId);
  if (malEmbedId) {
    servers.push({
      id: "embed-vidlink-sub",
      name: "VidLink Ultra (SUB)",
      provider: "vidlink",
      audio: "sub",
      playback_mode: "iframe",
      stream_url: `https://vidlink.pro/anime/${malEmbedId}/${episode}/sub`,
      quality: "Provider embed",
      subtitles: [],
      badge: "BACKUP SUB",
      fallback: true,
    });
  }
  if (!reserved) {
    servers.push({
      id: "embed-vidsrc-sub",
      name: "VidSrc Pro (SUB)",
      provider: "vidsrc",
      audio: "sub",
      playback_mode: "iframe",
      stream_url: `https://vidsrc.cc/v2/embed/anime/ani${anilistId}/${episode}/sub`,
      quality: "Provider embed",
      subtitles: [],
      badge: "MIRROR SUB",
      fallback: true,
    });
  }

  servers.sort((a, b) => {
    const audioMatch = (s) => (s.audio === audioPref ? 0 : 1);
    const modeRank = (s) => (s.playback_mode === "hls" || s.playback_mode === "mp4" ? 0 : 1);
    return audioMatch(a) - audioMatch(b) || modeRank(a) - modeRank(b);
  });

  if (!downloads.length) {
    downloads.push({
      label: `Episode ${episode} — resolve direct MP4 via AnimeHeaven Scraper`,
      quality: "Scraper resolver",
      audio: audioAvailability.dub && audioPref === "dub" ? "DUB" : "SUB",
      url: `/scraper?q=${encodeURIComponent(list[0] || `anime ${anilistId}`)}&auto_resolve=${episode}`,
      direct: false,
      provider: "AnimeHeaven resolver",
    });
  }

  return {
    anilist_id: anilistId,
    anime_id: String(anilistId),
    mal_id: malId,
    episode,
    heaven_id: heavenId,
    heaven_ep_key: heavenEpKey,
    anikoto_slug: anikotoSlug,
    servers,
    downloads,
    audio_availability: audioAvailability,
    requested_audio: audioPref,
    audio_fallback: audioPref === "dub" && !audioAvailability.dub,
    quality_note:
      "Only qualities and audio tracks published by the source are listed. " +
      "CamAnime does not re-encode video or invent dubs.",
    active_server:
      servers.find((s) => s.audio === audioPref && !s.unverified) ||
      servers.find((s) => !s.unverified) ||
      servers.find((s) => s.audio === audioPref) ||
      servers[0] || null,
  };
}
