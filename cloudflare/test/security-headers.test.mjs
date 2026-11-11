/** Every mirror response must carry the same security headers as the Render origin. */
import test from "node:test";
import assert from "node:assert/strict";
import { withSecurityHeaders } from "../src/index.js";

test("security headers are applied to a normal response", () => {
  const out = withSecurityHeaders(new Response("ok", { status: 200 }));
  assert.equal(out.headers.get("X-Content-Type-Options"), "nosniff");
  assert.equal(out.headers.get("X-Frame-Options"), "SAMEORIGIN");
  assert.equal(out.headers.get("Strict-Transport-Security"),
    "max-age=31536000; includeSubDomains");
  assert.equal(out.headers.get("Referrer-Policy"), "strict-origin-when-cross-origin");
  assert.equal(out.headers.get("Cross-Origin-Opener-Policy"), "same-origin");
  const csp = out.headers.get("Content-Security-Policy");
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /frame-ancestors 'self'/);
  assert.match(csp, /object-src 'none'/);
});

test("existing headers survive and a 304 keeps no body", () => {
  const out = withSecurityHeaders(new Response(null, {
    status: 304, headers: { "Cache-Control": "public, max-age=60" },
  }));
  assert.equal(out.status, 304);
  assert.equal(out.headers.get("Cache-Control"), "public, max-age=60");
  assert.equal(out.headers.get("X-Content-Type-Options"), "nosniff");
});
