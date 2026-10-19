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

/* CamAnime source protection (deterrence only — see docs/SECURITY.md) */
(function () {
  try {
    function shield(on) {
      try {
        var el = document.getElementById("ca-shield");
        if (on) {
          if (el) return;
          el = document.createElement("div");
          el.id = "ca-shield";
          el.setAttribute(
            "style",
            "position:fixed;inset:0;z-index:2147483647;background:#07080D;color:#FFB347;" +
              "display:flex;flex-direction:column;gap:14px;align-items:center;justify-content:center;" +
              "text-align:center;font:600 16px/1.5 system-ui,-apple-system,sans-serif;padding:24px;"
          );
          var msg = document.createElement("div");
          msg.textContent = "CamAnime \u2014 Content Protected. Close developer tools to continue.";
          var dismiss = document.createElement("button");
          dismiss.type = "button";
          dismiss.textContent = "Continue";
          dismiss.setAttribute(
            "style",
            "background:#FFB347;color:#07080D;border:0;border-radius:8px;padding:10px 18px;" +
              "font:700 14px system-ui,sans-serif;cursor:pointer;"
          );
          dismiss.onclick = function () {
            shield(false);
          };
          el.appendChild(msg);
          el.appendChild(dismiss);
          (document.body || document.documentElement).appendChild(el);
        } else if (el && el.parentNode) {
          el.parentNode.removeChild(el);
        }
      } catch (e) {}
    }
    document.addEventListener(
      "contextmenu",
      function (ev) {
        try {
          var t = ev.target;
          var tag = t && t.tagName ? t.tagName.toUpperCase() : "";
          if (tag === "INPUT" || tag === "TEXTAREA") return;
          ev.preventDefault();
        } catch (e) {}
      },
      false
    );
    document.addEventListener(
      "keydown",
      function (ev) {
        try {
          var k = ev.key ? ev.key.toUpperCase() : "";
          var code = ev.keyCode || 0;
          var mod = ev.ctrlKey || ev.metaKey;
          if (code === 123 || k === "F12") {
            ev.preventDefault();
            return;
          }
          if (mod && ev.shiftKey && (k === "I" || k === "J" || k === "C")) {
            ev.preventDefault();
            return;
          }
          if (mod && (k === "U" || code === 85)) ev.preventDefault();
        } catch (e) {}
      },
      false
    );
    /* Desktop only: the outer/inner size heuristic false-positives in mobile
       browsers with collapsing URL bars, so never run it on small screens. */
    var desktop = !("ontouchstart" in window) && (window.innerWidth || 0) >= 900;
    if (desktop) {
      var gauge = function () {
        try {
          var w = (window.outerWidth || 0) - (window.innerWidth || 0);
          var h = (window.outerHeight || 0) - (window.innerHeight || 0);
          shield(w > 220 || h > 280);
        } catch (e) {}
      };
      window.addEventListener("resize", gauge);
      window.addEventListener("load", gauge);
      setInterval(gauge, 1500);
    }
  } catch (e) {}
})();
