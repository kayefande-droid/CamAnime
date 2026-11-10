/** CamAnime edge pages: same branding/classes as the Render site, Jinja-free HTML builders. */
import { esc, BRAND } from "./util.js";
import { card } from "./catalog.js";

const THEME_GUARD = `<script>try{var t=localStorage.getItem('camanime-theme');if(['midnight','light','vibrant','sakura','forest','obsidian','neo','tokyo'].indexOf(t)===-1)t='midnight';document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>`;
const LAYOUT_GUARD = `<script>try{var l=localStorage.getItem('camanime-layout');if(['classic','cinema','compact','minimal','wide','magazine','wall'].indexOf(l)===-1)l='classic';document.documentElement.setAttribute('data-layout',l);}catch(e){}</script>`;

function head(title, desc) {
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
<meta property="og:image" content="__CA_ORIGIN__/static/icon-512.png">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)} | ${BRAND}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="__CA_ORIGIN__/static/icon-512.png">
<link rel="icon" href="/static/brand/camanime-icon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@600;700;800&family=Outfit:wght@400;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/static/css/base.css?v=20261111-tokens">
<link rel="stylesheet" href="/static/css/sync.css?v=20261111-tokens">
<link rel="stylesheet" href="/static/css/header-layout.css?v=20261111-tokens">
<link rel="stylesheet" href="/static/css/redesign.css?v=20261111-v13">
<link href="/static/css/motion.css?v=20261111-motion3" rel="stylesheet">
<script src="/static/js/site.js?v=20261106-flow" defer></script>
<script src="/static/js/motion.js?v=20261111-motion3" defer></script>
<script src="/static/js/release-schedule.js?v=20261019-tabprefs" defer></script>
${THEME_GUARD}
${LAYOUT_GUARD}
</head><body>`;
}

export function chrome(title, desc, userName, inner, active = "home") {
  return `${head(title, desc)}
<a class="skip-link" href="#main-content">Skip to content</a>
<header>
  <div class="header-inner">
    <div class="brand-group">
      <a class="site-logo" href="/">Cam<span style="color:var(--accent, #FFB347)">Anime</span></a>
      <nav class="nav-links">
        <a class="nav-link ${active === "home" ? "active" : ""}" href="/">Home</a>
        <a class="nav-link ${active === "library" ? "active" : ""}" href="/library">My Library</a>
        <a class="nav-link ${active === "download" ? "active" : ""}" href="/download">Downloads</a>
        <a class="nav-link ${active === "settings" ? "active" : ""}" href="/settings">Settings</a>
        <a class="nav-link ${active === "dev" ? "active" : ""}" href="/developers">Developers</a>
        ${userName ? `<a class="nav-link" href="/settings">Account (${esc(userName)})</a>` : `<a class="nav-link" href="/login">Sign in</a>`}
      </nav>
    </div>
    <button type="button" class="nav-toggle" id="navToggle" aria-expanded="false" aria-controls="mobileNav" aria-label="Open menu" onclick="toggleMobileNav()"><i class="fas fa-bars" aria-hidden="true"></i></button>
  </div>
  <nav class="mobile-nav" id="mobileNav" aria-label="Menu">
    <a href="/">Home</a>
    <a href="/library">My Library</a>
    <a href="/download">Downloads</a>
    <a href="/settings">Settings</a>
    <a href="/developers">Developers API</a>
    ${userName ? `<a href="/settings">Account (${esc(userName)})</a>` : `<a href="/login">Sign in</a>`}
  </nav>
</header>
<main class="main-wrap" id="main-content" tabindex="-1">
${inner}
</main>
<footer style="text-align:center;color:var(--text-muted,#64708a);padding:2rem 1rem;border-top:1px solid var(--border-subtle, rgba(255,255,255,.08))">
  <p>CamAnime — watch anime free. Independent Cloudflare deployment (camanjme); not affiliated with the Render origin.</p>
</footer>
<script>
function toggleMobileNav(force) {
  var nav = document.getElementById('mobileNav'), btn = document.getElementById('navToggle');
  if (!nav || !btn) return;
  var open = force !== undefined ? force : !nav.classList.contains('open');
  nav.classList.toggle('open', open);
  btn.setAttribute('aria-expanded', String(open));
  btn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
}
document.addEventListener('keydown', function (e) { if (e.key === 'Escape') toggleMobileNav(false); });
</script>
</body></html>`;
}

export function homePage(grids, userName) {
  const section = (title, items) => `
    <section>
      <h2 class="section-title">${esc(title)}</h2>
      <div class="anime-grid">${items.map(card).join("")}</div>
    </section>`;
  const inner = `
    <section class="hero">
      <div class="hero-inner">
        <h1 class="hero-title">Stream anime free.<br>No ads. ${userName ? "Welcome back, " + esc(userName) + "." : "No sign-up wall."}</h1>
        <p class="hero-sub">Trending, airing and movie picks — synced to the AniList catalogue with the full CamAnime theme system (8 themes, data saver, quality control).</p>
        <div class="hero-ctas">
          <a class="btn-primary" href="#trending">Start watching</a>
          <a class="btn-secondary" href="/settings">Site settings</a>
        </div>
      </div>
    </section>
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
    <section id="trending">${section("Trending now", grids.trending)}</section>
    ${section("Airing this season", grids.airing)}
    ${section("Popular movies", grids.movies)}
  `;
  return chrome("Watch anime free", "CamAnime on Cloudflare: trending anime, search, watch pages and the community forum.", userName, inner);
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

export function detailsPage(anime, ratingSummary, user) {
  const name = anime.title.english || anime.title.romaji;
  const inner = `
    <section class="anime-hero" style="display:flex;gap:1.5rem;flex-wrap:wrap">
      <img src="${esc(anime.coverImage?.extraLarge || anime.coverImage?.large || "")}" alt="${esc(name)} poster" style="border-radius:16px;max-width:280px">
      <div style="flex:1;min-width:280px">
        <h1 class="hero-title">${esc(name)}</h1>
        <p>${anime.title.native ? esc(anime.title.native) : ""} ${anime.format ? "· " + esc(anime.format) : ""} ${anime.status ? "· " + esc(anime.status) : ""} ${anime.seasonYear ? "· " + anime.seasonYear : ""}</p>
        <p class="muted">${anime.averageScore ? `AniList score ${anime.averageScore}% · ` : ""}${(anime.genres || []).join(", ") || ""}</p>
        ${anime.nextAiringEpisode ? `<p class="muted">Next episode airs in <strong>${Math.max(0, Math.ceil((anime.nextAiringEpisode.airingAt - Math.floor(Date.now() / 1000)) / 60))} min</strong> (EP ${anime.nextAiringEpisode.episode})</p>` : ""}
        <div id="ca-rating-out">${ratingSummary.average ? `Community score: <strong>${ratingSummary.average}/10</strong> (${ratingSummary.count} ratings)` : "No community ratings yet."}</div>
        <div class="hero-ctas">
          <a class="btn-primary" href="/watch/${anime.id}/1">Watch Episode 1</a>
        </div>
      </div>
    </section>
    <section><h2 class="section-title">Synopsis</h2><p class="ca-sub">${esc(String(anime.description || "").replace(/<[^>]*>/g, ""))}</p></section>
    <section><h2 class="section-title">Episodes</h2>
      ${(anime.streamingEpisodes || []).length
        ? `<div class="mini-grid">${anime.streamingEpisodes.map((se, i) => `
            <a class="anime-card" href="/watch/${anime.id}/${i + 1}">
              <span class="card-poster-wrap"><img src="${esc(se.thumbnail || anime.coverImage?.large || "")}" alt="Episode ${i + 1}" loading="lazy"></span>
              <span class="card-title">${esc(se.title || "Episode " + (i + 1))}</span><span class="card-format">EP ${i + 1}</span>
            </a>`).join("")}</div>`
        : `<p class="discovery-empty">No per-episode stream data on AniList for this title — main catalogue episodes: ${anime.episodes ?? "?"}.</p>`}
    </section>`;
  return chrome(name, `Watch ${name} on CamAnime — episodes, ratings, community.`, user?.name, inner, "browse");
}

export function watchPage(ctx, user) {
  const { anime, episodes, current, epNum } = ctx;
  const name = anime.title.english || anime.title.romaji || "Episode";
  const list = (episodes.length ? episodes : Array.from({ length: anime.episodes || 0 }, (_, i) => ({ n: i + 1, title: "Episode " + (i + 1), url: null })));
  const inner = `
    <div class="watch-container">
      <div class="player-column">
        <div class="video-stage" id="videoStage">
          ${current?.url
            ? `<iframe id="embedIframe" src="${esc(current.url)}" allowfullscreen allow="autoplay; encrypted-media; picture-in-picture" style="width:100%;aspect-ratio:16/9;border:0;border-radius:14px"></iframe>`
            : `<div class="discovery-empty" style="padding:2rem">No stream listing for this episode through AniList yet.</div>`}
        </div>
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
        <h2 class="section-title">Episodes</h2>
        <div class="ep-grid">${list.map((e) => `<a class="ep-chip ${e.n === epNum ? "current" : ""}" href="/watch/${anime.id}/${e.n}">${e.n}</a>`).join("")}</div>
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
  return chrome(`Watch ${name} Episode ${epNum}`, `Watch ${name} Episode ${epNum} on CamAnime.`, user?.name, inner, "browse");
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
  return chrome("Sign in", "Sign in to CamAnime.", null, inner, "login");
}

export function errorPage(status, msg) {
  const inner = `
    <div style="text-align:center;padding:4rem 1rem">
      <div style="font-size:4rem;font-weight:800;color:var(--accent, #FFB347)">${status}</div>
      <h1 style="margin:.5rem 0">${esc(msg)}</h1>
      <a class="btn-primary" href="/">Back home</a>
    </div>`;
  return chrome(String(status), "CamAnime", null, inner);
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

  return chrome("Developer API", "Free anime streaming API for developers: one provider, direct MP4, keyed access and 1,000 calls a day.", user?.name, inner, "dev");
}

export function settingsPage(user) {
  const THEMES = ["midnight", "light", "vibrant", "sakura", "forest", "obsidian", "neo", "tokyo"];
  const LAYOUTS = ["classic", "cinema", "compact", "minimal", "wide", "magazine", "wall"];
  const themeRow = THEMES.map((t) => `<button type="button" class="ca-theme-btn" data-theme-name="${t}">${t === "midnight" ? "Midnight" : t[0].toUpperCase() + t.slice(1)}</button>`).join("");
  const layoutRow = LAYOUTS.map((l) => `<button type="button" class="ca-theme-btn" data-layout-name="${l}">${l[0].toUpperCase() + l.slice(1)}</button>`).join("");
  const account = user
    ? `<div class="panel-box"><h2 class="section-title">Account</h2><p>Signed in as <strong>${esc(user.name)}</strong> (${esc(user.email)}).</p><form onsubmit='fetch("/api/auth/logout",{method:"POST",credentials:"same-origin"}).then(function(){location.href="/"})'><button class="btn-danger" type="submit">Sign out</button></form></div>`
    : `<div class="panel-box"><h2 class="section-title">Account</h2><p><a href="/login">Sign in</a> to save comments, ratings and resume points on this deployment.</p></div>`;
  const inner = `
    <h1 class="section-title">Site settings</h1>
    <div class="panel-box" style="margin-bottom:1rem">
      <h2 class="section-title">Theme</h2>
      <p class="muted">Eight themes, applied instantly and remembered on this device.</p>
      <div class="ca-theme-row" role="group" aria-label="Site theme">${themeRow}</div>
    </div>
    <div class="panel-box" style="margin-bottom:1rem">
      <h2 class="section-title">Layout template</h2>
      <p class="muted">Seven complete layout recipes — grid shape, poster style, hero scale and spacing reflow across every page.</p>
      <div class="ca-theme-row" role="group" aria-label="Layout template">${layoutRow}</div>
      <p class="muted" id="layoutNote"></p>
    </div>
    ${account}
    <script>
    document.addEventListener('DOMContentLoaded', function () {
      var root = document.documentElement;
      var LABELS = { classic: 'Classic — the original layout.', cinema: 'Cinema — big posters, wide stage.', compact: 'Compact — dense grid, landscape posters.', minimal: 'Minimal — flat editorial.', wide: 'Wide — full-bleed for large screens.', magazine: 'Magazine — editorial column.', wall: 'Poster Wall — dense poster grid.' };
      function ls(k) { try { return localStorage.getItem(k); } catch (e) { return null; } }
      var themes = ['midnight','light','vibrant','sakura','forest','obsidian','neo','tokyo'];
      var layouts = ['classic','cinema','compact','minimal','wide','magazine','wall'];
      var themeBtns = document.querySelectorAll('[data-theme-name]');
      var layoutBtns = document.querySelectorAll('[data-layout-name]');
      var note = document.getElementById('layoutNote');
      var t = ls('camanime-theme') || 'midnight'; if (themes.indexOf(t) === -1) t = 'midnight';
      var l = ls('camanime-layout') || 'classic'; if (layouts.indexOf(l) === -1) l = 'classic';
      function paint(nodes, attr, cur) {
        for (var i = 0; i < nodes.length; i++) { nodes[i].classList.toggle('active', nodes[i].getAttribute(attr) === cur); }
      }
      function setTheme(name) {
        if (window.caSetTheme) window.caSetTheme(name);
        else { root.setAttribute('data-theme', name); try { localStorage.setItem('camanime-theme', name); } catch (e) {} }
        paint(themeBtns, 'data-theme-name', name);
      }
      function setLayout(name) {
        if (window.caSetLayout) window.caSetLayout(name);
        else { root.setAttribute('data-layout', name); try { localStorage.setItem('camanime-layout', name); } catch (e) {} }
        paint(layoutBtns, 'data-layout-name', name);
        if (note) note.textContent = LABELS[name] || '';
      }
      paint(themeBtns, 'data-theme-name', t);
      paint(layoutBtns, 'data-layout-name', l);
      if (note) note.textContent = LABELS[l] || '';
      for (var i = 0; i < themeBtns.length; i++) {
        (function (btn) { btn.onclick = function () { setTheme(btn.getAttribute('data-theme-name')); }; })(themeBtns[i]);
      }
      for (var j = 0; j < layoutBtns.length; j++) {
        (function (btn) { btn.onclick = function () { setLayout(btn.getAttribute('data-layout-name')); }; })(layoutBtns[j]);
      }
    });
    </script>`;
  return chrome("Settings", "CamAnime settings: themes, layouts and account.", user?.name, inner, "settings");
}
