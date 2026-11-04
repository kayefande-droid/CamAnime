/** CamAnime edge pages: same branding/classes as the Render site, Jinja-free HTML builders. */
import { esc, BRAND } from "./util.js";
import { card } from "./catalog.js";

const THEME_GUARD = `<script>try{var t=localStorage.getItem('camanime-theme');if(['midnight','light','vibrant','sakura','forest','obsidian','neo','tokyo'].indexOf(t)===-1)t='midnight';document.documentElement.setAttribute('data-theme',t);}catch(e){}</script>`;

function head(title, desc) {
  return `<!DOCTYPE html>
<html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(title)} | ${BRAND}</title>
<meta name="description" content="${esc(desc)}">
<meta name="robots" content="index, follow, max-image-preview:large">
<meta name="theme-color" content="#087BFF">
<link rel="icon" href="/static/brand/camanime-icon.svg" type="image/svg+xml">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=Sora:wght@600;700;800&family=Outfit:wght@400;600;700&display=swap" rel="stylesheet">
<link rel="stylesheet" href="/static/css/sync.css?v=20261104-themes">
<script src="/static/js/site.js?v=20261104" defer></script>
${THEME_GUARD}
</head><body>`;
}

export function chrome(title, desc, userName, inner, active = "home") {
  return `${head(title, desc)}
<a class="skip-link" href="#main-content">Skip to content</a>
<header>
  <div class="nav-inner">
    <a class="site-logo" href="/">Cam<span style="color:var(--accent, #FFB347)">Anime</span></a>
    <nav class="nav-links">
      <a class="nav-link ${active === "home" ? "active" : ""}" href="/">Home</a>
      <a class="nav-link ${active === "library" ? "active" : ""}" href="/library">My Library</a>
      <a class="nav-link ${active === "download" ? "active" : ""}" href="/download">Downloads</a>
      ${userName ? `<a class="nav-link" href="/settings">Account (${esc(userName)})</a>` : `<a class="nav-link" href="/login">Sign in</a>`}
    </nav>
  </div>
</header>
<main id="main-content" tabindex="-1" style="max-width:1180px;margin:0 auto;padding:1.4rem 1rem 3rem">
${inner}
</main>
<footer style="text-align:center;color:var(--text-muted,#64708a);padding:2rem 1rem;border-top:1px solid var(--border-subtle, rgba(255,255,255,.08))">
  <p>CamAnime — watch anime free. Independent Cloudflare deployment (camanjme); not affiliated with the Render origin.</p>
</footer>
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
            <div style="font-size:.78rem;color:var(--text-muted)">Cloudflare edge playback · quality auto-scales to your link</div></div>
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
