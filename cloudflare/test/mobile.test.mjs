import test from "node:test";
import assert from "node:assert/strict";

import { card, route } from "../src/mobile.js";

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
  assert.equal(body.download_url, "/static/downloads/CamAnime.apk");
  assert.ok(body.app_version);
});

test("non-mobile paths fall through so the existing routes still run", async () => {
  const url = new URL("https://cam.example/api/counters");
  const res = await route({}, new Request(url), url, ["api", "counters"]);
  assert.equal(res, null);
});
