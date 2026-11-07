import test from "node:test";
import assert from "node:assert/strict";
import { createKey, listKeys, revokeKey, stream, DAILY_LIMIT, MAX_KEYS } from "../src/developer.js";

/** Minimal D1 stand-in: just enough SQL shape for developer.js. */
class FakeDB {
  constructor() {
    this.keys = [];
    this.usage = [];
  }
  prepare(sql) {
    const db = this;
    let args = [];
    return {
      bind(...next) {
        args = next;
        return this;
      },
      async first() {
        if (/FROM tokens JOIN users/.test(sql)) {
          return { expires: Date.now() + 60000, email: "dev@example.com", name: "Dev", role: "user", avatar: "" };
        }
        if (/COUNT\(\*\) AS n FROM api_keys/.test(sql)) {
          return { n: db.keys.filter((k) => k.email === args[0] && !k.revoked).length };
        }
        if (/SELECT id FROM api_keys WHERE id = \?1 AND email = \?2/.test(sql)) {
          const found = db.keys.find((k) => k.id === args[0] && k.email === args[1]);
          return found ? { id: found.id } : null;
        }
        if (/SELECT id, revoked FROM api_keys WHERE key_hash/.test(sql)) {
          const found = db.keys.find((k) => k.key_hash === args[0]);
          return found ? { id: found.id, revoked: found.revoked } : null;
        }
        if (/SELECT calls FROM api_usage/.test(sql)) {
          const row = db.usage.find((u) => u.key_id === args[0] && u.day === args[1]);
          return row ? { calls: row.calls } : null;
        }
        return null;
      },
      async all() {
        if (/FROM api_keys WHERE email/.test(sql)) {
          return { results: db.keys.filter((k) => k.email === args[0]) };
        }
        if (/FROM api_usage WHERE day/.test(sql)) {
          return { results: db.usage.filter((u) => u.day === args[0]) };
        }
        return { results: [] };
      },
      async run() {
        if (/INSERT INTO api_keys/.test(sql)) {
          db.keys.push({
            id: args[0], email: args[1], name: args[2], prefix: args[3], key_hash: args[4],
            plan: "free", created: args[5], last_used: 0, revoked: 0,
          });
        } else if (/UPDATE api_keys SET revoked = 1/.test(sql)) {
          const found = db.keys.find((k) => k.id === args[0]);
          if (found) found.revoked = 1;
        } else if (/UPDATE api_keys SET last_used/.test(sql)) {
          const found = db.keys.find((k) => k.id === args[1]);
          if (found) found.last_used = args[0];
        } else if (/INSERT INTO api_usage/.test(sql)) {
          const row = db.usage.find((u) => u.key_id === args[0] && u.day === args[1]);
          if (row) row.calls += 1;
          else db.usage.push({ key_id: args[0], day: args[1], calls: 1 });
        }
        return { success: true };
      },
    };
  }
}

const env = () => ({ DB: new FakeDB() });
const signedIn = (path = "/api/developer/keys", init = {}) =>
  new Request("https://camanime.test" + path, {
    ...init,
    headers: { cookie: "ca_session=abc", "content-type": "application/json", ...(init.headers || {}) },
  });

test("creating a key requires a signed-in session", async () => {
  const res = await createKey(env(), new Request("https://camanime.test/api/developer/keys", { method: "POST" }));
  assert.equal(res.status, 401);
});

test("createKey returns a live key once and stores only its hash", async () => {
  const e = env();
  const res = await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "My site" }) }));
  assert.equal(res.status, 201);
  const body = await res.json();
  assert.match(body.key, /^ca_live_[0-9a-f]{48}$/);
  assert.equal(body.daily_limit, DAILY_LIMIT);
  assert.equal(e.DB.keys.length, 1);
  assert.equal(e.DB.keys[0].key_hash.length, 64);
  assert.notEqual(e.DB.keys[0].key_hash, body.key);
  assert.ok(!JSON.stringify(e.DB.keys).includes(body.key), "plaintext key must never be stored");
});

test("listKeys exposes prefixes but never the secret", async () => {
  const e = env();
  const created = await (await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "docs" }) }))).json();
  const res = await listKeys(e, signedIn());
  const body = await res.json();
  assert.equal(body.keys.length, 1);
  assert.equal(body.keys[0].prefix, created.key.slice(0, 14));
  assert.ok(!JSON.stringify(body).includes(created.key));
});

test(`the free tier caps active keys at ${MAX_KEYS}`, async () => {
  const e = env();
  for (let i = 0; i < MAX_KEYS; i++) {
    const r = await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "k" + i }) }));
    assert.equal(r.status, 201);
  }
  const over = await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "extra" }) }));
  assert.equal(over.status, 429);
});

test("revoking a key marks it revoked", async () => {
  const e = env();
  const created = await (await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "tmp" }) }))).json();
  const res = await revokeKey(e, signedIn("/api/developer/keys/" + created.id, { method: "DELETE" }), created.id);
  assert.equal(res.status, 200);
  assert.equal(e.DB.keys[0].revoked, 1);
});

test("the public stream endpoint needs a key and adds CORS", async () => {
  const res = await stream(env(), new Request("https://camanime.test/api/v1/stream/16498/1"), new URL("https://camanime.test/api/v1/stream/16498/1"), "16498", "1");
  assert.equal(res.status, 401);
  assert.equal(res.headers.get("access-control-allow-origin"), "*");
  const body = await res.json();
  assert.match(body.docs, /\/developers$/);
});

test("an unknown or revoked key is refused before any provider lookup", async () => {
  const e = env();
  const res = await stream(e, new Request("https://camanime.test/api/v1/stream/16498/1", { headers: { "x-api-key": "ca_live_deadbeef" } }),
    new URL("https://camanime.test/api/v1/stream/16498/1"), "16498", "1");
  assert.equal(res.status, 403);
});

test("the daily free-tier cap answers 429", async () => {
  const e = env();
  const created = await (await createKey(e, signedIn("/api/developer/keys", { method: "POST", body: JSON.stringify({ name: "busy" }) }))).json();
  const day = new Date().toISOString().slice(0, 10);
  e.DB.usage.push({ key_id: created.id, day, calls: DAILY_LIMIT });
  const res = await stream(e, new Request("https://camanime.test/api/v1/stream/16498/1", { headers: { "x-api-key": created.key } }),
    new URL("https://camanime.test/api/v1/stream/16498/1"), "16498", "1");
  assert.equal(res.status, 429);
  const body = await res.json();
  assert.equal(body.daily_limit, DAILY_LIMIT);
});
