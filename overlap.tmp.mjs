import { chromium } from 'playwright';
const b = await chromium.launch({ channel: 'chrome' });
const p = await b.newPage({ viewport: { width: 1440, height: 900 } });
await p.goto('http://127.0.0.1:3000/', { waitUntil: 'domcontentloaded', timeout: 90000 });
await p.waitForTimeout(1500);
const info = await p.evaluate(() => {
  const strip = document.querySelector('.stat-strip');
  const r = strip.getBoundingClientRect();
  const hits = [];
  document.querySelectorAll('p, h1, h2, h3, span, a').forEach(el => {
    if (el.closest('.stat-strip')) return;
    const t = (el.textContent || '').trim();
    if (!t || t.length < 4) return;
    const b = el.getBoundingClientRect();
    if (b.width < 2 || b.height < 2) return;
    const overlap = !(b.right < r.left || b.left > r.right || b.bottom < r.top || b.top > r.bottom);
    if (overlap) hits.push([t.slice(0, 40), el.tagName, Math.round(b.top), Math.round(b.bottom)]);
  });
  return { strip: [Math.round(r.top), Math.round(r.bottom), Math.round(r.left), Math.round(r.right)], hits: hits.slice(0, 8) };
});
console.log(JSON.stringify(info, null, 1));
await b.close();
