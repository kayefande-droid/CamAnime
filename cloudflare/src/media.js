/**
 * Media proxy for the ported extractors.
 *
 * The scraped CDNs reject requests without the right Referer/Origin, and the
 * browser-style players cannot send those headers themselves. These routes
 * fetch upstream with the provider headers and stream the bytes back, so an
 * mp4 or HLS URL from providers.js is directly playable and downloadable.
 *
 * HLS playlists are rewritten line by line: variant playlists, segments, key
 * files and init maps all go back through /api/proxy/segment, which keeps the
 * Referer on every hop.
 */
const UA =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
  "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36";

// Cloudflare's egress is intermittently refused by the AnimeHeaven CDNs: the
// identical URL streams fine from Render, but the edge fetch fails for a while
// and every player that picked one of those mirrors got a 502. Retrying the
// same proxy path on Render keeps the first servers playable.
const RENDER_ORIGIN = "https://camanime.onrender.com";

const PRIVATE_HOST =
  /^(localhost|127\.|0\.|10\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|\[?::1\]?|.*\.local$|.*\.internal$)/i;

function assertPublicUrl(raw) {
  let parsed;
  try {
    parsed = new URL(raw);
  } catch {
    return null;
  }
  if (!/^https?:$/.test(parsed.protocol)) return null;
  if (PRIVATE_HOST.test(parsed.hostname)) return null;
  return parsed;
}

function cors(headers = {}) {
  return { "access-control-allow-origin": "*", ...headers };
}

// CDNs routinely label MPEG-TS segments as image/jpeg (or send no type at all).
// Faithfully passing that through makes strict players refuse the segment, so
// the URL extension wins whenever it names a known media type.
const EXT_TYPES = {
  ".m3u8": "application/vnd.apple.mpegurl",
  ".ts": "video/mp2t",
  ".m4s": "video/iso.segment",
  ".mp4": "video/mp4",
  ".m4a": "audio/mp4",
  ".webm": "video/webm",
  ".vtt": "text/vtt; charset=utf-8",
  ".srt": "text/plain; charset=utf-8",
  ".key": "application/octet-stream",
};

function mediaTypeFor(pathname, upstreamType) {
  const ext = String(pathname || "").toLowerCase().match(/\.[a-z0-9]{2,5}$/);
  if (ext && EXT_TYPES[ext[0]]) return EXT_TYPES[ext[0]];
  const type = String(upstreamType || "").trim();
  return type || "application/octet-stream";
}

/** Identify media from its first bytes; megapay-style CDNs hide the extension. */
function sniffType(bytes) {
  if (!bytes || bytes.length < 12) return "";
  if (bytes[0] === 0x47) return "video/mp2t";
  if (String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7]) === "ftyp") return "video/mp4";
  if (bytes[0] === 0xff && (bytes[1] & 0xf0) === 0xf0) return "audio/aac";
  if (String.fromCharCode(bytes[0], bytes[1], bytes[2]) === "ID3") return "audio/mpeg";
  return "";
}

/** Read one chunk to sniff the type, then replay it ahead of the live stream. */
async function sniffStream(body, fallbackType) {
  const reader = body.getReader();
  const first = await reader.read();
  if (first.done || !first.value) return { type: fallbackType, body: null };
  const head = first.value;
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(head);
    },
    async pull(controller) {
      const next = await reader.read();
      if (next.done) controller.close();
      else if (next.value) controller.enqueue(next.value);
    },
    cancel(reason) {
      Promise.resolve(reader.cancel(reason)).catch(() => {});
    },
  });
  return { type: sniffType(head) || fallbackType, body: stream };
}

// Exact stitched sizes cost one HEAD per segment, so results are reused for
// repeated downloads of the same episode.
const LENGTH_CACHE = new Map();
const LENGTH_TTL = 10 * 60 * 1000;

/**
 * Sum of every segment's size, or 0 when the total cannot be known exactly.
 *
 * A guessed Content-Length is worse than none: the client would stall waiting
 * for bytes that never arrive, so any unsupported HEAD drops the total.
 */
export async function sumSegmentBytes(segments, ref) {
  if (!Array.isArray(segments) || !segments.length || segments.length > 900) return 0;
  const key = `${segments.length}:${segments[0]}`;
  const now = Date.now();
  const hit = LENGTH_CACHE.get(key);
  if (hit && now - hit.at < LENGTH_TTL) return hit.sum;

  let origin = "";
  try {
    origin = ref ? new URL(ref).origin : "";
  } catch {}

  const sizeOf = async (segment) => {
    try {
      const res = await fetch(segment, {
        method: "HEAD",
        headers: { "user-agent": UA, referer: ref || "", origin, accept: "*/*" },
        redirect: "follow",
      });
      if (!res.ok) return 0;
      const length = Number(res.headers.get("content-length") || 0);
      return Number.isFinite(length) && length > 0 ? length : 0;
    } catch {
      return 0;
    }
  };

  let sum = 0;
  for (let i = 0; i < segments.length; i += 12) {
    const sizes = await Promise.all(segments.slice(i, i + 12).map(sizeOf));
    if (sizes.includes(0)) return 0;
    for (const size of sizes) sum += size;
  }
  if (sum > 0) {
    if (LENGTH_CACHE.size > 200) LENGTH_CACHE.clear();
    LENGTH_CACHE.set(key, { sum, at: now });
  }
  return sum;
}

/**
 * Byte total for a stream whose segments do not all report a size.
 *
 * Some CDNs answer HEAD with a chunked body, so no exact sum exists. Sizes are
 * sampled at even intervals and scaled to the segment count, so the client gets
 * a total to draw progress against without ever treating it as exact.
 */
export async function estimateSegmentBytes(segments, ref) {
  if (!Array.isArray(segments) || !segments.length) return 0;
  const key = `est:${segments.length}:${segments[0]}`;
  const now = Date.now();
  const hit = LENGTH_CACHE.get(key);
  if (hit && now - hit.at < LENGTH_TTL) return hit.sum;

  const step = Math.max(1, Math.floor(segments.length / 24));
  const sample = segments.filter((_, i) => i % step === 0).slice(0, 24);
  let origin = "";
  try {
    origin = ref ? new URL(ref).origin : "";
  } catch {}
  const sizes = await Promise.all(
    sample.map(async (segment) => {
      try {
        const res = await fetch(segment, {
          method: "HEAD",
          headers: { "user-agent": UA, referer: ref || "", origin, accept: "*/*" },
          redirect: "follow",
        });
        if (!res.ok) return 0;
        const length = Number(res.headers.get("content-length") || 0);
        return Number.isFinite(length) && length > 0 ? length : 0;
      } catch {
        return 0;
      }
    }),
  );
  const known = sizes.filter((size) => size > 0);
  if (known.length < 2) return 0;
  const mean = known.reduce((a, b) => a + b, 0) / known.length;
  const total = Math.round(mean * segments.length);
  if (total > 0) {
    if (LENGTH_CACHE.size > 200) LENGTH_CACHE.clear();
    LENGTH_CACHE.set(key, { sum: total, at: now });
  }
  return total;
}

async function fetchPlaylistText(url, ref) {
  let origin = url.origin;
  try {
    if (ref) origin = new URL(ref).origin;
  } catch {
    // Unparseable referer: keep the playlist's own origin.
  }
  const res = await fetch(url.toString(), {
    headers: { "user-agent": UA, referer: ref || `${url.origin}/`, origin, accept: "*/*" },
    redirect: "follow",
  });
  if (!res.ok) return null;
  const text = await res.text();
  if (!/#EXTM3U/i.test(text)) return null;
  return { text, base: res.url || url.toString() };
}

/** Highest rendition at or below [height] (``0`` = best available). */
export function pickVariant(text, baseUrl, height) {
  const lines = String(text || "").split(/\r?\n/);
  const variants = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line.startsWith("#EXT-X-STREAM-INF")) continue;
    let uri = "";
    for (let j = i + 1; j < lines.length; j += 1) {
      const next = lines[j].trim();
      if (next && !next.startsWith("#")) {
        uri = next;
        break;
      }
    }
    if (!uri) continue;
    const res = /RESOLUTION=(\d+)x(\d+)/i.exec(line);
    const bandwidth = /BANDWIDTH=(\d+)/i.exec(line);
    variants.push({
      uri,
      height: res ? Number(res[2]) : 0,
      bandwidth: bandwidth ? Number(bandwidth[1]) : 0,
    });
  }
  if (!variants.length) return null;
  const cap = Number(height) || 0;
  const best = (list) =>
    [...list].sort((a, b) => b.height - a.height || b.bandwidth - a.bandwidth)[0];
  if (cap > 0) {
    const under = variants.filter((v) => v.height > 0 && v.height <= cap);
    if (under.length) return best(under);
    // Nothing fits the cap: the smallest rendition is the closest match, so a
    // 480p request never quietly pulls the 1080p file.
    return [...variants].sort((a, b) => a.height - b.height || a.bandwidth - b.bandwidth)[0];
  }
  return best(variants);
}

/** Media segment URLs in playback order, with any init map first. */
export function segmentUrls(text, baseUrl) {
  const out = [];
  for (const raw of String(text || "").split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) continue;
    if (line.startsWith("#")) {
      const map = /^#EXT-X-MAP:.*URI="([^"]+)"/i.exec(line);
      if (map) {
        try {
          out.push(new URL(map[1], baseUrl).toString());
        } catch {}
      }
      continue;
    }
    try {
      out.push(new URL(line, baseUrl).toString());
    } catch {}
  }
  return out;
}

/**
 * Stitch an HLS episode into one progressive file.
 *
 * Segments are fetched in order and streamed back as a single body, so the
 * client saves a playable file instead of a playlist it cannot use offline.
 * The variant is chosen from `height` when the playlist is a master.
 */
async function hlsDownload(raw, ref, request, { title = "", height = 0 } = {}) {
  const url = assertPublicUrl(raw);
  if (!url) return new Response("Bad url", { status: 400, headers: cors() });

  // A rotating provider domain that no longer resolves must not surface as a
  // 500: it is the same "playlist unavailable" the caller already handles.
  const first = await fetchPlaylistText(url, ref).catch(() => null);
  if (!first) {
    console.error(
      JSON.stringify({ message: "playlist unavailable", url: url.toString(), ref }),
    );
    return new Response("Playlist unavailable", { status: 502, headers: cors() });
  }

  let media = first;
  if (/#EXT-X-STREAM-INF/i.test(first.text)) {
    const variant = pickVariant(first.text, first.base, height);
    if (!variant) return new Response("No playable variant", { status: 502, headers: cors() });
    let variantUrl;
    try {
      variantUrl = new URL(variant.uri, first.base);
    } catch {
      return new Response("Bad variant url", { status: 502, headers: cors() });
    }
    const next = await fetchPlaylistText(variantUrl, ref).catch(() => null);
    if (!next) {
      console.error(
        JSON.stringify({ message: "variant playlist unavailable", url: variantUrl.toString(), ref }),
      );
      return new Response("Variant playlist unavailable", { status: 502, headers: cors() });
    }
    media = next;
  }

  if (/#EXT-X-KEY:(?![^\n]*METHOD=NONE)/i.test(media.text)) {
    return new Response("Encrypted playlist cannot be saved", { status: 501, headers: cors() });
  }

  const segments = segmentUrls(media.text, media.base);
  if (!segments.length) return new Response("Playlist has no segments", { status: 502, headers: cors() });
  if (segments.length > 5000) return new Response("Episode too long to stitch", { status: 413, headers: cors() });

  const fmp4 = /#EXT-X-MAP:/i.test(media.text) || /\.m4s(\?|$)/i.test(segments[segments.length - 1]);
  const safe = String(title || "episode")
    .replace(/[^\w.\- ]+/g, "_")
    .slice(0, 120) || "episode";
  const headers = cors({
    "content-type": fmp4 ? "video/mp4" : "video/mp2t",
    "content-disposition": `attachment; filename="${safe}.${fmp4 ? "mp4" : "ts"}"`,
    "cache-control": "no-store",
  });

  // A byte total lets the app draw real progress instead of a spinner. Only an
  // exact, verified sum may claim to be Content-Length; a sampled estimate
  // travels in its own header so a short or long transfer stays visible.
  const exact = await sumSegmentBytes(segments, ref);
  const total = exact > 0 ? exact : await estimateSegmentBytes(segments, ref);
  // Workerd drops Content-Length on a streamed body of unknown length, so the
  // total is also published in headers the client can always read.
  if (exact > 0) headers["content-length"] = String(exact);
  if (total > 0) {
    headers["x-total-bytes"] = String(total);
    headers["x-total-exact"] = exact > 0 ? "1" : "0";
    headers["access-control-expose-headers"] =
      "content-length, x-total-bytes, x-total-exact";
  }

  if (request.method === "HEAD") return new Response(null, { status: 200, headers });

  let index = 0;
  const body = new ReadableStream({
    async pull(controller) {
      if (index >= segments.length) {
        controller.close();
        return;
      }
      const segment = segments[index];
      index += 1;
      try {
        let origin = "";
        try {
          origin = ref ? new URL(ref).origin : "";
        } catch {}
        const res = await fetch(segment, {
          headers: {
            "user-agent": UA,
            referer: ref || "",
            origin,
            accept: "*/*",
          },
          redirect: "follow",
        });
        if (!res.ok) throw new Error(`segment ${res.status}`);
        if (!res.body) throw new Error("segment body missing");
        // Stream the segment through instead of buffering it whole: a few MB
        // arriving in chunks keeps peak memory flat under the isolate limit.
        const reader = res.body.getReader();
        for (;;) {
          const { done, value } = await reader.read();
          if (done) break;
          if (value) controller.enqueue(value);
        }
      } catch (err) {
        controller.error(err);
      }
    },
  });

  return new Response(body, { status: 200, headers });
}

async function viaRender(pathAndQuery, range) {
  try {
    const headers = {};
    if (range) headers.range = range;
    const res = await fetch(RENDER_ORIGIN + pathAndQuery, {
      headers,
      redirect: "follow",
    });
    if (!res.ok && res.status !== 206) return null;
    return res;
  } catch {
    return null;
  }
}

async function upstream(raw, ref, request) {
  const url = assertPublicUrl(raw);
  if (!url) return null;
  const headers = {
    "user-agent": UA,
    referer: ref || `${url.origin}/`,
    origin: ref ? new URL(ref).origin : url.origin,
    accept: "*/*",
  };
  const range = request.headers.get("range");
  if (range) headers.range = range;
  return fetch(url.toString(), { headers, redirect: "follow" });
}

/** Rewrite every playable reference in a playlist through the segment proxy. */
export function rewritePlaylist(text, playlistUrl, ref) {
  const absolute = (u) => {
    try {
      return new URL(u, playlistUrl).toString();
    } catch {
      return u;
    }
  };
  const proxied = (u) =>
    `/api/proxy/segment?url=${encodeURIComponent(absolute(u))}&ref=${encodeURIComponent(ref || "")}`;

  return String(text || "")
    .split(/\r?\n/)
    .map((line) => {
      const trimmed = line.trim();
      if (!trimmed) return line;
      if (trimmed.startsWith("#")) {
        return line.replace(/URI="([^"]+)"/g, (_, uri) => `URI="${proxied(uri)}"`);
      }
      return proxied(trimmed);
    })
    .join("\n");
}

function looksLikePlaylist(url, contentType, bodyStart) {
  return (
    /\.m3u8(\?|$)/i.test(url) ||
    /mpegurl/i.test(contentType || "") ||
    String(bodyStart || "").startsWith("#EXTM3U")
  );
}

async function proxyPlaylist(raw, ref) {
  const url = assertPublicUrl(raw);
  if (!url) return new Response("Bad url", { status: 400, headers: cors() });
  let res = null;
  try {
    res = await fetch(url.toString(), {
      headers: { "user-agent": UA, referer: ref || `${url.origin}/`, accept: "*/*" },
      redirect: "follow",
    });
  } catch {
    res = null;
  }
  if (!res || !res.ok) {
    const relayed = await viaRender(
      `/api/proxy/hls?url=${encodeURIComponent(raw)}&ref=${encodeURIComponent(ref || "")}`,
    );
    if (relayed) res = relayed;
  }
  if (!res || !res.ok) {
    return new Response("Upstream playlist unavailable", {
      status: 502,
      headers: cors(),
    });
  }
  const text = await res.text();
  return new Response(rewritePlaylist(text, url.toString(), ref), {
    status: 200,
    headers: cors({
      "content-type": "application/vnd.apple.mpegurl",
      "cache-control": "public, max-age=20",
    }),
  });
}

async function proxyBinary(raw, ref, request, { download = false, filename = "", sniff = false } = {}) {
  const url = assertPublicUrl(raw);
  if (!url) return new Response("Bad url", { status: 400, headers: cors() });

  let res = null;
  try {
    res = await upstream(raw, ref, request);
  } catch {
    res = null;
  }
  if (!res) return new Response("Bad url", { status: 400, headers: cors() });
  if (!res.ok && res.status !== 206) {
    const here = new URL(request.url);
    const relayed = await viaRender(
      here.pathname + here.search,
      request.headers.get("range"),
    );
    if (relayed) res = relayed;
  }
  if (!res.ok && res.status !== 206) {
    return new Response(`Upstream ${res.status}`, { status: 502, headers: cors() });
  }

  const contentType = res.headers.get("content-type") || "";
  const isPlaylist = looksLikePlaylist(url.pathname, contentType, "");
  if (isPlaylist) {
    // Range requests never apply to playlists; rewrite instead of passing bytes.
    return proxyPlaylist(raw, ref);
  }

  const type = mediaTypeFor(url.pathname, contentType);
  if (download && /^text\/html/i.test(type)) {
    // File hosts hand back an interstitial page whose next hop is dead or
    // JavaScript-only; saving that as .mp4 would be a broken download.
    return new Response("Upstream returned a download page, not a media file.", {
      status: 502,
      headers: cors(),
    });
  }

  let body = res.body;
  let finalType = type;
  if (sniff && res.body && !/^(video|audio)\//i.test(type)) {
    const sniffed = await sniffStream(res.body, type);
    if (sniffed.body) {
      body = sniffed.body;
      finalType = sniffed.type;
    }
  }

  const headers = cors({
    "content-type": finalType,
    "accept-ranges": res.headers.get("accept-ranges") || "bytes",
    "cache-control": "public, max-age=300",
  });
  const length = res.headers.get("content-length");
  if (length) headers["content-length"] = length;
  const range = res.headers.get("content-range");
  if (range) headers["content-range"] = range;
  if (download) {
    const safe = String(filename || filenameFromUrl(url))
      .replace(/[^\w.\- ]+/g, "_")
      .slice(0, 120) || "video";
    headers["content-disposition"] = `attachment; filename="${safe}"`;
  }

  // Stream straight through: Workers keep the body lazy, so multi-GB files do
  // not buffer in memory.
  return new Response(body, { status: res.status, headers });
}

function filenameFromUrl(url) {
  const last = url.pathname.split("/").filter(Boolean).pop() || "video";
  return decodeURIComponent(last);
}

export async function route(request, url, parts) {
  if (request.method !== "GET" && request.method !== "HEAD") return null;
  const [, p1, p2] = parts;
  if (p1 !== "proxy" && p1 !== "download") return null;

  const target = url.searchParams.get("url") || "";
  const ref = url.searchParams.get("ref") || "";

  if (p1 === "proxy" && p2 === "hls") {
    return proxyPlaylist(target, ref);
  }

  if (p1 === "proxy" && p2 === "segment") {
    return proxyBinary(target, ref, request, { sniff: true });
  }

  if (p1 === "proxy" && p2 === "video") {
    return proxyBinary(target, ref, request);
  }

  if (p1 === "proxy" && p2 === "subtitle") {
    const res = await upstream(target, ref, request);
    if (!res) return new Response("Bad url", { status: 400, headers: cors() });
    if (!res.ok) {
      return new Response("Subtitle unavailable", { status: 502, headers: cors() });
    }
    const text = await res.text();
    return new Response(text, {
      headers: cors({
        "content-type": "text/vtt; charset=utf-8",
        "cache-control": "public, max-age=3600",
      }),
    });
  }

  if (p1 === "download" && p2 === "hls") {
    return hlsDownload(target, ref, request, {
      title: url.searchParams.get("title") || "",
      height: Number(url.searchParams.get("height") || 0) || 0,
    });
  }

  if (p1 === "download" && p2 === "video") {
    const title = url.searchParams.get("title") || "";
    const isHls = /\.m3u8(\?|$)/i.test(target);
    const name = title || "episode";
    const ext = isHls ? "m3u8" : /\.ts(\?|$)/i.test(target) ? "ts" : "mp4";
    return proxyBinary(target, ref, request, {
      download: true,
      filename: `${name}.${ext}`,
    });
  }

  return null;
}
