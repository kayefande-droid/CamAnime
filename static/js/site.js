/*! CamAnime (c) 2026 kayefande-droid. All rights reserved. Unauthorised copying, scraping or redistribution prohibited. */
/* CamAnime site JS: theme memory, search popup slide, play/click tracking, SW register */
(function () {
  var THEMES = ["midnight", "light", "vibrant", "sakura", "forest"];
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

/* CamAnime policy: developer tools, right-click and view-source are intentionally
   left open. Real protection lives on the server (see docs/SECURITY.md) —
   security headers, rate limiting, SSRF containment, scanner-path blocking,
   hardened session cookies and hashed passwords. Nothing in this file
   intercepts keys, clicks, or window size to hinder inspection. */
