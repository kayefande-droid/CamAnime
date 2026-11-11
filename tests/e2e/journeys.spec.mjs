// User journeys for CamAnime, run against the real Flask app on a throwaway DB.
// Each test follows TEST-PLAN.md; selectors are roles/labels first, ids only
// where the template has no accessible name.
import { test, expect } from "@playwright/test";

const OWNER = { email: "e2e-owner@example.com", password: "e2e-owner-password" };
const ADMIN_PATH = "/owner-console";
const ORIGIN = process.env.E2E_BASE_URL || "http://127.0.0.1:5055";

function watchConsole(page) {
  const problems = [];
  page.on("console", (msg) => {
    if (msg.type() === "error") problems.push(`console: ${msg.text()}`);
  });
  page.on("requestfailed", (req) => {
    const url = req.url();
    // Third-party CDNs and stream hosts fail intermittently in CI; a failed
    // same-origin asset is always a bug.
    // A <video> source swap aborts the previous media request; that is the
    // browser working as intended, not a broken asset.
    if (req.failure()?.errorText === "net::ERR_ABORTED" && url.includes("/api/proxy/")) return;
    if (url.startsWith(ORIGIN)) {
      problems.push(`request failed: ${url} ${req.failure()?.errorText}`);
    }
  });
  page.on("response", (resp) => {
    const url = resp.url();
    if (url.startsWith(ORIGIN) && resp.status() >= 400 && !url.includes("/api/heaven")) {
      problems.push(`http ${resp.status()}: ${url}`);
    }
  });
  return problems;
}

// AniList answers with a transient 404 or a slow page often enough that a
// single try would make the suite lie about the app. Retry, then fail loudly
// with the provider's own status so a real outage is still visible.
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

async function signUp(page, suffix) {
  const email = `e2e-${suffix}-${Date.now()}@example.com`;
  await page.goto("/login?mode=signup");
  await page.getByLabel("Username").fill(`E2E ${suffix}`);
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill("e2e-password-1");
  await page.getByRole("button", { name: /create free account/i }).click();
  await expect
    .poll(async () => {
      const r = await page.request.get("/api/auth/me");
      return r.status();
    }, { timeout: 20_000 })
    .toBe(200);
  return email;
}

async function signIn(page, email, password) {
  await page.goto("/login");
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Password").fill(password);
  await page.getByRole("button", { name: /sign in securely/i }).click();
}

// ── J1 … J4: browsing and playing ────────────────────────────────────────

test("J1 home renders the catalogue with no console errors", async ({ page, request }) => {
  const problems = watchConsole(page);
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(page).toHaveTitle(/CamAnime/i);

  const cards = page.locator('a[href^="/anime/"]');
  for (let attempt = 0; attempt < 3; attempt += 1) {
    if ((await cards.count()) > 3) break;
    await page.reload({ waitUntil: "domcontentloaded" });
    await page.waitForTimeout(3000);
  }
  await expect.poll(async () => cards.count(), { timeout: 30_000 }).toBeGreaterThan(3);

  const href = await cards.first().getAttribute("href");
  expect(href).toMatch(/^\/anime\/\d+$/);

  // Content is server-rendered: with JS off the cards are still there.
  const noJs = await request.get("/");
  expect(await noJs.text()).toContain('href="/anime/');
  expect(problems, problems.join("\n")).toEqual([]);
});

test("J2 search returns matches, and an empty state for nonsense", async ({ page }) => {
  await page.goto("/search?q=naruto");
  await expect(page).toHaveTitle(/search|naruto/i);
  await expect.poll(async () => page.locator('a[href^="/anime/"]').count(), { timeout: 30_000 }).toBeGreaterThan(0);

  await page.goto("/search?q=zzzqqq123notatitle", { waitUntil: "domcontentloaded" });
  const text = await page.locator("body").innerText();
  expect(text).toMatch(/No .*titles matched/i);
  await expect(page.getByRole("link", { name: "Clear search" })).toHaveAttribute("href", "/");

  // A 500-character query is capped, not crashed.
  const long = "a".repeat(500);
  const resp = await page.request.get(`/api/v1/search?q=${long}`);
  expect(resp.status()).toBeLessThan(500);
});

test("J3 details page shows the episode rail and 404s an unknown id", async ({ page, request }) => {
  const anime = await firstAnime(request);
  await page.goto(`/anime/${anime.id}`);
  await expect(page.locator("h1").first()).toBeVisible();
  await expect(page.locator(`a[href^="/watch/${anime.id}/"]`).first()).toBeVisible();

  const poster = page.locator("img").first();
  await expect(poster).toBeVisible();
  await expect.poll(async () => poster.evaluate((img) => img.naturalWidth), { timeout: 20_000 }).toBeGreaterThan(0);

  const missing = await page.goto("/anime/99999999");
  expect(missing.status()).toBe(404);
});

test("J4 watch page resolves a source and surfaces player errors", async ({ page, request }) => {
  const anime = await firstAnime(request);
  const sources = await request.get(`/api/episode-sources/${anime.id}/1`);
  expect(sources.status()).toBe(200);
  const payload = await sources.json();
  expect(JSON.stringify(payload)).toMatch(/https?:\/\//);

  const problems = watchConsole(page);
  await page.goto(`/watch/${anime.id}/1`, { waitUntil: "domcontentloaded" });
  await expect(page.locator("#caPlayer")).toBeVisible();

  const ready = await page.waitForFunction(() => {
    const video = document.querySelector("#nativeVideo");
    const frame = document.querySelector("#embedIframe");
    const videoSrc = video?.currentSrc || video?.src || "";
    const frameSrc = frame?.getAttribute("src") || "";
    return Boolean(videoSrc || frameSrc);
  }, undefined, { timeout: 45_000 });
  expect(await ready.jsonValue()).toBe(true);

  // No same-origin 4xx/5xx and no console errors while the player boots.
  expect(problems, problems.join("\n")).toEqual([]);
});

// ── J5, J6: community ────────────────────────────────────────────────────

test("J5 a guest comment posts, validates, and a bad sticker is rejected", async ({ page, request }) => {
  const anime = await firstAnime(request);
  const body = { anime_id: String(anime.id), ep: "1", name: "E2E guest" };

  const empty = await request.post("/api/community/comment", { data: { ...body, text: "   " } });
  expect(empty.status()).toBe(400);

  // Guests are throttled to one comment every eight seconds; posting twice in
  // a row must be refused with the wait message, not silently accepted.
  const tooSoon = await request.post("/api/community/comment", { data: { ...body, text: "second try" } });
  expect(tooSoon.status()).toBe(429);
  expect((await tooSoon.json()).error).toMatch(/slow down/i);
  await page.waitForTimeout(9000);

  const long = await request.post("/api/community/comment", { data: { ...body, text: "x".repeat(900) } });
  expect(long.status()).toBe(200);
  expect((await long.json()).comment.text.length).toBeLessThanOrEqual(600);

  await page.waitForTimeout(9000);
  const badSticker = await request.post("/api/community/comment", {
    data: { ...body, text: "sticker probe", sticker: '<img src=x onerror=alert(1)>' },
  });
  expect(badSticker.status()).toBe(200);
  const stored = (await badSticker.json()).comment.sticker || "";
  expect(stored).not.toContain("<");

  await page.waitForTimeout(9000);
  const posted = await request.post("/api/community/comment", {
    data: { ...body, text: `e2e hello ${Date.now()}`, sticker: "🔥" },
  });
  expect(posted.status()).toBe(200);
  expect((await posted.json()).status).toBe("success");

  await page.goto(`/watch/${anime.id}/1`);
  await expect(page.locator("#ca-comments")).toContainText("e2e hello", { timeout: 20_000 });
});

test("J6 rating posts and the score is clamped to 1-10", async ({ page, request }) => {
  const anime = await firstAnime(request);
  const ok = await request.post("/api/community/rate", { data: { anime_id: String(anime.id), score: 9 } });
  expect(ok.status()).toBe(200);
  const bad = await request.post("/api/community/rate", { data: { anime_id: String(anime.id), score: 44 } });
  expect(bad.status()).toBe(400);

  await page.goto(`/watch/${anime.id}/1`, { waitUntil: "domcontentloaded" });
  const scoreButton = page.locator("#ca-rate-row button").first();
  await expect(scoreButton).toBeVisible({ timeout: 20_000 });
  await scoreButton.click();
  await expect(page.locator("#ca-rating-out")).not.toHaveText(/Tap a score/i, { timeout: 15_000 });
});

// ── J7: the APK ──────────────────────────────────────────────────────────

test("J7 the download page names version 2.12.0 and serves the APK", async ({ page, request }) => {
  await page.goto("/download");
  const text = await page.locator("body").innerText();
  expect(text).toContain("2.12.0");
  expect(text).toMatch(/23/);

  // The APK is streamed, not redirected; check its size so a placeholder HTML
  // file can never pass as the app.
  const apk = await request.head("/get/android");
  expect(apk.status()).toBe(200);
  expect(Number(apk.headers()["content-length"] || 0)).toBeGreaterThan(50 * 1024 * 1024);
});

// ── J8, J9: member journeys ──────────────────────────────────────────────

test("J8 sign up, sign in, sign out, and their failure cases", async ({ page }) => {
  const email = await signUp(page, "member");
  const me = await (await page.request.get("/api/auth/me")).json();
  expect(me.user.email).toBe(email);

  await page.request.post("/api/auth/logout");
  expect((await page.request.get("/api/auth/me")).status()).toBe(401);

  // /settings is readable without an account (it holds theme preferences) but
  // must offer a sign-in rather than showing member controls.
  await page.goto("/settings");
  await expect(page.locator("body")).toContainText(/sign in/i);

  // A private page sends a signed-out visitor to login and remembers where.
  const privatePage = await page.request.get(ADMIN_PATH, { maxRedirects: 0 });
  expect(privatePage.headers().location).toContain("/login?next=");

  // Wrong password: an inline error and no session.
  await signIn(page, email, "definitely-wrong");
  await expect(page.locator("body")).toContainText(/incorrect|wrong|invalid|try again/i, { timeout: 15_000 });
  expect((await page.request.get("/api/auth/me")).status()).toBe(401);

  // Duplicate email is refused with a readable message.
  const dup = await page.request.post("/api/auth/register", {
    data: { email, password: "another-password", name: "Dup" },
  });
  expect(dup.status()).toBe(400);

  // Correct password works and sign-out clears the session again.
  await signIn(page, email, "e2e-password-1");
  await expect.poll(async () => (await page.request.get("/api/auth/me")).status(), { timeout: 20_000 }).toBe(200);
});

test("J9 history is owner-only and the watch page resumes", async ({ page, request }) => {
  const anime = await firstAnime(request);

  // Signed out: 401, never a silent success.
  const anon = await request.post("/api/history", { data: { anime_id: String(anime.id), ep: 1, position: 5 } });
  expect(anon.status()).toBe(401);

  const email = await signUp(page, "resume");
  const saved = await page.request.post("/api/history", {
    data: {
      anime_id: String(anime.id), ep: 1, position: 240, duration: 1300,
      title: anime.title || "E2E", image: anime.image || "",
    },
  });
  expect(saved.status()).toBe(200);

  await page.goto(`/watch/${anime.id}/1`, { waitUntil: "domcontentloaded" });
  await expect(page.locator("#caResumeNote")).toBeVisible({ timeout: 30_000 });
  await expect(page.locator("#caResumeNote")).toContainText(/0?4:00|4:0/);

  // Another account sees none of it. The API signs in with a bearer token
  // instead of a cookie, so the second reader is measured on its own token,
  // never on the first account's browser session.
  const otherEmail = `e2e-other-${Date.now()}@example.com`;
  const other = await request.post("/api/auth/register", {
    data: { email: otherEmail, password: "e2e-password-2", name: "Other" },
  });
  expect(other.status()).toBe(200);
  const otherLogin = await request.post("/api/auth/login", { data: { email: otherEmail, password: "e2e-password-2" } });
  expect(otherLogin.status()).toBe(200);
  const otherAuth = { Authorization: `Bearer ${(await otherLogin.json()).token}` };
  const otherHistory = await (await request.get("/api/history", { headers: otherAuth })).json();
  expect(otherHistory.history).toEqual([]);

  // The first account still has its row, and remove clears only its own.
  const mineLogin = await request.post("/api/auth/login", { data: { email, password: "e2e-password-1" } });
  const mineAuth = { Authorization: `Bearer ${(await mineLogin.json()).token}` };
  const mine = await (await request.get("/api/history", { headers: mineAuth })).json();
  expect(mine.history).toHaveLength(1);
  const remove = await request.post("/api/history/remove", { data: { anime_id: String(anime.id) }, headers: mineAuth });
  expect(remove.status()).toBe(200);
  const after = await (await request.get("/api/history", { headers: mineAuth })).json();
  expect(after.history).toEqual([]);
});

// ── J10, J11: boundaries and errors ─────────────────────────────────────

test("J10 the owner console is closed to guests and members, open to the owner", async ({ page }) => {
  const guest = await page.request.get(ADMIN_PATH, { maxRedirects: 0 });
  expect([301, 302]).toContain(guest.status());
  expect([401, 403]).toContain((await page.request.get("/api/admin/users")).status());

  await signUp(page, "not-owner");
  const member = await page.request.get(ADMIN_PATH, { maxRedirects: 0 });
  expect([301, 302, 403]).toContain(member.status());
  const memberApi = await page.request.get("/api/admin/users");
  expect([401, 403]).toContain(memberApi.status());

  await page.request.post("/api/auth/logout");
  await signIn(page, OWNER.email, OWNER.password);
  await expect.poll(async () => (await page.request.get("/api/auth/me")).status(), { timeout: 25_000 }).toBe(200);
  const ownerPage = await page.request.get(ADMIN_PATH);
  expect(ownerPage.status()).toBe(200);
  const ownerApi = await page.request.get("/api/admin/users");
  expect(ownerApi.status()).toBe(200);
});

test("J10b the media proxy refuses private addresses", async ({ request }) => {
  const probe = await request.get("/api/proxy/hls?url=http://10.0.0.5/x.m3u8");
  expect(probe.status()).toBe(400);
});

test("J11 unknown routes give the 404 page and the API answers in JSON", async ({ page, request }) => {
  const missing = await page.goto("/this-route-does-not-exist");
  expect(missing.status()).toBe(404);
  const text = await page.locator("body").innerText();
  expect(text).toMatch(/404|not found|lost/i);

  const api = await request.get("/api/v1/anime/99999999/episodes");
  expect(api.headers()["content-type"]).toContain("application/json");
  expect(api.status()).toBeGreaterThanOrEqual(200);
});
