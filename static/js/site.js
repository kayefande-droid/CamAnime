/*! CamAnime (c) 2026 kayefande-droid. All rights reserved. Unauthorised copying, scraping or redistribution prohibited. */
/* CamAnime site JS: theme memory, search popup slide, play/click tracking, SW register */
(function () {
  var THEMES = ["midnight", "light", "vibrant", "sakura", "forest", "obsidian", "neo", "tokyo"];
  try {
    var t = localStorage.getItem("camanime-theme");
    if (THEMES.indexOf(t) === -1) t = null;
    if (t) document.documentElement.setAttribute("data-theme", t);
    else document.documentElement.setAttribute("data-theme", "midnight");
    if (localStorage.getItem("camanime-motion") === "1") document.documentElement.dataset.motion = "reduced";
  } catch (e) {}
  window.caSetTheme = function (name) {
    if (THEMES.indexOf(name) === -1) name = "midnight";
    document.documentElement.setAttribute("data-theme", name);
    try { localStorage.setItem("camanime-theme", name); } catch (e) {}
  };
  window.caSearchPop = function (open) {
    var el = document.getElementById("caSearchPop");
    if (el) el.classList.toggle("open", open !== false);
  };
  window.caTrack = function (kind, animeId, ep) {
    try {
      var fd = new FormData();
      fd.append("kind", kind);
      fd.append("anime_id", animeId || "");
      fd.append("ep", ep || "");
      fetch("/api/track", { method: "POST", body: fd, credentials: "same-origin" });
    } catch (e) {}
  };
  if ("serviceWorker" in navigator) {
    window.addEventListener("load", function () {
      navigator.serviceWorker.register("/static/sw.js").catch(function () {});
    });
  }
})();

/* CamAnime data-saver: adapts to slow or metered networks without any Setup.
   Auto mode uses the Network Information API (saveData / 2G/3G / low downlink);
   users can force Data saver on or off from Settings (camanime-data-saver).
   Effect: html[data-data=low/medium/normal] CSS hooks trim heavy blur + hover
   compositing, posters swap to the smaller CDn variant, and loading="lazy"
   is applied to grid images. The watch player reads the tier to size its
   forward buffer. */
(function () {
  var PREF_KEY = "camanime-data-saver"; // "auto" | "low" | "normal"
  function pref() {
    try { return localStorage.getItem(PREF_KEY) || "auto"; } catch (e) { return "auto"; }
  }
  function conn() { return navigator.connection || navigator.mozConnection || navigator.webkitConnection || null; }
  function tier() {
    var p = pref(), c = conn();
    if (p === "low") return "low";
    if (p === "normal") return "normal";
    if (!c) return "normal"; // no telemetry: assume a healthy link, stay full-quality
    if (c.saveData) return "low";
    var et = c.effectiveType || "";
    if (et === "slow-2g" || et === "2g") return "low";
    if (et === "3g") return "medium";
    var dl = typeof c.downlink === "number" ? c.downlink : 10;
    if (dl && dl < 2) return "medium";
    return "normal";
  }
  function apply() {
    var t = tier();
    var root = document.documentElement;
    var changed = root.getAttribute("data-data") !== t;
    root.setAttribute("data-data", t);
    if (changed && document.dispatchEvent) {
      try { document.dispatchEvent(new CustomEvent("camanime:data", { detail: { tier: t } })); } catch (e) {}
    }
    if (t !== "normal") {
      var imgs = document.querySelectorAll(".card-poster-wrap img, .anime-card img, .mini-grid img");
      for (var i = 0; i < imgs.length; i++) {
        var img = imgs[i], src = img.getAttribute("src") || "";
        if (!img.getAttribute("data-ca-saved") && src.indexOf("/cover/large/") !== -1) {
          img.setAttribute("data-ca-saved", "1");
          img.setAttribute("src", src.replace("/cover/large/", "/cover/medium/"));
        }
        if (!img.getAttribute("loading")) img.setAttribute("loading", "lazy");
        img.setAttribute("decoding", "async");
      }
    }
  }
  var c = conn();
  if (c && c.addEventListener) {
    try { c.addEventListener("change", apply); } catch (e) {}
  }
  window.caDataSaver = {
    pref: pref,
    set: function (v) {
      try { localStorage.setItem(PREF_KEY, v === "low" ? "low" : (v === "normal" ? "normal" : "auto")); } catch (e) {}
      apply();
    },
    tier: tier,
    label: function (t) {
      t = t || tier();
      if (t === "low") return "Slow / metered link detected — light posters, no blur, max buffering";
      if (t === "medium") return "Moderate link detected — lighter posters and trimmed effects";
      return "Good connection — full quality";
    }
  };
  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", apply);
  else apply();
})();

/* CamAnime layout templates: complete switchable layout recipes that combine with themes.
   classic (default), cinema, compact, minimal — reflow grids, posters, hero and controls */
(function () {
  var LAYOUTS = ["classic", "cinema", "compact", "minimal", "wide", "magazine", "wall"];
  try {
    var l = localStorage.getItem("camanime-layout");
    if (LAYOUTS.indexOf(l) === -1) l = null;
    document.documentElement.setAttribute("data-layout", l || "classic");
  } catch (e) {}
  window.caSetLayout = function (name) {
    if (LAYOUTS.indexOf(name) === -1) name = "classic";
    document.documentElement.setAttribute("data-layout", name);
    try { localStorage.setItem("camanime-layout", name); } catch (e) {}
    try { document.dispatchEvent(new CustomEvent("camanime:layout", { detail: { layout: name } })); } catch (e) {}
  };
  window.caLayouts = LAYOUTS;
})();

/* CamAnime policy: developer tools, right-click and view-source are intentionally
   left open. Real protection lives on the server (see docs/SECURITY.md) —
   security headers, rate limiting, SSRF containment, scanner-path blocking,
   hardened session cookies and hashed passwords. Nothing in this file
   intercepts keys, clicks, or window size to hinder inspection. */
