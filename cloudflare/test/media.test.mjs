import test from "node:test";
import assert from "node:assert/strict";

import {
  rewritePlaylist,
  pickVariant,
  segmentUrls,
  sumSegmentBytes,
  estimateSegmentBytes,
} from "../src/media.js";

const playlist = [
  "#EXTM3U",
  "#EXT-X-VERSION:3",
  "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"",
  "#EXT-X-MAP:URI=\"init.mp4\"",
  "seg-1.ts",
  "https://cdn.example/hls/seg-2.ts",
  "",
].join("\n");

test("segments and keys are rewritten through the proxy", () => {
  const out = rewritePlaylist(playlist, "https://cdn.example/hls/master.m3u8", "https://megaplay.buzz/");
  assert.match(out, /#EXTM3U/);
  assert.match(
    out,
    /URI="\/api\/proxy\/segment\?url=https%3A%2F%2Fcdn\.example%2Fhls%2Fkey\.bin&ref=https%3A%2F%2Fmegaplay\.buzz%2F"/
  );
  assert.match(out, /url=https%3A%2F%2Fcdn\.example%2Fhls%2Fseg-1\.ts/);
  assert.match(out, /url=https%3A%2F%2Fcdn\.example%2Fhls%2Fseg-2\.ts/);
  assert.ok(!/\nseg-1\.ts/.test(out), "raw relative segments must not remain");
});

test("variant selection honours a height cap and never exceeds it", () => {
  const master = [
    "#EXTM3U",
    "#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080",
    "1080/index.m3u8",
    "#EXT-X-STREAM-INF:BANDWIDTH=2500000,RESOLUTION=1280x720",
    "720/index.m3u8",
    "#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360",
    "360/index.m3u8",
    '#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=90000,RESOLUTION=1920x1080,URI="iframes.m3u8"',
  ].join("\n");
  const base = "https://cdn.example/master.m3u8";
  assert.equal(pickVariant(master, base, 720).uri, "720/index.m3u8");
  assert.equal(pickVariant(master, base, 0).height, 1080, "no cap takes the best rendition");
  assert.equal(pickVariant(master, base, 200).height, 360, "a cap below every rendition still takes the smallest");
});

test("segment sizes are summed from HEAD responses", async () => {
  const segments = ["https://sizes.example/one.ts", "https://sizes.example/two.ts"];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (url, init) => {
    assert.equal(init.method, "HEAD");
    return new Response(null, { status: 200, headers: { "content-length": "500" } });
  };
  try {
    assert.equal(await sumSegmentBytes(segments, ""), 1000);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("an unknown segment size reports no total instead of a wrong one", async () => {
  const segments = ["https://sizes.example/alpha.ts", "https://sizes.example/beta.ts"];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 405 });
  try {
    assert.equal(await sumSegmentBytes(segments, ""), 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("a sampled estimate covers segments that hide their size", async () => {
  const segments = Array.from(
    { length: 40 },
    (_, i) => `https://samples.example/part-${i}.ts`,
  );
  const realFetch = globalThis.fetch;
  let calls = 0;
  globalThis.fetch = async (url, init) => {
    assert.equal(init.method, "HEAD");
    calls += 1;
    // Two thirds report a size; the rest stream chunked upstream.
    return calls % 3 === 0
      ? new Response(null, { status: 200 })
      : new Response(null, { status: 200, headers: { "content-length": "1000" } });
  };
  try {
    const estimate = await estimateSegmentBytes(segments, "");
    assert.equal(estimate, 40000, "mean sampled size scaled to the segment count");
    assert.ok(calls <= 25, `sampled ${calls} segments instead of all 40`);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("a single unknown size yields no estimate at all", async () => {
  const segments = ["https://lonely.example/a.ts", "https://lonely.example/b.ts"];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async () => new Response(null, { status: 405 });
  try {
    assert.equal(await estimateSegmentBytes(segments, ""), 0);
  } finally {
    globalThis.fetch = realFetch;
  }
});

test("segment order survives discontinuities and init maps come first", () => {
  const text = [
    "#EXTM3U",
    '#EXT-X-MAP:URI="init.mp4"',
    "a.ts",
    "#EXT-X-DISCONTINUITY",
    "https://other.example/b.ts",
  ].join("\n");
  assert.deepEqual(segmentUrls(text, "https://cdn.example/v/index.m3u8"), [
    "https://cdn.example/v/init.mp4",
    "https://cdn.example/v/a.ts",
    "https://other.example/b.ts",
  ]);
});

test("a variant playlist keeps its stream metadata lines untouched", () => {
  const master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=1280x720\n720/index.m3u8\n";
  const out = rewritePlaylist(master, "https://cdn.example/master.m3u8", "");
  assert.match(out, /#EXT-X-STREAM-INF:BANDWIDTH=800000/);
  assert.match(out, /url=https%3A%2F%2Fcdn\.example%2F720%2Findex\.m3u8/);
});
