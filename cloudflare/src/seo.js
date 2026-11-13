/**
 * Technical SEO for the independent Cloudflare deployment.
 *
 * The Worker is its own site (camanjme.camanime.workers.dev), so every URL it
 * publishes is built from the request origin. It never emits a Render hostname
 * and never lists a page it cannot serve: the sitemap only contains static
 * public routes plus anime ids that AniList just returned for the home grids,
 * which is exactly the set of pages `detailsPage` can render.
 */
import { homeGrids } from "./catalog.js";
import { rewriteAniListImages } from "./media.js";

/** Pages that exist for every visitor and return 200 without a session. */
const PUBLIC_PATHS = ["/", "/browse", "/download", "/developers"];

/** Routes that must never be indexed (private, per-user or credential pages). */
const PRIVATE_PREFIXES = ["/library", "/settings", "/login", "/register", "/logout", "/search"];

const SITEMAP_TTL_MS = 30 * 60 * 1000;
let sitemapCache = { at: 0, origin: "", xml: "" };

function xmlEscape(value) {
  return String(value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&apos;");
}

/**
 * @param {string} origin e.g. https://camanjme.camanime.workers.dev
 * @returns {Promise<string>} sitemap XML for this deployment
 */
export async function sitemapXml(origin) {
  const now = Date.now();
  if (sitemapCache.origin === origin && now - sitemapCache.at < SITEMAP_TTL_MS && sitemapCache.xml) {
    return sitemapCache.xml;
  }

  const paths = new Set(PUBLIC_PATHS);
  try {
    const grids = await homeGrids();
    for (const row of [grids.trending, grids.airing, grids.movies]) {
      for (const anime of row || []) {
        if (anime && anime.id) paths.add(`/anime/${anime.id}`);
      }
    }
  } catch {
    // AniList down: still publish the static routes rather than an empty file.
  }

  const urls = [...paths]
    .map((p) => `  <url><loc>${xmlEscape(origin + p)}</loc></url>`)
    .join("\n");
  const xml = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
${urls}
</urlset>
`;
  sitemapCache = { at: now, origin, xml };
  return xml;
}

export function sitemapResponse(xml) {
  return new Response(xml, {
    headers: {
      "content-type": "application/xml; charset=utf-8",
      "cache-control": "public, max-age=1800",
    },
  });
}

/**
 * robots.txt for this deployment. CSS/JS/images stay crawlable (Google needs
 * them to render the page), only private and API surfaces are disallowed.
 * @param {string} origin
 * @param {string} [adminPath] the configured dashboard path, if any
 */
export function robotsTxt(origin, adminPath) {
  const disallow = [
    "/api/",
    "/get/",
    "/login",
    "/register",
    "/logout",
    "/library",
    "/settings",
  ];
  if (adminPath && adminPath.startsWith("/")) disallow.push(adminPath);

  const rules = (agent) => [
    `User-agent: ${agent}`,
    "Allow: /",
    "Allow: /static/",
    ...disallow.map((p) => `Disallow: ${p}`),
    "",
  ];

  const body = [
    ...rules("Googlebot"),
    ...rules("*"),
    `Sitemap: ${origin}/sitemap.xml`,
    "",
  ].join("\n");

  return new Response(body, {
    headers: { "content-type": "text/plain; charset=utf-8", "cache-control": "public, max-age=3600" },
  });
}

function isPrivate(path) {
  return PRIVATE_PREFIXES.some((p) => path === p || path.startsWith(p + "/"));
}

/**
 * Fill the origin-dependent head tags and keep per-user pages out of the index.
 *
 * @param {Response} response HTML from pageRoutes
 * @param {URL} url request URL
 */
export async function withSeo(response, url) {
  const type = response.headers.get("content-type") || "";
  if (!type.includes("text/html")) return response;

  let body = await response.text();
  // Root keeps its trailing slash (https://host/), every other page is
  // published without one so canonical and sitemap URLs cannot disagree.
  const trimmed = url.pathname.replace(/\/+$/, "");
  const canonical = url.origin + (trimmed || "/");
  body = body.split("__CA_CANONICAL__").join(xmlEscape(canonical));
  body = body.split("__CA_ORIGIN__").join(xmlEscape(url.origin));

  if (isPrivate(url.pathname)) {
    body = body.replace(
      '<meta name="robots" content="index, follow, max-image-preview:large">',
      '<meta name="robots" content="noindex, follow">',
    );
  }

  // WebSite + SearchAction: factual, and only on the homepage where the site
  // itself is the subject. No ratings, dates or reviews are invented.
  if (url.pathname === "/") {
    const ld = {
      "@context": "https://schema.org",
      "@type": "WebSite",
      name: "CamAnime",
      url: url.origin + "/",
      potentialAction: {
        "@type": "SearchAction",
        target: `${url.origin}/search?q={search_term_string}`,
        "query-input": "required name=search_term_string",
      },
    };
    body = body.replace(
      "</head>",
      `<script type="application/ld+json">${JSON.stringify(ld).replace(/</g, "\\u003c")}</script>\n</head>`,
    );
  }

  // AniList blocks Cloudflare egress, so an unproxied s4.anilist.co URL is
  // blocked by the browser as an opaque response and every poster disappears.
  body = rewriteAniListImages(body);

  const headers = new Headers(response.headers);
  headers.delete("content-length");
  return new Response(body, { status: response.status, headers });
}
