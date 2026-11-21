/**
 * Render-identical page shells for the Cloudflare deployment.
 *
 * The markup below is the DOM the Render templates emit (same classes, same
 * ids, same order), so `static/css/page-watch.css` and
 * `static/css/page-details.css` — extracted verbatim from those templates —
 * compute the same layout, colours and motion on both hosts.
 *
 * Only the data is filled in from this deployment's catalogue and provider
 * resolver. Nothing here invents a stream, quality or dub.
 */
import { head } from "./pages.js";
import { esc, BRAND } from "./util.js";

const CSS_VERSION = "20261122-render";

/** Slice a rail into pages of 48, opening on the page holding `focus`. */
function pagerOf(items, requested, focus, size = 48) {
  const total = items.length;
  const pages = Math.max(1, Math.ceil(total / size));
  let page = Number.parseInt(requested || "", 10);
  if (!Number.isFinite(page) || page < 1) {
    const at = focus == null ? -1 : items.findIndex((entry) => entry.n === focus);
    page = at >= 0 ? Math.floor(at / size) + 1 : 1;
  }
  page = Math.min(Math.max(page, 1), pages);
  const start = (page - 1) * size;
  return {
    total,
    page,
    pages,
    start: total ? start + 1 : 0,
    end: Math.min(start + size, total),
    slice: items.slice(start, start + size),
  };
}

/** Prev/numbers/next pager with the site's own classes. */
function pagerHtml(pager, basePath, params = {}) {
  if (pager.pages <= 1) return "";
  const href = (page) => {
    const search = new URLSearchParams(params);
    search.set("eps", String(page));
    return esc(`${basePath}?${search.toString()}`);
  };
  const wanted = new Set([1, pager.pages]);
  for (let n = Math.max(1, pager.page - 2); n <= Math.min(pager.pages, pager.page + 2); n += 1) wanted.add(n);
  const numbers = [];
  let previous = 0;
  for (const n of [...wanted].sort((a, b) => a - b)) {
    if (previous && n - previous > 1) numbers.push(`<span class="ep-pager-gap" aria-hidden="true">…</span>`);
    numbers.push(n === pager.page
      ? `<span class="ep-pager-btn current" aria-current="page">${n}</span>`
      : `<a class="ep-pager-btn" href="${href(n)}" aria-label="Episode page ${n}">${n}</a>`);
    previous = n;
  }
  const prev = pager.page > 1 ? `<a class="ep-pager-btn" rel="prev" href="${href(pager.page - 1)}">Prev</a>` : "";
  const next = pager.page < pager.pages ? `<a class="ep-pager-btn" rel="next" href="${href(pager.page + 1)}">Next</a>` : "";
  return `<nav class="ep-pager" aria-label="Episode pages">
      <span class="ep-pager-range">Episodes ${pager.start}–${pager.end} of ${pager.total}</span>
      <div class="ep-pager-links">${prev}${numbers.join("")}${next}</div>
    </nav>`;
}

/** Render's slim watch header: logo, breadcrumb back to the title, tools. */
function watchHeader(anime, epNum, name) {
  return `<header>
    <div class="header-inner">
        <div style="display:flex;align-items:center;gap:1.5rem;">
            <a href="/" class="site-logo" aria-label="CamAnime — Watch, discover, enjoy">
                <img src="/static/brand/camanime-logo.svg" alt="CamAnime — Watch • Discover • Enjoy" fetchpriority="high">
            </a>
            <div class="breadcrumb-bar">
                <a href="/anime/${anime.id}"><i class="fas fa-arrow-left"></i> ${esc(name)}</a>
                <span>/</span>
                <strong style="color: var(--accent);">Episode ${epNum}</strong>
            </div>
        </div>
        <div style="display:flex;gap:0.65rem;flex-wrap:wrap;">
            <a href="/scraper" class="ctrl-btn" style="border-color:rgba(16,185,129,0.4);color:#34d399;">
                <i class="fas fa-bolt"></i> AnimeHeaven Engine
            </a>
            <a href="/anime/${anime.id}" class="ctrl-btn"><i class="fas fa-info-circle"></i> Anime Details</a>
            <a href="/download" class="ctrl-btn"><i class="fas fa-mobile-alt"></i> Apps</a>
        </div>
    </div>
</header>`;
}

/** Render's slim details header: logo, back to browse, scraper, apps. */
function detailsHeader() {
  return `<header>
    <div class="header-inner">
        <a href="/" class="site-logo" aria-label="CamAnime — Watch, discover, enjoy">
            <img src="/static/brand/camanime-logo.svg" alt="CamAnime — Watch • Discover • Enjoy" fetchpriority="high">
        </a>
        <div class="header-nav">
            <a href="/" class="nav-pill"><i class="fas fa-arrow-left"></i> Back to Browse</a>
            <a href="/scraper" class="nav-pill" style="border-color: rgba(16,185,129,0.4); color: #34d399;">
                <i class="fas fa-bolt"></i> AnimeHeaven Scraper
            </a>
            <a href="/download" class="nav-pill"><i class="fas fa-mobile-alt"></i> Apps</a>
        </div>
    </div>
</header>`;
}

export function watchPage(ctx, user) {
  const { anime, episodes, current, epNum } = ctx;
  const name = anime.title?.english || anime.title?.romaji || "Anime";
  const list = episodes.length
    ? episodes
    : Array.from({ length: anime.episodes || 0 }, (_, i) => ({ n: i + 1, title: "Episode " + (i + 1), url: null }));
  const pager = pagerOf(list, ctx.eps, epNum);
  const audio = ctx.audio === "dub" ? "dub" : "sub";
  const epTitle = current?.title || `Episode ${epNum}`;
  const poster = anime.bannerImage || anime.coverImage?.extraLarge || anime.coverImage?.large || "/static/brand/camanime-icon.svg";
  const nextEp = epNum < list.length ? epNum + 1 : null;
  const prevEp = epNum > 1 ? epNum - 1 : null;
  const title = `Watch ${name} Episode ${epNum}`;
  const desc = `Watch ${name} Episode ${epNum} on CamAnime — provider servers, subtitle and dub tracks, direct downloads.`;

  const inner = `
<a class="skip-link" href="#videoStage">Skip to video player</a>
${watchHeader(anime, epNum, name)}

<div class="watch-container" id="main-content" tabindex="-1">
    <div class="cinema-grid">
        <div class="player-column">
            <div class="video-stage" id="videoStage">
                <div class="ca-player" id="caPlayer">
                    <img class="ca-poster" src="${esc(poster)}" alt="" aria-hidden="true" decoding="async" referrerpolicy="no-referrer" onerror="this.onerror=null;this.src='/static/brand/camanime-icon.svg'">
                    <video id="nativeVideo" controls playsinline preload="auto" crossorigin="anonymous" style="display: none;"></video>
                    <div class="ca-shade" aria-hidden="true"></div>
                    <p class="ca-resume-note" id="caResumeNote" role="status" hidden></p>
                    <button type="button" class="ca-big-play" aria-label="Play"><i class="fas fa-play" aria-hidden="true"></i></button>
                    <div class="ca-loading" aria-hidden="true"><div class="ca-spinner"></div></div>
                    <div class="ca-controls">
                        <div class="ca-progress" role="slider" tabindex="0" aria-label="Seek" aria-valuemin="0" aria-valuemax="100" aria-valuenow="0">
                            <div class="ca-progress-track">
                                <div class="ca-buffered"></div>
                                <div class="ca-played"></div>
                            </div>
                            <div class="ca-scrub"></div>
                        </div>
                        <div class="ca-bar">
                            <button type="button" class="ca-btn" data-ca="play" aria-label="Play"><i class="fas fa-play" aria-hidden="true"></i></button>
                            <span class="ca-time"><span class="ca-current">0:00</span> / <span class="ca-duration">0:00</span></span>
                            <span class="ca-spacer"></span>
                            <button type="button" class="ca-btn" data-ca="cc" aria-label="Subtitles" aria-pressed="false" style="display:none"><i class="fas fa-closed-captioning" aria-hidden="true"></i></button>
                            <div class="ca-volume">
                                <button type="button" class="ca-btn" data-ca="mute" aria-label="Mute"><i class="fas fa-volume-up" aria-hidden="true"></i></button>
                                <input id="caVol" type="range" min="0" max="1" step="0.05" value="1" aria-label="Volume">
                            </div>
                            <select id="caSpeed" class="ca-select" aria-label="Playback speed">
                                <option value="0.5">0.5×</option><option value="0.75">0.75×</option>
                                <option value="1" selected>1×</option><option value="1.25">1.25×</option>
                                <option value="1.5">1.5×</option><option value="2">2×</option>
                            </select>
                            <button type="button" class="ca-btn" data-ca="pip" aria-label="Picture in picture"><i class="fas fa-clone" aria-hidden="true"></i></button>
                            <button type="button" class="ca-btn" data-ca="full" aria-label="Fullscreen"><i class="fas fa-expand" aria-hidden="true"></i></button>
                        </div>
                    </div>
                    <div class="ca-error" role="alert">
                        <span class="ca-error-text">Playback failed.</span>
                        <button type="button" class="ca-btn" data-ca="retry">Retry</button>
                    </div>
                </div>
                <iframe id="embedIframe" title="Episode player" allowfullscreen allow="autoplay; encrypted-media; picture-in-picture" style="display: none;"></iframe>
                <button type="button" id="skipIntroBtn" class="skip-intro-btn" style="display:none"><i class="fas fa-forward"></i> Skip Intro</button>
                <div id="playerError" style="display:none;position:absolute;left:12px;right:12px;bottom:12px;z-index:40;background:rgba(7,8,13,.92);border:1px solid rgba(248,113,113,.55);color:#fecaca;font-size:.82rem;border-radius:10px;padding:.6rem .8rem;"></div>
            </div>

            <div class="transport-bar">
                <div class="now-playing-info">
                    <span class="ep-pill">EPISODE ${Number(epNum) || 1}</span>
                    <div>
                        <h1 style="font-weight: 700; font-size: 0.98rem; margin: 0;">${esc(name)} — ${esc(epTitle)}</h1>
                        <div style="font-size: 0.78rem; color: var(--text-secondary);" id="activeServerStatus">Loading the fastest server…</div>
                    </div>
                    <span class="mode-badge" id="playbackBadge">STREAM</span>
                </div>
                <div class="transport-actions">
                    ${prevEp
                      ? `<a href="/watch/${anime.id}/${prevEp}?audio=${audio}" class="ctrl-btn"><i class="fas fa-step-backward"></i> Prev Ep</a>`
                      : `<a href="#" class="ctrl-btn disabled" aria-disabled="true"><i class="fas fa-step-backward"></i> Prev Ep</a>`}
                    ${nextEp
                      ? `<a id="nextEpBtn" href="/watch/${anime.id}/${nextEp}?audio=${audio}" class="ctrl-btn">Next Ep <i class="fas fa-step-forward"></i></a>`
                      : `<a id="nextEpBtn" href="#" class="ctrl-btn disabled" aria-disabled="true">Next Ep <i class="fas fa-step-forward"></i></a>`}
                    <span class="ctrl-btn" style="cursor:default;gap:.35rem" title="HLS adapts inside the provider's published renditions; MP4 plays at its published resolution">
                        <i class="fas fa-sliders-h"></i>
                        <select id="qualitySel" aria-label="Playback quality" data-anime-id="${anime.id}" style="background:transparent;border:0;color:inherit;font:inherit;font-weight:700;cursor:pointer">
                            <option value="auto">Quality: Auto</option><option value="max">Quality: Max</option><option value="low">Quality: Saver</option>
                        </select>
                    </span>
                    <button type="button" class="ctrl-btn" id="focusBtn"><i class="fas fa-lightbulb"></i> Focus Mode</button>
                    <a id="downloadCurrentBtn" class="ctrl-btn download-cta" href="#" download><i class="fas fa-download"></i> Download Playing Ep</a>
                    <button type="button" class="ctrl-btn" id="allFilesBtn"><i class="fas fa-list"></i> All Files</button>
                </div>
            </div>

            <div class="server-deck" id="serverDeck" aria-live="polite" aria-busy="true">
                <div class="server-row">
                    <span class="server-row-label"><i class="fas fa-closed-captioning" style="color:var(--accent);"></i> English subtitles</span>
                    <span class="ctrl-btn" style="opacity:.55;cursor:default">Loading servers…</span>
                </div>
                <div class="server-row" id="dubServerRow" hidden>
                    <span class="server-row-label"><i class="fas fa-headphones" style="color:var(--accent);"></i> Provider-listed English dub</span>
                </div>
                <p role="note" style="color:var(--text-secondary);font-size:.8rem;margin:.6rem 0 0;">Quality and dub availability are read from the provider for this exact episode. Choices the source does not publish are never shown or invented.</p>
            </div>
        </div>

        <aside class="episode-sidebar">
            <div class="sidebar-head">
                <span class="sidebar-title">Released episodes (${pager.total})</span>
                <span style="font-size:0.75rem;color:var(--text-secondary);font-family:'JetBrains Mono',monospace;">English ${audio.toUpperCase()}</span>
            </div>
            <input type="text" class="ep-search-box" id="epRailFilter" placeholder="Filter episode number..." aria-label="Filter episode number">
            <div class="ep-rail-list" id="epRailList">
                ${pager.slice.map((e) => `<a href="/watch/${anime.id}/${e.n}?audio=${audio}" class="ep-rail-item${e.n === epNum ? " current" : ""}" data-ep="${e.n}">${e.n}</a>`).join("")}
            </div>
            ${pagerHtml(pager, `/watch/${anime.id}/${epNum}`, { audio })}
        </aside>
    </div>

    <div class="lower-panels">
        <div class="panel-box" id="downloadPanel">
            <div class="panel-box-title"><i class="fas fa-cloud-download-alt" style="color: var(--emerald);"></i> Direct Episode ${Number(epNum) || 1} Download Manager</div>
            <p style="font-size: 0.84rem; color: var(--text-secondary); margin-bottom: 1rem;">
                The green button above downloads the exact file now playing. No sign-in needed. Only files the provider publishes are listed — CamAnime never re-encodes video into a lower resolution, so if 360p or a dub is missing here, the source does not have it.
            </p>
            <div id="dlStatus" style="display:none;font-size:.82rem;margin-bottom:.8rem;color:#fca5a5;"></div>
            <div class="dl-grid" id="downloadGrid">
                <p style="font-size:.85rem;color:var(--text-secondary);">Downloads appear as soon as a server answers.</p>
            </div>
        </div>
        <div class="panel-box">
            <div class="panel-box-title"><i class="fab fa-youtube" style="color:#ff4e45;"></i> Trailer &amp; episode notes</div>
            <div id="watchTrailerBox"><p style="font-size:.85rem;color:var(--text-secondary);">Loading the official trailer…</p></div>
            <p style="font-size:.8rem;color:var(--text-secondary);margin-top:.7rem;">The embedded trailer is provided by YouTube. External video services and embeds may show their own ads, which we cannot control.</p>
            <p style="font-size:.8rem;color:var(--text-secondary);margin-top:.7rem;" id="watchProviderNote"></p>
        </div>
    </div>

    <section id="ca-community" data-anime="${anime.id}" data-ep="${epNum}" class="ca-community">
        <h2 class="ca-community-title">Comments &amp; episode forum</h2>
        <p class="ca-community-sub">${user ? "Signed in as " + esc(user.name) + " — post below." : "Sign in to post comments and ratings."}</p>
        <div class="ca-theme-row" role="group" aria-label="Site theme">
            <span class="ca-theme-label">Theme:</span>
            ${["light", "midnight", "vibrant", "sakura", "forest", "obsidian", "neo", "tokyo"].map((t) => `<button type="button" class="ca-theme-btn" data-theme-name="${t}">${t === "midnight" ? "Midnight" : t[0].toUpperCase() + t.slice(1)}</button>`).join("")}
        </div>
    </section>
</div>

<script>
(function () {
  var animeId = ${JSON.stringify(String(anime.id))};
  var epNum = ${Number(epNum) || 1};
  var audio = ${JSON.stringify(audio)};
  var episodeTitle = ${JSON.stringify(name + " — " + epTitle)};
  var origin = "https://camanime.onrender.com";
  var $ = function (id) { return document.getElementById(id); };
  var player = $("caPlayer"), video = $("nativeVideo"), frame = $("embedIframe");
  var errBox = $("playerError"), badge = $("playbackBadge"), status = $("activeServerStatus");
  var deck = $("serverDeck"), dubRow = $("dubServerRow"), grid = $("downloadGrid"), dlStatus = $("dlStatus");
  var dlBtn = $("downloadCurrentBtn"), skipBtn = $("skipIntroBtn"), resumeNote = $("caResumeNote");
  var hls = null, servers = [], active = null, intro = null, tried = false;
  var key = "camanime-resume:" + animeId + ":" + epNum;

  function note(text) { var n = $("watchProviderNote"); if (n) n.textContent = text || ""; }
  function absUrl(u) { return (u && u.indexOf("http") === 0) ? u : (u ? location.origin + u : ""); }
  function fmt(s) {
    if (!isFinite(s) || s < 0) s = 0;
    var m = Math.floor(s / 60), sec = Math.floor(s % 60);
    return m + ":" + (sec < 10 ? "0" : "") + sec;
  }
  function fail(text) { errBox.textContent = text; errBox.style.display = "block"; }
  function clearErr() { errBox.style.display = "none"; }

  function teardown() {
    if (hls) { try { hls.destroy(); } catch (e) {} hls = null; }
    frame.style.display = "none"; frame.removeAttribute("src");
    video.style.display = "block";
    player.classList.remove("playing", "loading", "error");
  }

  function updateResumeNote(seconds) {
    if (!resumeNote) return;
    if (seconds > 20) { resumeNote.textContent = "Resuming from " + fmt(seconds) + " — saved on this device."; resumeNote.hidden = false; setTimeout(function () { resumeNote.hidden = true; }, 5000); }
  }

  function play(server) {
    if (!server) return;
    clearErr();
    teardown();
    active = server;
    intro = server.intro && Number.isFinite(server.intro.end) ? server.intro : null;
    var url = absUrl(server.stream_url);
    var label = server.name || "server";
    status.textContent = "Active Server: " + label + " (" + String(server.audio || audio).toUpperCase() + ")";
    badge.textContent = server.playback_mode === "iframe" ? "EMBED" : (server.playback_mode === "hls" || url.indexOf("/api/proxy/hls") !== -1 ? "HLS" : "MP4");
    dlBtn.href = absUrl(server.download_url || server.stream_url || "");
    dlBtn.setAttribute("download", "");
    servers.forEach(function (s) { var b = deck.querySelector('[data-server-id="' + s.id + '"]'); if (b) b.classList.toggle("active", s === server); });
    if (!url) { fail("This server returned no link. Pick another server below."); return; }
    if (server.playback_mode === "iframe") {
      player.classList.remove("playing");
      frame.src = url; frame.style.display = "block"; video.style.display = "none";
      note("Playing in " + label + "'s embed. If it stays blank, open it in a new tab.");
      return;
    }
    if (server.playback_mode === "hls" || url.indexOf("/api/proxy/hls") !== -1) {
      if (window.Hls && window.Hls.isSupported()) {
        hls = new window.Hls({ maxBufferLength: 30 });
        hls.on(window.Hls.Events.ERROR, function (evt, data) {
          if (data && data.fatal) { player.classList.add("error") ; fail("This stream stalled. Try another server below."); }
        });
        hls.loadSource(url); hls.attachMedia(video);
      } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = url;
      } else {
        fail("This browser cannot play HLS here. Pick an MP4 server or open the server page."); return;
      }
    } else {
      video.src = url;
    }
    var attempt = video.play();
    if (attempt && attempt.catch) attempt.catch(function () { player.classList.remove("playing"); });
  }

  function serverIcon(s) {
    return s.playback_mode === "iframe" ? "fa-play-circle" : "fa-bolt";
  }

  function renderDeck(data) {
    servers = (data.servers || []).slice();
    deck.removeAttribute("aria-busy");
    deck.querySelectorAll(".server-btn").forEach(function (b) { b.remove(); });
    var subRow = deck.querySelector(".server-row");
    var subs = servers.filter(function (s) { return String(s.audio || "").toLowerCase() !== "dub"; });
    var dubs = servers.filter(function (s) { return String(s.audio || "").toLowerCase() === "dub"; });
    if (!servers.length) {
      var empty = document.createElement("span");
      empty.style.cssText = "font-size:.82rem;color:var(--text-secondary)";
      empty.textContent = "No server answered yet.";
      subRow.appendChild(empty);
      dubRow.hidden = true;
    }
    subs.forEach(function (s) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "server-btn"; b.setAttribute("data-server-id", s.id || s.name || "");
      b.innerHTML = '<i class="fas ' + serverIcon(s) + '"></i><span></span><span class="server-tag"></span>';
      b.querySelector("span").textContent = s.name || s.label || s.provider || "Server";
      b.querySelector(".server-tag").textContent = s.badge || s.quality || s.playback_mode || "STREAM";
      b.addEventListener("click", function () { play(s); });
      subRow.appendChild(b);
    });
    dubRow.hidden = !dubs.length;
    dubs.forEach(function (s) {
      var b = document.createElement("button");
      b.type = "button"; b.className = "server-btn"; b.setAttribute("data-server-id", s.id || s.name || "");
      b.innerHTML = '<i class="fas ' + serverIcon(s) + '"></i><span></span><span class="server-tag"></span>';
      b.querySelector("span").textContent = s.name || s.label || s.provider || "Server";
      b.querySelector(".server-tag").textContent = s.badge || s.quality || s.playback_mode || "STREAM";
      b.addEventListener("click", function () { play(s); });
      dubRow.appendChild(b);
    });
    note(data.note || "");
  }

  function renderDownloads(data) {
    grid.innerHTML = "";
    var rows = (data.downloads || []).filter(function (d) { return d && d.url; });
    if (!rows.length && data.download_url) rows = [{ label: "Episode " + epNum + " direct file", url: data.download_url }];
    if (!rows.length) {
      grid.innerHTML = '<p style="font-size:.85rem;color:var(--text-secondary);">No direct download for this episode yet.</p>';
      return;
    }
    rows.slice(0, 12).forEach(function (d) {
      var row = document.createElement("div"); row.className = "dl-row";
      var meta = document.createElement("div"); meta.className = "dl-meta";
      var nm = document.createElement("span"); nm.className = "dl-name";
      nm.textContent = d.label || d.quality || ("Episode " + epNum + " file");
      var sub = document.createElement("span"); sub.className = "dl-sub";
      sub.textContent = [d.provider, d.quality, d.audio ? String(d.audio).toUpperCase() : ""].filter(Boolean).join(" • ") || "Provider file";
      meta.appendChild(nm); meta.appendChild(sub);
      var a = document.createElement("a"); a.className = "dl-action"; a.href = absUrl(d.url); a.setAttribute("download", "");
      a.innerHTML = '<i class="fas fa-download"></i> Direct MP4 Download';
      row.appendChild(meta); row.appendChild(a); grid.appendChild(row);
    });
  }

  function renderTrailer() {
    fetch("/api/trailer?anime_id=" + encodeURIComponent(animeId) + "&title=" + encodeURIComponent(episodeTitle.split(" — ")[0]), { headers: { accept: "application/json" } })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(function (d) {
        var id = d && d.youtube_id ? String(d.youtube_id) : "";
        if (!/^[A-Za-z0-9_-]{11}$/.test(id)) { $("watchTrailerBox").innerHTML = '<p style="font-size:.85rem;color:var(--text-secondary);">No official trailer is published for this title.</p>'; return; }
        $("watchTrailerBox").innerHTML = '<div class="trailer-embed-wrap" style="aspect-ratio:16/9;border-radius:12px;overflow:hidden;"><iframe style="width:100%;height:100%;border:0;" src="https://www.youtube.com/embed/' + id + '?rel=0" title="Official trailer" allow="encrypted-media; picture-in-picture" allowfullscreen></iframe></div>';
      })
      .catch(function () { $("watchTrailerBox").innerHTML = '<p style="font-size:.85rem;color:var(--text-secondary);">Trailer preview is unavailable right now.</p>'; });
  }

  // ── Custom controls ──────────────────────────────────────────────
  var playBtns = document.querySelectorAll('[data-ca="play"], .ca-big-play');
  function toggle() {
    if (video.paused) { var p = video.play(); if (p && p.catch) p.catch(function () {}); }
    else video.pause();
  }
  playBtns.forEach(function (b) { b.addEventListener("click", toggle); });
  video.addEventListener("play", function () {
    player.classList.add("playing"); player.classList.remove("loading");
    document.querySelectorAll('[data-ca="play"] i, .ca-big-play i').forEach(function (i) { i.className = "fas fa-pause"; });
  });
  video.addEventListener("pause", function () {
    document.querySelectorAll('[data-ca="play"] i, .ca-big-play i').forEach(function (i) { i.className = "fas fa-play"; });
  });
  video.addEventListener("waiting", function () { player.classList.add("loading"); });
  video.addEventListener("playing", function () { player.classList.remove("loading"); });
  video.addEventListener("error", function () { fail("The provider file could not be played here. Try another server."); });

  var played = player.querySelector(".ca-played"), buffered = player.querySelector(".ca-buffered");
  var progress = player.querySelector(".ca-progress");
  function paint() {
    if (!video.duration) return;
    var pct = (video.currentTime / video.duration) * 100;
    if (played) played.style.width = pct + "%";
    if (buffered && video.buffered.length) buffered.style.width = (video.buffered.end(video.buffered.length - 1) / video.duration) * 100 + "%";
    var cur = player.querySelector(".ca-current"), dur = player.querySelector(".ca-duration");
    if (cur) cur.textContent = fmt(video.currentTime);
    if (dur) dur.textContent = fmt(video.duration);
    if (progress) progress.setAttribute("aria-valuenow", String(Math.round(pct)));
    if (skipBtn && intro) {
      var inIntro = video.currentTime >= intro.start && video.currentTime < intro.end;
      skipBtn.style.display = inIntro ? "inline-flex" : "none";
    }
  }
  video.addEventListener("timeupdate", paint);
  video.addEventListener("loadedmetadata", function () {
    paint();
    try {
      var saved = Number(localStorage.getItem(key) || 0);
      if (saved > 20 && saved < video.duration - 20) { video.currentTime = saved; updateResumeNote(saved); }
    } catch (e) {}
  });
  video.addEventListener("timeupdate", function () {
    if (video.currentTime > 5) { try { localStorage.setItem(key, String(Math.floor(video.currentTime))); } catch (e) {} }
  });
  video.addEventListener("ended", function () {
    var auto = true;
    try { auto = localStorage.getItem("camanime-autoplay") !== "0"; } catch (e) {}
    var next = $("nextEpBtn");
    if (auto && next && next.getAttribute("href") && next.getAttribute("href").indexOf("#") !== 0) location.href = next.getAttribute("href");
  });
  function seekTo(clientX) {
    var rect = progress.getBoundingClientRect();
    var ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    if (video.duration) video.currentTime = ratio * video.duration;
  }
  if (progress) {
    progress.addEventListener("click", function (e) { seekTo(e.clientX); });
    progress.addEventListener("keydown", function (e) {
      if (e.key === "ArrowRight") { video.currentTime = Math.min(video.duration || 0, video.currentTime + 5); e.preventDefault(); }
      if (e.key === "ArrowLeft") { video.currentTime = Math.max(0, video.currentTime - 5); e.preventDefault(); }
    });
  }
  var muteBtn = player.querySelector('[data-ca="mute"]');
  if (muteBtn) muteBtn.addEventListener("click", function () {
    video.muted = !video.muted;
    muteBtn.querySelector("i").className = video.muted ? "fas fa-volume-mute" : "fas fa-volume-up";
  });
  var vol = $("caVol");
  if (vol) vol.addEventListener("input", function () { video.volume = Number(vol.value); video.muted = Number(vol.value) === 0; });
  var speed = $("caSpeed");
  if (speed) speed.addEventListener("change", function () { video.playbackRate = Number(speed.value) || 1; });
  var pip = player.querySelector('[data-ca="pip"]');
  if (pip) pip.addEventListener("click", function () {
    if (document.pictureInPictureElement) document.exitPictureInPicture().catch(function () {});
    else if (video.requestPictureInPicture) video.requestPictureInPicture().catch(function () {});
  });
  var full = player.querySelector('[data-ca="full"]');
  if (full) full.addEventListener("click", function () {
    if (document.fullscreenElement) document.exitFullscreen().catch(function () {});
    else if (player.requestFullscreen) player.requestFullscreen().catch(function () {});
  });
  var cc = player.querySelector('[data-ca="cc"]');
  function bindSubs(subs) {
    video.querySelectorAll("track").forEach(function (t) { t.remove(); });
    (subs || []).forEach(function (s, i) {
      var t = document.createElement("track");
      t.kind = "subtitles"; t.label = s.lang || ("Track " + (i + 1)); t.srclang = "en";
      t.src = absUrl(s.url); if (s.default && i === 0) t.default = true;
      video.appendChild(t);
    });
    if (cc) cc.style.display = (subs || []).length ? "inline-flex" : "none";
  }
  if (cc) cc.addEventListener("click", function () {
    var tracks = video.textTracks;
    if (!tracks.length) return;
    var next = tracks[0].mode === "showing" ? "disabled" : "showing";
    for (var i = 0; i < tracks.length; i += 1) tracks[i].mode = i === 0 ? next : "disabled";
    cc.setAttribute("aria-pressed", next === "showing" ? "true" : "false");
  });
  var retry = player.querySelector('[data-ca="retry"]');
  if (retry) retry.addEventListener("click", function () { if (active) play(active); });

  skipBtn.addEventListener("click", function () { if (intro) { video.currentTime = intro.end; skipBtn.style.display = "none"; } });
  $("focusBtn").addEventListener("click", function () { document.body.classList.toggle("lights-off"); });
  $("allFilesBtn").addEventListener("click", function () { $("downloadPanel").scrollIntoView({ behavior: "smooth", block: "start" }); });

  // ── Rail filter + server load ────────────────────────────────────
  $("epRailFilter").addEventListener("input", function () {
    var q = this.value.replace(/[^0-9]/g, "");
    document.querySelectorAll("#epRailList .ep-rail-item").forEach(function (a) {
      a.style.display = !q || String(a.dataset.ep).indexOf(q) === 0 ? "" : "none";
    });
  });

  var quality = $("qualitySel");
  function preferredServer(list) {
    var pref = "auto";
    try { pref = localStorage.getItem("camanime-quality:" + animeId) || localStorage.getItem("camanime-quality") || "auto"; } catch (e) {}
    if (pref === "auto") return list[0];
    var sorted = list.slice().sort(function (a, b) { return (Number(b.height) || 0) - (Number(a.height) || 0); });
    return pref === "max" ? sorted[0] : sorted[sorted.length - 1];
  }
  if (quality) {
    var pref = "auto";
    try { pref = localStorage.getItem("camanime-quality:" + animeId) || localStorage.getItem("camanime-quality") || "auto"; } catch (e) {}
    if (["auto", "max", "low"].indexOf(pref) === -1) pref = "auto";
    quality.value = pref;
    quality.addEventListener("change", function () {
      try { localStorage.setItem("camanime-quality:" + animeId, quality.value); } catch (e) {}
      if (servers.length) play(preferredServer(servers));
    });
  }

  function load() {
    var cached = null;
    try {
      var raw = sessionStorage.getItem("camanime-src:v3:" + animeId + ":" + epNum + ":" + audio);
      if (raw) { var hit = JSON.parse(raw); if (hit && hit.at && Date.now() - hit.at < 30 * 60 * 1000) cached = hit.data; }
    } catch (e) {}
    if (cached && cached.servers && cached.servers.length) {
      renderDeck(cached); renderDownloads(cached);
      play(preferredServer(cached.servers));
    }
    fetch("/api/episode-sources/" + animeId + "/" + epNum + "?audio=" + audio, { headers: { accept: "application/json" }, cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("HTTP " + r.status); return r.json(); })
      .then(function (data) {
        renderDeck(data); renderDownloads(data);
        var list = data.servers || [];
        if (!list.length) { fail("No server has answered for this episode yet. Nothing was invented."); return; }
        try { sessionStorage.setItem("camanime-src:v3:" + animeId + ":" + epNum + ":" + audio, JSON.stringify({ at: Date.now(), data: { servers: data.servers, downloads: data.downloads, note: data.note } })); } catch (e) {}
        play(preferredServer(list));
      })
      .catch(function () {
        if (cached && cached.servers && cached.servers.length) { note("Saved servers — live refresh failed. Tap a server to retry."); return; }
        servers = []; renderDeck({ servers: [], note: "" });
        fail("Servers are taking too long to answer. This is not a missing episode.");
        var retryLink = document.createElement("a");
        retryLink.className = "ctrl-btn"; retryLink.href = origin + "/watch/" + animeId + "/" + epNum + "?audio=" + audio;
        retryLink.target = "_blank"; retryLink.rel = "noopener"; retryLink.textContent = "Open the fallback player";
        deck.querySelector(".server-row").appendChild(retryLink);
      });
  }

  renderTrailer();
  load();
  window.caTrack && window.caTrack("play", animeId, String(epNum));
})();
</script>
<script>
(function () {
  var btns = document.querySelectorAll(".ca-theme-btn");
  btns.forEach(function (b) {
    b.addEventListener("click", function () {
      var name = b.getAttribute("data-theme-name");
      if (window.caSetTheme) window.caSetTheme(name);
      else { document.documentElement.setAttribute("data-theme", name); try { localStorage.setItem("camanime-theme", name); } catch (e) {} }
    });
  });
})();
</script>`;

  return `${head(title, desc, { styles: [`/static/css/page-watch.css?v=${CSS_VERSION}`] })}
<body class="page-watch">
${inner}
</body></html>`;
}

export function detailsPage(anime, ratingSummary, user, eps) {
  const name = anime.title?.english || anime.title?.romaji || "Anime";
  const romaji = anime.title?.romaji && anime.title.romaji.toLowerCase() !== name.toLowerCase() ? anime.title.romaji : "";
  const native = anime.title?.native && anime.title.native.toLowerCase() !== name.toLowerCase() && anime.title.native.toLowerCase() !== romaji.toLowerCase() ? anime.title.native : "";
  const studio = anime.studios?.nodes?.[0]?.name || "";
  const banner = anime.bannerImage || anime.coverImage?.extraLarge || anime.coverImage?.large || "/static/brand/camanime-icon.svg";
  const poster = anime.coverImage?.extraLarge || anime.coverImage?.large || "/static/brand/camanime-icon.svg";
  const released = (anime.streamingEpisodes || []).length;
  const nextEp = Number(anime.nextAiringEpisode?.episode) || 0;
  const nextAt = Number(anime.nextAiringEpisode?.airingAt) || 0;
  const aired = nextEp ? (nextAt && nextAt <= Math.floor(Date.now() / 1000) ? nextEp : nextEp - 1) : 0;
  const total = released || (anime.status === "RELEASING" ? aired : Number(anime.episodes)) || 0;
  const entries = Array.from({ length: total }, (_, i) => ({
    n: i + 1,
    title: (anime.streamingEpisodes || [])[i]?.title || `Episode ${i + 1}`,
    listed: Boolean((anime.streamingEpisodes || [])[i]),
  }));
  const pager = pagerOf(entries, eps, null);
  const season = anime.season && anime.seasonYear ? `${anime.season[0]}${anime.season.slice(1).toLowerCase()} ${anime.seasonYear}` : (anime.seasonYear || "");
  const summary = String(anime.description || "").replace(/<br\s*\/?>/gi, "\n").replace(/<[^>]*>/g, "").trim();
  const trailerId = anime.trailer?.site === "youtube" && /^[A-Za-z0-9_-]{11}$/.test(String(anime.trailer?.id || "")) ? anime.trailer.id : "";
  const related = (anime.relations?.edges || []).filter((e) => e?.node?.type === "ANIME").slice(0, 8);
  const title = `${name} — episodes, stream and download`;
  const desc = `Watch ${name} on CamAnime: every confirmed episode, provider servers, SUB/DUB availability and direct downloads.`;

  const inner = `
<a class="skip-link" href="#main-content">Skip to episode guide</a>
${detailsHeader()}

<div class="banner-wrap">
    <img src="${esc(banner)}" class="banner-img" alt="${esc(name)}" fetchpriority="high" decoding="async" referrerpolicy="no-referrer" onerror="this.onerror=null;this.src='/static/brand/camanime-icon.svg'">
    <div class="banner-gradient"></div>
</div>

<div class="container" id="main-content" role="main" tabindex="-1">
    <div class="dossier-card">
        <div class="poster-col">
            <img src="${esc(poster)}" class="anime-poster" alt="${esc(name)}" fetchpriority="high" decoding="async" referrerpolicy="no-referrer" onerror="this.onerror=null;this.src='/static/brand/camanime-icon.svg'">
            <div class="scraper-status-box">
                ${released
                  ? `<strong><i class="fas fa-check-circle"></i> Provider catalog matched</strong>Provider episode listings: <code>${released}</code> · playback not verified`
                  : entries.length
                    ? `<strong><i class="fas fa-circle-check"></i> Episode metadata available</strong>${entries.length} episodes confirmed as aired or listed by a provider. Playback has not been verified.`
                    : `<strong><i class="fas fa-circle-info"></i> Episodes not confirmed</strong>No released episode count is currently available.`}
            </div>
        </div>

        <div class="info-col">
            <div>
                <div class="kicker-row">
                    ${anime.averageScore ? `<span class="badge gold"><i class="fas fa-star"></i> ${(anime.averageScore / 10).toFixed(1)}</span>` : ""}
                    ${anime.format ? `<span class="badge">${esc(anime.format)}</span>` : ""}
                    ${anime.status ? `<span class="badge">${esc(anime.status[0] + anime.status.slice(1).toLowerCase())}</span>` : ""}
                    <span class="badge">${entries.length ? `${entries.length} episodes confirmed` : "Episodes not confirmed"}</span>
                    ${season ? `<span class="badge">${esc(season)}</span>` : ""}
                </div>

                <h1 class="anime-title">${esc(name)}</h1>
                ${romaji || native || studio ? `<div class="anime-subtitle">
                    ${romaji ? `<span>${esc(romaji)}</span>` : ""}
                    ${native ? `<span>${esc(native)}</span>` : ""}
                    ${studio ? `<span>Animated by ${esc(studio)}</span>` : ""}
                </div>` : ""}

                <div class="genre-tags">
                    ${(anime.genres || []).map((g) => `<a href="/?genre=${encodeURIComponent(g)}" class="genre-tag">${esc(g)}</a>`).join("")}
                </div>

                <div class="synopsis">${esc(summary)}</div>
            </div>

            <div class="action-bar">
                ${entries.length
                  ? `<a href="/watch/${anime.id}/1?audio=sub" class="btn-watch"><i class="fas fa-play"></i> Check Ep 1 (English SUB)</a>
                     <a href="/watch/${anime.id}/1?audio=dub" class="btn-outline"><i class="fas fa-headphones"></i> Try English Dub on Ep 1</a>`
                  : `<span class="btn-outline" aria-disabled="true"><i class="fas fa-circle-info"></i> No released episode confirmed</span>`}
                <button type="button" class="btn-outline" id="bookmarkBtn" aria-pressed="false"><i class="fas fa-bookmark" aria-hidden="true"></i> <span id="bookmarkText">Add to Watchlist</span></button>
            </div>
            ${nextEp && nextAt ? `<p class="release-countdown muted" data-airing-epoch="${nextAt}" data-airing-episode="${nextEp}">Next episode (EP ${nextEp}) airs in <strong class="cd-text">calculating…</strong></p>` : ""}
            <p class="availability-note">Quality and dub availability are detected per episode from the provider. A missing resolution or dub means the source does not publish it — it is never simulated.</p>
            ${ratingSummary?.average ? `<p class="availability-note">Community score: <strong>${ratingSummary.average}/10</strong> from ${ratingSummary.count} rating${ratingSummary.count === 1 ? "" : "s"}.</p>` : ""}
        </div>
    </div>

    <div class="two-col-layout">
        <div class="panel-card">
            <div class="panel-header">
                <div class="panel-title"><span class="accent-dot"></span> Released episodes (${entries.length})${pager.pages > 1 ? `<span class="ep-pager-count">page ${pager.page} of ${pager.pages}</span>` : ""}</div>
                <div class="ep-controls">
                    <label class="sr-only" for="epSearchInput">Jump to an episode number, or filter this page by title</label>
                    <input type="search" id="epSearchInput" class="ep-filter-input" placeholder="Jump to episode #..." aria-controls="epGrid">
                    <a class="nav-pill" id="reverseEpisodesButton" href="/anime/${anime.id}?eps=${pager.page}&order=desc"><i class="fas fa-sort"></i> Reverse Order</a>
                </div>
            </div>
            <p class="availability-note">Episode numbers are confirmed by release metadata. Provider listings are not proof a playable stream is currently available.</p>
            <div class="ep-grid" id="epGrid">
                ${entries.length ? "" : `<p class="schedule-empty">No released episodes are confirmed yet. This will update when an episode airs or a provider lists it.</p>`}
                <p class="ep-no-match" id="epNoMatch" role="status" hidden></p>
                ${pager.slice.map((e) => `<a href="/watch/${anime.id}/${e.n}" class="ep-card" data-ep="${e.n}">
                    <div class="ep-card-top">
                        <span class="ep-num">EP ${e.n}</span>
                        <span class="ep-dl-tag" title="${e.listed ? "Provider episode listing found · playback not verified" : "Aired · source unchecked"}">${e.listed ? "Provider listing · check player" : "Aired · source unchecked"}</span>
                    </div>
                    <div class="ep-name" title="${esc(e.title)}">${esc(e.title)}</div>
                </a>`).join("")}
            </div>
            ${pagerHtml(pager, `/anime/${anime.id}`, {})}
        </div>

        <div style="display: flex; flex-direction: column; gap: 1.5rem;">
            <div class="panel-card">
                <div class="panel-header" style="margin-bottom: 0.85rem;">
                    <div class="panel-title" style="font-size: 1.1rem;"><i class="fab fa-youtube" style="color: #ff4e45;"></i> Official YouTube Trailer</div>
                </div>
                <div class="trailer-embed-wrap" id="detailsTrailerBox">
                    ${trailerId
                      ? `<iframe src="https://www.youtube.com/embed/${trailerId}?rel=0" title="Trailer for ${esc(name)}" allow="encrypted-media; picture-in-picture" allowfullscreen></iframe>`
                      : `<p style="font-size:.85rem;color:var(--text-secondary);padding:1rem 0;">No official trailer is published for this title.</p>`}
                </div>
                <p style="font-size: 0.8rem; color: var(--text-secondary);">The embedded trailer is provided by YouTube. CamAnime does not place ads on its own pages or through its media proxy. External video services and embeds may show their own ads, which we cannot control.</p>
            </div>

            <div class="panel-card" id="seasonDownloadPanel">
                <div class="panel-header" style="margin-bottom: 0.5rem;">
                    <div class="panel-title" style="font-size: 1.1rem;"><i class="fas fa-list-check" style="color: var(--emerald);"></i> Provider episode listings</div>
                </div>
                <p class="availability-note" id="seasonDownloadNote">${released ? "Provider catalog matched. Listings and any resulting links are not verified playback or download guarantees." : "No provider listing is matched for this title yet. The watch page resolves sources live when an episode opens."}</p>
                ${entries.length ? `<a class="btn-outline emerald" style="width:100%;justify-content:center;margin-top:0.85rem;" href="/watch/${anime.id}/1"><i class="fas fa-play"></i> Open the player for Ep 1</a>` : ""}
            </div>
        </div>
    </div>

    ${related.length ? `<div class="panel-card" style="margin-bottom: 2.5rem;">
        <div class="panel-header"><div class="panel-title"><span class="accent-dot"></span> Seasons, Sequels &amp; Related Releases</div></div>
        <div class="mini-grid">
            ${related.map((e) => `<a href="/anime/${e.node.id}" class="mini-poster-card" title="${esc(e.node.title?.english || e.node.title?.romaji || "")}">
                ${e.node.coverImage?.large ? `<img src="${esc(e.node.coverImage.large)}" loading="lazy" decoding="async" referrerpolicy="no-referrer" alt="${esc(e.node.title?.english || e.node.title?.romaji || "")}" onerror="this.style.display='none';this.nextElementSibling.style.display='flex'">` : ""}
                <div class="mini-poster-fallback" style="${e.node.coverImage?.large ? "display:none;" : ""}"><i class="fas fa-layer-group"></i></div>
                <div class="mini-poster-body">
                    <div class="mini-poster-rel">${esc(String(e.relationType || "").replace(/_/g, " "))}${e.node.format ? " • " + esc(e.node.format) : ""}${e.node.seasonYear ? " • " + e.node.seasonYear : ""}</div>
                    <div class="mini-poster-title">${esc(e.node.title?.english || e.node.title?.romaji || "")}</div>
                    <div class="mini-poster-sub">${e.node.episodes ? e.node.episodes + " EPISODES • " : ""}${esc(e.node.status || "")}</div>
                </div>
            </a>`).join("")}
        </div>
    </div>` : ""}
</div>

<script>
(function () {
  function filterEpisodes(value) {
    var q = String(value || "").trim().toLowerCase();
    var shown = 0;
    document.querySelectorAll("#epGrid .ep-card").forEach(function (card) {
      var hit = !q || String(card.dataset.ep) === q || card.textContent.toLowerCase().indexOf(q) !== -1;
      card.style.display = hit ? "" : "none";
      if (hit) shown += 1;
    });
    var empty = document.getElementById("epNoMatch");
    if (empty) { empty.hidden = shown !== 0 || !q; empty.textContent = shown ? "" : "No episode on this page matches “" + value + "”."; }
  }
  var search = document.getElementById("epSearchInput");
  if (search) search.addEventListener("input", function () { filterEpisodes(this.value); });

  var box = document.querySelector(".release-countdown");
  if (box) {
    var epoch = Number(box.dataset.airingEpoch) || 0;
    var out = box.querySelector(".cd-text");
    function tick() {
      var s = epoch - Math.floor(Date.now() / 1000);
      if (s <= 0) { out.textContent = "airing now or aired - checking provider"; return; }
      var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60), x = s % 60;
      out.textContent = (d ? d + "d " : "") + h + "h " + m + "m " + x + "s";
    }
    tick(); setInterval(tick, 1000);
  }

  var btn = document.getElementById("bookmarkBtn");
  var label = document.getElementById("bookmarkText");
  if (btn) {
    var id = ${JSON.stringify(String(anime.id))};
    var key = "camanime-watchlist";
    function read() { try { var raw = localStorage.getItem(key); return raw ? JSON.parse(raw) : []; } catch (e) { return []; } }
    function paint() {
      var has = read().map(String).indexOf(String(id)) !== -1;
      btn.setAttribute("aria-pressed", has ? "true" : "false");
      label.textContent = has ? "In Watchlist" : "Add to Watchlist";
    }
    btn.addEventListener("click", function () {
      var list = read().map(String).filter(function (x) { return x !== String(id); });
      if (btn.getAttribute("aria-pressed") !== "true") list.push(String(id));
      try { localStorage.setItem(key, JSON.stringify(list)); } catch (e) {}
      paint();
    });
    paint();
  }
})();
</script>`;

  return `${head(title, desc, { styles: [`/static/css/page-details.css?v=${CSS_VERSION}`] })}
<body class="page-details">
${inner}
</body></html>`;
}
