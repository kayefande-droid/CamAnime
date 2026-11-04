/** Node test runner (node --test): pure utilities + derived HTML, no CF bindings needed. */
import test from "node:test";
import assert from "node:assert/strict";
import { esc, hashPassword, verifyPassword, parseCookies, sessionCookie } from "../src/util.js";
import { card } from "../src/catalog.js";

test("esc escapes HTML specials", () => {
  assert.equal(esc(`<img src=x onerror="alert(1)">`), "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;");
  assert.equal(esc(null), "");
});

test("parseCookies reads session cookie and ignores garbage", () => {
  const req = { headers: new Map([["cookie", "ca_session=abc123; junk; theme=light"]]) };
  const map = parseCookies({ headers: { get: (h) => req.headers.get(h) } });
  assert.equal(map.ca_session, "abc123");
  assert.equal(map.junk, undefined);
  assert.equal(map.theme, "light");
});

test("sessionCookie flags HttpOnly/Secure/SameSite", () => {
  const c = sessionCookie("tok%20en");
  assert.match(c, /HttpOnly/);
  assert.match(c, /Secure/);
  assert.match(c, /SameSite=Lax/);
  assert.match(c, /^ca_session=/);
});

test("PBKDF2 hash/verify roundtrip rejects wrong password", async () => {
  const stored = await hashPassword("correct horse battery staple");
  assert.ok(stored.startsWith("pbkdf2$100000$"));
  assert.equal(await verifyPassword("correct horse battery staple", stored), true);
  assert.equal(await verifyPassword("wrong password", stored), false);
  assert.equal(await verifyPassword("hash", stored), false);
});

test("catalog card renders branded markup with escaped title", () => {
  const htmlOut = card({
    id: 16498,
    title: { english: 'Tra"><b>x</b>', romaji: "Overlord" },
    coverImage: { large: "https://s4.anilist.co/file/anilistcdn/media/anime/cover/large/x.png" },
    averageScore: 82,
    format: "TV",
  });
  assert.match(htmlOut, /class="anime-card"/);
  assert.match(htmlOut, /href="\/anime\/16498"/);
  assert.ok(htmlOut.includes("loading=&quot;lazy&quot;") === false); // attr broken-out safely
  assert.ok(htmlOut.includes('Tra&quot;&gt;&lt;b&gt;x&lt;/b&gt;'));
  assert.match(htmlOut, /★ 8.2/);
});
