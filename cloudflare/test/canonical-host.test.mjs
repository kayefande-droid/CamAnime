/** The mirror answers on one hostname once PUBLIC_ORIGIN names the domain. */
import test from "node:test";
import assert from "node:assert/strict";
import { canonicalHostRedirect } from "../src/index.js";

const ORIGIN = { PUBLIC_ORIGIN: "https://camanime.example" };

function req(url, method = "GET") {
  return new Request(url, { method });
}

test("www redirects to the configured apex and keeps path and query", () => {
  const out = canonicalHostRedirect(
    req("https://www.camanime.example/anime/21?eps=2"), ORIGIN,
    new URL("https://www.camanime.example/anime/21?eps=2"),
  );
  assert.equal(out.status, 301);
  assert.equal(out.headers.get("Location"), "https://camanime.example/anime/21?eps=2");
});

test("the apex is served without a redirect", () => {
  const url = new URL("https://camanime.example/download");
  assert.equal(canonicalHostRedirect(req(url.href), ORIGIN, url), null);
});

test("no PUBLIC_ORIGIN leaves the workers.dev hostname alone", () => {
  const url = new URL("https://www.camanjme.camanime.workers.dev/");
  assert.equal(canonicalHostRedirect(req(url.href), {}, url), null);
});

test("POST bodies are never redirected", () => {
  const url = new URL("https://www.camanime.example/api/auth/login");
  assert.equal(canonicalHostRedirect(req(url.href, "POST"), ORIGIN, url), null);
});
