import test from "node:test";
import assert from "node:assert/strict";
import { robotsTxt, withSeo } from "../src/seo.js";

const ORIGIN = "https://camanjme.camanime.workers.dev";

function htmlPage(extra = "") {
  return new Response(
    `<!DOCTYPE html><html><head>
<meta name="robots" content="index, follow, max-image-preview:large">
<link rel="canonical" href="__CA_CANONICAL__">
<meta property="og:image" content="__CA_ORIGIN__/static/icon-512.png">
${extra}</head><body>ok</body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8" } },
  );
}

test("robots.txt points at this deployment's own sitemap", async () => {
  const body = await robotsTxt(ORIGIN, "/panel").text();
  assert.match(body, /Sitemap: https:\/\/camanjme\.camanime\.workers\.dev\/sitemap\.xml/);
  assert.doesNotMatch(body, /onrender/);
  // CSS/JS must stay crawlable or Google cannot render the page.
  assert.match(body, /Allow: \/static\//);
  assert.match(body, /Disallow: \/api\//);
  assert.match(body, /Disallow: \/panel/);
});

test("robots.txt omits an admin rule when no dashboard path is configured", async () => {
  const body = await robotsTxt(ORIGIN, "").text();
  assert.doesNotMatch(body, /Disallow: \/panel/);
});

test("canonical and social URLs use the request origin, not Render", async () => {
  const res = await withSeo(htmlPage(), new URL(ORIGIN + "/anime/104157"));
  const body = await res.text();
  assert.match(body, /<link rel="canonical" href="https:\/\/camanjme\.camanime\.workers\.dev\/anime\/104157">/);
  assert.match(body, /content="https:\/\/camanjme\.camanime\.workers\.dev\/static\/icon-512\.png"/);
  assert.doesNotMatch(body, /__CA_/);
  assert.doesNotMatch(body, /onrender/);
});

test("the homepage canonical keeps its trailing slash", async () => {
  const res = await withSeo(htmlPage(), new URL(ORIGIN + "/"));
  assert.match(await res.text(), /<link rel="canonical" href="https:\/\/camanjme\.camanime\.workers\.dev\/">/);
});

test("per-user pages are marked noindex", async () => {
  for (const path of ["/settings", "/library", "/login", "/developers"]) {
    const res = await withSeo(htmlPage(), new URL(ORIGIN + path));
    const body = await res.text();
    assert.match(body, /<meta name="robots" content="noindex, follow">/, `${path} should be noindex`);
  }
});

test("public pages stay fully indexable and get WebSite JSON-LD on the homepage", async () => {
  const anime = await (await withSeo(htmlPage(), new URL(ORIGIN + "/anime/32"))).text();
  assert.match(anime, /content="index, follow, max-image-preview:large"/);
  assert.doesNotMatch(anime, /application\/ld\+json/);

  const home = await (await withSeo(htmlPage(), new URL(ORIGIN + "/"))).text();
  assert.match(home, /application\/ld\+json/);
  assert.match(home, /"@type":"WebSite"/);
});

test("non-HTML responses pass through untouched", async () => {
  const original = new Response("{}", { headers: { "content-type": "application/json" } });
  const res = await withSeo(original, new URL(ORIGIN + "/api/x"));
  assert.equal(res, original);
});
