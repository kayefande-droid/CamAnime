/**
 * App lifecycle API tests, run against the REAL schema in an in-memory SQLite
 * database through a small D1-shaped adapter. This exercises the actual SQL
 * (ON CONFLICT clauses, indexes, defaults) rather than a hand-written fake.
 */
import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { DatabaseSync } from "node:sqlite";

import {
  updateManifest,
  getConfig,
  putConfig,
  registerDevice,
  unregisterDevice,
  sendNotification,
  notificationHistory,
  publishRelease,
  listReleases,
  usageSummary,
  versionInfo,
  mergeConfig,
  DEFAULT_CONFIG,
  buildDigestItems,
  digestMessage,
  digestConfig,
  hourlyDigest,
  DIGEST_DEFAULTS,
  route as appRoute,
} from "../src/appapi.js";
import { LATEST_BUILD, LATEST_VERSION } from "../src/release.js";

const here = dirname(fileURLToPath(import.meta.url));
const schema = readFileSync(resolve(here, "../schema.sql"), "utf8");

/** Wrap node:sqlite in the tiny subset of the D1 API the worker uses. */
function makeEnv() {
  const sqlite = new DatabaseSync(":memory:");
  sqlite.exec(schema);
  const now = Date.now();
  sqlite
    .prepare("INSERT INTO users (email,name,pw,role,avatar,created) VALUES (?,?,?,?,?,?)")
    .run("admin@example.com", "Admin", "x", "admin", "", Math.floor(now / 1000));
  sqlite
    .prepare("INSERT INTO tokens (token,email,created,expires) VALUES (?,?,?,?)")
    .run("admin-token", "admin@example.com", now, now + 86400000);

  const DB = {
    prepare(sql) {
      const stmt = sqlite.prepare(sql);
      let args = [];
      const api = {
        bind(...next) {
          args = next;
          return api;
        },
        async first() {
          const row = stmt.get(...args);
          return row ? { ...row } : null;
        },
        async all() {
          return { results: stmt.all(...args).map((r) => ({ ...r })) };
        },
        async run() {
          const info = stmt.run(...args);
          return { success: true, meta: { changes: Number(info.changes || 0) } };
        },
      };
      return api;
    },
  };
  return { DB, sqlite, env: { DB } };
}

const adminReq = (path, init = {}) =>
  new Request(`https://camanime.test${path}`, {
    ...init,
    headers: { cookie: "ca_session=admin-token", "content-type": "application/json", ...(init.headers || {}) },
  });

const anonReq = (path, init = {}) =>
  new Request(`https://camanime.test${path}`, {
    ...init,
    headers: { "content-type": "application/json", ...(init.headers || {}) },
  });

test("the router resolves /api/v1 paths from the /api/v1 prefix, not from p1", async () => {
  const { env } = makeEnv();
  const url = new URL("https://camanime.test/api/v1/releases/publish");
  const res = await appRoute(
    env,
    adminReq(url.pathname, {
      method: "POST",
      body: JSON.stringify({ version: "2.13.0", build: 24 }),
    }),
    url,
    ["api", "v1", "releases", "publish"],
  );
  assert.ok(res, "publish must be matched when the path is /api/v1/releases/publish");
  assert.equal(res.status, 200);

  const listUrl = new URL("https://camanime.test/api/v1/releases");
  const listRes = await appRoute(env, anonReq(listUrl.pathname), listUrl, ["api", "v1", "releases"]);
  assert.equal((await listRes.json()).releases.length, 1);

  const unrelated = new URL("https://camanime.test/api/v1/stream/1/1");
  assert.equal(await appRoute(env, anonReq(unrelated.pathname), unrelated, ["api", "v1", "stream", "1", "1"]), null);
});

test("/api/v1/app/version answers the app's version shape with no D1 access", async () => {
  const body = await (await versionInfo(new URL("https://camanime.test/api/v1/app/version"))).json();
  assert.equal(body.api, "camanime-version");
  assert.equal(body.app_version, LATEST_VERSION);
  assert.equal(body.version_code, LATEST_BUILD);
  assert.match(body.sha256, /^[0-9a-f]{64}$/);
  assert.equal(body.apk_url, "https://camanime.test/get/android");
});

test("the update manifest answers with the built-in release when D1 has none", async () => {
  const { env } = makeEnv();
  const url = new URL(`https://camanime.test/api/v1/app/update?build=${LATEST_BUILD - 1}`);
  const body = await (await updateManifest(env, anonReq(url.pathname + url.search), url)).json();

  assert.equal(body.version_name, LATEST_VERSION);
  assert.equal(body.version_code, LATEST_BUILD);
  assert.equal(body.update_available, true);
  assert.equal(body.update_required, false);
  assert.equal(body.apk_url, "https://camanime.test/get/android");
  assert.match(body.notes.length > 0 ? "ok" : "", /ok/);
});

test("an obsolete build is marked update_required, a current one is not", async () => {
  const { env } = makeEnv();
  const oldUrl = new URL("https://camanime.test/api/v1/app/update?build=10");
  const old = await (await updateManifest(env, anonReq(oldUrl.pathname + oldUrl.search), oldUrl)).json();
  assert.equal(old.update_required, true);

  const curUrl = new URL(`https://camanime.test/api/v1/app/update?build=${LATEST_BUILD}`);
  const cur = await (await updateManifest(env, anonReq(curUrl.pathname + curUrl.search), curUrl)).json();
  assert.equal(cur.update_available, false);
  assert.equal(cur.update_required, false);
});

test("publishing a release requires admin and feeds the manifest", async () => {
  const { env } = makeEnv();
  const denied = await publishRelease(env, anonReq("/api/v1/releases/publish", {
    method: "POST",
    body: JSON.stringify({ version: "2.12.0", build: 23 }),
  }));
  assert.equal(denied.status, 403);

  const badHash = await publishRelease(env, adminReq("/api/v1/releases/publish", {
    method: "POST",
    body: JSON.stringify({ version: "2.12.0", build: 23, sha256: "nothex" }),
  }));
  assert.equal(badHash.status, 400);

  const ok = await publishRelease(env, adminReq("/api/v1/releases/publish", {
    method: "POST",
    body: JSON.stringify({
      version: "2.12.0",
      build: 23,
      mandatory: true,
      sha256: "a".repeat(64),
      notes: "New player",
    }),
  }));
  assert.equal(ok.status, 200);

  const url = new URL("https://camanime.test/api/v1/app/update?build=22");
  const manifest = await (await updateManifest(env, anonReq(url.pathname + url.search), url)).json();
  assert.equal(manifest.version_name, "2.12.0");
  assert.equal(manifest.version_code, 23);
  assert.equal(manifest.mandatory, true);
  assert.equal(manifest.sha256, "a".repeat(64));
  assert.equal(manifest.update_available, true);

  const list = await (await listReleases(env, anonReq("/api/v1/releases"), new URL("https://camanime.test/api/v1/releases"))).json();
  assert.equal(list.releases.length, 1);
});

test("remote config merges stored values over safe defaults and ignores unknown keys", async () => {
  const { env, sqlite } = makeEnv();

  const fresh = await (await getConfig(env)).json();
  assert.equal(fresh.source, "defaults");
  assert.equal(fresh.config.maintenance.enabled, false);
  assert.equal(fresh.config.features.streaming, true);

  const merged = mergeConfig(DEFAULT_CONFIG, {
    maintenance: { enabled: true, message: "Back at 20:00" },
    evil_key: "ignored",
    features: { downloads: false },
  });
  assert.equal(merged.maintenance.enabled, true);
  assert.equal(merged.features.downloads, false);
  assert.equal(merged.features.streaming, true);
  assert.equal("evil_key" in merged, false);

  const denied = await putConfig(env, anonReq("/api/v1/app/config", { method: "PUT", body: "{}" }));
  assert.equal(denied.status, 403);

  const saved = await putConfig(env, adminReq("/api/v1/app/config", {
    method: "PUT",
    body: JSON.stringify({ config: { maintenance: { enabled: true, message: "scheduled" } } }),
  }));
  assert.equal(saved.status, 200);

  const row = sqlite.prepare("SELECT COUNT(*) n FROM remote_config").get();
  assert.equal(Number(row.n), 1);

  const after = await (await getConfig(env)).json();
  assert.equal(after.source, "remote");
  assert.equal(after.config.maintenance.enabled, true);
  assert.equal(after.config.maintenance.message, "scheduled");
  assert.equal(after.config.features.streaming, true, "untouched defaults survive");
});

test("device registration validates the install id and upserts one row", async () => {
  const { env } = makeEnv();

  const bad = await registerDevice(env, anonReq("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({ install_id: "short" }),
  }));
  assert.equal(bad.status, 400);

  const body = JSON.stringify({
    install_id: "install-abc12345",
    token: "fcm-token-1",
    app_version: "2.11.0",
    app_build: 22,
    android_version: "14",
    language: "en",
    topics: ["all", "new_episodes", "bogus"],
  });
  const first = await (await registerDevice(env, anonReq("/api/v1/devices/register", { method: "POST", body }))).json();
  assert.equal(first.ok, true);
  assert.deepEqual(first.topics, ["all", "new_episodes"], "unknown topics are dropped");
  assert.equal(first.push_configured, false);

  await registerDevice(env, anonReq("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({ install_id: "install-abc12345", token: "fcm-token-2", app_build: 22 }),
  }));

  const rows = await env.DB.prepare("SELECT install_id, token FROM devices").all();
  assert.equal(rows.results.length, 1, "the install id is the primary key");
  assert.equal(rows.results[0].token, "fcm-token-2");
});

test("sending needs an admin session and records an unconfigured send", async () => {
  const { env } = makeEnv();
  await registerDevice(env, anonReq("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({ install_id: "install-abc12345", token: "fcm-1", topics: ["all"] }),
  }));

  const denied = await sendNotification(env, anonReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "Hi", body: "There" }),
  }));
  assert.equal(denied.status, 403);

  const missing = await sendNotification(env, adminReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "", body: "" }),
  }));
  assert.equal(missing.status, 400);

  const res = await sendNotification(env, adminReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "Episode 1100 is out", body: "Watch now", category: "new_episodes" }),
  }));
  assert.equal(res.status, 200);
  const out = await res.json();
  assert.equal(out.audience, 1);
  assert.equal(out.sent, 0);
  assert.equal(out.configured, false);
  assert.equal(out.status, "not_configured");
  assert.match(out.reason, /FCM/i);

  const hist = await (await notificationHistory(env, adminReq("/api/v1/notifications/history"))).json();
  assert.equal(hist.history.length, 1);
  assert.equal(hist.history[0].title, "Episode 1100 is out");
});

test("topic targeting only reaches devices that opted in", async () => {
  const { env } = makeEnv();
  const reg = (id, topics) =>
    registerDevice(env, anonReq("/api/v1/devices/register", {
      method: "POST",
      body: JSON.stringify({ install_id: id, token: `tok-${id}`, topics }),
    }));
  await reg("install-aaaa1111", ["all"]);
  await reg("install-bbbb2222", ["all", "new_episodes"]);
  await reg("install-cccc3333", ["all", "dubbed"]);

  const all = await (await sendNotification(env, adminReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "All", body: "everyone" }),
  }))).json();
  assert.equal(all.audience, 3);

  const episodic = await (await sendNotification(env, adminReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "New episode", body: "sub", target: "topic", target_value: "new_episodes" }),
  }))).json();
  assert.equal(episodic.audience, 1);
});

test("unregistering keeps the row but stops delivery", async () => {
  const { env } = makeEnv();
  await registerDevice(env, anonReq("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({ install_id: "install-dddd4444", token: "tok-d" }),
  }));
  const res = await unregisterDevice(env, anonReq("/api/v1/devices/unregister", {
    method: "POST",
    body: JSON.stringify({ install_id: "install-dddd4444" }),
  }));
  assert.equal(res.status, 200);

  const row = await env.DB.prepare("SELECT COUNT(*) n FROM devices").first();
  assert.equal(row.n, 1);
  const token = await env.DB.prepare("SELECT token FROM devices").first();
  assert.equal(token.token, "");
});

test("the digest keeps only real, non-adult airing rows and caps the list", () => {
  const data = {
    Page: {
      airingSchedules: [
        { episode: 1100, media: { id: 21, isAdult: false, title: { english: "One Piece" }, coverImage: { large: "https://img/21.jpg" } } },
        { episode: 5, media: { id: 99, isAdult: true, title: { romaji: "Adult" } } },
        { episode: null, media: { id: 7, isAdult: false, title: { romaji: "No Episode" } } },
        { episode: 2, media: { id: 8, isAdult: false, title: { romaji: "Frieren" } } },
        { episode: 3, media: null },
      ],
    },
  };
  const items = buildDigestItems(data, 5);
  assert.equal(items.length, 2);
  assert.deepEqual(items.map((i) => i.id), ["21", "8"]);
  assert.equal(items[0].title, "One Piece");

  assert.equal(buildDigestItems(data, 1).length, 1, "max_items caps the payload");
  assert.deepEqual(buildDigestItems(null, 5), []);

  const one = digestMessage([items[0]]);
  assert.equal(one.title, "One Piece EP 1100 is out");
  const many = digestMessage(items);
  assert.equal(many.title, "2 new episodes just aired");
  assert.match(many.body, /One Piece EP 1100 · Frieren EP 2/);
  assert.equal(digestMessage([]), null);
});

test("the hourly digest skips cheaply instead of sending empty notices", async () => {
  const { env, sqlite } = makeEnv();

  // Disabled by admin.
  sqlite
    .prepare("INSERT INTO remote_config (key,value,updated,updated_by) VALUES ('digest',?,?,?)")
    .run(JSON.stringify({ enabled: false }), 1, "admin@example.com");
  assert.deepEqual(await hourlyDigest(env, { nowMs: Date.UTC(2026, 10, 10, 12) }), { skipped: "disabled" });

  // Re-enabled, but quiet hours apply at 03:00 UTC.
  sqlite.prepare("UPDATE remote_config SET value = ? WHERE key = 'digest'").run(JSON.stringify({ enabled: true }));
  const quiet = await hourlyDigest(env, { nowMs: Date.UTC(2026, 10, 10, 3) });
  assert.deepEqual(quiet, { skipped: "quiet_hours" });

  // Outside quiet hours, but this worker has no FCM credentials: no API calls,
  // no AniList call, no log row.
  const realFetch = globalThis.fetch;
  let outbound = 0;
  globalThis.fetch = async () => {
    outbound += 1;
    return new Response("{}", { status: 200 });
  };
  try {
    const res = await hourlyDigest(env, { nowMs: Date.UTC(2026, 10, 10, 12) });
    assert.deepEqual(res, { skipped: "fcm_not_configured" });
    assert.equal(outbound, 0, "an unconfigured worker must not call out");
  } finally {
    globalThis.fetch = realFetch;
  }

  const cfg = await digestConfig(env);
  assert.equal(cfg.enabled, true);
  assert.deepEqual(cfg.quiet_hours_utc, DIGEST_DEFAULTS.quiet_hours_utc, "missing keys keep defaults");
  assert.equal(cfg.min_interval_minutes, 55);
});

test("the usage summary counts devices, notifications and releases for an admin", async () => {
  const { env } = makeEnv();
  await registerDevice(env, anonReq("/api/v1/devices/register", {
    method: "POST",
    body: JSON.stringify({ install_id: "install-eeee5555", token: "tok-e" }),
  }));
  await sendNotification(env, adminReq("/api/v1/notifications/send", {
    method: "POST",
    body: JSON.stringify({ title: "Usage", body: "test" }),
  }));

  const denied = await usageSummary(env, anonReq("/api/v1/app/usage"));
  assert.equal(denied.status, 403);

  const body = await (await usageSummary(env, adminReq("/api/v1/app/usage"))).json();
  assert.equal(body.devices.total, 1);
  assert.equal(body.devices.push_enabled, 1);
  assert.equal(body.releases, 0);
  assert.equal(body.push_configured, false);
  assert.equal(body.r2_configured, false);
  assert.ok(Array.isArray(body.notes) && body.notes.length >= 2);
});
