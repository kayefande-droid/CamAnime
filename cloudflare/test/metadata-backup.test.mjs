/** The Kitsu backup keeps AniList ids, so links never point at the wrong show. */
import test from "node:test";
import assert from "node:assert/strict";
import { entriesFrom, animeListFrom, toMedia, backupSearchMedia } from "../src/metadata-backup.js";

const payload = {
  data: [
    {
      id: "1",
      type: "anime",
      attributes: {
        canonicalTitle: "Cowboy Bebop",
        titles: { en: "Cowboy Bebop", en_jp: "Cowboy Bebop", ja_jp: "カウボーイビバップ" },
        subtype: "TV",
        status: "finished",
        episodeCount: 26,
        averageRating: "82.28",
        startDate: { year: 1998 },
        synopsis: "Spike Spiegel and crew.",
        posterImage: { large: "https://media.kitsu.io/poster.jpg", medium: "https://media.kitsu.io/poster-m.jpg" },
        coverImage: { large: "https://media.kitsu.io/cover.jpg" },
      },
      relationships: { mappings: { data: [{ id: "m1", type: "mappings" }, { id: "m2", type: "mappings" }] } },
    },
    {
      id: "2",
      type: "anime",
      attributes: { canonicalTitle: "Unmapped Show", subtype: "movie" },
      relationships: { mappings: { data: [{ id: "m3", type: "mappings" }] } },
    },
  ],
  included: [
    { id: "m1", type: "mappings", attributes: { externalSite: "myanimelist/anime", externalId: "1" } },
    { id: "m2", type: "mappings", attributes: { externalSite: "anilist/anime", externalId: "1" } },
    { id: "m3", type: "mappings", attributes: { externalSite: "myanimelist/anime", externalId: "999" } },
  ],
};

test("entries keep the AniList id and skip titles without one", () => {
  const entries = entriesFrom(payload);
  assert.equal(entries.length, 1);
  assert.equal(entries[0].anilistId, 1);
  assert.equal(entries[0].kitsuId, "1");
});

test("Kitsu fields map into the AniList media shape", () => {
  const media = animeListFrom(payload)[0];
  assert.equal(media.id, 1);
  assert.equal(media.title.english, "Cowboy Bebop");
  assert.equal(media.title.native, "カウボーイビバップ");
  assert.equal(media.format, "TV");
  assert.equal(media.status, "FINISHED");
  assert.equal(media.episodes, 26);
  assert.equal(media.averageScore, 82);
  assert.equal(media.seasonYear, 1998);
  assert.equal(media.streamingEpisodes.length, 0);
  assert.equal(media.metadata_source, "kitsu");
  const movie = toMedia(payload.data[1], 42);
  assert.equal(movie.format, "MOVIE");
});

test("search sends the title to Kitsu and returns AniList-shaped media", async () => {
  const realFetch = globalThis.fetch;
  const seen = [];
  globalThis.fetch = async (target) => {
    seen.push(String(target));
    return new Response(JSON.stringify(payload), { status: 200, headers: { "content-type": "application/json" } });
  };
  try {
    const media = await backupSearchMedia("cowboy bebop", 5);
    assert.equal(media.length, 1);
    assert.equal(media[0].id, 1);
    assert.match(seen[0], /filter%5Btext%5D=cowboy%20bebop/);
    assert.match(seen[0], /include=mappings/);
  } finally {
    globalThis.fetch = realFetch;
  }
});
