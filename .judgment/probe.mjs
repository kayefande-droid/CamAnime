import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");
const b = await puppeteer.launch({executablePath:"C:/Program Files/Google/Chrome/Application/chrome.exe",headless:"new",args:["--no-sandbox"]});
const p = await b.newPage();
await p.setViewport({width:360,height:800});
await p.goto(process.argv[2], {waitUntil:"domcontentloaded", timeout:60000});
await new Promise(r=>setTimeout(r,500));
console.log(JSON.stringify(await p.evaluate(()=>{
  const limit = document.documentElement.clientWidth;
  const bad = [];
  for (const el of document.body.querySelectorAll("*")) {
    const s = getComputedStyle(el);
    if (s.position === "fixed" || s.display === "none") continue;
    const r = el.getBoundingClientRect();
    if (r.width && r.right > limit + 1 && !el.classList.contains("skip-link")) {
      const chain = [];
      for (let a = el; a && chain.length < 4; a = a.parentElement) {
        const cs = getComputedStyle(a);
        chain.push({t:a.tagName.toLowerCase(), c:(a.className||"").toString().slice(0,40), w:Math.round(a.getBoundingClientRect().width), disp:cs.display, wrap:cs.flexWrap, ov:cs.overflowX});
      }
      bad.push({w:Math.round(r.width), right:Math.round(r.right), chain});
    }
  }
  return bad.slice(0,4);
}), null, 1));
await b.close();
