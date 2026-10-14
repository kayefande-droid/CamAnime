/* CamAnime community widget: comments, replies, likes, stickers, ratings, notifications */
(function () {
  function sec() { return document.getElementById('ca-community'); }
  async function load() {
    const s = sec(); if (!s) return;
    const { anime, ep } = s.dataset;
    try {
      const r = await fetch(`/api/community/comments?anime_id=${encodeURIComponent(anime)}&ep=${encodeURIComponent(ep || '')}`);
      const d = await r.json();
      const box = document.getElementById('ca-comments');
      const stickers = document.getElementById('ca-sticker-row');
      stickers.innerHTML = (d.stickers || []).map(x => `<button type="button" data-st="${x}" style="font-size:1.2rem;background:#141926;border:1px solid rgba(255,255,255,.12);border-radius:8px;padding:.2rem .5rem;cursor:pointer">${x}</button>`).join('');
      stickers.querySelectorAll('[data-st]').forEach(b => b.onclick = () => post('', '', b.dataset.st));
      const top = d.comments.filter(c => !c.parent), kids = {};
      d.comments.forEach(c => { if (c.parent) (kids[c.parent] = kids[c.parent] || []).push(c); });
      box.innerHTML = top.slice(-30).map(c => card(c, kids[c.id] || [])).join('') || '<p style="color:#64708a">No comments yet — start the forum.</p>';
      box.querySelectorAll('[data-like]').forEach(b => b.onclick = async () => {
        const rr = await fetch(`/api/community/like/${b.dataset.like}`, { method: 'POST' });
        if (rr.status === 401) { location.href = '/login?next=' + encodeURIComponent(location.pathname); return; }
        load();
      });
      box.querySelectorAll('[data-reply]').forEach(b => b.onclick = () => {
        const t = prompt('Reply to ' + b.dataset.who + ':');
        if (t) post(t, b.dataset.reply, '');
      });
    } catch (e) {}
  }
  function card(c, replies) {
    return `<div style="background:#141926;border:1px solid rgba(255,255,255,.08);border-radius:10px;padding:.6rem .75rem">
      <div style="font-size:.8rem;color:#FFB347"><strong>${esc(c.user)}</strong> <span style="color:#64708a">• ${new Date(c.t * 1000).toLocaleString()}</span></div>
      <div style="font-size:.92rem">${c.sticker ? `<span style="font-size:1.3rem">${c.sticker}</span> ` : ''}${esc(c.text)}</div>
      <div style="display:flex;gap:.6rem;font-size:.78rem;color:#a0abc0;margin-top:.3rem">
        <button data-like="${c.id}" style="background:none;border:none;color:#a0abc0;cursor:pointer">♥ ${c.likes || 0}</button>
        <button data-reply="${c.id}" data-who="${esc(c.user)}" style="background:none;border:none;color:#a0abc0;cursor:pointer">Reply</button>
      </div>
      ${replies.map(r => `<div style="margin:.4rem 0 0 1rem;border-left:2px solid rgba(255,179,71,.4);padding-left:.6rem">${card(r, [])}</div>`).join('')}
    </div>`;
  }
  function esc(s) { return (s || '').replace(/[&<>"]/g, m => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m])); }
  async function post(text, parent, sticker) {
    const s = sec();
    const fd = new FormData();
    fd.append('anime_id', s.dataset.anime); fd.append('ep', s.dataset.ep || '');
    fd.append('text', text || document.getElementById('ca-comment-text').value);
    fd.append('parent', parent || ''); fd.append('sticker', sticker || '');
    const r = await fetch('/api/community/comment', { method: 'POST', body: fd });
    if (r.status === 401) { location.href = '/login?next=' + encodeURIComponent(location.pathname); return; }
    document.getElementById('ca-comment-text').value = '';
    load();
  }
  document.addEventListener('DOMContentLoaded', () => {
    load();
    const f = document.getElementById('ca-comment-form');
    if (f) f.onsubmit = (e) => { e.preventDefault(); post('', '', ''); };
    document.querySelectorAll('.ca-rate-btn').forEach(b => b.onclick = async () => {
      const s = sec(); const fd = new FormData();
      fd.append('anime_id', s.dataset.anime); fd.append('score', b.dataset.score);
      const r = await fetch('/api/community/rate', { method: 'POST', body: fd });
      if (r.status === 401) { location.href = '/login?next=' + encodeURIComponent(location.pathname); return; }
      const d = await r.json();
      document.getElementById('ca-rating-out').textContent = `Avg ${d.rating.avg}/10 from ${d.rating.count} honest ratings`;
    });
  });
})();
