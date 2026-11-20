// System back inside DSH Web, one step at a time. Injected by dsh-app's
// WebView page after every load (phone layout on or off); idempotent.
//
// The official client keeps where the person is in component state: no URL
// changes and no history entries (0.2.1-rc.4 calls neither pushState nor
// replaceState), so the WebView's own history can't take back. The app asks
// window.__dshAppBack() first; it takes the topmost step there is and says
// which:
//
//   'layer'   the top dialog or menu (settings included) got Escape, the key
//             the official modal layer and menus close on
//   'popup'   a popover that closes on a touch elsewhere (the composer's
//             suggestions, pickers, the Cordis panel) got one
//   'drawer'  the sidebar as a drawer closed: the app's (phone layout) or
//             DSH Web's own (official layout, phone widths)
//   'panel'   the right panel covering the conversation (files, terminal)
//             folded away
//   'page'    the main area went up a level: a plugin's page to the list, a
//             subagent's conversation to its parent's
//   'chat'    a full page (plugins, automations…) gave way to the
//             conversation, through its row in the sidebar
//   'none'    nothing left: the app goes back itself
//
// Only presses what a person could (the close key, a touch outside, the
// official buttons); never changes official state itself. Nothing can hold
// back forever: a dialog still open after Escape gets its own way out (its
// backdrop, its close button), and after that the app takes back; a popover
// that stays gets passed over.
(function () {
  if (window.__dshAppBack) return;

  // dsh-client-ui-primitives' modalSelector: their order in the document is
  // the order of the official modal stack.
  var MODAL = '[role="dialog"][aria-modal="true"], [role="menu"]';
  // Floating but not modal: they close on a pointer down outside them.
  var POPUP = '[role="dialog"]:not([aria-modal="true"]), [role="listbox"], [data-cordis-panel]';
  // A target still there this long after a try did not close.
  var SETTLE_MS = 500;
  // The dialog, menu or popover tried last: {el, n (tries), at}.
  var tries = null;

  function shown(el) {
    return !!el && el.isConnected && el.getClientRects().length > 0;
  }

  function lastShown(selector, root) {
    var all = (root || document).querySelectorAll(selector);
    for (var i = all.length - 1; i >= 0; i--) {
      if (shown(all[i])) return all[i];
    }
    return null;
  }

  function attempt(el) {
    if (!tries || tries.el !== el) tries = { el: el, n: 0, at: 0 };
    return tries;
  }

  // Tried a moment ago: still on its way out (a second press of the same
  // back, or a close animation). Takes the press without trying again.
  function settling(t) {
    return t.n > 0 && Date.now() - t.at < SETTLE_MS;
  }

  function editable(el) {
    return !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
  }

  function key(target, type) {
    target.dispatchEvent(
      new KeyboardEvent(type, { key: 'Escape', code: 'Escape', keyCode: 27, which: 27, bubbles: true, cancelable: true })
    );
  }

  // Escape, as a key press. The official layer ignores the key that ends an
  // IME composition: a word still being composed is committed first, and a
  // key up clears what the composition left behind.
  function escape() {
    var active = document.activeElement;
    if (editable(active)) active.blur();
    var target = document.activeElement || document.body;
    key(target, 'keyup');
    key(target, 'keydown');
    key(target, 'keyup');
  }

  // A touch on the page's background, outside every popover.
  function touchOutside() {
    var init = { bubbles: true, cancelable: true, pointerType: 'touch', isPrimary: true };
    document.body.dispatchEvent(new PointerEvent('pointerdown', init));
    document.body.dispatchEvent(new PointerEvent('pointerup', init));
  }

  // A dialog's own way out when Escape didn't do it: its backdrop (the
  // official modals put it right before the dialog), else its close button.
  function dismiss(layer) {
    if (layer.getAttribute('role') === 'menu') return touchOutside();
    var mask = layer.previousElementSibling;
    if (mask && mask.getAttribute('aria-hidden') === 'true' && /_mask/.test(mask.className)) return mask.click();
    var close = layer.querySelector('button[class*="_close"]');
    if (close) close.click();
  }

  function frame() {
    return document.querySelector('[data-slot="root"] > [class*="_frame"]');
  }

  function step() {
    // 1. The top dialog or menu: Escape, then its own way out. One that
    //    stays even so (a notice to acknowledge) holds what is under it,
    //    and the app takes back.
    var layer = lastShown(MODAL);
    if (layer) {
      var t = attempt(layer);
      if (settling(t)) return 'layer';
      if (t.n >= 2) return 'none';
      if (t.n === 0) escape();
      else dismiss(layer);
      t.n++;
      t.at = Date.now();
      return 'layer';
    }

    // 2. A popover, once.
    var popup = lastShown(POPUP);
    if (popup) {
      var p = attempt(popup);
      if (settling(p)) return 'popup';
      if (p.n === 0) {
        touchOutside();
        p.n++;
        p.at = Date.now();
        return 'popup';
      }
    }

    // 3. The sidebar as a drawer: the app's with the phone layout, DSH Web's
    //    own in the official layout at phone widths (its toggle in the
    //    sidebar's logo row is the way a person folds it). Only the official
    //    layout: with the phone layout the frame is a drawer too, and its
    //    sidebar stays expanded inside the app's.
    var app = window.__dshApp;
    var appLayout = document.documentElement.getAttribute('data-dsh-app-layout');
    if (app && appLayout === 'drawer' && app.sidebarOpen()) {
      app.closeSidebar();
      return 'drawer';
    }
    var f = frame();
    if (appLayout !== 'drawer' && f && f.hasAttribute('data-sidebar-drawer') && !f.hasAttribute('data-sidebar-collapsed')) {
      var fold = lastShown('[data-slot="sidebar"] [class*="_logoRow"] button[class*="_iconButton"]');
      if (fold) {
        fold.click();
        return 'drawer';
      }
    }

    // 4. The right panel covering the conversation.
    if (f && f.getAttribute('data-rightbar-fullscreen') === 'true') {
      var fold = lastShown('[data-slot="rightbar"] button[data-sidebar-right-toggle]');
      if (fold) {
        fold.click();
        return 'panel';
      }
    }

    var main = document.querySelector('[data-slot="main"]');
    if (!main) return 'none';

    // 5. Up a level inside the main area: a page's crumb (a plugin's page
    //    to the list), or the conversation's parent (a subagent's).
    var crumb =
      lastShown(':scope > section button[class*="_crumb"]', main) ||
      lastShown('nav[class*="_crumbs"] button[class*="_crumb"]', main);
    if (crumb) {
      crumb.click();
      return 'page';
    }

    // 6. A full page (plugins, automations…) in the conversation's place:
    //    back to the conversation it covers (the client's stored selection;
    //    the sidebar marks none while a page is up), through its row in the
    //    sidebar. An archived one doesn't open.
    if (main.firstElementChild && !main.querySelector(':scope > [data-slot="main.conversation"]')) {
      var id = storedSession();
      var row =
        id &&
        document.querySelector(
          '[data-slot="sidebar"] [role="treeitem"][data-row-key="session:' + CSS.escape(id) + '"]:not([aria-description])'
        );
      if (row) {
        row.click();
        return 'chat';
      }
    }

    return 'none';
  }

  // The conversation the client shows when no page covers it (the store
  // dsh_web_open.js and dsh_web_state.js read too).
  function storedSession() {
    try {
      return (JSON.parse(localStorage.getItem('dsh.sessions.current') || '{}') || {}).sessionId || null;
    } catch (e) {
      return null;
    }
  }

  window.__dshAppBack = function () {
    try {
      return step();
    } catch (e) {
      return 'none';
    }
  };
})();
