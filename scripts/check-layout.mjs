// Layout parity + overflow check for both hosts.
//   NODE_PATH=<dir with puppeteer-core> node scripts/check-layout.mjs
//
// 1. Collects the same-origin links from each host's home page and reports any
//    page that exists on one host but not the other.
// 2. Visits every shared page at every breakpoint and fails when any element
//    reaches past the viewport edge — including overflow hidden by overflow-x:clip,
//    which `scrollWidth` alone cannot see. Descendants of a horizontal scroll
//    container are exempt: they are meant to be wider than their frame.
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");

const CHROME =
  process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";
const HOSTS = {
  render: "https://camanime.onrender.com",
  mirror: "https://camanjme.camanime.workers.dev",
};
const WIDTHS = [360, 414, 768, 1024, 1280, 1920];
const SKIP = /\/(logout|signout|api\/|static\/|owner-console)/i;

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: "new",
  args: ["--no-sandbox", "--hide-scrollbars"],
});

async function links(base) {
  const page = await browser.newPage();
  await page.setViewport({ width: 1280, height: 900 });
  await page.goto(base + "/", { waitUntil: "domcontentloaded", timeout: 60000 });
  const hrefs = await page.evaluate(() =>
    [...document.querySelectorAll("a[href]")].map((a) => a.getAttribute("href")),
  );
  await page.close();
  const set = new Set();
  for (const h of hrefs) {
    if (!h || h.startsWith("#") || h.startsWith("http") || h.startsWith("mailto")) continue;
    let p = h.split("?")[0].split("#")[0];
    if (!p.startsWith("/") || SKIP.test(p)) continue;
    set.add(p);
  }
  return set;
}

let failures = 0;
const renderLinks = await links(HOSTS.render);
const mirrorLinks = await links(HOSTS.mirror);
const onlyRender = [...renderLinks].filter((p) => !mirrorLinks.has(p));
const onlyMirror = [...mirrorLinks].filter((p) => !renderLinks.has(p));
console.log(`home links: render=${renderLinks.size} mirror=${mirrorLinks.size}`);
if (onlyRender.length) console.log(`  only on render: ${onlyRender.join(" ")}`);
if (onlyMirror.length) console.log(`  only on mirror: ${onlyMirror.join(" ")}`);
if (onlyRender.length || onlyMirror.length) failures++;

const paths = process.env.CHECK_PATHS
  ? process.env.CHECK_PATHS.split(",")
  : [...new Set([...renderLinks, ...mirrorLinks])];

for (const [host, base] of Object.entries(HOSTS)) {
  for (const path of paths) {
    for (const width of WIDTHS) {
      const page = await browser.newPage();
      await page.setViewport({ width, height: 800 });
      try {
        const res = await page.goto(base + path, {
          waitUntil: "domcontentloaded",
          timeout: 60000,
        });
        const status = res?.status() ?? "ERR";
        await new Promise((r) => setTimeout(r, 350));
        const report = await page.evaluate(() => {
          const limit = document.documentElement.clientWidth;
          const intentionallyOffCanvas = (el) => el.classList.contains("skip-link");
          const clipped = (el) => {
            // content that a clip ancestor already cuts off cannot move the page
            for (let p = el.parentElement; p; p = p.parentElement) {
              const ov = getComputedStyle(p).overflowX;
              if (ov === "clip" || ov === "hidden") return true;
            }
            return false;
          };
          const inScroller = (el) => {
            for (let p = el.parentElement; p; p = p.parentElement) {
              const s = getComputedStyle(p);
              if (/(auto|scroll)/.test(s.overflowX) || /(auto|scroll)/.test(s.overflow)) return true;
            }
            return false;
          };
          const offenders = [];
          for (const el of document.body.querySelectorAll("*")) {
            const s = getComputedStyle(el);
            if (s.position === "fixed" || s.display === "none" || s.visibility === "hidden") continue;
            const r = el.getBoundingClientRect();
            if (r.width === 0 || r.height === 0) continue;
            if (r.right <= limit + 1 && r.left >= -1) continue;
            if (intentionallyOffCanvas(el) || inScroller(el) || clipped(el)) continue;
            offenders.push({
              tag: el.tagName.toLowerCase(),
              cls: (el.className || "").toString().slice(0, 50),
              left: Math.round(r.left),
              right: Math.round(r.right),
            });
          }
          return offenders.slice(0, 5);
        });
        const bad = report.length > 0 || status >= 400;
        if (bad) failures++;
        if (bad)
          console.log(
            `FAIL ${host.padEnd(6)} ${String(width).padStart(4)}px ${status} ${path}  ${JSON.stringify(report)}`,
          );
      } catch (err) {
        failures++;
        console.log(`FAIL ${host.padEnd(6)} ${String(width).padStart(4)}px ${path}  ${err.message}`);
      } finally {
        await page.close();
      }
    }
  }
}
await browser.close();
console.log(
  failures ? `\n${failures} check(s) failed` : `\nall ${paths.length} pages clean at ${WIDTHS.length} widths on both hosts`,
);
process.exit(failures ? 1 : 0);
