// DSH Web on a touch screen: behaviour that CSS alone can't give the drawer
// layout in dsh_web_phone.css. Injected by dsh-app's WebView page after every
// load; idempotent. Exposes window.__dshApp for the app's own buttons.
//
// The drawer is the app's, not the official sidebar's toggle: the official
// sidebar stays expanded underneath and the drawer only slides
// (html[data-dsh-app-layout="drawer"] + the app's data-dsh-app-drawer on the
// frame). Toggling the official one swaps the icon rail for the full sidebar
// — every conversation row mounted, styled and laid out in the frame the
// drawer starts to move, then the grid's column animating under it — which
// is what made opening and closing the drawer stutter. Kept expanded, opening
// is one transform on the compositor.
(function () {
  if (window.__dshApp) return;
  // Install the display default only here, before the page's styles. Declaring
  // it first in the appended phone CSS would give it a later layer position.
  var defaults = document.createElement('style');
  defaults.id = 'dsh-app-phone-layers';
  defaults.textContent = '@layer dsh-app-touch-defaults { @media (pointer: coarse) { ' +
    ':where(:root[data-dsh-app-layout] [data-slot="main"] :is(a, span)[role="button"]:not([hidden], [hidden] *, [data-dsh-adapt="off"], [data-dsh-adapt="off"] *)) ' +
    '{ display: inline-block; } } }';
  document.head.insertBefore(defaults, document.head.firstChild);
  var OPEN = 'data-dsh-app-drawer';

  // The app picks the layout from the frame width (web_view_page.dart) and
  // keeps it current through rotations and resizes. Below 768px DSH 0.2.2 on
  // has a drawer of its own and ties `inert` on the page and the sidebar to its
  // state, so nothing can slide over it: the app's buttons drive that one.
  function drawer() {
    if (document.documentElement.getAttribute('data-dsh-app-layout') !== 'drawer') return false;
    var f = frame();
    return !f || !f.hasAttribute('data-sidebar-drawer');
  }

  function frame() {
    return document.querySelector('[data-slot="root"] > [class*="_frame"]');
  }
  // The official sidebar: expanded, or folded into its icon rail.
  function expanded() {
    var f = frame();
    return !!f && !f.hasAttribute('data-sidebar-collapsed');
  }
  // A right panel (files, terminal…) shares the row: the official layout
  // folds the sidebar for it, and so does the drawer once it closes.
  function rightPanel() {
    var f = frame();
    return !!f && !f.hasAttribute('data-rightbar-collapsed');
  }
  // The toggle is the icon button in the sidebar's logo row, in both the rail
  // and the expanded state (its label is localized, so find it by place).
  function toggleButton() {
    return document.querySelector(
      '[data-slot="sidebar"] [class*="_logoRow"] button[class*="_iconButton"]'
    );
  }
  var toggling = false;
  function setExpanded(open) {
    if (expanded() === open) return;
    var b = toggleButton();
    if (!b) return;
    toggling = true;
    try {
      b.click();
    } finally {
      toggling = false;
    }
  }

  function sidebarOpen() {
    if (!drawer()) return expanded();
    var f = frame();
    return !!f && f.hasAttribute(OPEN);
  }
  function setSidebar(open) {
    // The official layout (tablets): its own sidebar, its own toggle.
    if (!drawer()) return setExpanded(open);
    var f = frame();
    if (!f || f.hasAttribute(OPEN) === open) return;
    if (open) {
      // Folded for a right panel, or not yet expanded: expand first (the
      // one time the rows mount), then slide.
      setExpanded(true);
      f.setAttribute(OPEN, '');
    } else {
      f.removeAttribute(OPEN);
      // Folded behind the slide, where it can't be seen.
      if (rightPanel()) setTimeout(function () { if (!sidebarOpen()) setExpanded(false); }, 360);
    }
  }

  // Ready for the drawer: the official sidebar expanded underneath (unless a
  // right panel needs its track), the drawer closed. Again whenever the
  // layout changes (rotation, a resize across the official breakpoint, which
  // folds the sidebar again).
  var settleTimer = 0;
  function settle(tries) {
    clearTimeout(settleTimer);
    if (!drawer()) return;
    var f = frame();
    if (!f || !toggleButton()) {
      if (tries > 0) settleTimer = setTimeout(function () { settle(tries - 1); }, 200);
      return;
    }
    if (!f.hasAttribute(OPEN)) setExpanded(!rightPanel());
  }
  settle(50);

  // The official toggle inside the open drawer closes the drawer: folding
  // the sidebar into its rail would only show the rail in the drawer.
  document.addEventListener(
    'click',
    function (e) {
      if (toggling || !drawer() || !e.target || !e.target.closest) return;
      var b = e.target.closest('[data-slot="sidebar"] [class*="_logoRow"] button[class*="_iconButton"]');
      if (!b) return;
      e.preventDefault();
      e.stopPropagation();
      setSidebar(!sidebarOpen());
    },
    true
  );

  // A touch beside the open drawer closes it when it lifts and goes no
  // further (the page under the scrim must not react; a drag on the scrim
  // doesn't scroll it either, as on a native drawer). Judged by position,
  // not by event target: on Android a tap on the scrim doesn't reliably
  // target it.
  var pending = false;
  var swallowClick = false;
  function outsideDrawer(e) {
    if (!drawer() || !sidebarOpen()) return false;
    var f = frame();
    var side = f.querySelector('[class*="_sidebarCol"]');
    if (!side || e.clientX <= side.getBoundingClientRect().right) return false;
    // On the scrim (the drawer's column) or what lies under it; a menu or a
    // dialog over the scrim (a row's more menu reaches past the drawer's
    // edge) isn't outside.
    var t = e.target;
    return t === side || (f.contains(t) && !side.contains(t));
  }
  document.addEventListener(
    'pointerdown',
    function (e) {
      if (!outsideDrawer(e)) return;
      e.preventDefault();
      e.stopPropagation();
      pending = true;
    },
    true
  );
  function lifted(e) {
    if (!pending) return;
    pending = false;
    e.stopPropagation();
    // The click that follows the lift goes nowhere either.
    swallowClick = true;
    setTimeout(function () { swallowClick = false; }, 400);
    setSidebar(false);
  }
  document.addEventListener('pointerup', lifted, true);
  document.addEventListener('pointercancel', lifted, true);
  ['mousedown', 'mouseup', 'touchend'].forEach(function (type) {
    document.addEventListener(
      type,
      function (e) {
        if (pending || swallowClick) e.stopPropagation();
      },
      true
    );
  });
  document.addEventListener(
    'click',
    function (e) {
      // The app's own click on the official toggle.
      if (toggling) return;
      if (swallowClick) {
        swallowClick = false;
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      if (!drawer() || !sidebarOpen()) return;
      // Picking a destination closes the drawer; menus and row actions don't.
      var side = frame().querySelector('[class*="_sidebarCol"]');
      if (!side || !side.contains(e.target)) return;
      if (e.target.closest('[class*="_rowActions"], [aria-haspopup], [aria-expanded]')) return;
      var dest = e.target.closest(
        '[role="treeitem"][class*="_sessionRow"], button[class*="_newSession"], button[class*="_brand"], button[class*="_panelRow"]'
      );
      if (dest) setTimeout(function () { setSidebar(false); }, 80);
    },
    true
  );

  // The app offsets <body> under its floating bar; <html> shows above it, so
  // keep it the page colour (light/dark switches included). The layout the
  // app sets on <html> readies the drawer.
  function syncBackground() {
    // A load can finish before <body> exists (the injection then ran without
    // it and must not stop here: window.__dshApp below marks it done).
    if (!document.body) return;
    var bg = getComputedStyle(document.body).backgroundColor;
    if (bg && bg !== 'rgba(0, 0, 0, 0)' && document.documentElement.style.backgroundColor !== bg) {
      document.documentElement.style.backgroundColor = bg;
    }
  }
  syncBackground();
  var layout = document.documentElement.getAttribute('data-dsh-app-layout');
  new MutationObserver(function () {
    syncBackground();
    var now = document.documentElement.getAttribute('data-dsh-app-layout');
    if (now === layout) return;
    layout = now;
    // Leaving the drawer layout: nothing of the app's stays on the frame.
    if (now !== 'drawer') {
      var f = frame();
      if (f) f.removeAttribute(OPEN);
    }
    // After the official layout has measured the new width.
    settleTimer = setTimeout(function () { settle(10); }, 300);
  }).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['class', 'data-theme', 'data-color-scheme', 'data-dsh-app-layout'],
  });
  var watch = { attributes: true, attributeFilter: ['class', 'data-theme', 'data-color-scheme'] };
  function watchBody() {
    syncBackground();
    new MutationObserver(syncBackground).observe(document.body, watch);
  }
  if (document.body) watchBody();
  else document.addEventListener('DOMContentLoaded', watchBody);
  window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () {
    setTimeout(syncBackground, 50);
  });

  window.__dshApp = {
    toggleSidebar: function () { setSidebar(!sidebarOpen()); },
    closeSidebar: function () { setSidebar(false); },
    sidebarOpen: sidebarOpen,
  };
})();
