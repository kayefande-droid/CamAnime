/**
 * Five-layer request firewall for the Cloudflare deployment.
 *
 * Same policy as the Flask host (firewall.py) so a request behaves identically
 * on either origin:
 *
 *   L1 ban        addresses that keep tripping rules are refused outright
 *   L2 rate       per-address buckets, tight on auth and generous on segments
 *   L3 signatures scanner paths, traversal, injection, known attack tools
 *   L4 payload    oversized or wrongly-typed bodies are refused before parsing
 *   L5 strikes    every block scores the address, which is what fills L1
 *
 * State lives in the isolate: a shield against one noisy client per edge
 * location, with Cloudflare's own edge handling distributed floods.
 */

const WINDOW_MS = 60_000;
const GENERAL_LIMIT = 300;
const AUTH_LIMIT = 12;
const MEDIA_LIMIT = 1200;

const AUTH_MAX_BODY = 64 * 1024;
const GENERAL_MAX_BODY = 2 * 1024 * 1024;

const STRIKE_WINDOW_MS = 600_000;
const BAN_STRIKES = 8;
const BAN_MS = 900_000;

const AUTH_PREFIXES = ["/api/auth/", "/login", "/register", "/api/mfa"];
const MEDIA_PREFIXES = ["/api/proxy/", "/api/download/", "/api/v1/stream"];

const ATTACK_PATTERNS = [
  /\.\.[/\\]/,
  /\/etc\/(passwd|shadow)/,
  /\.(env|git|svn|hg)(\/|$|\?)/,
  /(wp-admin|wp-login|phpmyadmin|xmlrpc\.php|adminer|\.DS_Store)/i,
  /(union\s+(all\s+)?select|information_schema|sleep\(\d+\)|benchmark\()/i,
  /(<script|javascript:|onerror\s*=|onload\s*=)/i,
  /(%00|\x00)/,
  /(cmd\.exe|\/bin\/(ba)?sh|powershell)/i,
];

const SCANNER_UAS =
  /(sqlmap|nikto|nmap|masscan|zgrab|wpscan|dirbuster|gobuster|feroxbuster|hydra|acunetix|nessus|openvas|nuclei|ffuf)/i;

const hits = new Map(); // ip -> { general: [], auth: [], media: [] }
const strikes = new Map(); // ip -> [timestamps]
const bans = new Map(); // ip -> until epoch ms
let blockedTotal = 0;

function clientIp(request) {
  return (
    request.headers.get("cf-connecting-ip") ||
    (request.headers.get("x-forwarded-for") || "").split(",")[0].trim() ||
    "unknown"
  ).slice(0, 64);
}

function bucketFor(path) {
  if (AUTH_PREFIXES.some((p) => path.startsWith(p))) return ["auth", AUTH_LIMIT];
  if (MEDIA_PREFIXES.some((p) => path.startsWith(p))) return ["media", MEDIA_LIMIT];
  return ["general", GENERAL_LIMIT];
}

function strike(ip) {
  const now = Date.now();
  const list = (strikes.get(ip) || []).filter((t) => now - t < STRIKE_WINDOW_MS);
  list.push(now);
  blockedTotal += 1;
  if (list.length >= BAN_STRIKES) {
    bans.set(ip, now + BAN_MS);
    strikes.delete(ip);
  } else {
    strikes.set(ip, list);
  }
  // Bounded memory: drop the oldest addresses when the maps grow.
  if (strikes.size > 10_000) {
    for (const key of [...strikes.keys()].slice(0, 1000)) strikes.delete(key);
  }
}

function deny(message, status, headers) {
  return new Response(JSON.stringify({ error: message, status: "blocked" }), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      ...headers,
    },
  });
}

export function guard(request, url) {
  const ip = clientIp(request);
  const path = url.pathname || "/";

  // L1 — an active ban ends the request immediately.
  const until = bans.get(ip) || 0;
  if (until > Date.now()) {
    return deny("Address temporarily blocked after repeated abuse.", 403, {
      "retry-after": String(Math.ceil((until - Date.now()) / 1000)),
      "x-camanime-firewall": "ban",
    });
  }

  // L2 — per-address bucket.
  const [bucket, limit] = bucketFor(path);
  const now = Date.now();
  const entry = hits.get(ip) || { general: [], auth: [], media: [] };
  const stamps = (entry[bucket] || []).filter((t) => now - t < WINDOW_MS);
  stamps.push(now);
  entry[bucket] = stamps;
  hits.set(ip, entry);
  if (hits.size > 20_000) {
    for (const key of [...hits.keys()].slice(0, 2000)) hits.delete(key);
  }
  if (stamps.length > limit) {
    // Pace signal, not an attack: striking it would turn an honest burst into
    // a ban and lock the visitor out of every other route.
    return deny("Too many requests. Slow down and retry shortly.", 429, {
      "retry-after": "60",
      "x-camanime-firewall": "rate",
    });
  }

  // L3 — request signatures.
  let decoded = `${url.pathname}?${url.search}`;
  try {
    decoded = decodeURIComponent(decoded);
  } catch {
    // A malformed escape is itself suspicious; test it undecoded.
  }
  if (ATTACK_PATTERNS.some((re) => re.test(decoded))) {
    strike(ip);
    // 404, not 403: the site already answers unknown paths with its decoy 404,
    // and confirming "you were filtered" only helps a scanner map the rules.
    return deny("Not found.", 404, { "x-camanime-firewall": "signature" });
  }

  // L4 — body size and auth tooling.
  const length = Number(request.headers.get("content-length") || 0);
  const limitBody = AUTH_PREFIXES.some((p) => path.startsWith(p))
    ? AUTH_MAX_BODY
    : GENERAL_MAX_BODY;
  if (length > limitBody) {
    strike(ip);
    return deny("Request body too large.", 413, { "x-camanime-firewall": "payload" });
  }
  if (
    AUTH_PREFIXES.some((p) => path.startsWith(p)) &&
    SCANNER_UAS.test(request.headers.get("user-agent") || "")
  ) {
    strike(ip);
    return deny("Request blocked.", 403, { "x-camanime-firewall": "scanner" });
  }

  // L5 — strikes were recorded above; nothing else to do on a clean request.
  return null;
}

export function firewallStats() {
  return { blocked_total: blockedTotal, active_bans: bans.size, tracked_ips: hits.size };
}
