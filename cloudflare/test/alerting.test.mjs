/** Edge alerting: the 5-minute health sweep and the throttled webhook. */
import test from "node:test";
import assert from "node:assert/strict";
import { alertWebhook, uptimeSweep } from "../src/index.js";

function fakeCtx() {
  const pending = [];
  return { waitUntil: (promise) => pending.push(promise), pending };
}

function stubFetch(handler, captured = []) {
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    captured.push({ url: String(url), init });
    return handler(String(url), init);
  };
  return () => {
    globalThis.fetch = original;
  };
}

test("no ALERT_WEBHOOK means no alert and no network call", async () => {
  const calls = [];
  const restore = stubFetch(() => new Response("ok"), calls);
  try {
    assert.equal(alertWebhook({}, fakeCtx(), "test:unset", "should not send"), false);
    assert.equal(calls.length, 0);
  } finally {
    restore();
  }
});

test("an alert posts {text, kind, message} to the webhook", async () => {
  const calls = [];
  const restore = stubFetch(() => new Response(null, { status: 204 }), calls);
  const ctx = fakeCtx();
  try {
    const env = { ALERT_WEBHOOK: "https://hooks.example/camanime" };
    assert.equal(alertWebhook(env, ctx, "http-500:test", "500 on GET /x", "edge"), true);
    await Promise.all(ctx.pending);

    const post = calls.find((call) => call.url === "https://hooks.example/camanime");
    assert.ok(post);
    assert.equal(post.init.method, "POST");
    const body = JSON.parse(post.init.body);
    assert.equal(body.kind, "http-500:test");
    assert.equal(body.message, "500 on GET /x");
    assert.match(body.text, /^\[CamAnime edge\] 500 on GET \/x/);
    assert.equal(body.detail, "edge");
  } finally {
    restore();
  }
});

test("the same kind is not re-sent inside the throttle window", async () => {
  const calls = [];
  const restore = stubFetch(() => new Response(null, { status: 204 }), calls);
  try {
    const env = { ALERT_WEBHOOK: "https://hooks.example/camanime" };
    assert.equal(alertWebhook(env, fakeCtx(), "throttle:test", "first"), true);
    assert.equal(alertWebhook(env, fakeCtx(), "throttle:test", "second"), false);
  } finally {
    restore();
  }
});

test("the health sweep alerts only for the host that failed", async () => {
  const calls = [];
  const restore = stubFetch((url) => {
    if (url.includes("origin.test")) throw new Error("connect ETIMEDOUT");
    return new Response('{"status":"ok"}', { status: 200 });
  }, calls);
  const ctx = fakeCtx();
  try {
    const env = {
      ALERT_WEBHOOK: "https://hooks.example/camanime",
      UPTIME_TARGETS: "https://mirror.test/healthz,https://origin.test/healthz",
    };
    const results = await uptimeSweep(env, ctx);
    await Promise.all(ctx.pending);

    assert.deepEqual(
      results.map((r) => [r.target, r.ok]),
      [["https://mirror.test/healthz", true], ["https://origin.test/healthz", false]],
    );
    const alerts = calls.filter((call) => call.url === "https://hooks.example/camanime");
    assert.equal(alerts.length, 1);
    const body = JSON.parse(alerts[0].init.body);
    assert.equal(body.kind, "uptime:https://origin.test/healthz");
    assert.match(body.message, /origin\.test/);
  } finally {
    restore();
  }
});

test("a health endpoint answering non-200 counts as down", async () => {
  const calls = [];
  const restore = stubFetch(() => new Response("down", { status: 503 }), calls);
  const ctx = fakeCtx();
  try {
    const env = {
      ALERT_WEBHOOK: "https://hooks.example/camanime",
      UPTIME_TARGETS: "https://mirror.test/healthz",
    };
    const results = await uptimeSweep(env, ctx);
    await Promise.all(ctx.pending);
    assert.equal(results[0].ok, false);
    assert.match(results[0].detail, /503/);
  } finally {
    restore();
  }
});
