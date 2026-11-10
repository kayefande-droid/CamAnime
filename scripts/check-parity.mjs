#!/usr/bin/env node
/**
 * Milestone 5 — release parity gate.
 *
 * Both deployments share one /static tree, so they must serve the same asset
 * pins, advertise the same app version, hand out the same APK, answer the same
 * routes and link to the same pages. Anything that drifts here is a user seeing
 * a different site depending on which host answered.
 *
 * Exits 0 when the two hosts agree, 1 on any divergence, so it can gate a deploy.
 */
const HOSTS = {
  render: 'https://camanime.onrender.com',
  mirror: 'https://camanjme.camanime.workers.dev',
};

// Pages whose <head> assets are compared, and every route whose status is compared.
const PAGES = ['/', '/download', '/developers', '/schedule', '/scraper', '/login'];
const ROUTES = [...PAGES, '/library', '/promo', '/advert', '/anime/207329', '/watch/207329/1', '/owner-console'];

const PIN = /(?:href|src)="(\/static\/[^"]+\.(?:css|js))\?v=([^"]+)"/g;
const LINK = /href="(\/[^"#?]*)"/g;
const LOC = /<loc>\s*([^<\s]+)\s*<\/loc>/g;

async function attempt(url, { method = 'GET', timeout = 30000 } = {}) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeout);
  try {
    const res = await fetch(url, { method, redirect: 'follow', signal: controller.signal });
    const text = method === 'GET' ? await res.text() : '';
    return { status: res.status, url: res.url, text, headers: res.headers };
  } catch (error) {
    return { status: 0, url, text: '', headers: new Headers(), error: error.message };
  } finally {
    clearTimeout(timer);
  }
}

// One retry. A release gate must not fail because a single edge request hiccuped —
// the earlier run saw a transient 000 from the mirror and reported eight phantom
// divergences from it.
async function load(url, options = {}) {
  const first = await attempt(url, options);
  if (first.status === 0 || first.status >= 500) {
    await new Promise((resolve) => setTimeout(resolve, 1500));
    return attempt(url, options);
  }
  return first;
}

const pins = (html) => {
  const map = new Map();
  for (const m of html.matchAll(PIN)) map.set(m[1], m[2]);
  return map;
};
const links = (html) => new Set([...html.matchAll(LINK)].map((m) => m[1].replace(/\/$/, '') || '/'));
const version = (html) => {
  const m = html.match(/CamAnime\s+(\d+\.\d+\.\d+)\s*\(build\s*(\d+)\)/i);
  return m ? `${m[1]}/${m[2]}` : null;
};
const pathOf = (url) => {
  try { return new URL(url).pathname.replace(/\/$/, '') || '/'; } catch { return url; }
};

const problems = [];
const report = {};

for (const [host, base] of Object.entries(HOSTS)) {
  const entry = { pages: {}, routes: {}, inventory: new Set(), sitemap: null, apk: null, version: new Set() };

  for (const path of PAGES) {
    const page = await load(base + path);
    if (page.status !== 200) problems.push(`${host} ${path} -> HTTP ${page.status}${page.error ? ` (${page.error})` : ''}`);
    entry.pages[path] = { status: page.status, pins: pins(page.text), links: links(page.text) };
    for (const l of entry.pages[path].links) entry.inventory.add(l);
    const v = version(page.text);
    if (v) entry.version.add(v);
  }

  for (const path of ROUTES) {
    const res = await load(base + path, { method: 'HEAD' });
    entry.routes[path] = res.status;
    if (res.status >= 500) problems.push(`${host} ${path} -> HTTP ${res.status}`);
  }

  const sitemap = await load(base + '/sitemap.xml');
  if (sitemap.status === 200) {
    const urls = [...sitemap.text.matchAll(LOC)].map((m) => pathOf(m[1]));
    entry.sitemap = new Set(urls);
    for (const u of urls) entry.inventory.add(u);
    report.sitemapCounts = { ...(report.sitemapCounts || {}), [host]: urls.length };
  } else {
    entry.sitemap = null;
    report.sitemapCounts = { ...(report.sitemapCounts || {}), [host]: `HTTP ${sitemap.status}` };
  }

  const apk = await load(base + '/get/android', { method: 'HEAD' });
  entry.apk = apk.headers.get('content-length');
  if (apk.status !== 200) problems.push(`${host} /get/android -> HTTP ${apk.status}`);

  report[host] = entry;
}

// Pages both hosts actually serve. Comparing the <head> of a 404 page tells you
// nothing, so those are reported as status divergences instead.
const comparablePages = PAGES.filter(
  (path) => report.render.pages[path].status === 200 && report.mirror.pages[path].status === 200,
);

// 1. Asset pins must match, per page.
for (const path of comparablePages) {
  const a = report.render.pages[path].pins;
  const b = report.mirror.pages[path].pins;
  for (const [asset, ver] of a) {
    if (!b.has(asset)) problems.push(`${path}: mirror does not load ${asset}`);
    else if (b.get(asset) !== ver) problems.push(`${path}: ${asset} is ${ver} on render, ${b.get(asset)} on mirror`);
  }
  for (const asset of b.keys()) if (!a.has(asset)) problems.push(`${path}: render does not load ${asset}`);
}

// 2. One advertised version.
const versions = new Set([...report.render.version, ...report.mirror.version]);
if (versions.size > 1) problems.push(`version differs: ${[...versions].join(' vs ')}`);

// 3. Same APK.
if (report.render.apk && report.mirror.apk && report.render.apk !== report.mirror.apk) {
  problems.push(`APK size differs: ${report.render.apk} vs ${report.mirror.apk}`);
}

// 4. Same routes, same answers.
for (const path of ROUTES) {
  const a = report.render.routes[path];
  const b = report.mirror.routes[path];
  if (a !== b) problems.push(`${path}: render HTTP ${a}, mirror HTTP ${b}`);
}

// 5. Same page inventory (nav links across pages, plus sitemap entries).
for (const path of report.render.inventory) {
  if (!report.mirror.inventory.has(path)) problems.push(`inventory: mirror never links to ${path}`);
}
for (const path of report.mirror.inventory) {
  if (!report.render.inventory.has(path)) problems.push(`inventory: render never links to ${path}`);
}
if (report.render.sitemap && report.mirror.sitemap) {
  for (const u of report.render.sitemap) if (!report.mirror.sitemap.has(u)) problems.push(`sitemap: mirror is missing ${u}`);
  for (const u of report.mirror.sitemap) if (!report.render.sitemap.has(u)) problems.push(`sitemap: render is missing ${u}`);
}

const pinCounts = comparablePages.map((p) => `${p}=${report.render.pages[p].pins.size}/${report.mirror.pages[p].pins.size}`);
console.log(`pages fetched: ${PAGES.length}; comparable on both hosts: ${comparablePages.length}`);
console.log(`pins render/mirror: ${pinCounts.join(', ')}`);
console.log(`routes compared: ${ROUTES.length}`);
console.log(`inventory: render ${report.render.inventory.size} paths, mirror ${report.mirror.inventory.size} paths`);
console.log(`sitemap: render ${report.sitemapCounts?.render ?? 'n/a'}, mirror ${report.sitemapCounts?.mirror ?? 'n/a'}`);
console.log(`version: ${[...versions].join(', ') || 'none parsed'}`);
console.log(`APK bytes: render=${report.render.apk} mirror=${report.mirror.apk}`);

if (problems.length) {
  console.log(`\n${problems.length} parity problem(s):`);
  for (const p of problems) console.log(' - ' + p);
  process.exit(1);
}
console.log('\nparity OK: pins, version, APK, routes and page inventory agree');
