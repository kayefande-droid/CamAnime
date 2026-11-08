import test from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.js";

function ctx() {
  return { waitUntil() {}, passThroughOnException() {} };
}

test("/get/android serves the APK from this deployment's own assets", async () => {
  const bytes = new Uint8Array([0x50, 0x4b, 0x03, 0x04]);
  let requestedPath = "";
  const env = {
    ASSETS: {
      fetch: async (req) => {
        requestedPath = new URL(req.url).pathname;
        return new Response(bytes, {
          status: 200,
          headers: { "content-type": "application/octet-stream" },
        });
      },
    },
  };
  const res = await worker.fetch(
    new Request("https://cam.example/get/android"),
    env,
    ctx()
  );
  assert.equal(res.status, 200);
  assert.equal(requestedPath, "/downloads/CamAnime.apk");
  assert.equal(res.headers.get("content-type"), "application/vnd.android.package-archive");
  assert.match(res.headers.get("content-disposition"), /CamAnime\.apk/);
});

test("blocked builds lose streaming and downloads on this host too", async () => {
  for (const build of [12, 15, 16]) {
    const res = await worker.fetch(
      new Request("https://cam.example/api/proxy/media?url=https://cdn.example/v.mp4", {
        headers: { "X-CamAnime-Build": String(build), "X-CamAnime-Version": "2.6.4" },
      }),
      {},
      ctx()
    );
    assert.equal(res.status, 426);
    const body = await res.json();
    assert.equal(body.status, "update_required");
    assert.equal(body.reason, "discontinued");
    assert.equal(body.minimum_supported_version_code, 19);
    assert.ok(body.download_urls.render.includes("/get/android"));
    assert.ok(body.download_urls.cloudflare.includes("/get/android"));
  }
});

test("supported builds and headerless web requests are not gated", async () => {
  const web = await worker.fetch(new Request("https://cam.example/x"), {}, ctx());
  assert.notEqual(web.status, 426);
  const version = await worker.fetch(
    new Request("https://cam.example/api/version", {
      headers: { "X-CamAnime-Build": "16" },
    }), {}, ctx());
  assert.equal(version.status, 200, "the version check must stay reachable");
});

test("/get/android falls back to the Render origin when the asset is missing", async () => {
  const env = { ASSETS: { fetch: async () => new Response(null, { status: 404 }) } };
  const res = await worker.fetch(
    new Request("https://cam.example/get/android"),
    env,
    ctx()
  );
  assert.equal(res.status, 302);
  assert.equal(res.headers.get("location"), "https://camanime.onrender.com/get/android");
});
