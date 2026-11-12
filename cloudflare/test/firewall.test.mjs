import { test } from "node:test";
import assert from "node:assert/strict";
import { guard } from "../src/firewall.js";

function req(path, { ip = "203.0.113.10", method = "GET", ua = "Mozilla/5.0", body = null } = {}) {
  const request = new Request(`https://camanjme.camanime.workers.dev${path}`, {
    method,
    headers: { "cf-connecting-ip": ip, "user-agent": ua, "content-type": "application/json" },
    body,
  });
  return [request, new URL(request.url)];
}

test("clean page request passes", () => {
  const [request, url] = req("/watch/21/1", { ip: "198.51.100.1" });
  assert.equal(guard(request, url), null);
});

test("scanner paths answer with the decoy 404", () => {
  for (const [i, path] of ["/.env", "/wp-admin/x.php", "/../../etc/passwd"].entries()) {
    const [request, url] = req(path, { ip: `198.51.100.${10 + i}` });
    const res = guard(request, url);
    assert.ok(res, path);
    assert.equal(res.status, 404);
  }
});

test("auth bucket is tighter than pages", () => {
  const ip = "198.51.100.50";
  for (let i = 0; i < 12; i += 1) {
    const [request, url] = req("/api/auth/login", { ip, method: "POST" });
    assert.equal(guard(request, url), null);
  }
  const [request, url] = req("/api/auth/login", { ip, method: "POST" });
  const res = guard(request, url);
  assert.ok(res);
  assert.equal(res.status, 429);
  assert.equal(res.headers.get("retry-after"), "60");
});

test("media segments allow a playback burst", () => {
  const ip = "198.51.100.60";
  for (let i = 0; i < 300; i += 1) {
    const [request, url] = req("/api/proxy/segment?url=x", { ip });
    assert.equal(guard(request, url), null);
  }
});

test("oversized auth bodies are refused", () => {
  const ip = "198.51.100.70";
  const request = new Request("https://camanjme.camanime.workers.dev/api/auth/register", {
    method: "POST",
    headers: {
      "cf-connecting-ip": ip,
      "content-type": "application/json",
      "content-length": "200000",
    },
  });
  const res = guard(request, new URL(request.url));
  assert.ok(res);
  assert.equal(res.status, 413);
});

test("repeated abuse escalates to a ban", () => {
  const ip = "198.51.100.80";
  for (let i = 0; i < 8; i += 1) {
    const [request, url] = req(`/.env?i=${i}`, { ip });
    assert.equal(guard(request, url)?.status, 404);
  }
  const [request, url] = req("/", { ip });
  const res = guard(request, url);
  assert.ok(res);
  assert.equal(res.headers.get("x-camanime-firewall"), "ban");
  assert.ok(Number(res.headers.get("retry-after")) > 0);
});

test("attack tooling is blocked on auth paths only", () => {
  const [okRequest, okUrl] = req("/", { ip: "198.51.100.90", ua: "sqlmap/1.7" });
  assert.equal(guard(okRequest, okUrl), null);
  const [badRequest, badUrl] = req("/api/auth/login", {
    ip: "198.51.100.90",
    method: "POST",
    ua: "sqlmap/1.7",
  });
  assert.equal(guard(badRequest, badUrl)?.status, 403);
  assert.equal(guard(badRequest, badUrl)?.headers.get("x-camanime-firewall"), "scanner");
});
