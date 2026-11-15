import test from "node:test";
import assert from "node:assert/strict";

import { detailsPage, watchPage } from "../src/pages.js";

const anime = {
  id: 21,
  title: { english: "One Piece", romaji: "One Piece" },
  episodes: 120,
  coverImage: { large: "https://img.example/poster.jpg" },
  bannerImage: "https://img.example/banner.jpg",
  streamingEpisodes: Array.from({ length: 120 }, (_, i) => ({ title: `Episode ${i + 1}` })),
};

const episodes = Array.from({ length: 120 }, (_, i) => ({ n: i + 1, title: `Episode ${i + 1}`, url: null }));

const chips = (html) => (html.match(/class="ep-chip/g) || []).length;
const cards = (html) => (html.match(/class="anime-card"/g) || []).length;

test("the details page renders one page of a long episode list", () => {
  const first = detailsPage(anime, { average: 0, count: 0 }, null, "");
  const second = detailsPage(anime, { average: 0, count: 0 }, null, "2");
  const beyond = detailsPage(anime, { average: 0, count: 0 }, null, "999");

  assert.equal(cards(first), 48);
  assert.match(first, /Episodes 1–48 of 120/);
  assert.match(first, /href="\/anime\/21\?eps=2"/);

  assert.equal(cards(second), 48);
  assert.match(second, /href="\/anime\/21\?eps=1"/);

  // Past the end the page clamps to the last slice rather than rendering empty.
  assert.match(beyond, /Episodes 97–120 of 120/);
  assert.doesNotMatch(beyond, /href="\/anime\/21\?eps=4"/);
});

test("the watch rail opens around the episode being watched", () => {
  const base = { anime, episodes, current: null, epNum: 100 };
  const first = watchPage({ ...base, eps: "" }, null);
  const pageOne = watchPage({ ...base, eps: "1" }, null);

  // Page 3 of 120 episodes at 48 per page holds the last 24.
  assert.equal(chips(first), 24);
  assert.match(first, /Episodes 97–120 of 120/);
  assert.match(first, />97<\/a>/);
  assert.match(first, /aria-current="page">3<\/span>/);
  assert.match(first, /href="\/watch\/21\/100\?eps=2"/);

  assert.equal(chips(pageOne), 48);
  assert.match(pageOne, />1<\/a>/);
  // Paging the rail keeps the player on the current episode.
  assert.match(pageOne, /href="\/watch\/21\/100\?eps=2"/);
});

test("a one-page rail renders no pager at all", () => {
  const short = { ...anime, episodes: 12, streamingEpisodes: anime.streamingEpisodes.slice(0, 12) };
  const html = detailsPage(short, { average: 0, count: 0 }, null, "");
  assert.equal(cards(html), 12);
  assert.doesNotMatch(html, /class="ep-pager"/);
});
