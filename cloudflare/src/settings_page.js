/**
 * Settings page for the Cloudflare mirror.
 *
 * Same sections, classes and copy as `templates/settings.html` on the Render
 * origin (Appearance, Layout, Account, Playback, Network, Forum identity,
 * Device data), so the shared stylesheets render both deployments the same
 * way. `chrome` and `esc` are passed in from pages.js to avoid a circular
 * import.
 */

const THEMES = [
  ["light", "Light", "linear-gradient(135deg,#ffffff,#e8e2d2)"],
  ["midnight", "Midnight", "linear-gradient(135deg,#141a2a,#07080d)"],
  ["vibrant", "Vibrant", "linear-gradient(135deg,#7C61D4,#14101f)"],
  ["sakura", "Sakura", "linear-gradient(135deg,#ff7aa8,#3a1530)"],
  ["forest", "Forest", "linear-gradient(135deg,#34d399,#07120e)"],
  ["obsidian", "Obsidian", "linear-gradient(135deg,#FFB347,#0e1118)"],
  ["neo", "Neo Streaming", "linear-gradient(135deg,#4EA8FF,#070d1c)"],
  ["tokyo", "Neon Tokyo", "linear-gradient(135deg,#35F1E4,#FF3DDB)"],
];

const LAYOUTS = [
  ["classic", "Classic", "linear-gradient(135deg,#FFB347,#0e111a)"],
  ["cinema", "Cinema", "linear-gradient(135deg,#7C61D4,#FF5E62)"],
  ["compact", "Compact", "linear-gradient(135deg,#34d399,#0e111a)"],
  ["minimal", "Minimal", "linear-gradient(135deg,#64708a,#f6f4ee)"],
  ["wide", "Wide", "linear-gradient(135deg,#FFD27D,#7C61D4)"],
  ["magazine", "Magazine", "linear-gradient(135deg,#f6f4ee,#171a21)"],
  ["wall", "Poster Wall", "linear-gradient(135deg,#34d399,#4EA8FF)"],
];

const ADMIN_ROLES = ["admin", "owner", "developer", "support"];

const swatches = (items, attr) =>
  items
    .map(
      ([id, label, bg]) =>
        `<button type="button" class="theme-pick" ${attr}="${id}"><span class="theme-dot" style="background:${bg}"></span>${label}</button>`
    )
    .join("");

const SCRIPT = `
<script>
(function () {
  var $ = function (id) { return document.getElementById(id); };
  function say(t) { var m = $('saveMsg'); if (m) m.textContent = t || ''; }
  function cur(k, d) { try { return localStorage.getItem(k) || d; } catch (e) { return d; } }
  function set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} }
  var LABELS = {
    classic: 'Classic — the original CamAnime layout.',
    cinema: 'Cinema — big posters, wide stage, rounded showtimes feel.',
    compact: 'Compact — dense grid, landscape posters, more per row.',
    minimal: 'Minimal — flat editorial: square corners, borders, no gradients.',
    wide: 'Wide — full-bleed stage for big monitors, larger posters, more per row.',
    magazine: 'Magazine — editorial column, landscape thumbnails, rule-led sections.',
    wall: 'Poster Wall — dense poster grid for scanning a whole catalogue at once.'
  };
  var themes = ['light','midnight','vibrant','sakura','forest','obsidian','neo','tokyo'];
  var layouts = ['classic','cinema','compact','minimal','wide','magazine','wall'];
  var themeBtns = document.querySelectorAll('#themeGrid [data-theme-name]');
  var layoutBtns = document.querySelectorAll('#layoutGrid [data-layout-name]');

  function paint(nodes, attr, value) {
    for (var i = 0; i < nodes.length; i++) nodes[i].classList.toggle('active', nodes[i].getAttribute(attr) === value);
  }
  function paintTheme() {
    var t = cur('camanime-theme', 'midnight');
    if (themes.indexOf(t) === -1) t = 'midnight';
    paint(themeBtns, 'data-theme-name', t);
    var mode = t === 'light' ? 'light' : 'dark';
    document.querySelectorAll('#modeSeg button').forEach(function (b) { b.classList.toggle('active', b.dataset.mode === mode); });
  }
  function pickTheme(name) {
    if (window.caSetTheme) window.caSetTheme(name);
    else { document.documentElement.setAttribute('data-theme', name); set('camanime-theme', name); }
    paintTheme();
    say(name === 'light' ? 'Light mode on.' : 'Dark theme saved: ' + name + '.');
  }
  themeBtns.forEach(function (b) { b.onclick = function () { pickTheme(b.dataset.themeName); }; });
  document.querySelectorAll('#modeSeg button').forEach(function (b) {
    b.onclick = function () { pickTheme(b.dataset.mode === 'light' ? 'light' : 'midnight'); };
  });

  function paintLayout() {
    var l = cur('camanime-layout', 'classic');
    if (layouts.indexOf(l) === -1) l = 'classic';
    paint(layoutBtns, 'data-layout-name', l);
    if ($('layoutNote')) $('layoutNote').textContent = LABELS[l];
  }
  layoutBtns.forEach(function (b) {
    b.onclick = function () {
      if (window.caSetLayout) window.caSetLayout(b.dataset.layoutName);
      else { document.documentElement.setAttribute('data-layout', b.dataset.layoutName); set('camanime-layout', b.dataset.layoutName); }
      paintLayout();
      say('Layout: ' + b.dataset.layoutName + '.');
    };
  });

  function paintData() {
    var pref = (window.caDataSaver && window.caDataSaver.pref) ? window.caDataSaver.pref() : cur('camanime-data-saver', 'auto');
    document.querySelectorAll('#dataSeg button').forEach(function (b) { b.classList.toggle('active', b.dataset.data === pref); });
    if ($('dataTierNote') && window.caDataSaver && window.caDataSaver.label) $('dataTierNote').textContent = window.caDataSaver.label();
  }
  document.querySelectorAll('#dataSeg button').forEach(function (b) {
    b.onclick = function () {
      if (window.caDataSaver) window.caDataSaver.set(b.dataset.data);
      else set('camanime-data-saver', b.dataset.data);
      paintData();
      say(b.dataset.data === 'auto' ? 'Data saver follows your connection.' : (b.dataset.data === 'low' ? 'Data saver on.' : 'Max quality — no lower quality.'));
    };
  });

  function paintAudio() {
    var a = cur('camanime-audio', 'sub');
    document.querySelectorAll('#audioSeg button').forEach(function (b) { b.classList.toggle('active', b.dataset.audio === a); });
  }
  document.querySelectorAll('#audioSeg button').forEach(function (b) {
    b.onclick = function () { set('camanime-audio', b.dataset.audio); paintAudio(); say('Default audio: English ' + b.dataset.audio.toUpperCase() + '.'); };
  });

  if ($('setAutoplay')) {
    $('setAutoplay').checked = cur('camanime-autoplay', '0') === '1';
    $('setAutoplay').onchange = function () { set('camanime-autoplay', this.checked ? '1' : '0'); say('Autoplay ' + (this.checked ? 'on.' : 'off.')); };
  }
  if ($('setMotion')) {
    $('setMotion').checked = cur('camanime-motion', '0') === '1';
    $('setMotion').onchange = function () {
      set('camanime-motion', this.checked ? '1' : '0');
      document.documentElement.dataset.motion = this.checked ? 'reduced' : '';
      say('Motion preference saved.');
    };
  }
  if ($('setGuestName')) $('setGuestName').value = cur('camanime-guest', '');
  if ($('saveNameBtn')) {
    $('saveNameBtn').onclick = function () {
      var v = ($('setGuestName').value || '').trim().slice(0, 24);
      set('camanime-guest', v);
      say(v ? 'Display name saved.' : 'Display name cleared — you will post as Guest.');
    };
  }
  function measure() {
    if (!$('storageLine')) return;
    try {
      var bytes = 0;
      ['camanime_watchlist', 'camanime-guest'].forEach(function (k) { bytes += (localStorage.getItem(k) || '').length; });
      $('storageLine').textContent = 'Local site data: ~' + Math.max(1, Math.round(bytes / 1024)) + ' KB in this browser.';
    } catch (e) { $('storageLine').textContent = 'Local storage unavailable.'; }
  }
  if ($('clearWatchBtn')) {
    $('clearWatchBtn').onclick = function () {
      try { localStorage.removeItem('camanime_watchlist'); } catch (e) {}
      measure(); say('Watchlist cleared.');
    };
  }
  if ($('resetAllBtn')) {
    $('resetAllBtn').onclick = function () {
      ['camanime-theme','camanime-motion','camanime-autoplay','camanime-audio','camanime-layout'].forEach(function (k) {
        try { localStorage.removeItem(k); } catch (e) {}
      });
      document.documentElement.setAttribute('data-theme', 'midnight');
      document.documentElement.setAttribute('data-layout', 'classic');
      document.documentElement.dataset.motion = '';
      if ($('setAutoplay')) $('setAutoplay').checked = false;
      if ($('setMotion')) $('setMotion').checked = false;
      if (window.caApplySchedulePrefs) window.caApplySchedulePrefs();
      paintTheme(); paintAudio(); paintLayout(); paintData(); measure();
      say('All site settings reset to defaults.');
    };
  }
  if ($('setSignOut')) {
    $('setSignOut').onclick = function () {
      fetch('/api/auth/logout', { method: 'POST', credentials: 'same-origin' }).then(function () { location.href = '/'; });
    };
  }

  paintTheme(); paintLayout(); paintAudio(); paintData(); measure();
})();
</script>`;

export function renderSettings(user, chrome, esc) {
  const themeRow = swatches(THEMES, "data-theme-name");
  const layoutRow = swatches(LAYOUTS, "data-layout-name");
  const isAdmin = ADMIN_ROLES.indexOf(user?.role) !== -1;

  const account = user
    ? `<div class="set-card">
      <h2><i class="fas fa-user-check" aria-hidden="true"></i> Account
        ${isAdmin ? `<span style="font-size:.8rem;color:#34d399;border:1px solid rgba(52,211,153,.4);border-radius:999px;padding:.15rem .7rem">Admin</span>` : ""}
      </h2>
      <p>Signed in as <strong>${esc(user.name || user.email)}</strong>${user.name && user.email ? ` (${esc(user.email)})` : ""}.</p>
      <div class="btn-row">
        ${isAdmin ? `<a class="btn-primary" href="/admin"><i class="fas fa-shield-halved" aria-hidden="true"></i> Open admin tools</a>` : ""}
        <button class="btn-danger" type="button" id="setSignOut"><i class="fas fa-arrow-right-from-bracket" aria-hidden="true"></i> Sign out</button>
      </div>
    </div>`
    : `<div class="set-card">
      <h2><i class="fas fa-right-to-bracket" aria-hidden="true"></i> Sign in</h2>
      <p>Save your comments, ratings and watch progress to your CamAnime account. Watching works without an account too.</p>
      <div class="btn-row"><a class="btn-primary" href="/login?next=/settings"><i class="fas fa-right-to-bracket" aria-hidden="true"></i> Sign in or create an account</a></div>
      <p class="storage-line">Passwords are stored hashed — never in plain text.</p>
    </div>`;

  const inner = `
    <div class="set-wrap">
      <div class="set-head">
        <a href="/" aria-label="CamAnime home"><img src="/static/brand/camanime-logo.svg" alt="CamAnime"></a>
        <h1><i class="fas fa-cog" aria-hidden="true"></i> Settings</h1>
      </div>
      <p style="margin-bottom:1.2rem"><a href="/" style="font-weight:700;font-size:.92rem"><i class="fas fa-arrow-left" aria-hidden="true"></i> Back to Discover</a></p>

      <div class="set-card">
        <h2><i class="fas fa-palette" aria-hidden="true"></i> Appearance</h2>
        <p>Pick a mode or a theme — it applies instantly across the whole site and is remembered on this device.</p>
        <div class="seg" id="modeSeg" role="group" aria-label="Appearance mode" style="margin-bottom:.6rem">
          <button type="button" data-mode="dark"><i class="fas fa-moon" aria-hidden="true"></i> Dark mode</button>
          <button type="button" data-mode="light"><i class="fas fa-sun" aria-hidden="true"></i> Light mode</button>
        </div>
        <div class="theme-grid" id="themeGrid">${themeRow}</div>
      </div>

      <div class="set-card">
        <h2><i class="fas fa-table-cells" aria-hidden="true"></i> Layout template</h2>
        <p>Switch between complete layout designs — grid shape, poster style, hero size, spacing and controls reflow across the whole site.</p>
        <div class="theme-grid" id="layoutGrid">${layoutRow}</div>
        <p class="storage-line" id="layoutNote">Classic — the original CamAnime layout.</p>
      </div>

      ${account}

      <div class="set-card">
        <h2><i class="fas fa-play-circle" aria-hidden="true"></i> Playback</h2>
        <p>How episodes behave while you watch. Changes apply on the next episode you open.</p>
        <div class="row-toggle">
          <span class="lab">Autoplay next episode</span>
          <label class="switch"><input type="checkbox" id="setAutoplay" aria-label="Autoplay episodes"><span class="track"></span><span class="thumb"></span></label>
          <span class="hint">When an episode ends, the next one starts automatically.</span>
        </div>
        <div class="row-toggle">
          <span class="lab">Reduce motion</span>
          <label class="switch"><input type="checkbox" id="setMotion" aria-label="Reduce motion"><span class="track"></span><span class="thumb"></span></label>
          <span class="hint">Turns off animations and transitions across the site.</span>
        </div>
        <div class="lab" style="font-weight:700;font-size:.95rem;margin:.4rem 0 .5rem">Default audio</div>
        <div class="seg" id="audioSeg" role="group" aria-label="Default audio">
          <button type="button" data-audio="sub"><i class="fas fa-closed-captioning" aria-hidden="true"></i> English SUB</button>
          <button type="button" data-audio="dub"><i class="fas fa-headphones" aria-hidden="true"></i> English DUB</button>
        </div>
      </div>

      <div class="set-card">
        <h2><i class="fas fa-wifi" aria-hidden="true"></i> Network &amp; data</h2>
        <p id="dataTierNote">Detecting your connection…</p>
        <div class="seg" id="dataSeg" role="group" aria-label="Data saver mode">
          <button type="button" data-data="auto"><i class="fas fa-magic" aria-hidden="true"></i> Auto</button>
          <button type="button" data-data="low"><i class="fas fa-feather" aria-hidden="true"></i> Data saver on</button>
          <button type="button" data-data="normal"><i class="fas fa-gauge-high" aria-hidden="true"></i> Max quality</button>
        </div>
        <p style="font-size:.82rem">Auto follows the Network Information API (save-data, 2G/3G, hotspot). Data saver trims blur, swaps to smaller posters and enlarges the playback buffer so episodes keep playing on bad links.</p>
      </div>

      <div class="set-card">
        <h2><i class="fas fa-user" aria-hidden="true"></i> Forum identity</h2>
        <p>The display name shown on your ratings and comments. No account needed.</p>
        <div class="name-row">
          <input id="setGuestName" maxlength="24" placeholder="Your display name" autocomplete="nickname" aria-label="Display name">
          <button type="button" class="btn-primary" id="saveNameBtn"><i class="fas fa-check" aria-hidden="true"></i> Save</button>
        </div>
      </div>

      <div class="set-card">
        <h2><i class="fas fa-database" aria-hidden="true"></i> Data on this device</h2>
        <p>Watchlist and resume points live in this browser only. Clearing frees space and signs out guest extras.</p>
        <div class="btn-row">
          <button type="button" class="btn-danger" id="clearWatchBtn"><i class="fas fa-trash" aria-hidden="true"></i> Clear watchlist</button>
          <button type="button" class="btn-ghost" id="resetAllBtn">Reset all site settings</button>
        </div>
        <div class="storage-line" id="storageLine">Measuring local data…</div>
      </div>
      <div id="saveMsg" role="status" aria-live="polite" style="min-height:1.4em;font-size:.88rem;color:#34d399;margin-top:.7rem"></div>
    </div>
    ${SCRIPT}`;

  return chrome(
    "Settings",
    "CamAnime settings: themes, layouts and account.",
    user?.name,
    inner,
    "settings"
  );
}
