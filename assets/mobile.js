/*
 * dsh-remote-portal — assets/mobile.js
 *
 * The *behaviour* half of the mobile presentation layer. `mobile.css` is inert
 * unless `<html data-drp-mobile>` is present, so everything here is fail-closed:
 * if this file never runs (route missing, blocked script, old browser) the
 * shipped desktop UI is untouched.
 *
 * What it does, and why:
 *   - `matchMedia("(max-width: 900px)")` is the single source of truth, and it
 *     uses the *same* boundary as the stylesheet. Crossing it in either
 *     direction fully activates or fully tears down the layer.
 *   - `data-drp-mobile` on <html> is the stylesheet's gate.
 *   - A floating 44×44 drawer button + a full-height scrim are the only nodes
 *     this file adds. Nothing else in the React tree is touched: the drawer is
 *     the app's own `[data-slot="sidebar"]` column, moved off-canvas by CSS.
 *   - Opening the drawer clicks the app's *own* sidebar toggle so React renders
 *     the expanded sidebar (labels, workspace list, search) instead of the
 *     56 px icon rail. The click is a normal DOM click on an existing control —
 *     no React internals are patched and no framework node is reparented.
 *   - Closing slides the drawer out first and collapses the rail afterwards,
 *     so you never see the rail pop in while the drawer is still on screen.
 *   - The viewport meta gains `viewport-fit=cover` (so `env(safe-area-inset-*)`
 *     actually resolves to something on iOS) and the original value is put
 *     back verbatim when the media query stops matching.
 *
 * Public surface for tests and for client.js:
 *   window.__DRP_MOBILE__ = { open, close, toggle, refresh, active }
 */
(function () {
  "use strict";

  // Second load of the same script: just re-sync, never double-inject.
  if (window.__DRP_MOBILE__) {
    try { window.__DRP_MOBILE__.refresh(); } catch (_) { /* ignore */ }
    return;
  }

  var QUERY = "(max-width: 900px)";
  var DRAWER_ATTR = "data-drp-drawer";
  var MOBILE_ATTR = "data-drp-mobile";
  // Set when the page is served to another device (LAN or relay). The layout
  // layer is width-based; the *remote* adaptations are not: a 1440px laptop at
  // the office must not be offered "open in Explorer" either.
  var REMOTE_ATTR = "data-drp-remote";
  var SIDEBAR_ID = "drp-sidebar";
  // Menus in the shipped UI include actions that only make sense in the native
  // shell ("open in Explorer", "open in VS Code", "show in Finder"). Over a
  // remote link they either do nothing or open something only the host can see,
  // so the mobile layer removes them from the menu it is in.
  var HIDDEN_CLASS = "drp-hidden";
  var NATIVE_LABEL = /(资源管理器|文件管理器|访达|Finder|Explorer|终端|Terminal|VS ?Code|Cursor|系统默认应用|默认应用|打开配置文件|打开数据目录|打开日志|下载 ?Session ?日志|反馈)/;
  // Triggers (not menu items): the "open with…" cluster in the session header.
  // They lead to the host's desktop, which the phone cannot see.
  var NATIVE_ARIA = /(文件资源管理器|更多打开方式|open (in|with)|reveal in|show in)/i;
  // "添加工作区…" is backed by the plugin's own server-side picker (client.js
  // registers `__DSH_DIRECTORY_PICKER__`), so the entry stays.
  var NATIVE_LABEL_EN = /(open|show|reveal)\s+(in|with)\s+(finder|explorer|terminal|vs ?code|cursor|default)/i;
  var SHORTCUT_ONLY = /^[⌘⌥⇧⌃⌫←→↑↓,.\s]+$/;
  var VIEWPORT_VALUE = "width=device-width, initial-scale=1, viewport-fit=cover";

  var mql = typeof window.matchMedia === "function" ? window.matchMedia(QUERY) : null;

  var state = {
    active: false,
    open: false,
    button: null,
    scrim: null,
    collapseTimer: 0,
    viewportMeta: null,
    viewportOriginal: null,
    sidebarIdAdded: false,
    routeHooked: false,
    historyPatched: false,
    observers: [],
    frame: null,
    remote: false,
  };

  // ---------------------------------------------------------------- helpers

  function doc() { return document; }

  function rootSlot() { return doc().querySelector('[data-slot="root"]'); }

  /** The grid frame that owns the three columns (`.…_frame`). */
  function frameEl() {
    var root = rootSlot();
    if (!root) return null;
    for (var i = 0; i < root.children.length; i++) {
      if (root.children[i].nodeType === 1) return root.children[i];
    }
    return null;
  }

  function slotEl(name) { return doc().querySelector('[data-slot="' + name + '"]'); }

  /** The grid column that wraps a slot (slots themselves are display:contents). */
  function columnOf(name) {
    var slot = slotEl(name);
    return slot ? slot.parentElement : null;
  }

  /**
   * The app's sidebar expand/collapse control. Preferred hook is the keyboard
   * shortcut marker the app puts on the toggle (`Alt+Meta+B`); the CSS-module
   * class is the fallback. Returns null when the sidebar is not mounted.
   */
  function toggleButton() {
    var sidebar = slotEl("sidebar");
    if (!sidebar) return null;
    var buttons = sidebar.querySelectorAll("button");
    for (var i = 0; i < buttons.length; i++) {
      var keys = buttons[i].getAttribute("aria-keyshortcuts") || "";
      if (/(^|[+\s])B$/i.test(keys) && !/shift/i.test(keys)) return buttons[i];
    }
    for (var j = 0; j < buttons.length; j++) {
      var cls = buttons[j].className;
      if (typeof cls === "string" && cls.indexOf("_toggle") !== -1) return buttons[j];
    }
    return null;
  }

  /**
   * `true` when the app believes the sidebar is expanded, `false` when it is the
   * icon rail, `null` when there is no frame (first paint, logged-out shell).
   */
  function appSidebarExpanded() {
    var frame = frameEl();
    if (!frame) return null;
    var attr = frame.getAttribute("data-sidebar-collapsed");
    return attr !== "true";
  }

  function setAppSidebarExpanded(want) {
    var current = appSidebarExpanded();
    if (current === null || current === want) return;
    var button = toggleButton();
    if (button) button.click();
  }

  function isZh() {
    return /^zh/i.test(doc().documentElement.lang || navigator.language || "");
  }

  function drawerLabel() {
    return isZh() ? "打开侧边栏" : "Open sidebar";
  }

  // ------------------------------------------------------------ DOM nodes

  var ICON =
    '<svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" ' +
    'stroke-width="1.6" stroke-linecap="round" aria-hidden="true" focusable="false">' +
    '<path d="M4 7h16"></path><path d="M4 12h16"></path><path d="M4 17h16"></path></svg>';

  function buildButton() {
    var button = doc().createElement("button");
    button.type = "button";
    button.className = "drp-drawer-btn";
    button.setAttribute("aria-label", drawerLabel());
    button.setAttribute("aria-expanded", state.open ? "true" : "false");
    button.setAttribute("aria-controls", SIDEBAR_ID);
    button.innerHTML = ICON;
    button.addEventListener("click", onButtonClick);
    return button;
  }

  function buildScrim() {
    var scrim = doc().createElement("div");
    // Namespaced under `drp-drawer-`: client.js already owns a scrim node inside
    // its own sheet overlay, and the two must never style each other.
    scrim.className = "drp-drawer-scrim";
    scrim.setAttribute("aria-hidden", "true");
    scrim.addEventListener("click", onScrimClick);
    return scrim;
  }

  // ------------------------------------------------------------- behaviour

  function onButtonClick(event) {
    event.preventDefault();
    toggle();
  }

  function onScrimClick() { close(); }

  function onKeyDown(event) {
    if (event.key === "Escape" && state.open) {
      event.stopPropagation();
      close();
    }
  }

  function onRouteChange() {
    if (state.open) close();
  }

  function onMediaChange() { refresh(); }

  /**
   * SPA navigation is invisible to `popstate` for pushState/replaceState, so both
   * are wrapped once. The wrapper keeps the original return value and dispatches
   * a plain DOM event that the activation listeners can react to.
   */
  function patchHistory() {
    if (state.historyPatched) return;
    var h = window.history;
    if (!h || typeof h.pushState !== "function") return;
    var originalPush = h.pushState;
    var originalReplace = h.replaceState;
    var notify = function () {
      try { window.dispatchEvent(new Event("drp:navigate")); } catch (_) { /* ignore */ }
    };
    h.pushState = function () {
      var out = originalPush.apply(this, arguments);
      notify();
      return out;
    };
    h.replaceState = function () {
      var out = originalReplace.apply(this, arguments);
      notify();
      return out;
    };
    state.historyPatched = true;
    state.restoreHistory = function () {
      // Only undo our own patch: if something else wrapped history afterwards,
      // restoring our originals would throw their wrapper away.
      if (h.pushState === state.wrappedPush) h.pushState = originalPush;
      if (h.replaceState === state.wrappedReplace) h.replaceState = originalReplace;
      state.historyPatched = false;
      state.restoreHistory = null;
    };
    state.wrappedPush = h.pushState;
    state.wrappedReplace = h.replaceState;
  }

  function open() {
    if (!state.active) return;
    clearTimeout(state.collapseTimer);
    state.open = true;
    setAppSidebarExpanded(true);
    doc().documentElement.setAttribute(DRAWER_ATTR, "open");
    if (state.button) {
      state.button.setAttribute("aria-expanded", "true");
      state.button.setAttribute("aria-label", isZh() ? "关闭侧边栏" : "Close sidebar");
    }
  }

  function close() {
    if (!state.active) return;
    var wasOpen = state.open;
    state.open = false;
    doc().documentElement.removeAttribute(DRAWER_ATTR);
    if (state.button) {
      state.button.setAttribute("aria-expanded", "false");
      state.button.setAttribute("aria-label", drawerLabel());
    }
    if (!wasOpen) return;
    // Let the 240 ms slide finish before collapsing the rail underneath it.
    clearTimeout(state.collapseTimer);
    state.collapseTimer = setTimeout(function () {
      if (!state.open) setAppSidebarExpanded(false);
    }, 260);
  }

  function toggle() {
    if (state.open) close();
    else open();
  }

  // ------------------------------------------------------------- lifecycle

  function applyViewport() {
    var meta = doc().querySelector('meta[name="viewport"]');
    if (!meta) {
      meta = doc().createElement("meta");
      meta.setAttribute("name", "viewport");
      doc().head.appendChild(meta);
      state.createdViewport = true;
    }
    state.viewportMeta = meta;
    state.viewportOriginal = meta.getAttribute("content");
    meta.setAttribute("content", VIEWPORT_VALUE);
  }

  function restoreViewport() {
    if (!state.viewportMeta) return;
    if (state.createdViewport) {
      if (state.viewportMeta.parentNode) state.viewportMeta.parentNode.removeChild(state.viewportMeta);
    } else if (state.viewportOriginal === null) {
      state.viewportMeta.removeAttribute("content");
    } else {
      state.viewportMeta.setAttribute("content", state.viewportOriginal);
    }
    state.viewportMeta = null;
    state.viewportOriginal = null;
    state.createdViewport = false;
  }

  /**
   * iOS standalone hint. Added once and intentionally left in place: it only
   * matters when the page is saved to the home screen, and rewriting it on every
   * breakpoint change would be pointless churn (no manifest is rewritten).
   */
  function applyAppleHints() {
    var wanted = [
      ["apple-mobile-web-app-title", "DeepSeek Harness"],
      ["apple-mobile-web-app-status-bar-style", "black-translucent"],
    ];
    for (var i = 0; i < wanted.length; i++) {
      if (doc().querySelector('meta[name="' + wanted[i][0] + '"]')) continue;
      var meta = doc().createElement("meta");
      meta.setAttribute("name", wanted[i][0]);
      meta.setAttribute("content", wanted[i][1]);
      doc().head.appendChild(meta);
    }
  }

  /**
   * Hide native-only entries and keyboard hints inside whatever menu or dialog
   * is on screen. Class-based on purpose: the marker is inert the moment the
   * layer is off, so nothing has to be undone item by item.
   */
  /** False for the desktop shell itself (file://) and for loopback. */
  function isRemoteOrigin() {
    try {
      var p = String(location.protocol || "");
      if (p === "file:" || p === "chrome-extension:") return false;
      var h = String(location.hostname || "").toLowerCase();
      if (h === "" || h === "localhost" || h === "127.0.0.1" || h === "[::1]" || h === "::1") return false;
      return true;
    } catch (e) {
      return false;
    }
  }

  var nativeTimer = 0;

  /** Debounced: the DOM churns while a stream renders; a scan per frame is waste. */
  function scheduleNativeScan() {
    if (nativeTimer) return;
    nativeTimer = setTimeout(function () {
      nativeTimer = 0;
      markNativeActions();
    }, 200);
  }

  function markNativeActions() {
    // Active layout (≤900px) or a remote page at any width — either way the
    // native-only entries must go.
    if (!state.active && !state.remote) return;

    // Any trigger in the shell: the session header, the document preview tabs,
    // the file browser, dialogs — "open in Explorer" appears in several of them.
    var triggers = doc().querySelectorAll("[aria-label]");
    for (var k = 0; k < triggers.length; k++) {
      if (!NATIVE_ARIA.test(String(triggers[k].getAttribute("aria-label") || ""))) continue;
      triggers[k].classList.add(HIDDEN_CLASS);
      // The "main" button and its chevron share one cluster: hiding only one
      // leaves a stray arrow behind.
      var cluster = triggers[k].parentElement;
      if (cluster && cluster.querySelectorAll("button").length <= 2) cluster.classList.add(HIDDEN_CLASS);
    }

    var items = doc().querySelectorAll('[role="menuitem"], [role="option"], [role="menu"] button, [role="menubar"] button');
    for (var j = 0; j < items.length; j++) {
      var item = items[j];
      var text = (item.textContent || "").trim();
      if (text === "" || text.length > 64) continue;
      var key = item.querySelector("kbd");
      if (key && SHORTCUT_ONLY.test((key.textContent || "").trim())) key.classList.add(HIDDEN_CLASS);
      if (NATIVE_LABEL.test(text) || NATIVE_LABEL_EN.test(text)) item.classList.add(HIDDEN_CLASS);
    }

    // A menu whose entries are all gone is a dead button: hide the "…" that
    // opens it too, instead of leaving an empty popover behind.
    var menus = doc().querySelectorAll('[role="menu"]');
    for (var m = 0; m < menus.length; m++) {
      var entries = menus[m].querySelectorAll('[role="menuitem"]');
      if (entries.length === 0) continue;
      var visible = 0;
      for (var e = 0; e < entries.length; e++) {
        if (!entries[e].classList.contains(HIDDEN_CLASS)) visible += 1;
      }
      if (visible > 0) continue;
      menus[m].classList.add(HIDDEN_CLASS);
      var trigger = null;
      if (menus[m].id) trigger = doc().querySelector('[aria-controls="' + menus[m].id + '"]');
      if (!trigger) trigger = doc().querySelector('[aria-haspopup="menu"][aria-expanded="true"]');
      if (trigger) trigger.classList.add(HIDDEN_CLASS);
    }
  }

  /**
   * A tap inside the drawer that opens a session should also close the drawer —
   * otherwise the conversation stays behind the panel and looks frozen.
   * Folder rows (`aria-expanded`) only expand, so they leave it open.
   */
  function onFrameClick(event) {
    if (!state.open) return;
    var target = event.target;
    if (!target || typeof target.closest !== "function") return;
    if (target.closest('[aria-haspopup], input, textarea, [contenteditable="true"]')) return;
    var row = target.closest('[data-slot="sidebar"] [role="treeitem"], [data-slot="sidebar"] [role="option"]');
    var link = target.closest('[data-slot="sidebar"] a[href]');
    if (!row && !link) return;
    if (row && row.hasAttribute("aria-expanded") && !row.hasAttribute("aria-selected")) return;
    // Let the host handle the click (and start the navigation) first.
    setTimeout(function () { if (state.open) close(); }, 120);
  }

  function mount() {
    var frame = frameEl();
    if (!frame) return false;
    state.button = buildButton();
    state.scrim = buildScrim();
    frame.appendChild(state.scrim);
    frame.appendChild(state.button);
    state.frame = frame;
    // Document-level capture: React's synthetic handlers live on the root, and a
    // `stopPropagation()` there would hide the click from a listener on the frame.
    doc().addEventListener("click", onFrameClick, true);
    markNativeActions();

    // `aria-controls` needs a stable id on the drawer column.
    var column = columnOf("sidebar");
    if (column) {
      if (!column.id) {
        column.id = SIDEBAR_ID;
        state.sidebarIdAdded = true;
      } else if (column.id !== SIDEBAR_ID) {
        state.button.setAttribute("aria-controls", column.id);
      }

      // The user can also collapse the drawer with the app's own control; when
      // React reports the rail again the overlay drawer must follow.
      if (typeof MutationObserver === "function") {
        var observer = new MutationObserver(function () {
          if (state.open && appSidebarExpanded() === false) close();
        });
        observer.observe(frame, { attributes: true, attributeFilter: ["data-sidebar-collapsed"] });
        state.observers.push(observer);
      }
    }
    return true;
  }

  function unmount() {
    clearTimeout(state.collapseTimer);
    state.collapseTimer = 0;
    if (state.frame) {
      doc().removeEventListener("click", onFrameClick, true);
      state.frame = null;
    }
    if (state.button) {
      state.button.removeEventListener("click", onButtonClick);
      if (state.button.parentNode) state.button.parentNode.removeChild(state.button);
      state.button = null;
    }
    if (state.scrim) {
      state.scrim.removeEventListener("click", onScrimClick);
      if (state.scrim.parentNode) state.scrim.parentNode.removeChild(state.scrim);
      state.scrim = null;
    }
    for (var i = 0; i < state.observers.length; i++) state.observers[i].disconnect();
    state.observers.length = 0;
    if (state.sidebarIdAdded) {
      var column = columnOf("sidebar");
      if (column && column.id === SIDEBAR_ID) column.removeAttribute("id");
      state.sidebarIdAdded = false;
    }
    doc().documentElement.removeAttribute(DRAWER_ATTR);
  }

  function activate() {
    if (state.active) return;
    state.active = true;
    doc().documentElement.setAttribute(MOBILE_ATTR, "");
    applyViewport();
    applyAppleHints();
    mount();
    // Opening moves the sidebar off-canvas; if React already had it expanded
    // (desktop → narrow resize) show the drawer instead of an invisible panel.
    if (appSidebarExpanded() === true) open();
    else close();
    window.addEventListener("keydown", onKeyDown, true);
    window.addEventListener("popstate", onRouteChange);
    window.addEventListener("drp:navigate", onRouteChange);
    patchHistory();
    state.routeHooked = true;
  }

  function deactivate() {
    if (!state.active) return;
    state.active = false;
    state.open = false;
    unmount();
    doc().documentElement.removeAttribute(MOBILE_ATTR);
    restoreViewport();
    window.removeEventListener("keydown", onKeyDown, true);
    window.removeEventListener("popstate", onRouteChange);
    window.removeEventListener("drp:navigate", onRouteChange);
    state.routeHooked = false;
    if (state.restoreHistory) state.restoreHistory();
  }

  /** Re-evaluate the breakpoint and re-attach to the current React tree. */
  function refresh() {
    var matches = mql ? mql.matches : window.innerWidth <= 900;
    if (!matches) { deactivate(); return; }
    if (!state.active) { activate(); return; }
    // Still mobile: the shell may have re-rendered (logout/login swaps the
    // frame). Re-mount the nodes if they fell out of the tree.
    var frame = frameEl();
    if (!frame) return;
    if (!state.button || state.button.parentNode !== frame) {
      unmount();
      mount();
      if (appSidebarExpanded() === true) open();
    }
  }

  // The React shell mounts asynchronously: watch the DOM for the frame to appear
  // (and for a logout/login that throws it away) and re-sync. The observer is
  // rAF-throttled and its callback is a couple of boolean checks, so streaming
  // chat output costs nothing measurable.
  function watchShell() {
    if (typeof MutationObserver !== "function") return;
    var host = doc().body || doc().documentElement;
    var pending = false;
    var observer = new MutationObserver(function () {
      if (pending) return;
      pending = true;
      requestAnimationFrame(function () {
        pending = false;
        // A modal opened over the app (the host's own dialogs live on <body>,
        // the panel sheet inside the shell overlay): step out of the way.
        if (state.open && overlayIsUp()) close();
        if (state.remote || state.active) scheduleNativeScan();
        var frame = frameEl();
        if (!state.active || !frame || !state.button || !state.button.isConnected) refresh();
      });
    });
    observer.observe(host, { childList: true, subtree: true });
  }

  /**
   * Remote-host adaptations that do not depend on the viewport width: a laptop
   * across the LAN is 1440 px wide and still cannot open a file on the host.
   */
  function activateRemote() {
    if (!isRemoteOrigin()) return;
    state.remote = true;
    doc().documentElement.setAttribute(REMOTE_ATTR, "");
    markNativeActions();
    scheduleNativeScan();
  }

  /** True when a modal surface is on screen above the frame. */
  function overlayIsUp() {
    return doc().querySelector('[role="dialog"][aria-modal="true"], [data-drp-overlay="1"]') !== null;
  }

  window.__DRP_MOBILE__ = {
    open: open,
    close: close,
    toggle: toggle,
    refresh: refresh,
    get active() { return state.active; },
    get isOpen() { return state.open; },
    get query() { return QUERY; },
  };

  if (mql && typeof mql.addEventListener === "function") mql.addEventListener("change", onMediaChange);
  else if (mql && typeof mql.addListener === "function") mql.addListener(onMediaChange);

  watchShell();
  try { activateRemote(); } catch (_) { /* never fatal */ }
  if (doc().readyState === "loading") {
    doc().addEventListener("DOMContentLoaded", refresh, { once: true });
  } else {
    refresh();
  }
})();












