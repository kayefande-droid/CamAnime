  /* Live current-season schedule refresh: metadata only, bounded to every 15 minutes. */
(function () {
  'use strict';

  // Schedule tab preferences (set in Settings): visibility and screen position.
  var SCHEDULE_POSITIONS = ['left-top', 'left-middle', 'left-bottom', 'right-top', 'right-middle', 'right-bottom'];
  function applySchedulePrefs() {
    var root = typeof document !== 'undefined' && document.documentElement;
    if (!root) return;
    var pos = 'left-middle';
    var show = true;
    try {
      var saved = localStorage.getItem('camanime-schedule-pos');
      if (SCHEDULE_POSITIONS.indexOf(saved) !== -1) pos = saved;
      show = localStorage.getItem('camanime-schedule-tab') !== '0';
    } catch (error) { /* storage unavailable: keep defaults */ }
    root.setAttribute('data-schedule-pos', pos);
    root.setAttribute('data-schedule-tab', show ? 'on' : 'off');
  }
  window.caApplySchedulePrefs = applySchedulePrefs;
  applySchedulePrefs();
  var list = document.getElementById('releaseTickerList');
  var drawer = document.getElementById('liveScheduleDrawer');
  var drawerList = document.getElementById('liveScheduleList');
  var drawerToggle = document.getElementById('liveScheduleToggle');
  var drawerClose = document.getElementById('liveScheduleClose');
  var drawerBackdrop = document.getElementById('liveScheduleBackdrop');
  var drawerCount = document.getElementById('liveScheduleCount');
  var drawerTabCount = document.getElementById('liveScheduleTabCount');
  var drawerAnnouncement = document.getElementById('liveScheduleAnnouncement');
  var previousFocus = null;
  var scheduleUrl = (list && list.dataset.scheduleUrl) ||
    (drawerList && drawerList.dataset.scheduleUrl) || '/api/v1/schedule';
  var refreshMs = 15 * 60 * 1000;
  var busy = false;
  var scheduleLoaded = !!(drawer && drawer.dataset.scheduleNeedsInitialLoad !== 'true');
  // Server HTML already includes both schedule views. Do not issue an
  // identical request on load; refresh after the browser cache interval.
  var lastRefresh = Date.now();

  function setDrawerOpen(open, restoreFocus) {
    if (!drawer || !drawerToggle) return;
    drawer.classList.toggle('is-open', open);
    drawer.setAttribute('aria-hidden', open ? 'false' : 'true');
    drawerToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
    drawerToggle.classList.toggle('is-active', open);
    if (drawerBackdrop) drawerBackdrop.hidden = !open;
    document.body.classList.toggle('schedule-drawer-open', open);
    if (open) {
      previousFocus = document.activeElement;
      var closeButton = drawer.querySelector('#liveScheduleClose');
      if (closeButton) closeButton.focus();
      if (!scheduleLoaded) refresh(true);
    } else if (restoreFocus) {
      (previousFocus && previousFocus.focus ? previousFocus : drawerToggle).focus();
    }
  }

  if (drawer && drawerToggle) {
    drawerToggle.addEventListener('click', function () {
      setDrawerOpen(drawerToggle.getAttribute('aria-expanded') !== 'true');
    });
    if (drawerClose) drawerClose.addEventListener('click', function () { setDrawerOpen(false, true); });
    if (drawerBackdrop) drawerBackdrop.addEventListener('click', function () { setDrawerOpen(false, true); });
    document.addEventListener('keydown', function (event) {
      if (!drawer.classList.contains('is-open')) return;
      if (event.key === 'Escape') {
        event.preventDefault();
        setDrawerOpen(false, true);
      } else if (event.key === 'Tab') {
        var focusable = drawer.querySelectorAll('a[href], button:not([disabled])');
        if (!focusable.length) return;
        var first = focusable[0];
        var last = focusable[focusable.length - 1];
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first.focus();
        }
      }
    });
    if (window.location && new URLSearchParams(window.location.search || '').get('schedule') === 'open') {
      setDrawerOpen(true);
    }
  }

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  function renderList(target, items, season, compact) {
    if (!target) return;
    target.dataset.season = (season.name || '') + ' ' + (season.year || '');
    if (!Array.isArray(items) || !items.length) {
      target.innerHTML = '<p class="schedule-empty">No current-season air dates are listed by AniList right now. Refresh later for updates.</p>';
      return;
    }
    target.innerHTML = items.map(function (item) {
      var airing = item.next_airing_episode || {};
      var epoch = Number(airing.airing_at) || 0;
      var episode = airing.episode == null ? '' : airing.episode;
      var isUpcoming = epoch > Math.floor(Date.now() / 1000);
      var id = escapeHtml(item.id);
      var providerLink = item.official_episode_link;
      var providerUrl = providerLink && providerLink.url;
      var safeProviderUrl = '';
      try {
        if (typeof providerUrl === 'string' && providerUrl.trim()) {
          var parsedProviderUrl = new URL(providerUrl, window.location.origin);
          if ((parsedProviderUrl.protocol === 'http:' || parsedProviderUrl.protocol === 'https:') &&
              !parsedProviderUrl.username && !parsedProviderUrl.password) {
            safeProviderUrl = parsedProviderUrl.href;
          }
        }
      } catch (error) {}
      var provider = safeProviderUrl
        ? '<a class="release-provider" rel="nofollow noopener noreferrer" target="_blank" href="' + escapeHtml(safeProviderUrl) + '">Watch episode ' + escapeHtml(item.released_episode || '') + ' on ' + escapeHtml(providerLink.provider || 'official provider') + '</a>'
        : '';
      var stateText = !epoch ? 'Awaiting schedule from AniList' : (isUpcoming ? 'Countdown' : (item.official_link_available ? 'Provider listing found · verify release' : 'Aired · checking provider'));
      var when = epoch ? escapeHtml(item.airing_hour || '') + ' UTC' : 'Air date not listed';
      var countdown = epoch
        ? '<span class="cd-chip"><b data-cd-d>00</b><span>d</span></span>' +
          '<span class="cd-chip"><b data-cd-h>00</b><span>hrs</span></span>' +
          '<span class="cd-chip"><b data-cd-m>00</b><span>min</span></span>' +
          '<span class="cd-chip"><b data-cd-s>00</b><span>sec</span></span>' +
          '<span class="release-state" data-release-state>' + stateText + '</span>' + provider
        : '<span class="release-state">Next-episode date not listed</span>';
      var title = escapeHtml(item.title || 'Untitled anime');
      var metadata = '<div class="rt-sub">Episode ' + escapeHtml(episode || '?') + ' · ' + when + '</div>';
      var compactTitle = '<a class="live-schedule-title" href="/anime/' + id + '">' + title + '</a>';
      return '<article class="release-ticker' + (compact ? ' release-ticker-compact' : '') + '" data-anime-id="' + id + '" data-airing-epoch="' + epoch + '" data-airing-episode="' + escapeHtml(episode) + '" data-countdown-state="' + (epoch ? (isUpcoming ? 'upcoming' : 'aired_checking') : 'date_unknown') + '">' +
        '<div class="release-ticker-copy"><div class="rt-title">' + (compact ? compactTitle : title) + '</div>' + metadata + (!compact ? '<div class="rt-season">' + escapeHtml(season.name || '') + ' ' + escapeHtml(season.year || '') + '</div>' : '') + '</div>' +
        '<div class="countdown-chips" data-cd-for="' + id + '">' + countdown + '</div></article>';
    }).join('');
  }

  function render(items, season) {
    if (list) renderList(list, items, season, false);
    if (drawerList && drawerList !== list) renderList(drawerList, items, season, true);
    var itemCount = Array.isArray(items) ? items.length : 0;
    if (drawerCount) drawerCount.textContent = String(itemCount);
    if (drawerTabCount) {
      drawerTabCount.textContent = String(itemCount);
      drawerTabCount.setAttribute('aria-label', itemCount + ' scheduled titles');
    }
    if (drawerAnnouncement) drawerAnnouncement.textContent = 'Schedule updated. ' + (Array.isArray(items) ? items.length : 0) + ' current-season titles.';
    if (drawer) drawer.dataset.scheduleNeedsInitialLoad = 'false';
    scheduleLoaded = true;
    tick();
  }

  function tick() {
    var now = Math.floor(Date.now() / 1000);
    document.querySelectorAll('#releaseTickerList .release-ticker[data-airing-epoch], #liveScheduleList .release-ticker[data-airing-epoch]').forEach(function (row) {
      var epoch = Number(row.dataset.airingEpoch) || 0;
      var diff = Math.max(0, epoch - now);
      var d = Math.floor(diff / 86400);
      var h = Math.floor((diff % 86400) / 3600);
      var m = Math.floor((diff % 3600) / 60);
      var s = diff % 60;
      [['d', d], ['h', h], ['m', m], ['s', s]].forEach(function (pair) {
        var el = row.querySelector('[data-cd-' + pair[0] + ']');
        if (el) el.textContent = String(pair[1]).padStart(2, '0');
      });
      if (epoch && epoch <= now && row.dataset.countdownState === 'upcoming') {
        row.dataset.countdownState = 'aired_checking';
        var state = row.querySelector('[data-release-state]');
        if (state) state.textContent = 'Aired · checking provider';
      }
    });
  }

  async function refresh(force) {
    var now = Date.now();
    if (busy || (!force && now - lastRefresh < refreshMs)) return;
    if (document.hidden && !force) return;
    busy = true;
    lastRefresh = now;
    try {
      var response = await fetch(scheduleUrl, {
        headers: { 'Accept': 'application/json' },
        credentials: 'same-origin'
      });
      if (!response.ok) return;
      var data = await response.json();
      if (data.status === 'success') render(data.items, data.season || {});
    } catch (error) {
      /* Keep last provider-confirmed metadata visible during transient errors. */
    } finally {
      busy = false;
    }
  }

  setInterval(tick, 1000);
  setInterval(function () {
    if ((drawer && drawer.classList.contains('is-open')) || list) refresh(false);
  }, refreshMs);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden && ((drawer && drawer.classList.contains('is-open')) || list)) refresh(false);
  });
  tick();
})();
