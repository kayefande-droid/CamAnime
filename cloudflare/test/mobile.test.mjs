import test from "node:test";
import assert from "node:assert/strict";

import { card, dubFlags, route } from "../src/mobile.js";

test("card maps AniList media and drops malformed trailer ids", () => {
  const row = card({
    id: 21,
    title: { romaji: "One Piece", english: "One Piece" },
    coverImage: { large: "https://img/large.jpg" },
    bannerImage: "https://img/banner.jpg",
    description: "<b>Pirates</b> &amp; treasure",
    episodes: 1100,
    genres: ["Action"],
    trailer: { site: "youtube", id: "short" },
  });
  assert.equal(row.id, "21");
  assert.equal(row.title, "One Piece");
  assert.equal(row.image, "https://img/large.jpg");
  assert.equal(row.synopsis, "Pirates & treasure");
  assert.equal(row.trailer_id, "", "an 11-char id is required");
});

test("version endpoint is served locally, with no upstream request", async () => {
  const url = new URL("https://cam.example/api/version");
  const res = await route({}, new Request(url), url, ["api", "version"]);
  assert.ok(res, "version must be handled by this worker");
  const body = await res.json();
  assert.equal(body.architecture, "workers+d1+r2");
  assert.equal(body.download_url, "/get/android");
  assert.ok(body.app_version);
});

test("non-mobile paths fall through so the existing routes still run", async () => {
  const url = new URL("https://cam.example/api/counters");
  const res = await route({}, new Request(url), url, ["api", "counters"]);
  assert.equal(res, null);
});

test("dub flags come from provider episode rows, never from a guess", () => {
  const flags = dubFlags([
    { num: "1", has_sub: true, has_dub: true },
    { num: "2", has_sub: true, has_dub: true },
    { num: "3", has_sub: true, has_dub: false },
  ]);
  assert.equal(flags.dub, true);
  assert.deepEqual(flags.dub_episodes, [1, 2]);
  assert.equal(flags.source, "anikoto");
});

test("an undubbed title reports sub only, and an empty index stays unknown", () => {
  const subOnly = dubFlags([{ num: "1", has_sub: true, has_dub: false }]);
  assert.equal(subOnly.dub, false);
  assert.deepEqual(subOnly.dub_episodes, []);
  assert.equal(dubFlags([]).dub, null, "no episode index means unknown, not undubbed");
});

test("dub availability rejects malformed and oversized id lists", async () => {
  const call = async (qs) => {
    const url = new URL(`https://cam.example/api/v1/dub-availability?${qs}`);
    const res = await route({}, new Request(url), url, ["api", "v1", "dub-availability"]);
    return [res.status, await res.json()];
  };
  assert.equal((await call("ids=abc"))[0], 400);
  assert.equal((await call("ids="))[0], 400);
  assert.equal((await call("ids=0"))[0], 400);
  const many = Array.from({ length: 25 }, (_, i) => i + 1).join(",");
  assert.equal((await call(`ids=${many}`))[0], 400);
});
