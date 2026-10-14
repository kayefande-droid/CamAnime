/* CamAnime site JS: theme memory, search popup slide, play/click tracking, SW register */
(function () {
  try {
    var t = localStorage.getItem("camanime-theme");
    if (t) document.documentElement.setAttribute("data-theme", t);
  } catch (e) {}
  window.caSetTheme = function (name) {
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
