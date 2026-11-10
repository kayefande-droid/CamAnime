// Capture the computed colours/type of every visible element, so a CSS refactor
// can be proven not to have changed any rendering.
//   NODE_PATH=<dir with puppeteer-core> node scripts/snapshot-styles.mjs out.json
import { createRequire } from "node:module";
import { writeFileSync } from "node:fs";
const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");

const CHROME = process.env.CHROME_PATH || "C:/Program Files/Google/Chrome/Application/chrome.exe";
const HOSTS = {
  render: "https://camanime.onrender.com",
  mirror: "https://camanjme.camanime.workers.dev",
};
const PATHS = (process.env.CHECK_PATHS || "/,/download,/developers").split(",");
const WIDTHS = [360, 1280];

const browser = await puppeteer.launch({ executablePath: CHROME, headless: "new", args: ["--no-sandbox"] });
const snap = {};
for (const [host, base] of Object.entries(HOSTS)) {
  for (const path of PATHS) {
    for (const width of WIDTHS) {
      const page = await browser.newPage();
      await page.setViewport({ width, height: 900 });
      await page.goto(base + path, { waitUntil: "networkidle2", timeout: 90000 }).catch(() => {});
      const styles = await page.evaluate(() => {
        const out = [];
        const els = [...document.querySelectorAll("body *")];
        els.forEach((el, i) => {
          const s = getComputedStyle(el);
          if (s.display === "none" || s.visibility === "hidden") return;
          out.push([
            i,
            el.tagName.toLowerCase(),
            s.color,
            s.backgroundColor,
            s.fontSize,
            s.fontWeight,
            s.borderTopColor,
            s.borderRadius,
            s.boxShadow === "none" ? "-" : "shadow",
          ].join("|"));
        });
        return out;
      });
      snap[`${host}${path}@${width}`] = styles;
      await page.close();
    }
  }
}
await browser.close();
writeFileSync(process.argv[2], JSON.stringify(snap, null, 0));
console.log(`captured ${Object.keys(snap).length} page states`);
