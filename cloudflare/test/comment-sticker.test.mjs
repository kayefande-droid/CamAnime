/** Stickers are rendered as markup, so only the published set may be stored. */
import test from "node:test";
import assert from "node:assert/strict";
import { STICKERS, safeSticker } from "../src/api.js";

test("safeSticker keeps published stickers", () => {
  for (const s of STICKERS) assert.equal(safeSticker(s), s);
  assert.equal(safeSticker(" 🔥 "), "🔥");
});

test("safeSticker drops markup and unknown values", () => {
  assert.equal(safeSticker('<img src=x onerror="alert(1)">'), "");
  assert.equal(safeSticker("<script>x</script>"), "");
  assert.equal(safeSticker("not-a-sticker"), "");
  assert.equal(safeSticker(null), "");
});
