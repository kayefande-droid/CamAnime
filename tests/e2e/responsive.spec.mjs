// Responsive sweep: no page may scroll sideways at any width a real device
// uses, from a small Android phone to a wide desktop. `scrollWidth` beyond the
// viewport is the measurable symptom of a layout that overflows.
import { test, expect } from "@playwright/test";

const WIDTHS = [360, 390, 768, 1024, 1440, 1920];

const PAGES = [
  ["/", "home"],
  ["/search?q=naruto", "search"],
  ["/download", "download"],
  ["/login?mode=signup", "sign up"],
  ["/developers", "developers"],
];

async function firstAnime(request) {
  let last = "no attempt";
  for (let attempt = 0; attempt < 4; attempt += 1) {
    const resp = await request.get("/api/v1/catalog/home");
    last = `status ${resp.status()}`;
    if (resp.status() === 200) {
      const body = await resp.json();
      const card =
        body?.catalog?.trending?.[0] ||
        body?.catalog?.popular?.[0] ||
        body?.catalog?.recently_added?.[0];
      if (card) return card;
      last = `empty catalog (source ${body?.catalog_source})`;
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error(`catalogue unavailable after 4 tries: ${last}`);
}

async function overflowOf(page) {
  return page.evaluate(() => {
    const doc = document.documentElement;
    const wide = [];
    for (const el of document.querySelectorAll("body *")) {
      const r = el.getBoundingClientRect();
      if (r.width > 0 && r.right > doc.clientWidth + 2) {
        wide.push(`${el.tagName.toLowerCase()}.${(el.className || "").toString().split(" ")[0]}`);
      }
    }
    return {
      scrollWidth: doc.scrollWidth,
      clientWidth: doc.clientWidth,
      offenders: [...new Set(wide)].slice(0, 8),
    };
  });
}

for (const [path, label] of PAGES) {
  for (const width of WIDTHS) {
    test(`${label} fits ${width}px`, async ({ page }) => {
      await page.setViewportSize({ width, height: 900 });
      const resp = await page.goto(path, { waitUntil: "domcontentloaded" });
      expect(resp?.status(), path).toBeLessThan(400);
      const result = await overflowOf(page);
      expect(
        result.scrollWidth,
        `${label} at ${width}px scrolls to ${result.scrollWidth}px; widest: ${result.offenders.join(", ")}`,
      ).toBeLessThanOrEqual(result.clientWidth + 2);
    });
  }
}

test("details and watch pages fit a phone and a desktop", async ({ page, request }) => {
  const anime = await firstAnime(request);
  for (const width of [360, 1920]) {
    for (const path of [`/anime/${anime.id}`, `/watch/${anime.id}/1`]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto(path, { waitUntil: "domcontentloaded" });
      const result = await overflowOf(page);
      expect(
        result.scrollWidth,
        `${path} at ${width}px scrolls to ${result.scrollWidth}px; widest: ${result.offenders.join(", ")}`,
      ).toBeLessThanOrEqual(result.clientWidth + 2);
    }
  }
});
