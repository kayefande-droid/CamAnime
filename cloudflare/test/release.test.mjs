/**
 * Release policy + mobile contract tests.
 *
 * These cover the defects fixed in the Cloudflare audit: the version gate the
 * APK actually polls (/api/app/ping), the update metadata the in-app updater
 * parses (/api/version), R2-backed APK downloads with resume, the DL prefix
 * confinement, and the SSRF host allowlist.
 */
import test from "node:test";
import assert from "node:assert/strict";

import worker from "../src/index.js";
import { route } from "../src/mobile.js";
import { downloadFile, proxyMedia } from "../src/api.js";
import { parseByteRange } from "../src/util.js";
import { LATEST_BUILD, LATEST_VERSION } from "../src/release.js";

function ctx() {
  return { waitUntil() {}, passThroughOnException() {} };
}

test("/api/version carries the fields the in-app updater needs", async () => {
  const url = new URL("https://cam.example/api/version");
  const res = await route({}, new Request(url), url, ["api", "version"]);
  assert.ok(res);
  const body = await res.json();

  assert.equal(body.app_version, LATEST_VERSION);
  assert.equal(body.latest_version_code, LATEST_BUILD);
  assert.equal(body.download_url, "/get/android");
  // app_updater.dart rejects an APK URL whose host differs from the API host.
  assert.equal(body.apk_url, "https://cam.example/get/android");
  assert.match(body.sha256, /^[0-9a-f]{64}$/);
  assert.ok(body.whats_new.length > 0);
});

test("the version gate a supported build polls answers 200 and does not block", async () => {
  const url = new URL("https://cam.example/api/app/ping");
  const res = await route(
    {},
    new Request(url, { headers: { "X-CamAnime-Build": String(LATEST_BUILD) } }),
    url,
    ["api", "app", "ping"],
  );
  assert.equal(res.status, 200);
  const body = await res.json();
  assert.equal(body.required, false);
  assert.equal(body.policy.latest_version, LATEST_VERSION);
  assert.equal(body.policy.force_update, false);
  assert.ok(body.policy.download_urls.cloudflare.includes("/get/android"));
});

test("the version gate refuses a retired build with 426 and a policy", async () => {
  const url = new URL("https://cam.example/api/app/ping");
  const res = await route(
    {},
    new Request(url, { headers: { "X-CamAnime-Build": "16" } }),
    url,
    ["api", "app", "ping"],
  );
  assert.equal(res.status, 426);
  const body = await res.json();
  assert.equal(body.discontinued, true);
  assert.equal(body.reason, "discontinued");
  assert.equal(body.minimum_supported_version_code, 19);
});

test("byte ranges parse into R2 options and malformed ones are ignored", () => {
  assert.deepEqual(parseByteRange("bytes=0-99"), { offset: 0, length: 100 });
  assert.deepEqual(parseByteRange("bytes=100-"), { offset: 100 });
  assert.deepEqual(parseByteRange("bytes=-500"), { suffix: 500 });
  assert.equal(parseByteRange("bytes=-"), null);
  assert.equal(parseByteRange("bytes=40-10"), null);
  assert.equal(parseByteRange(""), null);
});

test("the APK is served from R2 and honours a Range so downloads resume", async () => {
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(new Uint8Array([0x50, 0x4b, 0x03, 0x04]));
      controller.close();
    },
  });
  const env = {
    FILES: {
      async get(key, options) {
        assert.equal(key, "downloads/CamAnime.apk");
        assert.deepEqual(options, { range: { offset: 0, length: 4 } });
        return {
          key,
          size: 53414795,
          httpEtag: '"etag"',
          writeHttpMetadata() {},
          range: { offset: 0, length: 4 },
          body,
        };
      },
    },
  };
  const res = await worker.fetch(
    new Request("https://cam.example/get/android", { headers: { range: "bytes=0-3" } }),
    env,
    ctx(),
  );
  assert.equal(res.status, 206);
  assert.equal(res.headers.get("content-range"), "bytes 0-3/53414795");
  assert.equal(res.headers.get("content-length"), "4");
  assert.equal(res.headers.get("accept-ranges"), "bytes");
  assert.equal(res.headers.get("content-type"), "application/vnd.android.package-archive");
});

test("an R2 miss still resolves to the asset bundle and never 500s", async () => {
  const env = {
    FILES: { get: async () => null, head: async () => null },
    ASSETS: { fetch: async () => new Response(new Uint8Array([1]), { status: 200 }) },
  };
  const res = await worker.fetch(new Request("https://cam.example/get/android"), env, ctx());
  assert.equal(res.status, 200);
});

test("public downloads are confined to the downloads/ prefix", async () => {
  const env = {
    FILES: {
      get: async () => {
        throw new Error("must not read a key outside downloads/");
      },
      head: async () => {
        throw new Error("must not read a key outside downloads/");
      },
    },
  };
  for (const key of ["users/private.db", "../downloads/x.apk", "downloads/../../secret"]) {
    const res = await downloadFile(env, new Request("https://cam.example/api/download/file/x"), key);
    assert.equal(res.status, 404, `key ${key} must be refused`);
  }
});

test("a ranged download answers 206 with a content-range", async () => {
  const env = {
    FILES: {
      async get(key, options) {
        assert.equal(key, "downloads/episode.mp4");
        assert.deepEqual(options, { range: { offset: 10, length: 5 } });
        return {
          size: 1000,
          httpEtag: '"e"',
          writeHttpMetadata() {},
          range: { offset: 10, length: 5 },
          body: new Uint8Array([1, 2, 3, 4, 5]),
        };
      },
    },
  };
  const res = await downloadFile(
    env,
    new Request("https://cam.example/api/download/file/downloads%2Fepisode.mp4", {
      headers: { range: "bytes=10-14" },
    }),
    "downloads%2Fepisode.mp4",
  );
  assert.equal(res.status, 206);
  assert.equal(res.headers.get("content-range"), "bytes 10-14/1000");
});

test("the media proxy refuses lookalike hosts, userinfo tricks and non-GET methods", async () => {
  const lookalike = await proxyMedia(
    {},
    new Request("https://cam.example/api/proxy/media?u=https%3A%2F%2Fevil-anilist.co%2Fx.mp4"),
  );
  assert.equal(lookalike.status, 403);

  const bareLookalike = await proxyMedia(
    {},
    new Request("https://cam.example/api/proxy/media?u=https%3A%2F%2Fnotr2.dev%2Fx.mp4"),
  );
  assert.equal(bareLookalike.status, 403);

  const userinfo = await proxyMedia(
    {},
    new Request(
      "https://cam.example/api/proxy/media?u=https%3A%2F%2Fanilist.co%40evil.example%2Fx.mp4",
    ),
  );
  assert.equal(userinfo.status, 403);

  const post = await proxyMedia(
    {},
    new Request("https://cam.example/api/proxy/media?u=https%3A%2F%2Fanilist.co%2Fx.mp4", {
      method: "POST",
    }),
  );
  assert.equal(post.status, 405);
});
