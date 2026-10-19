/* Browser-local release reminders. No server database, push service, or third-party SDK. */
(function () {
  'use strict';
  var STORAGE_KEY = 'camanime_release_follows';
  var buttons = Array.prototype.slice.call(document.querySelectorAll('.release-follow-toggle'));
  if (!buttons.length) return;

  function readFollows() {
    try {
      var value = JSON.parse(localStorage.getItem(STORAGE_KEY) || '[]');
      return Array.isArray(value) ? value.filter(function (item) {
        return item && Number.isInteger(Number(item.id));
      }) : [];
    } catch (error) { return []; }
  }

  function writeFollows(follows) {
    try {
      localStorage.setItem(STORAGE_KEY, JSON.stringify(follows.slice(0, 100)));
      return true;
    } catch (error) { return false; }
  }

  function announce(button, message) {
    var live = document.getElementById('releaseReminderStatus');
    if (!live) {
      live = document.createElement('p');
      live.id = 'releaseReminderStatus';
      live.className = 'release-reminder-status';
      live.setAttribute('role', 'status');
      live.setAttribute('aria-live', 'polite');
      var parent = button.parentNode;
      if (parent) parent.appendChild(live);
    }
    live.textContent = message;
  }

  function labelButton(button, active) {
    var span = button.querySelector('span');
    if (span) span.textContent = active ? 'Release reminder saved' : 'Remind me about releases';
    button.setAttribute('aria-pressed', String(active));
  }

  function updateButtons() {
    var follows = readFollows();
    buttons.forEach(function (button) {
      var active = follows.some(function (item) { return Number(item.id) === Number(button.dataset.animeId); });
      labelButton(button, active);
    });
  }

  function notificationPermission() {
    return ('Notification' in window) ? window.Notification.permission : 'unsupported';
  }

  function requestNotificationPermission() {
    if (!('Notification' in window) || !window.Notification.requestPermission) return Promise.resolve('unsupported');
    return window.Notification.requestPermission();
  }

  function checkDueReminders() {
    var follows = readFollows();
    var now = Math.floor(Date.now() / 1000);
    var changed = false;
    follows.forEach(function (item) {
      if (item.notified || Number(item.airingAt) > now) return;
      if (notificationPermission() === 'granted') {
        var notification;
        try { notification = new window.Notification('Release reminder', {
          body: (item.title || 'Your followed anime') + (item.episode ? ' · Episode ' + item.episode : '') + ' is scheduled to air. Provider availability is not verified.',
          tag: 'camanime-release-' + item.id,
          data: { url: '/anime/' + encodeURIComponent(item.id) }
        }); } catch (error) { return; }
        item.notified = true;
        changed = true;
        notification.onclick = function () {
          window.focus();
          window.location.href = notification.data.url;
        };
      }
    });
    if (changed) writeFollows(follows);
  }

  buttons.forEach(function (button) {
    button.addEventListener('click', async function () {
      var id = Number(button.dataset.animeId);
      var follows = readFollows();
      var existing = follows.some(function (item) { return Number(item.id) === id; });
      if (existing) {
        follows = follows.filter(function (item) { return Number(item.id) !== id; });
        if (writeFollows(follows)) {
          labelButton(button, false);
          announce(button, 'Release reminder removed from this browser.');
        } else announce(button, 'Could not update browser storage. Check your browser settings.');
        return;
      }

      var permission = notificationPermission();
      if (permission === 'default' && window.isSecureContext) {
        try { permission = await requestNotificationPermission(); } catch (error) { permission = 'denied'; }
      }
      if (permission === 'default' || permission === 'unsupported') {
        announce(button, 'This browser does not support notifications. The release reminder was not saved.');
        return;
      }
      follows.unshift({
        id: id,
        title: button.dataset.animeTitle || 'Anime release',
        episode: button.dataset.airingEpisode || '',
        airingAt: Number(button.dataset.airingEpoch) || 0,
        notified: false
      });
      if (writeFollows(follows)) {
        labelButton(button, true);
        announce(button, permission === 'granted'
          ? 'Reminder saved in this browser. A notification can appear while this site is open; push notifications are not supported.'
          : 'Reminder saved in this browser, but notifications are blocked. No notification will be shown.');
      } else {
        announce(button, 'Could not save the reminder. Check browser storage settings.');
      }
    });
  });

  window.addEventListener('storage', function (event) {
    if (event.key === STORAGE_KEY) updateButtons();
  });
  updateButtons();
  checkDueReminders();
  window.setInterval(checkDueReminders, 30000);
})();
