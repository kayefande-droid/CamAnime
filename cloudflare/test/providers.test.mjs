import test from "node:test";
import assert from "node:assert/strict";

import {
  scoreTitle,
  generateTitleVariants,
  parseHeavenSearch,
  parseHeavenEpisodes,
  parseGateSources,
  parseAnikotoSearch,
  parseAnikotoServers,
  parseMegaplayScript,
  decryptMegaplayEnc,
} from "../src/providers.js";

test("title scoring keeps the Python thresholds", () => {
  assert.equal(scoreTitle("One Piece", "One Piece"), 100);
  assert.equal(scoreTitle("One Piece", "one piece, op"), 100, "comma aliases are scored");
  assert.ok(scoreTitle("Jujutsu Kaisen", "Jujutsu Kaisen 2nd Season") < 85, "a spinoff must not score as a match");
  assert.ok(scoreTitle("Naruto", "Bleach") < 40);
});

test("title variants strip possessives, punctuation and long tails", () => {
  const variants = generateTitleVariants(["Kaguya-sama: Love is War"]);
  assert.ok(variants.includes("Kaguya-sama: Love is War"));
  assert.ok(variants.includes("Kaguya"), "the Python split also cuts on the hyphen");
  assert.ok(generateTitleVariants(["Naruto's Journey"]).includes("Naruto Journey"));
});

test("AnimeHeaven search markup is parsed", () => {
  const html = `
    <a href="anime.php?abc123"><img src="/covers/op.jpg" alt="ONE PIECE">
      <span class="fastname">ONE PIECE</span></a>
    <a href="anime.php?def456"><span class="fastname">BLEACH</span></a>`;
  const rows = parseHeavenSearch(html);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].id, "abc123");
  assert.equal(rows[0].title, "ONE PIECE");
  assert.equal(rows[0].image, "https://animeheaven.me/covers/op.jpg");
});

test("episode keys are read from gate calls and numbered", () => {
  const html = `
    <a href="anime.php?x" onmouseover="gateh('KEY-A')"><span class="watch2">1</span></a>
    <a onmouseover="gateh('KEY-B')"><span class="watch2">2</span></a>`;
  const eps = parseHeavenEpisodes(html);
  assert.deepEqual(eps.map((e) => e.num), [1, 2]);
  assert.deepEqual(eps.map((e) => e.key), ["KEY-A", "KEY-B"]);
});

test("gate.php MP4 mirrors are extracted, placeholders are not invented", () => {
  const html = `<video><source src="https://rt.animeheaven.me/v/op1.mp4" type="video/mp4"></video>`;
  assert.deepEqual(parseGateSources(html), ["https://rt.animeheaven.me/v/op1.mp4"]);
  assert.deepEqual(parseGateSources("<p>watch episode on animeheaven.me</p>"), []);
});

test("Anikoto search and server groups parse into sub/dub entries", () => {
  const search = `<a href="/watch/one-piece-123"><div class="name">One Piece</div></a>`;
  const rows = parseAnikotoSearch(search);
  assert.equal(rows[0].slug, "one-piece-123");
  assert.equal(rows[0].title, "One Piece");

  const servers = `
    <div class="type">SUB</div>
    <ul><li data-link-id="L1" data-sv-id="S1">HD-1</li></ul>
    <div class="type">DUB</div>
    <ul><li data-link-id="L2" data-sv-id="S2">HD-1</li></ul>`;
  const parsed = parseAnikotoServers(servers);
  assert.deepEqual(parsed.map((s) => [s.link_id, s.type, s.sv_id]), [
    ["L1", "sub", "S1"],
    ["L2", "dub", "S2"],
  ]);
});

test("MegaPlay keys/ivs are harvested from the player script", () => {
  const script = `const k="0123456789abcdef";const iv="abcdefghijklmnop";/* getSources AES-CBC */`;
  const { keys, ivs } = parseMegaplayScript(script);
  assert.ok(keys.some((k) => new TextDecoder().decode(k) === "0123456789abcdef"));
  assert.ok(ivs.some((v) => new TextDecoder().decode(v) === "abcdefghijklmnop"));
});

test("AES-CBC enc payload decrypts to the HLS url", async () => {
  const key = new TextEncoder().encode("0123456789abcdef");
  const keyBytes = new Uint8Array(32);
  keyBytes.set(key);
  const iv = new TextEncoder().encode("abcdefghijklmnop");
  const plain = new TextEncoder().encode(
    JSON.stringify({ file: "https://cdn.example/master.m3u8" })
  );
  const imported = await crypto.subtle.importKey("raw", keyBytes, { name: "AES-CBC" }, false, [
    "encrypt",
  ]);
  const cipher = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-CBC", iv }, imported, plain)
  );
  const b64url = Buffer.from(cipher)
    .toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const url = await decryptMegaplayEnc(b64url, [keyBytes], [iv]);
  assert.equal(url, "https://cdn.example/master.m3u8");
  assert.equal(await decryptMegaplayEnc(b64url, [keyBytes], [new Uint8Array(16)]), null);
});
