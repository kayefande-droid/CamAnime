/* CamAnime community widget: guest comments/ratings, likes, stickers, theme switch */
(function () {
  function sec() { return document.getElementById('ca-community'); }
  function msg(t, bad) {
    var el = document.getElementById('ca-form-msg');
    if (!el) return;
    el.textContent = t || '';
    el.classList.toggle('bad', !!bad);
  }
  async function load() {
    var s = sec(); if (!s) return;
    var anime = s.dataset.anime, ep = s.dataset.ep;
    try {
      var r = await fetch('/api/community/comments?anime_id=' + encodeURIComponent(anime) + '&ep=' + encodeURIComponent(ep || ''), { credentials: 'same-origin' });
      var d = await r.json();
      var box = document.getElementById('ca-comments');
      var stickers = document.getElementById('ca-sticker-row');
      stickers.innerHTML = (d.stickers || []).map(function (x) { return '<button type="button" data-st="' + x + '">' + x + '</button>'; }).join('');
      stickers.querySelectorAll('[data-st]').forEach(function (b) { b.onclick = function () { post('', '', b.dataset.st); }; });
      var top = d.comments.filter(function (c) { return !c.parent; }), kids = {};
      d.comments.forEach(function (c) { if (c.parent) (kids[c.parent] = kids[c.parent] || []).push(c); });
      box.innerHTML = top.slice(-30).map(function (c) { return card(c, kids[c.id] || []); }).join('') || '<p class="ca-empty">No comments yet — start the forum.</p>';
      box.querySelectorAll('[data-like]').forEach(function (b) {
        b.onclick = async function () {
          try {
            var rr = await fetch('/api/community/like/' + b.dataset.like, { method: 'POST', credentials: 'same-origin' });
            if (!rr.ok) { msg('Like failed — try again.', true); return; }
          } catch (e) { msg('Like failed — check connection.', true); return; }
          load();
        };
      });
      box.querySelectorAll('[data-reply]').forEach(function (b) {
        b.onclick = function () {
          var t = prompt('Reply to ' + b.dataset.who + ':');
          if (t) post(t, b.dataset.reply, '');
        };
      });
    } catch (e) {}
  }
  function card(c, replies) {
    return '<div class="ca-card"><div class="ca-card-head"><strong>' + esc(c.user) + '</strong><span> • ' + new Date(c.t * 1000).toLocaleString() + '</span></div>'
      + '<div class="ca-card-body">' + (c.sticker ? '<span class="ca-sticker">' + c.sticker + '</span> ' : '') + esc(c.text) + '</div>'
      + '<div class="ca-card-actions"><button data-like="' + c.id + '">♥ ' + (c.likes || 0) + '</button>'
      + '<button data-reply="' + c.id + '" data-who="' + esc(c.user) + '">Reply</button></div>'
      + replies.map(function (x) { return '<div class="ca-reply">' + card(x, []) + '</div>'; }).join('') + '</div>';
  }
  function esc(s) { return (s || '').replace(/[&<>"]/g, function (m) { return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]); }); }
  function guestName() {
    var el = document.getElementById('ca-guest-name');
    var v = (el && el.value || '').trim();
    try { if (v) localStorage.setItem('camanime-guest', v.slice(0, 24)); } catch (e) {}
    return v;
  }
  async function post(text, parent, sticker) {
    var s = sec(); if (!s) return;
    var input = document.getElementById('ca-comment-text');
    var body = text || (input && input.value || '');
    if (!body.trim() && !sticker) { msg('Write something or tap a sticker.', true); return; }
    var fd = new FormData();
    fd.append('anime_id', s.dataset.anime); fd.append('ep', s.dataset.ep || '');
    fd.append('text', body); fd.append('parent', parent || ''); fd.append('sticker', sticker || '');
    fd.append('name', guestName());
    msg('Posting…');
    try {
      var r = await fetch('/api/community/comment', { method: 'POST', body: fd, credentials: 'same-origin' });
      var d = await r.json().catch(function () { return {}; });
      if (!r.ok || d.status !== 'success') { msg('Failed: ' + (d.error || r.status), true); return; }
      if (input) input.value = '';
      msg(d.guest ? 'Posted as guest — nice!' : 'Posted!');
    } catch (e) { msg('Post failed — check connection.', true); return; }
    load();
  }
  document.addEventListener('DOMContentLoaded', function () {
    try {
      var saved = localStorage.getItem('camanime-guest');
      if (saved && document.getElementById('ca-guest-name')) document.getElementById('ca-guest-name').value = saved;
    } catch (e) {}
    load();
    var f = document.getElementById('ca-comment-form');
    if (f) f.onsubmit = function (e) { e.preventDefault(); post('', '', ''); };
    document.querySelectorAll('.ca-rate-btn').forEach(function (b) {
      b.onclick = async function () {
        var s = sec(); if (!s) return;
        var fd = new FormData();
        fd.append('anime_id', s.dataset.anime); fd.append('score', b.dataset.score);
        fd.append('name', guestName());
        var out = document.getElementById('ca-rating-out');
        out.textContent = 'Saving rating…';
        try {
          var r = await fetch('/api/community/rate', { method: 'POST', body: fd, credentials: 'same-origin' });
          var d = await r.json().catch(function () { return {}; });
          if (!r.ok || d.status !== 'success') { out.textContent = 'Rating failed: ' + (d.error || r.status); return; }
          out.textContent = 'Avg ' + d.rating.avg + '/10 from ' + d.rating.count + ' honest ratings' + (d.guest ? ' (guest vote counted)' : '');
        } catch (e) { out.textContent = 'Rating failed — check connection.'; }
      };
    });
    document.querySelectorAll('.ca-theme-btn').forEach(function (b) {
      b.onclick = function () {
        if (window.caSetTheme) window.caSetTheme(b.dataset.themeName);
        else document.documentElement.setAttribute('data-theme', b.dataset.themeName);
        document.querySelectorAll('.ca-theme-btn').forEach(function (x) { x.classList.toggle('active', x === b); });
      };
      var cur = null;
      try { cur = localStorage.getItem('camanime-theme') || 'midnight'; } catch (e) {}
      if ((cur || 'midnight') === b.dataset.themeName) b.classList.add('active');
    });
  });
})();
