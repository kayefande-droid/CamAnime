import { renderSettings } from "./settings_page.js";
/** CamAnime edge pages: same branding/classes as the Render site, Jinja-free HTML builders. */
import { esc, BRAND } from "./util.js";
import { card } from "./catalog.js";

const THEME_GUARD = `<script>try{var t=localStorage.getItem('camanime-theme');if(['midnight','light','vibrant','sakura','forest','obsidian','neo','tokyo'].indexOf(t)===-1)t='midnight';document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>`;
const LAYOUT_GUARD = `<script>try{var l=localStorage.getItem('camanime-layout');if(['classic','cinema','compact','minimal','wide','magazine','wall'].indexOf(l)===-1)l='classic';document.documentElement.setAttribute('data-layout',l);}catch(e){}</script>`;

export function head(title, desc, opts = {}) {
  return `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)} | ${BRAND}</title>
<meta name="description" content="${esc(desc)}">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#087BFF">
<!-- Self-referencing canonical and social cards. __CA_CANONICAL__ / __CA_ORIGIN__
     are filled by seo.js with this request's own origin, so this deployment
     never claims to be the Render site. -->
<link rel="canonical" href="__CA_CANONICAL__">
<meta property="og:type" content="website">
<meta property="og:site_name" content="${BRAND}">
<meta property="og:title" content="${esc(title)} | ${BRAND}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="__CA_CANONICAL__">
<meta property="og:image" content="__CA_ORIGIN__/static/brand/og-card-1200x630.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)} | ${BRAND}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="__CA_ORIGIN__/static/brand/og-card-1200x630.png">
<link rel="icon" href="/static/brand/camanime-icon.svg" type="image/svg+xml">
<link rel="icon" href="/static/favicon-32.png" sizes="32x32" type="image/png">
<link rel="apple-touch-icon" href="/static/apple-touch-icon.png">
<link rel="manifest" href="/static/manifest.webmanifest">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="preconnect" href="https://cdnjs.cloudflare.com">
<!-- Same faces as the Render templates, so the shared stylesheets compute
     identical type on both hosts. Font Awesome is the icon set those
     templates use for card badges and nav items. -->
<link href="https://fonts.googleapis.com/css2?family=Bricolage+Grotesque:opsz,wght@12..96,600..800&family=Plus+Jakarta+Sans:wght@400;500;600;700&family=JetBrains+Mono:wght@500;600&display=swap" rel="stylesheet">
<link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.1/css/all.min.css" rel="stylesheet">
<link rel="stylesheet" href="/static/css/base.css?v=20261116-ep">
<link rel="stylesheet" href="/static/css/sync.css?v=20261112-ink">
<link rel="stylesheet" href="/static/css/header-layout.css?v=20261114-nav2">
<link rel="stylesheet" href="/static/css/redesign.css?v=20261114-skin2">
<link href="/static/css/motion.css?v=20261111-motion3" rel="stylesheet">
<!-- The Render templates load this on every page; the mirror loads the same
     file so the two hosts cannot drift in home-page styling. -->
<link rel="stylesheet" href="/static/css/home.css?v=20261116-home">
<script src="/static/js/site.js?v=20261111-scroll" defer></script>
<script src="/static/js/motion.js?v=20261111-motion3" defer></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.17/hls.min.js" defer></script>
<script src="/static/js/release-schedule.js?v=20261111-sched2" defer></script>
${THEME_GUARD}
${LAYOUT_GUARD}
${(opts.styles || []).map((href) => `<link rel="stylesheet" href="${href}">`).join("\n")}
${(opts.scripts || []).map((src) => `<script src="${src}" defer></script>`).join("\n")}
</head><body>`;
}

export function chrome(title, desc, userName, inner, active = "home", opts = {}) {
  const bodyClass = opts.bodyClass ? ` class="${opts.bodyClass}"` : "";
  const mainClass = opts.mainClass || "main-wrap";
  return `${head(title, desc, opts)}
<body${bodyClass}>
<a class="skip-link" href="#main-content">Skip to content</a>
<header>
  <div class="header-inner">
    <div class="brand-group">
      <a class="site-logo" href="/" aria-label="CamAnime — Watch, discover, enjoy"><img src="/static/brand/camanime-logo.svg" alt="CamAnime — Watch • Discover • Enjoy"></a>
      <nav class="nav-links">
        <a class="nav-link ${active === "home" ? "active" : ""}" href="/"><i class="fas fa-compass" aria-hidden="true"></i> Discover</a>
        <a class="nav-link" href="/?format=TV"><i class="fas fa-tv" aria-hidden="true"></i> TV Series</a>
        <a class="nav-link" href="/?format=MOVIE"><i class="fas fa-film" aria-hidden="true"></i> Movies</a>
        <a class="nav-link scraper-pill" href="/scraper"><span class="live-dot" aria-hidden="true"></span> AnimeHeaven Scraper &amp; Downloader</a>
        <a class="nav-link ${active === "download" ? "active" : ""}" href="/download"><i class="fas fa-mobile-alt" aria-hidden="true"></i> Apps</a>
        <a class="nav-link ${active === "settings" ? "active" : ""}" href="/settings"><i class="fas fa-cog" aria-hidden="true"></i> Settings</a>
        <a class="nav-link ${active === "dev" ? "active" : ""}" href="/developers"><i class="fas fa-code" aria-hidden="true"></i> Developers</a>
        ${userName ? `<a class="nav-link" href="/settings">Account (${esc(userName)})</a>` : `<a class="nav-link" href="/login">Sign in</a>`}
      </nav>
    </div>
    <button type="button" class="nav-toggle" id="navToggle" aria-expanded="false" aria-controls="mobileNav" aria-label="Open menu" onclick="toggleMobileNav()"><i class="fas fa-bars" aria-hidden="true"></i></button>
    <div class="header-actions">
      <form action="/search" method="get" class="search-form" role="search">
        <input type="search" name="q" class="search-input" aria-label="Search anime catalogue" placeholder="Search anime, seasons, movies..." required>
        <button type="submit" class="search-btn" aria-label="Submit anime search"><i class="fas fa-search" aria-hidden="true"></i></button>
      </form>
      <a class="btn-watchlist-Trigger" href="/library" style="text-decoration:none" aria-label="Open your watchlist">
        <i class="fas fa-bookmark" aria-hidden="true"></i> <span class="wl-label">Watchlist</span>
      </a>
    </div>
  </div>
  <nav class="mobile-nav" id="mobileNav" aria-label="Menu">
    <a href="/" class="${active === "home" ? "active" : ""}"><i class="fas fa-compass" aria-hidden="true"></i> Discover</a>
    <a href="/?format=TV"><i class="fas fa-tv" aria-hidden="true"></i> TV Series</a>
    <a href="/?format=MOVIE"><i class="fas fa-film" aria-hidden="true"></i> Movies</a>
    <a href="/scraper"><i class="fas fa-bolt" aria-hidden="true"></i> AnimeHeaven Scraper &amp; Downloader</a>
    <a href="/library" class="${active === "library" ? "active" : ""}"><i class="fas fa-bookmark" aria-hidden="true"></i> My Library</a>
    <a href="/download" class="${active === "download" ? "active" : ""}"><i class="fas fa-mobile-alt" aria-hidden="true"></i> Apps</a>
    <a href="/settings" class="${active === "settings" ? "active" : ""}"><i class="fas fa-cog" aria-hidden="true"></i> Settings</a>
    <a href="/developers" class="${active === "dev" ? "active" : ""}"><i class="fas fa-code" aria-hidden="true"></i> Developers API</a>
    ${userName ? `<a href="/settings">Account (${esc(userName)})</a>` : `<a href="/login">Sign in</a>`}
  </nav>
</header>
<main class="${mainClass}" id="main-content" tabindex="-1">
${inner}
</main>
<footer>
  <div class="footer-inner">
    <div><strong style="color: var(--text-primary);">CamAnime</strong> — anime discovery, episode metadata, release schedule and the provider listings this deployment can actually play.</div>
    <div style="display: flex; gap: 1.25rem; flex-wrap: wrap;">
      <a href="/" style="color: var(--text-secondary); text-decoration: none;">Home</a>
      <a href="/developers" style="color: var(--text-secondary); text-decoration: none;">Developer API</a>
      <a href="/download" style="color: var(--accent); text-decoration: none;"><i class="fas fa-mobile-alt" aria-hidden="true"></i> Get the apps</a>
      <a href="/settings" style="color: var(--text-secondary); text-decoration: none;">Settings</a>
      <a href="/privacy" style="color: var(--text-secondary); text-decoration: none;">Privacy</a>
    </div>
  </div>
  <div class="footer-inner" style="margin-top: .9rem; padding-top: .9rem; border-top: 1px solid var(--border-subtle, rgba(255,255,255,.08)); display: flex; flex-wrap: wrap; gap: .4rem 1rem; justify-content: space-between; color: var(--text-secondary); font-size: .78rem;">
    <span>© 2026 CamAnime. All rights reserved.</span>
    <span>Independent Cloudflare deployment (camanjme) — not affiliated with the Render origin.</span>
  </div>
</footer>
<script>
function toggleMobileNav(force) {
  var nav = document.getElementById('mobileNav'), btn = document.getElementById('navToggle');
  if (!nav || !btn) return;
  var wasOpen = nav.classList.contains('open');
  var open = force !== undefined ? force : !wasOpen;
  nav.classList.toggle('open', open);
  btn.setAttribute('aria-expanded', String(open));
  btn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
  if (wasOpen && !open) btn.focus();
}
document.addEventListener('keydown', function (e) { if (e.key === 'Escape') toggleMobileNav(false); });
// Tapping the page behind the menu closes it, as does growing past the
// breakpoint where the tab row takes over.
document.addEventListener('click', function (e) {
  var nav = document.getElementById('mobileNav');
  if (!nav || !nav.classList.contains('open')) return;
  if (nav.contains(e.target)) return;
  var btn = document.getElementById('navToggle');
  if (btn && btn.contains(e.target)) return;
  toggleMobileNav(false);
});
var wideQuery = window.matchMedia('(min-width: 900px)');
function closeWhenWide(query) {
  if (!query.matches) return;
  var nav = document.getElementById('mobileNav');
  if (nav && nav.classList.contains('open')) toggleMobileNav(false);
}
if (wideQuery.addEventListener) wideQuery.addEventListener('change', closeWhenWide);
else if (wideQuery.addListener) wideQuery.addListener(closeWhenWide);
</script>
</body></html>`;
}

export function homePage(grids, userName) {
  const section = (title, subtitle, items, id) => `
    <section class="section-block"${id ? ` id="${id}"` : ""}>
      <div class="section-head">
        <div class="section-title-wrap">
          <span class="section-accent-bar" aria-hidden="true"></span>
          <h2 class="section-title">${esc(title)}</h2>
          <span class="section-subtitle">${esc(subtitle)}</span>
        </div>
      </div>
      <div class="anime-grid">${items.map(card).join("")}</div>
    </section>`;
  // The mirror rotates the same five trending titles the origin does, so the
  // two home pages behave alike instead of the mirror freezing on one poster.
  const trending = grids.trending || [];
  // Same rule the origin uses, so both home pages rotate the same titles.
  const withBanner = trending.filter((a) => a.bannerImage);
  const heroItems = (withBanner.length ? withBanner : trending).slice(0, 6);
  const heroMetaOf = (a) => [
    a?.averageScore ? `<span class="meta-pill gold"><i class="fas fa-star" aria-hidden="true"></i> ${(a.averageScore / 10).toFixed(1)}</span>` : "",
    a?.format ? `<span class="meta-pill">${esc(a.format)}</span>` : "",
    a?.episodes ? `<span class="meta-pill">EP ${Number(a.episodes)}</span>` : "",
    a?.seasonYear ? `<span class="meta-pill">${esc(a.seasonYear)}</span>` : "",
    ...(a?.genres || []).slice(0, 3).map((g) => `<span class="meta-pill">${esc(g)}</span>`),
  ].join("");
  const heroDesc = (a) => {
    const raw = String(a?.description || "").replace(/<[^>]*>/g, " ").replace(/\s+/g, " ").trim();
    if (!raw) return "Trending on AniList right now, with provider listings resolved live on this deployment.";
    return raw.length > 220 ? raw.slice(0, 217).replace(/\s+\S*$/, "") + "..." : raw;
  };
  const heroSlides = heroItems.map((a, i) => {
    const title = a.title?.english || a.title?.romaji || "Featured anime";
    const meta = heroMetaOf(a);
    return `<div class="hero-slide${i === 0 ? " active" : ""}" data-slide-index="${i}">
        <img class="hero-backdrop" src="${esc(a.bannerImage || a.coverImage?.extraLarge || a.coverImage?.large || "")}" alt="${esc(title)}" width="1600" height="900" ${i === 0 ? 'fetchpriority="high"' : 'fetchpriority="auto"'} decoding="async" referrerpolicy="no-referrer">
        <div class="hero-vignette"></div>
        <div class="hero-body">
          ${i === 0 ? `<h1 class="hero-title">${esc(title)}</h1>` : `<div class="hero-title">${esc(title)}</div>`}
          ${meta ? `<div class="hero-meta-row">${meta}</div>` : ""}
          <p class="hero-desc">${esc(heroDesc(a))}</p>
          <div class="hero-ctas">
            <a class="btn-primary" href="/watch/${a.id}/1"><i class="fas fa-play" aria-hidden="true"></i> Watch Episode 1</a>
            <a class="btn-secondary" href="/anime/${a.id}"><i class="fas fa-layer-group" aria-hidden="true"></i> Episodes &amp; download</a>
          </div>
        </div>
      </div>`;
  }).join("");
  const heroDots = heroItems.map((a, i) =>
    `<button type="button" class="hero-dot${i === 0 ? " active" : ""}" data-slide="${i}" aria-label="Slide ${i + 1}"></button>`).join("");
  const heroScript = heroItems.length > 1 ? `<script>
    (function () {
      var stage = document.getElementById("heroCarousel");
      if (!stage) return;
      var slides = stage.querySelectorAll(".hero-slide");
      var dots = stage.querySelectorAll(".hero-dot");
      var reduce = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      var current = 0, timer = null;
      function show(idx) {
        current = idx;
        slides.forEach(function (s, i) { s.classList.toggle("active", i === idx); });
        dots.forEach(function (d, i) { d.classList.toggle("active", i === idx); });
      }
      dots.forEach(function (d) {
        d.addEventListener("click", function () {
          if (timer) { clearInterval(timer); timer = null; }
          show(Number(d.dataset.slide) || 0);
        });
      });
      if (reduce) return;
      var raw = getComputedStyle(document.documentElement).getPropertyValue("--ca-cycle").trim();
      var cycle = raw.indexOf("ms") > -1 ? parseFloat(raw) : raw.indexOf("s") > -1 ? parseFloat(raw) * 1000 : parseFloat(raw);
      if (!isFinite(cycle) || cycle < 1500) cycle = 7500;
      timer = setInterval(function () {
        if (current >= slides.length - 1) { clearInterval(timer); timer = null; return; }
        show(current + 1);
      }, cycle);
    })();
  </script>` : "";
  const inner = `
    ${heroItems.length ? `
    <section class="hero-spotlight" id="heroCarousel">
      ${heroSlides}
      ${heroItems.length > 1 ? `<div class="hero-dots">${heroDots}</div>` : ""}
    </section>
    ${heroScript}` : ""}
    <section class="dev-ad" aria-labelledby="devAdTitle">
      <span class="dev-eyebrow">Developer API · Free</span>
      <h2 id="devAdTitle">One free anime streaming API, ready to embed.</h2>
      <p class="dev-lede">Create a key, call one endpoint, play a direct MP4 on your own site. A thousand calls a day, no card, CORS enabled.</p>
      <ul class="dev-bullets">
        <li>Direct MP4 — no iframe, no ads</li>
        <li>One provider, resolved live</li>
        <li>Keys you can revoke anytime</li>
      </ul>
      <div class="hero-ctas">
        <a class="btn-primary" href="/developers#keys">Create a free API key</a>
        <a class="btn-secondary" href="/developers#docs">View the docs</a>
      </div>
    </section>
    <section class="filter-bar" aria-label="Browse by genre">
      <div class="rail-head"><h2 class="rail-title">Browse by genre</h2></div>
      <div class="genre-pills">
        <a href="/" class="genre-pill active">All Anime</a>
        ${["Action", "Adventure", "Comedy", "Drama", "Fantasy", "Horror", "Mystery", "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller"].map((g) => `<a href="/?genre=${encodeURIComponent(g)}" class="genre-pill">${esc(g)}</a>`).join("")}
      </div>
    </section>
    ${section("Trending now", "What AniList is trending this hour", grids.trending || [], "trending")}
    ${section("Airing this season", "Currently airing, highest rated first", grids.airing || [])}
    ${section("Popular movies", "Most followed anime films", grids.movies || [])}
  `;
  return chrome("Watch anime free", "CamAnime on Cloudflare: trending anime, search, watch pages and the community forum.", userName, inner, "home");
}

/** A single titled card grid, shared by the header filters and genre strip. */
function browseGrid(label, subtitle, items, userName) {
  const inner = `
    <section class="section-block">
      <div class="section-head">
        <div class="section-title-wrap">
          <span class="section-accent-bar" aria-hidden="true"></span>
          <h2 class="section-title">${esc(label)}</h2>
          <span class="section-subtitle">${esc(subtitle)}</span>
        </div>
      </div>
      ${items.length
        ? `<div class="anime-grid">${items.map(card).join("")}</div>`
        : `<div class="discovery-empty">No titles answered for this filter right now.</div>`}
    </section>`;
  return chrome(label, `${label} streaming on CamAnime.`, userName, inner, "browse");
}

/** TV / movie browse view for the filters the Render header exposes. */
export function browsePage(format, items, userName) {
  const isMovie = format === "MOVIE";
  return browseGrid(
    isMovie ? "Anime movies" : "TV series",
    `${isMovie ? "Most followed films" : "Most popular series"} on AniList`,
    items,
    userName,
  );
}

/** Genre browse view linked from the home page's genre strip. */
export function genrePage(genre, items, userName) {
  return browseGrid(
    `${genre} anime`,
    `Most popular ${genre} titles on AniList`,
    items,
    userName,
  );
}

export function searchGrid(q, items, userName) {
  const inner = `
    <section>
      <h1 class="section-title">Search: “${esc(q)}”</h1>
      <form action="/search" method="get" role="search" style="display:flex;gap:.5rem;margin:1rem 0">
        <input type="search" name="q" value="${esc(q)}" placeholder="Find an anime…" aria-label="Search anime"
          style="flex:1;padding:.7rem;border-radius:12px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input, #141926);color:var(--text-primary, #f3f5fa)">
        <button class="search-btn" type="submit">Search</button>
      </form>
      ${items.length ? `<div class="anime-grid">${items.map(card).join("")}</div>` :
        `<div class="discovery-empty">No results for “${esc(q)}”. Try an English/romaji title.</div>`}
    </section>`;
  return chrome(`Search ${q}`, `Search results for ${q} on CamAnime.`, userName, inner, "browse");
}

/** Episode cards rendered per page on a rail. AniList titles can run past a
 * thousand episodes, so the mirror paginates exactly like the Render origin. */
const EPISODE_PAGE_SIZE = 48;

/** Slice a rail to the `?eps=` page, clamped to the real range. */
function episodePage(items, requested, focus) {
  const total = items.length;
  const pages = Math.max(1, Math.ceil(total / EPISODE_PAGE_SIZE));
  let page = Number.parseInt(requested || "", 10);
  if (!Number.isFinite(page) || page < 1) {
    const at = focus == null ? -1 : items.findIndex((entry) => entry.n === focus);
    page = at >= 0 ? Math.floor(at / EPISODE_PAGE_SIZE) + 1 : 1;
  }
  page = Math.min(Math.max(page, 1), pages);
  const start = (page - 1) * EPISODE_PAGE_SIZE;
  return {
    total,
    page,
    pages,
    start: total ? start + 1 : 0,
    end: Math.min(start + EPISODE_PAGE_SIZE, total),
    slice: items.slice(start, start + EPISODE_PAGE_SIZE),
  };
}

/** Prev/numbers/next pager for a paginated rail. */
function episodePager(pager, basePath, params) {
  if (pager.pages <= 1) return "";
  const href = (page) => {
    const search = new URLSearchParams(params);
    search.set("eps", String(page));
    return esc(`${basePath}?${search.toString()}`);
  };
  const wanted = new Set([1, pager.pages]);
  for (let n = Math.max(1, pager.page - 2); n <= Math.min(pager.pages, pager.page + 2); n += 1) {
    wanted.add(n);
  }
  const numbers = [];
  let previous = 0;
  for (const n of [...wanted].sort((a, b) => a - b)) {
    if (previous && n - previous > 1) numbers.push(`<span class="ep-pager-gap" aria-hidden="true">…</span>`);
    numbers.push(
      n === pager.page
        ? `<span class="ep-pager-btn current" aria-current="page">${n}</span>`
        : `<a class="ep-pager-btn" href="${href(n)}" aria-label="Episode page ${n}">${n}</a>`,
    );
    previous = n;
  }
  const prev = pager.page > 1 ? `<a class="ep-pager-btn" rel="prev" href="${href(pager.page - 1)}">Prev</a>` : "";
  const next = pager.page < pager.pages ? `<a class="ep-pager-btn" rel="next" href="${href(pager.page + 1)}">Next</a>` : "";
  return `<nav class="ep-pager" aria-label="Episode pages">
      <span class="ep-pager-range">Episodes ${pager.start}–${pager.end} of ${pager.total}</span>
      <div class="ep-pager-links">${prev}${numbers.join("")}${next}</div>
    </nav>`;
}

export function detailsPage(anime, ratingSummary, user, eps) {
  const name = anime.title.english || anime.title.romaji;
  const inner = `
    <section class="anime-hero" style="display:flex;gap:1.5rem;flex-wrap:wrap">
      <img src="${esc(anime.coverImage?.extraLarge || anime.coverImage?.large || "")}" alt="${esc(name)} poster" style="border-radius:16px;max-width:280px">
      <div style="flex:1;min-width:280px">
        <h1 class="hero-title">${esc(name)}</h1>
        <p>${anime.title.native ? esc(anime.title.native) : ""} ${anime.format ? "· " + esc(anime.format) : ""} ${anime.status ? "· " + esc(anime.status) : ""} ${anime.seasonYear ? "· " + anime.seasonYear : ""}</p>
        <p class="muted">${anime.averageScore ? `AniList score ${anime.averageScore}% · ` : ""}${(anime.genres || []).join(", ") || ""}</p>
        ${anime.nextAiringEpisode ? `<div class="release-countdown" data-airing-epoch="${Number(anime.nextAiringEpisode.airingAt) || 0}" data-airing-episode="${esc(String(anime.nextAiringEpisode.episode ?? ""))}"><p class="muted">Next episode (EP ${esc(String(anime.nextAiringEpisode.episode ?? "?"))}) airs in <strong class="cd-text">${Math.max(0, Math.ceil((anime.nextAiringEpisode.airingAt - Math.floor(Date.now() / 1000)) / 60))} min</strong></p><noscript>Countdown needs JavaScript.</noscript></div><script>(function(){var box=document.querySelector(".release-countdown");if(!box)return;var epoch=Number(box.dataset.airingEpoch)||0;var out=box.querySelector(".cd-text");function tick(){var s=epoch-Math.floor(Date.now()/1000);if(s<=0){out.textContent="airing now or aired - checking provider";return;}var d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60),x=s%60;out.textContent=(d?d+"d ":"")+h+"h "+m+"m "+x+"s";}tick();setInterval(tick,1000);})();</script>` : ""}
        <div id="ca-rating-out">${ratingSummary.average ? `Community score: <strong>${ratingSummary.average}/10</strong> (${ratingSummary.count} ratings)` : "No community ratings yet."}</div>
        <div class="hero-ctas">
          <a class="btn-primary" href="/watch/${anime.id}/1">Watch Episode 1</a>
        </div>
      </div>
    </section>
    <section><h2 class="section-title">Synopsis</h2><p class="ca-sub">${esc(String(anime.description || "").replace(/<[^>]*>/g, ""))}</p></section>
    <section><h2 class="section-title">Episodes</h2>
      ${(() => {
        // AniList often has no per-episode list for new or ongoing titles. Fall
        // back to the episode count so the watch links still show.
        // Same rule as the Render app: an ongoing title counts only episodes
        // already aired, so the next scheduled episode is not listed early.
        const nextEp = Number(anime.nextAiringEpisode?.episode) || 0;
        const nextAt = Number(anime.nextAiringEpisode?.airingAt) || 0;
        const aired = nextEp ? (nextAt && nextAt <= Math.floor(Date.now() / 1000) ? nextEp : nextEp - 1) : 0;
        const total = (anime.streamingEpisodes || []).length || (anime.status === "RELEASING" ? aired : Number(anime.episodes)) || 0;
        const entries = Array.from({ length: total }, (_, i) => ({ n: i + 1, se: (anime.streamingEpisodes || [])[i] || { title: "Episode " + (i + 1) } }));
        if (!entries.length) {
          return `<p class="discovery-empty">No per-episode stream data on AniList for this title — main catalogue episodes: ${anime.episodes ?? "?"}.</p>`;
        }
        const pager = episodePage(entries, eps, null);
        const cards = pager.slice.map(({ n, se }) => `
            <a class="anime-card" href="/watch/${anime.id}/${n}">
              <span class="card-poster-wrap"><img src="${esc(se.thumbnail || anime.coverImage?.large || "")}" alt="Episode ${n}" loading="lazy"></span>
              <span class="card-title">${esc(se.title || "Episode " + n)}</span><span class="card-format">EP ${n}</span>
            </a>`).join("");
        return `<div class="mini-grid">${cards}</div>${episodePager(pager, `/anime/${anime.id}`, {})}`;
      })()}
    </section>`;
  return chrome(name, `Watch ${name} on CamAnime — episodes, ratings, community.`, user?.name, inner, "browse", { bodyClass: "page-details" });
}

export function watchPage(ctx, user) {
  const { anime, episodes, current, epNum, eps } = ctx;
  // Play the provider bundle this deployment resolves, the same endpoint the
  // apps call. AniList's own links are third-party watch pages that refuse to be
  // framed, so they are only used as a fallback link, never as the player.
  const providerLink = current?.url ? current.url.replace(/^http:\/\//i, "https://") : "";
  const name = anime.title.english || anime.title.romaji || "Episode";
  const list = (episodes.length ? episodes : Array.from({ length: anime.episodes || 0 }, (_, i) => ({ n: i + 1, title: "Episode " + (i + 1), url: null })));
  // Default to the page holding the episode being watched, so the rail opens
  // around it instead of at episode 1 on a 1000-episode title.
  const pager = episodePage(list, eps, epNum);
  const inner = `
    <div class="watch-container">
      <div class="player-column">
        <div class="video-stage" id="videoStage">
          <video id="caPlayer" class="ca-player" controls playsinline preload="metadata"
            poster="${esc(anime.bannerImage || anime.coverImage?.extraLarge || "")}"
            style="width:100%;aspect-ratio:16/9;background:#000;border-radius:14px"></video>
          <iframe id="caFrame" title="Provider player" allow="autoplay; fullscreen; encrypted-media; picture-in-picture" allowfullscreen style="display:none;width:100%;aspect-ratio:16/9;border:0;border-radius:14px;background:#000"></iframe>
          <p class="discovery-empty" id="caPlayerMsg" style="display:none;padding:1rem"></p>
        </div>
        <div id="caServers" class="ca-servers" aria-live="polite" aria-busy="true" style="display:flex;flex-wrap:wrap;gap:.4rem;margin:.6rem 0">
          <span class="ctrl-btn" style="opacity:.55;cursor:default" data-skeleton>AnimeHeaven…</span>
          <span class="ctrl-btn" style="opacity:.55;cursor:default" data-skeleton>MegaPlay / Anikoto…</span>
          <span class="ctrl-btn" style="opacity:.55;cursor:default" data-skeleton>VidLink…</span>
          <span class="ctrl-btn" style="opacity:.55;cursor:default" data-skeleton>VidSrc…</span>
          <span style="font-size:.78rem;color:var(--text-muted);align-self:center" data-skeleton>Loading servers…</span>
        </div>
        <p id="caServerNote" style="margin:.2rem 0;font-size:.78rem;color:var(--text-muted)"></p>
        <p id="caDownloads" style="margin:.4rem 0;font-size:.82rem;color:var(--text-muted)">Loading downloads…</p>
        <script>
        (function () {
          var animeId = "${anime.id}";
          var epNum = ${Number(epNum) || 1};
          var audio = "sub";
          var video = document.getElementById("caPlayer");
          var frame = document.getElementById("caFrame");
          var msg = document.getElementById("caPlayerMsg");
          var serversEl = document.getElementById("caServers");
          var noteEl = document.getElementById("caServerNote");
          var dlEl = document.getElementById("caDownloads");
          var cacheKey = "camanime-src:v2:" + animeId + ":" + epNum + ":" + audio;
          var originPlayer = "https://camanime.onrender.com/watch/" + animeId + "/" + epNum;
          var hls = null;
          var inflight = {};

          function absUrl(u) { return (u && u.indexOf("http") === 0) ? u : (u ? location.origin + u : ""); }
          function note(text) { noteEl.textContent = text || ""; }
          function fail(text) { msg.textContent = text; msg.style.display = "block"; }

          function clearStage() {
            if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
            frame.style.display = "none";
            frame.removeAttribute("src");
            video.style.display = "block";
            try { video.pause(); } catch (e) {}
          }

          function play(server) {
            clearStage();
            msg.style.display = "none";
            msg.textContent = "";
            var url = absUrl(server.stream_url);
            if (!url) { fail("This server returned no link. Pick another server below."); return; }
            if (server.playback_mode === "iframe") {
              frame.src = url;
              frame.style.display = "block";
              video.style.display = "none";
              note("");
              var open = document.createElement("a");
              open.href = url;
              open.target = "_blank";
              open.rel = "noopener";
              open.textContent = "open " + (server.name || "the server") + " in a new tab";
              noteEl.appendChild(document.createTextNode("Playing in the provider's embed. If it stays blank, "));
              noteEl.appendChild(open);
              noteEl.appendChild(document.createTextNode("."));
              return;
            }
            if (server.playback_mode === "hls" || url.indexOf("/api/proxy/hls") !== -1) {
              if (window.Hls && window.Hls.isSupported()) {
                hls = new window.Hls({ maxBufferLength: 30 });
                hls.on(window.Hls.Events.ERROR, function (evt, data) {
                  if (data && data.fatal) note("This stream stalled. Try another server below.");
                });
                hls.loadSource(url);
                hls.attachMedia(video);
                return;
              }
              if (video.canPlayType("application/vnd.apple.mpegurl")) { video.src = url; return; }
              fail("This browser cannot play HLS here. Pick an MP4 server or open the server page.");
              return;
            }
            video.src = url;
            var attempt = video.play();
            if (attempt && attempt.catch) attempt.catch(function () {});
          }

          function renderServers(servers, active) {
            serversEl.innerHTML = "";
            serversEl.removeAttribute("aria-busy");
            if (!servers.length) {
              var empty = document.createElement("span");
              empty.style.cssText = "font-size:.82rem;color:var(--text-muted)";
              empty.textContent = "No server answered yet.";
              serversEl.appendChild(empty);
              return;
            }
            servers.forEach(function (s, i) {
              var b = document.createElement("button");
              b.type = "button";
              b.className = "ctrl-btn";
              b.textContent = s.name || s.label || s.provider || ("Server " + (i + 1));
              if (s === active) b.setAttribute("aria-current", "true");
              b.addEventListener("click", function () { play(s); });
              serversEl.appendChild(b);
            });
          }

          function renderDownloads(data) {
            dlEl.innerHTML = "";
            var rows = (data.downloads || []).filter(function (d) { return d && d.url; });
            if (!rows.length && data.download_url) rows = [{ label: "Download episode", url: data.download_url }];
            if (!rows.length) { dlEl.textContent = "No direct download for this episode yet."; return; }
            rows.slice(0, 10).forEach(function (d, i) {
              var a = document.createElement("a");
              a.className = "ctrl-btn";
              a.href = absUrl(d.url);
              a.setAttribute("download", "");
              a.textContent = d.label || d.quality || ("Download " + (i + 1));
              dlEl.appendChild(a);
              dlEl.appendChild(document.createTextNode(" "));
            });
          }

          function readCache() {
            try {
              var raw = sessionStorage.getItem(cacheKey);
              if (!raw) return null;
              var hit = JSON.parse(raw);
              if (!hit || !hit.at || Date.now() - hit.at > 30 * 60 * 1000) return null;
              return hit.data || null;
            } catch (e) { return null; }
          }

          function writeCache(data) {
            try {
              sessionStorage.setItem(cacheKey, JSON.stringify({ at: Date.now(), data: {
                servers: data.servers || [],
                downloads: data.downloads || [],
                active_server: data.active_server || null,
                download_url: data.download_url || ""
              }}));
            } catch (e) {}
          }

          function showEmpty(text) {
            msg.textContent = "";
            msg.style.display = "block";
            msg.appendChild(document.createTextNode(text + " "));
            var retry = document.createElement("button");
            retry.type = "button";
            retry.className = "ctrl-btn";
            retry.textContent = "Retry";
            retry.addEventListener("click", function () {
              msg.style.display = "none";
              serversEl.setAttribute("aria-busy", "true");
              load();
            });
            var link = document.createElement("a");
            link.className = "ctrl-btn";
            link.href = originPlayer;
            link.target = "_blank";
            link.rel = "noopener";
            link.textContent = "Open origin player";
            msg.appendChild(retry);
            msg.appendChild(document.createTextNode(" "));
            msg.appendChild(link);
          }

          function load() {
            var ctrl = window.AbortController ? new AbortController() : null;
            var timer = ctrl ? setTimeout(function () { ctrl.abort(); }, 12000) : null;
            var opts = { headers: { accept: "application/json" }, cache: "no-store" };
            if (ctrl) opts.signal = ctrl.signal;
            return fetch("/api/episode-sources/" + animeId + "/" + epNum + "?audio=" + audio, opts)
              .then(function (res) { if (!res.ok) throw new Error("HTTP " + res.status); return res.json(); })
              .then(function (data) {
                if (timer) clearTimeout(timer);
                var servers = data.servers || [];
                renderServers(servers, data.active_server || servers[0]);
                renderDownloads(data);
                if (!servers.length) { showEmpty("No server has answered for this episode yet."); return; }
                writeCache(data);
                note("");
                play(data.active_server || servers[0]);
                setTimeout(function () { prefetch(epNum + 1); }, 1400);
              })
              .catch(function () {
                if (timer) clearTimeout(timer);
                var cached = readCache();
                if (cached && cached.servers && cached.servers.length) {
                  renderServers(cached.servers, cached.active_server);
                  renderDownloads(cached);
                  note("Saved servers — live refresh failed. Tap a server to retry.");
                  play(cached.active_server || cached.servers[0]);
                  return;
                }
                renderServers([], null);
                dlEl.textContent = "Downloads appear once a server answers.";
                showEmpty("Servers are taking too long to answer. This is not a missing episode.");
              });
          }

          function prefetch(ep) {
            if (!ep || ep < 1 || ep === epNum) return;
            var k = "camanime-src:v2:" + animeId + ":" + ep + ":" + audio;
            if (inflight[k]) return;
            inflight[k] = true;
            try { if (sessionStorage.getItem(k)) return; } catch (e) {}
            fetch("/api/episode-sources/" + animeId + "/" + ep + "?audio=" + audio, { headers: { accept: "application/json" } })
              .then(function (r) { return r.ok ? r.json() : null; })
              .then(function (d) {
                if (!d || !d.servers || !d.servers.length) return;
                try {
                  sessionStorage.setItem(k, JSON.stringify({ at: Date.now(), data: {
                    servers: d.servers,
                    downloads: d.downloads || [],
                    active_server: d.active_server || null,
                    download_url: d.download_url || ""
                  }}));
                } catch (e) {}
              })
              .catch(function () {});
          }

          document.addEventListener("mouseover", function (e) {
            var el = e.target;
            while (el && el !== document) {
              if (el.tagName === "A" && el.getAttribute("href")) {
                var href = el.getAttribute("href");
                if (href.indexOf("/watch/" + animeId + "/") === 0) {
                  var n = parseInt(href.split("/").pop(), 10);
                  if (n) prefetch(n);
                }
                return;
              }
              el = el.parentNode;
            }
          }, { passive: true });

          function start() {
            var cached = readCache();
            if (cached && cached.servers && cached.servers.length) {
              renderServers(cached.servers, cached.active_server);
              renderDownloads(cached);
              note("Saved servers shown instantly — refreshing…");
              play(cached.active_server || cached.servers[0]);
            } else {
              note("Loading the fastest server…");
            }
            load();
          }

          if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
          else start();
        })();
        </script>
        <div class="transport-bar">
          <div class="now-playing-info">
            <span class="ep-pill">EPISODE ${epNum}</span>
            <div><h1 style="font-weight:700;font-size:.98rem;margin:0">${esc(name)} — ${esc(current?.title || "Episode " + epNum)}</h1>
            <div style="font-size:.78rem;color:var(--text-muted)">Cloudflare edge playback · quality follows the provider's published source</div></div>
            <span class="mode-badge">STREAM</span>
          </div>
          <div class="transport-actions">
            <a class="ctrl-btn ${epNum > 1 ? "" : "disabled"}" href="/watch/${anime.id}/${Math.max(1, epNum - 1)}">Prev Ep</a>
            <a class="ctrl-btn ${epNum < list.length ? "" : "disabled"}" id="nextEpBtn" href="/watch/${anime.id}/${Math.min(list.length, epNum + 1)}">Next Ep</a>
            <span class="ctrl-btn" style="cursor:default;gap:.35rem">
              <i class="fas fa-sliders-h"></i>
              <select id="qualitySel" aria-label="Playback quality" data-anime-id="${anime.id}" style="background:transparent;border:0;color:inherit;font:inherit;font-weight:700">
                <option value="auto">Quality: Auto</option><option value="max">Quality: Max</option><option value="low">Quality: Saver</option>
              </select>
            </span>
          </div>
        </div>
      </div>
      <aside class="episodes-rail">
        <h2 class="section-title">Episodes${pager.pages > 1 ? ` <span class="ep-pager-count">page ${pager.page} of ${pager.pages}</span>` : ""}</h2>
        <div class="ep-grid">${pager.slice.map((e) => `<a class="ep-chip ${e.n === epNum ? "current" : ""}" href="/watch/${anime.id}/${e.n}">${e.n}</a>`).join("")}</div>
        ${episodePager(pager, `/watch/${anime.id}/${epNum}`, {})}
      </aside>
    </div>
    <section id="ca-community" data-anime="${anime.id}" data-ep="${epNum}" class="ca-community">
      <h2 class="ca-community-title">Comments &amp; episode forum</h2>
      <p class="ca-community-sub">${user ? "Signed in as " + esc(user.name) + " — post below." : "Sign in to post comments and ratings."}</p>
      <div class="ca-theme-row" role="group" aria-label="Site theme">
        <span class="ca-theme-label">Theme:</span>
        ${["light","midnight","vibrant","sakura","forest","obsidian","neo","tokyo"].map((t) => `<button type="button" class="ca-theme-btn" data-theme-name="${t}">${t === "midnight" ? "Midnight" : t[0].toUpperCase() + t.slice(1)}</button>`).join("")}
      </div>
    </section>
    <script>
    (function () {
      var sel = document.getElementById('qualitySel');
      if (sel) {
        var animeId = sel.getAttribute('data-anime-id') || '';
        var kSeries = 'camanime-quality:' + animeId, kGlobal = 'camanime-quality';
        function ls(k, v) { try { if (v === undefined) return localStorage.getItem(k); localStorage.setItem(k, v); } catch (e) { return null; } }
        var pref = ls(kSeries) || ls(kGlobal) || 'auto';
        if (['auto','max','low'].indexOf(pref) === -1) pref = 'auto';
        sel.value = pref;
        sel.onchange = function () { ls(kSeries, sel.value); };
      }
      window.caTrack && window.caTrack('play', '${anime.id}', '${epNum}');
    })();
    </script>`;
  return chrome(`Watch ${name} Episode ${epNum}`, `Watch ${name} Episode ${epNum} on CamAnime.`, user?.name, inner, "browse", { bodyClass: "page-watch" });
}

export function loginPage(name) {
  const inner = `
    <div class="auth-box" style="max-width:420px;margin:4rem auto">
      <h1 class="section-title">${name ? "Welcome back, " + esc(name) : "Sign in"}</h1>
      <form id="caLogin">
        <input id="name" placeholder="Display name" autocomplete="nickname" style="width:100%;padding:.7rem;margin:.4rem 0;border-radius:12px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <input type="email" id="email" required placeholder="Email" autocomplete="email" style="width:100%;padding:.7rem;margin:.4rem 0;border-radius:12px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <input type="password" id="password" required minlength="8" placeholder="Password (8+)" autocomplete="current-password" style="width:100%;padding:.7rem;margin:.4rem 0;border-radius:12px;border:1px solid var(--border-subtle, rgba(255,255,255,.08));background:var(--bg-input,#141926);color:var(--text-primary,#f3f5fa)">
        <button class="btn-primary" type="submit" id="authBtn" style="width:100%;margin-top:.6rem">Sign in</button>
      </form>
      <p class="muted"><a href="#" id="toggleSignup">New here? Create an account</a></p>
      <div id="authOut" aria-live="polite" style="margin-top:.6rem;color:var(--text-muted)"></div>
    </div>
    <script>
    (function () {
      var $ = function (id) { return document.getElementById(id); };
      var mode = 'login';
      $('toggleSignup').onclick = function (e) {
        e.preventDefault();
        mode = mode === 'login' ? 'signup' : 'login';
        this.textContent = mode === 'login' ? 'New here? Create an account' : 'Have an account? Sign in';
        $('authBtn').textContent = mode === 'login' ? 'Sign in' : 'Create account';
        document.getElementById('name').required = mode === 'signup';
      };
      $('caLogin').onsubmit = async function (e) {
        e.preventDefault();
        var out = $('authOut');
        out.textContent = mode === 'signup' ? 'Creating account…' : 'Signing in…';
        var res = await fetch(mode === 'signup' ? '/api/auth/register' : '/api/auth/login', {
          method: 'POST', credentials: 'same-origin',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ email: $('email').value, password: $('password').value, name: $('name').value })
        });
        var data = await res.json();
        out.textContent = res.ok ? 'Success! Redirecting…' : (data.error || 'Failed.');
        if (res.ok) setTimeout(function () { location.href = '/'; }, 400);
      };
    })();
    </script>`;
  return chrome("Sign in", "Sign in to CamAnime.", null, inner, "login", { bodyClass: "page-auth" });
}

/** Privacy + account-data page. Mirrors the origin's /privacy, same facts. */
export function privacyPage() {
  const inner = `
    <article style="max-width:760px;margin:0 auto;padding:2.5rem 1.25rem 1rem">
      <p class="mono-label" style="font-family:var(--font-mono,monospace);font-size:.75rem;text-transform:uppercase;letter-spacing:.08em;color:var(--accent)">Privacy · account data</p>
      <h1>What CamAnime stores, and why</h1>
      <p>CamAnime is a free anime catalogue and player. You can browse and watch without an account. This page lists every piece of information the site keeps, where it lives, and how to have it deleted. Last updated 15 November 2026.</p>

      <h2>If you only browse</h2>
      <p>No account and no cookie is created. The server keeps ordinary request logs (IP address, user agent, path, status, time) for security, abuse prevention and rate limiting, and it counts page visits in aggregate. Those logs are not used to build a profile and are not sold or shared.</p>

      <h2>If you create an account</h2>
      <ul>
        <li><strong>Email address</strong> — your account identifier and sign-in name.</li>
        <li><strong>Display name</strong> — shown next to your comments and ratings.</li>
        <li><strong>Password</strong> — stored only as a PBKDF2-SHA256 hash with a random salt. The plain password is never stored or logged.</li>
        <li><strong>Session cookie</strong> — <code>ca_session</code>, HttpOnly and Secure, so the site knows you are signed in. Signing out clears it.</li>
      </ul>

      <h2>If you comment, rate or like</h2>
      <p>Comments (text, optional sticker, the episode they belong to, likes), ratings and your watch history are stored with your account so they can be shown back to you and to other visitors on that episode. Comments you post are public.</p>

      <h2>If you install the mobile app</h2>
      <p>The app may register a push token with your account so announcements and release notifications can reach you. Nothing else from your device is read.</p>

      <h2>Third parties</h2>
      <ul>
        <li><strong>AniList</strong> — anime titles, artwork and episode metadata.</li>
        <li><strong>Cloudflare</strong> and <strong>Render</strong> — hosting and delivery of this site; both process requests on our behalf.</li>
        <li><strong>Streaming providers</strong> — when you press play, your browser requests the video from the provider that published it, so that provider sees your IP address. CamAnime doesn't control their logging.</li>
        <li><strong>Google Fonts</strong> and <strong>cdnjs</strong> — stylesheets and icons.</li>
      </ul>
      <p>There are no advertising networks, no third-party analytics scripts and no cross-site trackers on this site. The theme and watchlist preferences you pick are kept in your browser's local storage, not on the server.</p>

      <h2>Deleting your data</h2>
      <p>Ask for deletion in the project's issue tracker — <a href="https://github.com/kayefande-droid/CamAnime/issues">github.com/kayefande-droid/CamAnime/issues</a> — from the email address on the account, and the account, its comments, ratings, watch history and push token are removed. You can also just stop using the site: signing out removes the session cookie.</p>

      <h2>Children</h2>
      <p>The site is not directed at children under 13 and no account should be created for one.</p>

      <h2>Content and terms</h2>
      <p>CamAnime indexes metadata and links to media hosted by third-party providers; it does not host video files. Playback only works when a provider lists a source for that episode, and availability can change or disappear without notice. Don't use the site to break the law, don't attempt to overload or attack it, and don't resell the developer API. Accounts that abuse the service can be removed.</p>

      <p style="margin-top:2rem"><a href="/">Back to CamAnime</a></p>
    </article>`;
  return chrome(
    "Privacy & account data",
    "What CamAnime stores when you browse, sign in, comment or rate, and how to remove it.",
    null,
    inner,
    "privacy",
    { bodyClass: "page-legal" },
  );
}

export function errorPage(status, msg) {
  const inner = `
    <div style="text-align:center;padding:4rem 1rem">
      <div style="font-size:4rem;font-weight:800;color:var(--accent, #FFB347)">${status}</div>
      <h1 style="margin:.5rem 0">${esc(msg)}</h1>
      <a class="btn-primary" href="/">Back home</a>
    </div>`;
  return chrome(String(status), "CamAnime", null, inner, "home", { bodyClass: "page-error" });
}

/** Real settings page: working theme + layout pickers (previously only described in text). */
/** Developer advert + docs + key manager. One free provider, one endpoint. */
export function developersPage(user) {
  const keyPanel = user
    ? `<form class="dev-form" id="devKeyForm">
         <input id="devKeyName" placeholder="What are you building? (optional)" maxlength="40" aria-label="Key label">
         <button class="btn-primary" type="submit">Create API key</button>
       </form>
       <div id="devKeyOut" aria-live="polite"></div>
       <div class="dev-keys" id="devKeys"><p class="muted">Loading your keys…</p></div>`
    : `<div class="discovery-empty">Sign in to create and manage your free API keys. <a href="/login">Sign in</a> — it takes a name, an email and a password.</div>`;

  const inner = `
    <header class="dev-hero">
      <span class="dev-eyebrow">Developer API · Free tier</span>
      <h1>Ship anime playback on your own site with <em>one endpoint</em>.</h1>
      <p class="dev-lede">CamAnime exposes a single streaming provider — AnimeHeaven direct MP4 — behind a key you create here. No iframe, no ads injected into your page, no card, no waiting for approval.</p>
      <div class="hero-ctas">
        <a class="btn-primary" href="${user ? "#keys" : "/login"}">${user ? "Create a free API key" : "Sign in to get a key"}</a>
        <a class="btn-secondary" href="#docs">Read the docs</a>
      </div>
    </header>

    <section class="dev-grid" aria-label="What the API gives you">
      <div class="dev-card"><h3>Direct MP4</h3><p>A real <code>video/mp4</code> URL you can set as a <code>&lt;video&gt;</code> source or hand to any player. Seeking works.</p></div>
      <div class="dev-card"><h3>One provider</h3><p>AnimeHeaven, resolved live through the same extractor this site plays with. If a title has no file, you get a 404 — never a dead link.</p></div>
      <div class="dev-card"><h3>Keyed + CORS</h3><p><code>x-api-key</code> auth, per-key daily quota, revoke anytime, and <code>access-control-allow-origin: *</code> so browser calls just work.</p></div>
      <div class="dev-card"><h3><b>1,000</b> calls / day</h3><p>Free per key, reset at 00:00 UTC. Up to <b>3</b> active keys per account. Attribution is the only price.</p></div>
    </section>

    <section id="docs">
      <h2 class="section-title">Quickstart</h2>
      <pre class="dev-code"><span class="tok-key">curl</span> -s "https://camanime.onrender.com/api/v1/stream/16498/1" \\\\
  -H "x-api-key: ca_live_your_key_here"</pre>
      <p class="muted">The same route exists on the Cloudflare deployment: <code>https://camanjme.camanime.workers.dev/api/v1/stream/16498/1</code>.</p>

      <h2 class="section-title">Endpoints</h2>
      <div class="dev-table-scroll"><table class="dev-table">
        <thead><tr><th>Method</th><th>Path</th><th>Auth</th><th>Returns</th></tr></thead>
        <tbody>
          <tr><td><code>GET</code></td><td><code>/api/v1/stream/:animeId/:ep</code></td><td><code>x-api-key</code></td><td>Stream URLs for that episode</td></tr>
          <tr><td><code>GET</code></td><td><code>/api/developer/keys</code></td><td>Session cookie</td><td>Your keys and today's usage</td></tr>
          <tr><td><code>POST</code></td><td><code>/api/developer/keys</code></td><td>Session cookie</td><td>A new key — shown once</td></tr>
          <tr><td><code>DELETE</code></td><td><code>/api/developer/keys/:id</code></td><td>Session cookie</td><td>Revokes the key</td></tr>
        </tbody>
      </table></div>

      <h2 class="section-title">Response</h2>
      <pre class="dev-code">{
  "api": "camanime-stream",
  "version": 1,
  "provider": "animeheaven",
  "anime": { "id": "16498", "title": "Attack on Titan", "episodes": 25 },
  "episode": 1,
  "audio": "sub",
  "streams": [
    { "label": "AnimeHeaven Primary", "type": "video/mp4", "quality": "Source MP4", "height": 0, "url": "https://…/api/proxy/video?url=…" }
  ],
  "usage": { "calls_today": 1, "daily_limit": 1000 },
  "attribution": "Powered by CamAnime"
}</pre>

      <h2 class="section-title">Embed it</h2>
      <pre class="dev-code">const res = await fetch("https://camanime.onrender.com/api/v1/stream/16498/1", {
  headers: { "x-api-key": "ca_live_your_key_here" }
});
const data = await res.json();
player.src = data.streams[0].url;   // &lt;video id="player" controls&gt;&lt;/video&gt;</pre>
      <p class="muted">Keep the key server-side when you can. The proxy URL is Referer-safe, so it plays from your domain without extra headers.</p>
    </section>

    <section id="keys">
      <h2 class="section-title">Your API keys</h2>
      <p class="muted">${user ? `Signed in as <strong>${esc(user.name)}</strong>. A key is shown once — copy it then, and revoke it here if it leaks.` : "Keys are tied to your CamAnime account."}</p>
      ${keyPanel}
    </section>

    <section id="limits">
      <h2 class="section-title">Free tier, in plain numbers</h2>
      <div class="dev-table-scroll"><table class="dev-table">
        <thead><tr><th>What</th><th>Free</th></tr></thead>
        <tbody>
          <tr><td>Calls per key per day</td><td><b>1,000</b></td></tr>
          <tr><td>Active keys per account</td><td><b>3</b></td></tr>
          <tr><td>Providers</td><td>1 — AnimeHeaven direct MP4</td></tr>
          <tr><td>Subtitles / dubs</td><td>Provider files as-is (sub)</td></tr>
          <tr><td>Commercial use</td><td>Ask first — the key is personal</td></tr>
        </tbody>
      </table></div>
      <p class="dev-note">CamAnime does not host these files; it resolves and proxies them from the provider the site already uses. Keep your key private, link back to CamAnime, and respect the provider's terms and your local law. Rate limits exist so one integration cannot take the shared provider offline for the site and the app.</p>
    </section>

    ${user ? `<script>
    (function () {
      var out = document.getElementById('devKeyOut');
      var list = document.getElementById('devKeys');
      var form = document.getElementById('devKeyForm');
      if (!out || !list || !form) return;
      function el(tag, cls, text) { var n = document.createElement(tag); if (cls) n.className = cls; if (text) n.textContent = text; return n; }
      function render(keys) {
        list.innerHTML = '';
        if (!keys.length) { list.appendChild(el('p', 'muted', 'No keys yet — create one above.')); return; }
        keys.forEach(function (k) {
          var row = el('div', 'dev-key-row' + (k.revoked ? ' is-revoked' : ''));
          var box = el('div', '');
          box.appendChild(el('div', 'dev-key-name', k.name || 'Untitled key'));
          box.appendChild(el('div', 'dev-key-meta', k.prefix + '… · created ' + new Date(k.created).toLocaleDateString() + ' · ' + (k.calls_today || 0) + ' calls today'));
          row.appendChild(box);
          if (!k.revoked) {
            var btn = el('button', 'ctrl-btn', 'Revoke');
            btn.type = 'button';
            btn.onclick = function () {
              if (!confirm('Revoke this key? Any site using it stops working.')) return;
              fetch('/api/developer/keys/' + k.id, { method: 'DELETE', credentials: 'same-origin' }).then(load);
            };
            row.appendChild(btn);
          } else {
            row.appendChild(el('span', 'dev-key-meta', 'revoked'));
          }
          list.appendChild(row);
        });
      }
      function load() {
        fetch('/api/developer/keys', { credentials: 'same-origin' })
          .then(function (r) { return r.ok ? r.json() : { keys: [] }; })
          .then(function (d) { render(d.keys || []); })
          .catch(function () { list.textContent = 'Could not load keys right now.'; });
      }
      form.onsubmit = function (e) {
        e.preventDefault();
        var name = document.getElementById('devKeyName').value;
        out.innerHTML = '';
        fetch('/api/developer/keys', { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ name: name }) })
          .then(function (r) { return r.json().then(function (d) { return { ok: r.ok, d: d }; }); })
          .then(function (res) {
            if (!res.ok) { out.textContent = res.d.error || 'Could not create a key.'; return; }
            var code = el('code', 'dev-key-plain', res.d.key);
            out.appendChild(code);
            out.appendChild(el('p', 'muted', res.d.note || 'Copy this key now.'));
            form.reset();
            load();
          })
          .catch(function () { out.textContent = 'Network error — try again.'; });
      };
      load();
    })();
    </script>` : ""}`;

  const shell = `<div class="dev-layout">
    <aside class="dev-rail" aria-label="On this page">
      <a href="#docs">Quickstart</a>
      <a href="#build">Build with it</a>
      <a href="/settings">Get an API key</a>
    </aside>
    <div class="dev-content">${inner}</div>
  </div>`;
  return chrome("Developer API", "Free anime streaming API for developers: one provider, direct MP4, keyed access and 1,000 calls a day.", user?.name, shell, "dev", { bodyClass: "page-developers", styles: ["/static/css/page-developers.css?v=20261122-render"] });
}

export function settingsPage(user) {
  return renderSettings(user, chrome, esc);
}

/**
 * Download page. Same sections, classes and copy as `templates/download.html`
 * on the Render origin, so the shared stylesheets render both hosts the same
 * way; only the figures come from this deployment's own R2 bucket.
 */
export function downloadPage({ userName, user, version, build, sizeLabel, archive = [], extras = [], origin }) {
  const here = String(origin || "").replace(/\/+$/, "");
  const copyBlock = (id, label, value, ariaLabel) => `
      <div class="dl-copy">
        <label for="${id}">${esc(label)}</label>
        <div class="copy-row"><input id="${id}" type="text" readonly value="${esc(value)}" aria-label="${esc(ariaLabel)}"><button type="button" id="copy-${id}" aria-describedby="copy-${id}-status">Copy link</button></div>
        <div id="copy-${id}-status" class="copy-status" role="status" aria-live="polite"></div>
      </div>`;

  const inner = `
  <section class="dl-hero">
    <div class="dl-hero-copy">
      <h1>Download the CamAnime app</h1>
      <p class="dl-lede">Same account, watchlist and resume points as the website, with downloads that play offline. Files only leave the app when you tap Save to device.</p>
      <div class="dl-actions">
        <a class="btn-primary" href="/get/android" download><i class="fas fa-mobile-alt" aria-hidden="true"></i> Install for Android</a>
        <a class="dl-secondary" href="/get/windows" download><i class="fas fa-laptop" aria-hidden="true"></i> Windows build</a>
      </div>
    </div>
    <dl class="dl-facts">
      <div><dt>Version</dt><dd>CamAnime ${esc(version)} (build ${esc(build)})</dd></div>
      <div><dt>Android file</dt><dd>${esc(sizeLabel)}</dd></div>
      <div><dt>Account</dt><dd>One sign-in for the site and the app</dd></div>
    </dl>
  </section>

  <section class="dl-platforms" aria-label="Available apps">
    <article class="dl-platform">
      <header class="dl-platform-head"><h2>Android</h2><span class="dl-tag">APK</span></header>
      <p class="dl-platform-note">The app checks for a new release on launch and hands it to Android's installer.</p>
      <a class="btn-primary" href="/get/android" download>Install App</a>
      <a class="dl-link" href="/get/android" download>Direct link: CamAnime.apk</a>
      ${copyBlock("android-download-url", "Copyable download URL", `${here}/get/android`, "Direct CamAnime Android APK URL on this site")}
      ${copyBlock("render-download-url", "Render-hosted APK URL", "https://camanime.onrender.com/get/android", "CamAnime Android APK URL on the Render site")}
    </article>

    <article class="dl-platform">
      <header class="dl-platform-head"><h2>Windows</h2><span class="dl-tag">.NET</span></header>
      <p class="dl-platform-note">Windows builds ship with every release from the main site.</p>
      <a class="btn-primary" href="/get/windows" download>Install App</a>
      <a class="dl-link" href="/get/windows" download>Direct link: CamAnime-Windows.zip</a>
    </article>
  </section>

  <section class="dl-build" id="build">
    <h2>Build it yourself</h2>
    <ol class="dl-steps">
      <li><strong>Automatic updates.</strong> The app checks this site on launch, downloads the new release and hands it to Android's installer. Library, downloads and watch history are preserved.</li>
      <li><strong>Android.</strong> Install Flutter, then <code>cd mobile/camanime_app &amp;&amp; flutter pub get &amp;&amp; flutter build apk --release</code>. The APK lands in <code>build/app/outputs/flutter-apk/app-release.apk</code>.</li>
      <li><strong>Windows.</strong> Install the .NET 8 SDK, then <code>cd windows/CamAnime.Windows &amp;&amp; dotnet publish -c Release -r win-x64 --self-contained</code>.</li>
      <li>Point the app at your site URL and sign in with your website account. One shared user database.</li>
    </ol>
  </section>
  ${archive.length ? `
  <section class="dl-build" aria-label="Previous Android builds">
    <h2>Previous Android builds</h2>
    <p class="dl-platform-note">Older CamAnime builds stay downloadable here. Every build from 2.9.0 (build 19) up still streams and downloads from the same servers; the app only asks you to update below that floor.</p>
    <ul class="dl-steps">${archive.map((f) => {
      const m = /CamAnime-([\d.]+)-build(\d+)\.apk$/i.exec(f.name);
      const label = m ? `CamAnime ${m[1]} (build ${m[2]})` : f.name.replace(/^archive\//, "");
      return `<li><a href="${esc(f.url)}" download>${esc(label)}</a> — ${(f.size / 1024 / 1024).toFixed(1)} MB</li>`;
    }).join("")}</ul>
  </section>` : ""}
  ${extras.length ? `
  <section class="dl-build" aria-label="Other files">
    <h2>Other files</h2>
    <ul class="dl-steps">${extras.map((f) => `<li><a href="${esc(f.url)}" download>${esc(f.name)}</a> — ${(f.size / 1024 / 1024).toFixed(1)} MB</li>`).join("")}</ul>
  </section>` : ""}
  ${user?.role === "admin" ? `
  <section class="dl-build" aria-label="Admin upload">
    <h2>Admin upload</h2>
    <form id="upForm" enctype="multipart/form-data">
      <input type="file" name="file" required>
      <button class="btn-primary" type="submit">Upload</button>
    </form>
  </section>
  <script>
  document.getElementById('upForm').onsubmit = async function (e) {
    e.preventDefault();
    var fd = new FormData(this);
    var res = await fetch('/api/admin/upload', { method: 'POST', body: fd, credentials: 'same-origin' });
    if (res.ok) location.reload(); else alert((await res.json()).error || 'Upload failed');
  };
  </script>` : ""}
  <script>
  (() => {
    ["android-download-url", "render-download-url"].forEach((id) => {
      const field = document.getElementById(id);
      const button = document.getElementById("copy-" + id);
      const status = document.getElementById("copy-" + id + "-status");
      if (!field || !button || !status) return;
      button.addEventListener("click", async () => {
        try {
          await navigator.clipboard.writeText(field.value);
          status.textContent = "Download link copied.";
        } catch (_) {
          field.focus();
          field.select();
          field.setSelectionRange(0, field.value.length);
          const copied = document.execCommand("copy");
          status.textContent = copied ? "Download link copied." : "Select and copy the link above.";
        }
      });
    });
  })();
  </script>`;

  return chrome(
    "Download the CamAnime app",
    "Install the CamAnime Android app, or build it yourself from source.",
    userName,
    inner,
    "download",
    { bodyClass: "page-apps", mainClass: "main-wrap dl-main" },
  );
}
