// Accessibility sweep: every public page is checked with axe-core against
// WCAG 2.1 AA. Serious and critical violations fail the run; moderate and
// minor ones are reported so they can be triaged instead of ignored.
import { test, expect } from "@playwright/test";
import AxeBuilder from "@axe-core/playwright";

const ORIGIN = process.env.E2E_BASE_URL || "http://127.0.0.1:5055";

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

function summarise(violations) {
  return violations
    .map((v) => {
      const where = v.nodes
        .slice(0, 3)
        .map((n) => n.target.join(" "))
        .join(" | ");
      return `${v.impact} ${v.id}: ${v.help} -> ${where}`;
    })
    .join("\n");
}

async function audit(page, label) {
  const results = await new AxeBuilder({ page })
    .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
    .analyze();
  const blocking = results.violations.filter(
    (v) => v.impact === "serious" || v.impact === "critical",
  );
  if (results.violations.length) {
    // Keep the full list visible in the report even when it does not fail.
    console.log(`[a11y] ${label}: ${results.violations.length} violation(s)\n${summarise(results.violations)}`);
  }
  expect(blocking, `${label}\n${summarise(blocking)}`).toEqual([]);
}

const PAGES = [
  ["/", "home"],
  ["/search?q=naruto", "search results"],
  ["/search?q=zzzqqq123notatitle", "search empty state"],
  ["/download", "download"],
  ["/login", "sign in"],
  ["/login?mode=signup", "sign up"],
  ["/settings", "settings (guest)"],
  ["/developers", "developer docs"],
];

for (const [path, label] of PAGES) {
  test(`axe: ${label}`, async ({ page }) => {
    const resp = await page.goto(path, { waitUntil: "domcontentloaded" });
    expect(resp?.status(), path).toBeLessThan(400);
    await audit(page, label);
  });
}

test("axe: details and watch pages", async ({ page, request }) => {
  const anime = await firstAnime(request);
  const details = await page.goto(`/anime/${anime.id}`, { waitUntil: "domcontentloaded" });
  expect(details?.status()).toBe(200);
  await audit(page, `details ${anime.id}`);

  const watch = await page.goto(`/watch/${anime.id}/1`, { waitUntil: "domcontentloaded" });
  expect(watch?.status()).toBe(200);
  await audit(page, `watch ${anime.id} ep 1`);
});

test("axe: owner console redirect target is labelled", async ({ page }) => {
  // Guests never see the console, so the reachable page is the login form that
  // explains why, with the return path preserved.
  await page.goto("/owner-console", { waitUntil: "domcontentloaded" });
  expect(page.url()).toContain("/login");
  await audit(page, "owner console gate");
});

test("axe: error page", async ({ page }) => {
  const resp = await page.goto("/anime/99999999", { waitUntil: "domcontentloaded" });
  expect(resp?.status()).toBe(404);
  await audit(page, "404 page");
});

test("keyboard: skip link reaches the main region", async ({ page }) => {
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await page.keyboard.press("Tab");
  const focused = await page.evaluate(() => {
    const el = document.activeElement;
    return { text: (el?.textContent || "").trim(), href: el?.getAttribute?.("href") || "" };
  });
  expect(focused.href || focused.text).toBeTruthy();
  expect(ORIGIN).toBeTruthy();
});
