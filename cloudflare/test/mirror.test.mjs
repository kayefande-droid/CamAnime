/** The exact-duplicate mirror: origin pages, host rewriting, cookie passthrough. */
import test from "node:test";
import assert from "node:assert/strict";
import { mirror, mirrorOrigin } from "../src/mirror.js";

test("mirrorOrigin accepts an https origin and rejects everything else", () => {
  assert.equal(mirrorOrigin({ MIRROR_ORIGIN: "https://camanime.onrender.com/" }), "https://camanime.onrender.com");
  assert.equal(mirrorOrigin({ MIRROR_ORIGIN: "http://insecure.test" }), "");
  assert.equal(mirrorOrigin({ MIRROR_ORIGIN: "not a url" }), "");
  assert.equal(mirrorOrigin({}), "");
});

test("mirror is disabled without MIRROR_ORIGIN", async () => {
  const response = await mirror(new Request("https://edge.test/"), {}, new URL("https://edge.test/"));
  assert.equal(response, null);
});

test("mirror forwards the origin's page and rewrites the host", async () => {
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (target, init) => {
    seen.push({ target: String(target), init });
    return new Response(
      '<!DOCTYPE html><link rel="canonical" href="https://camanime.onrender.com/watch/1/2">' +
        '<a href="https://camanime.onrender.com/x">x</a>',
      {
        status: 200,
        headers: {
          "content-type": "text/html; charset=utf-8",
          "set-cookie": "session=abc; Path=/; HttpOnly",
        },
      },
    );
  };
  try {
    const request = new Request("https://edge.test/watch/1/2?audio=dub", {
      headers: { cookie: "session=abc" },
    });
    const response = await mirror(
      request,
      { MIRROR_ORIGIN: "https://camanime.onrender.com" },
      new URL(request.url),
    );
    assert.ok(response, "mirror returned a response");
    assert.equal(seen[0].target, "https://camanime.onrender.com/watch/1/2?audio=dub");
    assert.equal(seen[0].init.headers.get("cookie"), "session=abc");
    const body = await response.text();
    assert.ok(body.includes("https://edge.test/watch/1/2"));
    assert.ok(!body.includes("camanime.onrender.com"));
    assert.equal(response.headers.get("x-camanime-mirror"), "onrender");
    assert.match(response.headers.get("set-cookie") || "", /session=abc/);
  } finally {
    globalThis.fetch = realFetch;
  }
});
