  /* Live current-season schedule refresh: metadata only, bounded to every 15 minutes. */
(function () {
  'use strict';
  var list = document.getElementById('releaseTickerList');
  if (!list) return;

  var refreshMs = 15 * 60 * 1000;
  var busy = false;
  // The page already includes server-rendered schedule metadata. Do not issue
  // an identical request on load; refresh only after the local cache interval.
  var lastRefresh = Date.now();

  function escapeHtml(value) {
    return String(value == null ? '' : value).replace(/[&<>"']/g, function (c) {
      return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c];
    });
  }

  function render(items, season) {
    list.dataset.season = (season.name || '') + ' ' + (season.year || '');
    if (!Array.isArray(items) || !items.length) {
      list.innerHTML = '<p class="schedule-empty">No current-season air dates are listed by AniList right now. Refresh later for updates.</p>';
      return;
    }
    list.innerHTML = items.map(function (item) {
      var airing = item.next_airing_episode || {};
      var epoch = Number(airing.airing_at) || 0;
      var episode = airing.episode == null ? '' : airing.episode;
      var isUpcoming = epoch > Math.floor(Date.now() / 1000);
      var id = escapeHtml(item.id);
      var providerLink = item.official_episode_link;
      var providerUrl = providerLink && providerLink.url;
      var safeProviderUrl = '';
      try {
        var parsedProviderUrl = new URL(providerUrl, window.location.origin);
        if ((parsedProviderUrl.protocol === 'http:' || parsedProviderUrl.protocol === 'https:') &&
            !parsedProviderUrl.username && !parsedProviderUrl.password) {
          safeProviderUrl = parsedProviderUrl.href;
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
      return '<div class="release-ticker" data-anime-id="' + id + '" data-airing-epoch="' + epoch + '" data-airing-episode="' + escapeHtml(episode) + '" data-countdown-state="' + (epoch ? (isUpcoming ? 'upcoming' : 'aired_checking') : 'date_unknown') + '">' +
        '<div><div class="rt-title">' + escapeHtml(item.title || 'Untitled anime') + '</div><div class="rt-sub">Episode ' + escapeHtml(episode || '?') + ' · airs ' + when + ' · ' + escapeHtml(season.name || '') + ' ' + escapeHtml(season.year || '') + '</div></div>' +
        '<div class="countdown-chips" data-cd-for="' + id + '">' + countdown + '</div></div>';
    }).join('');
    tick();
  }

  function tick() {
    var now = Math.floor(Date.now() / 1000);
    list.querySelectorAll('.release-ticker[data-airing-epoch]').forEach(function (row) {
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
      var response = await fetch(list.dataset.scheduleUrl || '/api/v1/schedule', {
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
  setInterval(function () { refresh(false); }, refreshMs);
  document.addEventListener('visibilitychange', function () {
    if (!document.hidden) refresh(false);
  });
  tick();
})();
