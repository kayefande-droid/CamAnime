/* CamAnime — reveal driver for motion.css.
   Marks sections and cards as they enter the viewport and gives siblings a
   shared stagger index. Everything degrades to the static page: no class is
   added unless this file runs, and nothing is hidden without `.ca-reveal`. */
(function () {
  'use strict';

  var reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)');
  if (reduce && reduce.matches) return;
  if (!('IntersectionObserver' in window)) return;

  var SELECTOR = '.section-block, .panel-box, .anime-card, .stat, .tool-card';
  var MAX_STEP = 8;
  var seen = new WeakSet();

  var io = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add('ca-in');
      io.unobserve(entry.target);
      setTimeout(function () { entry.target.style.willChange = ''; }, 900);
    });
  }, { rootMargin: '0px 0px -8% 0px', threshold: 0.08 });

  function scan(root) {
    var nodes = (root || document).querySelectorAll(SELECTOR);
    var batch = new Map();
    for (var i = 0; i < nodes.length; i++) {
      var el = nodes[i];
      if (seen.has(el)) continue;
      // Already on screen at load: show it immediately, no animation.
      var box = el.getBoundingClientRect();
      var onScreen = box.top < window.innerHeight && box.bottom > 0;
      if (onScreen) { seen.add(el); continue; }
      seen.add(el);
      el.classList.add('ca-reveal');
      var parent = el.parentElement || document.body;
      var n = batch.get(parent) || 0;
      batch.set(parent, n + 1);
      el.style.setProperty('--i', String(Math.min(n, MAX_STEP)));
      io.observe(el);
    }
  }

  function ready() {
    scan(document);
    // Catalogue rows and rails fill in after load; pick new cards up quietly.
    if ('MutationObserver' in window) {
      var pending = null;
      new MutationObserver(function () {
        if (pending) return;
        pending = setTimeout(function () { pending = null; scan(document); }, 180);
      }).observe(document.body, { childList: true, subtree: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', ready);
  } else {
    ready();
  }
})();
