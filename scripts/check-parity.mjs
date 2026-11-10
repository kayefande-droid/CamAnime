/* Asserts both deployments serve the same thing: identical asset pins, the same
   advertised app version, the same APK size, and the same page inventory.
   Exits non-zero on any mismatch so it can gate a deploy. */
const HOSTS = {
  render: 'https://camanime.onrender.com',
  mirror: 'https://camanjme.camanime.workers.dev',
};
const PAGES = ['/', '/download', '/developers', '/watch/207329/1', '/anime/207329'];
const PIN = /(?:href|src)="(\/static\/[^"]+\.(?:css|js))\?v=([^"]+)"/g;

async function get(url, method = 'GET') {
  const res = await fetch(url, { method, redirect: 'follow' });
  return { status: res.status, text: method === 'GET' ? await res.text() : '', headers: res.headers };
}

function pins(html) {
  const out = new Map();
  for (const m of html.matchAll(PIN)) out.set(m[1], m[2]);
  return out;
}

function version(html) {
  const m = html.match(/CamAnime\s+(\d+\.\d+\.\d+)\s*\(build\s*(\d+)\)/i);
  return m ? `${m[1]}/${m[2]}` : null;
}

const problems = [];
const seen = {};

for (const [host, base] of Object.entries(HOSTS)) {
  seen[host] = {};
  for (const path of PAGES) {
    try {
      const page = await get(base + path);
      if (page.status !== 200) problems.push(`${host} ${path} -> HTTP ${page.status}`);
      seen[host][path] = { pins: pins(page.text), version: version(page.text) };
    } catch (e) {
      problems.push(`${host} ${path} -> ${e.message}`);
    }
  }
  try {
    const apk = await get(base + '/get/android', 'HEAD');
    seen[host].apk = apk.headers.get('content-length');
    if (apk.status !== 200) problems.push(`${host} APK HEAD -> HTTP ${apk.status}`);
  } catch (e) {
    problems.push(`${host} APK HEAD -> ${e.message}`);
  }
}

// Pins must match across hosts for every shared page.
for (const path of PAGES) {
  const a = seen.render[path], b = seen.mirror[path];
  if (!a || !b) continue;
  for (const [asset, ver] of a.pins) {
    if (!b.pins.has(asset)) problems.push(`${path}: mirror is missing ${asset}`);
    else if (b.pins.get(asset) !== ver) problems.push(`${path}: ${asset} pin ${ver} vs ${b.pins.get(asset)}`);
  }
  for (const asset of b.pins.keys()) {
    if (!a.pins.has(asset)) problems.push(`${path}: render is missing ${asset}`);
  }
}

// Advertised version must agree wherever it is printed.
const versions = new Set();
for (const path of ['/download', '/']) {
  for (const host of Object.keys(HOSTS)) {
    const v = seen[host]?.[path]?.version;
    if (v) versions.add(v);
  }
}
if (versions.size > 1) problems.push(`version mismatch across hosts: ${[...versions].join(' vs ')}`);

const apkSizes = new Set([seen.render?.apk, seen.mirror?.apk].filter(Boolean));
if (apkSizes.size > 1) problems.push(`APK size differs: ${[...apkSizes].join(' vs ')}`);

const assetCount = new Set(PAGES.map((p) => seen.render[p]?.pins.size));
console.log(`pages checked: ${PAGES.length} per host`);
console.log(`asset pins per page: ${[...assetCount].join(', ')}`);
console.log(`versions seen: ${[...versions].join(', ') || 'none parsed'}`);
console.log(`APK bytes: render=${seen.render?.apk} mirror=${seen.mirror?.apk}`);

if (problems.length) {
  console.log(`\n${problems.length} parity problem(s):`);
  for (const p of problems) console.log(' - ' + p);
  process.exit(1);
}
console.log('\nparity OK: pins, version and APK agree on both hosts');
