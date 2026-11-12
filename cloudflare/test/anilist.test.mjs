import test from "node:test";
import assert from "node:assert/strict";

import { alQuery } from "../src/anilist.js";

const ok = (data) =>
  new Response(JSON.stringify({ data }), {
    status: 200,
    headers: { "content-type": "application/json" },
  });

test("identical concurrent queries share one upstream request", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    await new Promise((resolve) => setTimeout(resolve, 10));
    return ok({ value: 1 });
  };
  const [a, b] = await Promise.all([alQuery("same-query"), alQuery("same-query")]);
  assert.equal(calls, 1, "coalescing must prevent a second rate-limit hit");
  assert.deepEqual(a, { data: { value: 1 } });
  assert.deepEqual(b, { data: { value: 1 } });
});

test("a 429 is retried after Retry-After instead of failing the page", async () => {
  let calls = 0;
  globalThis.fetch = async () => {
    calls += 1;
    if (calls === 1) {
      return new Response("", { status: 429, headers: { "retry-after": "0" } });
    }
    return ok({ value: 2 });
  };
  const payload = await alQuery("retry-query");
  assert.equal(calls, 2);
  assert.deepEqual(payload, { data: { value: 2 } });
});

test("exhausted retries surface the rate limit rather than inventing data", async () => {
  let direct = 0;
  let relay = 0;
  globalThis.fetch = async (input) => {
    const url = String(input && input.url ? input.url : input);
    if (url.includes("onrender.com")) {
      relay += 1;
      return new Response("", { status: 502 });
    }
    direct += 1;
    return new Response("", { status: 429, headers: { "retry-after": "0" } });
  };
  await assert.rejects(() => alQuery("always-429"), /429/);
  assert.equal(direct, 3, "initial try plus two retries against AniList");
  assert.equal(relay, 1, "one origin relay before the error surfaces");
});
