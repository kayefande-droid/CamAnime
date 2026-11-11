// Playwright config for the CamAnime end-to-end suite.
//
// Chromium runs through the locally installed Chrome because this machine's
// system disk has no room for Playwright's browser downloads. Firefox and
// WebKit projects are declared but only run when their binaries exist, so a
// failing download never hides a Chromium pass.
import { defineConfig, devices } from "@playwright/test";

const localBase = process.env.E2E_BASE_URL || "http://127.0.0.1:5055";
const hasBundled = ["chromium", "firefox", "webkit"].filter(
  (browser) => process.env[`PW_HAS_${browser.toUpperCase()}`] === "1",
);

const projects = [
  {
    name: "chromium",
    use: { ...devices["Desktop Chrome"], channel: "chrome" },
  },
];

for (const browser of ["firefox", "webkit"]) {
  if (hasBundled.includes(browser)) {
    projects.push({ name: browser, use: { ...devices[browser === "firefox" ? "Desktop Firefox" : "Desktop Safari"] } });
  }
}

export default defineConfig({
  testDir: "./tests/e2e",
  timeout: 150_000,
  expect: { timeout: 15_000 },
  fullyParallel: false,
  workers: 1,
  // One retry absorbs the occasional browser-process crash on a machine this
  // low on disk; a real failure fails twice.
  retries: 1,
  projects,
  // This machine's C: is full, so artifacts and the JSON report can be pinned
  // to another drive by env var without changing the config.
  outputDir: process.env.PW_OUTPUT_DIR || "test-results",
  reporter: [["list"], ["json", { outputFile: process.env.PW_JSON || ".e2e/results.json" }]],
  use: {
    baseURL: localBase,
    viewport: { width: 1280, height: 900 },
    screenshot: "only-on-failure",
    trace: "retain-on-failure",
    actionTimeout: 15_000,
    navigationTimeout: 90_000,
  },
  webServer: {
    command: "node tests/e2e/start-server.mjs",
    url: `${localBase}/healthz`,
    reuseExistingServer: false,
    timeout: 120_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
