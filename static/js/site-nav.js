/* Mobile menu behaviour for every shell that carries #navToggle / #mobileNav.
   The pages used to define this separately, and one of them (the download
   page) defined the button without the function at all. This file supplies
   the missing function and adds the two ways out of a menu that a drawer is
   expected to have: tapping the page behind it, and growing past 900px. */
(function () {
  'use strict';

  function els() {
    return { nav: document.getElementById('mobileNav'), btn: document.getElementById('navToggle') };
  }

  function setOpen(force) {
    var pair = els(), nav = pair.nav, btn = pair.btn;
    if (!nav || !btn) return;
    var wasOpen = nav.classList.contains('open');
    var open = force === undefined ? !wasOpen : !!force;
    nav.classList.toggle('open', open);
    btn.setAttribute('aria-expanded', String(open));
    btn.setAttribute('aria-label', open ? 'Close menu' : 'Open menu');
    if (wasOpen && !open) btn.focus();
  }

  if (typeof window.toggleMobileNav !== 'function') {
    window.toggleMobileNav = setOpen;
  }

  document.addEventListener('click', function (event) {
    var pair = els(), nav = pair.nav, btn = pair.btn;
    if (!nav || !nav.classList.contains('open')) return;
    if (nav.contains(event.target)) return;
    if (btn && btn.contains(event.target)) return;
    window.toggleMobileNav(false);
  });

  document.addEventListener('keydown', function (event) {
    if (event.key !== 'Escape') return;
    var nav = els().nav;
    if (nav && nav.classList.contains('open')) window.toggleMobileNav(false);
  });

  var wide = window.matchMedia('(min-width: 900px)');
  function closeWhenWide(query) {
    if (!query.matches) return;
    var nav = els().nav;
    if (nav && nav.classList.contains('open')) window.toggleMobileNav(false);
  }
  if (wide.addEventListener) wide.addEventListener('change', closeWhenWide);
  else if (wide.addListener) wide.addListener(closeWhenWide);
})();
