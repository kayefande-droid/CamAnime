/** The mirror's download page must carry the same structure as templates/download.html. */
import test from "node:test";
import assert from "node:assert/strict";
import { downloadPage } from "../src/pages.js";

const base = {
  userName: null,
  user: null,
  version: "2.12.0",
  build: 23,
  sizeLabel: "56.7 MB",
  sha: "0".repeat(64),
  extras: [],
  origin: "https://camanjme.camanime.workers.dev",
};

test("download page uses the same sections and classes as the Render template", () => {
  const page = downloadPage(base);
  for (const cls of ["page-apps", "main-wrap dl-main", "dl-hero", "dl-facts", "dl-platforms",
    "dl-platform-head", "dl-tag", "dl-build", "dl-steps", "dl-copy", "copy-row", "copy-status"]) {
    assert.ok(page.includes(cls), `missing ${cls}`);
  }
  for (const link of ['href="/get/android"', 'href="/get/windows"']) {
    assert.ok(page.includes(link), `missing ${link}`);
  }
  assert.ok(page.includes("Download the CamAnime app"));
  assert.ok(page.includes("Build it yourself"));
  assert.ok(page.includes("CamAnime 2.12.0 (build 23)"));
});

test("download page copies this deployment's own APK URL", () => {
  const page = downloadPage(base);
  assert.ok(page.includes('value="https://camanjme.camanime.workers.dev/get/android"'));
  assert.ok(page.includes("https://camanime.onrender.com/get/android"));
});

test("download page keeps uploaded extras and only shows the admin form to admins", () => {
  const withExtras = downloadPage({
    ...base,
    extras: [{ key: "downloads/notes.zip", name: "notes.zip", size: 2 * 1024 * 1024, url: "/api/download/file/downloads/notes.zip" }],
  });
  assert.ok(withExtras.includes("notes.zip"));
  assert.ok(!withExtras.includes("Admin upload"));

  const admin = downloadPage({ ...base, userName: "owner", user: { role: "admin" } });
  assert.ok(admin.includes("Admin upload"));
});
