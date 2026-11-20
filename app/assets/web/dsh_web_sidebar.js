// The official sidebar's drawer, seen from the app. Injected by dsh-app's
// WebView page after every load (idempotent): it only reports, and only when
// the official layout turns the sidebar into a drawer (phone widths) — the
// app's own phone layout has its own drawer (dsh_web_phone.js).
//
// The app's marker sits in DSH Web's leading seat, over the page's own header
// row; the sidebar, opened, slides over that row. So the marker steps aside
// while the sidebar is up instead of covering the sidebar's brand and rows.
(function () {
  if (window.__dshAppSidebar) return;

  var CHANNEL = 'DshAppSidebar';

  function frame() {
    return document.querySelector('[data-slot="root"] > [class*="_frame"]');
  }

  // The drawer is up while the frame keeps it open: the official layout puts
  // `data-sidebar-drawer` on the frame at phone widths and folds the sidebar
  // away with `data-sidebar-collapsed`. Wider windows show the sidebar as a
  // column (no drawer): nothing to cover, so that reads as closed.
  //
  // The app's own phone layout sets `html[data-dsh-app-layout="drawer"]`; its
  // drawer is the app's (dsh_web_phone.js, dsh_web_phone.css) and the marker
  // sits below it, so only the official layout's drawer counts here.
  function open() {
    if (document.documentElement.getAttribute('data-dsh-app-layout') === 'drawer') return false;
    var f = frame();
    return !!f && f.hasAttribute('data-sidebar-drawer') && !f.hasAttribute('data-sidebar-collapsed');
  }

  // Closed to start with: the app's marker is up before the page says
  // otherwise, and a load that finishes on an error page never says.
  var last = false;
  function report() {
    var now = open();
    if (now === last) return;
    last = now;
    try {
      var channel = window[CHANNEL];
      if (channel && channel.postMessage) channel.postMessage(now ? 'open' : 'closed');
    } catch (e) {
      // No channel (an old shell): nothing to tell.
    }
  }

  // The frame can be replaced when the page rebuilds its layout; keep the
  // attribute watch on whichever frame is there, and report the new state.
  var watched = null;
  var frameObserver = new MutationObserver(report);
  function bind() {
    var f = frame();
    if (f === watched) return;
    frameObserver.disconnect();
    watched = f;
    if (f) {
      frameObserver.observe(f, {
        attributes: true,
        attributeFilter: ['data-sidebar-drawer', 'data-sidebar-collapsed'],
      });
    }
    report();
  }

  // Page load can finish before React mounts the root slot. Watch from the
  // document so a late root (or its replacement) also gets a frame listener.
  new MutationObserver(bind).observe(document.documentElement, { childList: true, subtree: true });
  new MutationObserver(report).observe(document.documentElement, {
    attributes: true,
    attributeFilter: ['data-dsh-app-layout'],
  });
  window.__dshAppSidebar = true;
  bind();
})();
