/**
 * test/mobile.test.mjs — the mobile presentation layer (assets/mobile.css +
 * assets/mobile.js) under `node --test`.
 *
 * Three layers of checking, cheapest first:
 *
 *  1. **Static lint** (no browser): the stylesheet is one @media block, every
 *     selector is gated on `html[data-yuremote-mobile]`, `!important` is used only
 *     where an inline style from the layout solver forces it, no CSS-module
 *     content hashes leak in, and the accessibility/theme invariants that are
 *     easy to regress by accident are pinned.
 *
 *  2. **Behaviour** (one headless Chrome run against the live dsh web UI): the
 *     layer activates at 390 px, injects exactly one button + one scrim,
 *     opens/closes the drawer through the public API, and restores the page
 *     when it deactivates.
 *
 *  3. **Overflow audit** (one headless Chrome run, all widths in one session):
 *     documentElement.scrollWidth and body.scrollWidth may never exceed
 *     innerWidth, and no visible element may stick out past the right edge.
 *
 * Both browser checks skip themselves (not fail) when Chrome or the test
 * instance is missing — this suite must stay green on a machine without them.
 * Runtime: ~20 s with Chrome, <1 s without.
 */
import { test, describe, before, after } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { spawn, spawnSync } from "node:child_process";
import { tmpdir, homedir } from "node:os";
import { join, dirname, delimiter } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const PLUGIN = join(HERE, "..");
const CSS_PATH = join(PLUGIN, "assets", "mobile.css");
const JS_PATH = join(PLUGIN, "assets", "mobile.js");
const CDP = join(PLUGIN, "tools", "cdp.mjs");

/** First Chrome/Chromium we can find; `CHROME_PATH` always wins. */
function resolveChrome() {
  if (process.env.CHROME_PATH) return process.env.CHROME_PATH;
  const candidates = process.platform === "win32"
    ? [
      "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
      "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
      "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    ]
    : process.platform === "darwin"
      ? ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]
      : [
        "/usr/bin/google-chrome",
        "/usr/bin/google-chrome-stable",
        "/usr/bin/chromium",
        "/usr/bin/chromium-browser",
        "/snap/bin/chromium",
      ];
  return candidates.find((p) => existsSync(p)) || candidates[0];
}
const CHROME = resolveChrome();

/**
 * The live half of this suite needs a running dsh web UI **and its launch
 * token**. A hardcoded token is a trap: it belongs to one process, so the tests
 * silently degraded into "the 401 page rendered" the first time the instance was
 * restarted. Point the suite at an existing server with
 * `DSH_WEB_TEST_URL` + `DSH_WEB_TEST_TOKEN`, or let it start its own instance on
 * a free port and read the token from the startup line.
 */
const ENV_BASE = process.env.DSH_WEB_TEST_URL || "";
const ENV_TOKEN = process.env.DSH_WEB_TEST_TOKEN || "";

let BASE = ENV_BASE || "";
let TOKEN_URL = "";
let child = null;

/** The dsh launcher, from PATH or the default Windows install. */
function dshExe() {
  const fromPath = (process.env.PATH || "")
    .split(delimiter)
    .map((dir) => join(dir, "dsh.cmd"))
    .find((candidate) => existsSync(candidate));
  if (fromPath) return fromPath;
  const guess = join(process.env.LOCALAPPDATA || "", "Programs", "DeepSeek Harness", "resources", "runtime", "cli", "bin", "dsh.cmd");
  return existsSync(guess) ? guess : "";
}

/** Start `dsh --profile web` on a free port and return the token URL it prints. */
async function startInstance() {
  const exe = dshExe();
  if (!exe) throw new Error("the dsh CLI was not found (set DSH_WEB_TEST_URL/DSH_WEB_TEST_TOKEN instead)");
  const port = 19000 + Math.floor(Math.random() * 700);
  BASE = `http://127.0.0.1:${port}/?yuremote=mobile`;
  // `dsh.cmd` is a batch shim: Node refuses to spawn it directly on Windows
  // (EINVAL since Node 20.12), so hand the whole command line to the shell.
  const command = `"${exe}" --profile web --port ${port} --no-open`;
  child = spawn(command, {
    shell: true,
    stdio: ["ignore", "pipe", "pipe"],
    env: { ...process.env, DSH_HOME: process.env.DSH_HOME || join(homedir(), ".dsh") },
  });
  const url = await new Promise((resolve, reject) => {
    let buffer = "";
    const timer = setTimeout(() => reject(new Error("dsh web did not print its URL in 90 s")), 90000);
    child.stdout.on("data", (chunk) => {
      buffer += chunk.toString();
      const match = /dsh web: (http:\/\/[^\s]+)/.exec(buffer);
      if (match) { clearTimeout(timer); resolve(match[1]); }
    });
    child.on("exit", (code) => { clearTimeout(timer); reject(new Error(`dsh web exited with ${code}`)); });
  });
  return url;
}

function stopInstance() {
  if (!child || child.killed) return;
  try {
    // `dsh.cmd` is a shim; the listener is a grandchild, so kill the tree.
    spawnSync("taskkill", ["/PID", String(child.pid), "/T", "/F"], { stdio: "ignore" });
  } catch {
    try { child.kill("SIGKILL"); } catch { /* gone */ }
  }
  child = null;
}

process.on("exit", stopInstance);


const css = readFileSync(CSS_PATH, "utf8");
const js = readFileSync(JS_PATH, "utf8");

// --------------------------------------------------------------------------
// tiny CSS helpers — enough for a lint, not a parser
// --------------------------------------------------------------------------

const stripComments = (source) => source.replace(/\/\*[\s\S]*?\*\//g, "");

/** Top-level blocks: [{ prelude, body }] for `prelude { body }` at depth 0. */
function topLevelBlocks(source) {
  const out = [];
  let depth = 0;
  let preludeStart = 0;
  let bodyStart = -1;
  for (let i = 0; i < source.length; i++) {
    const ch = source[i];
    if (ch === "{") {
      if (depth === 0) bodyStart = i + 1;
      depth++;
    } else if (ch === "}") {
      depth--;
      if (depth === 0) {
        out.push({ prelude: source.slice(preludeStart, bodyStart - 1).trim(), body: source.slice(bodyStart, i) });
        preludeStart = i + 1;
      }
    }
  }
  return out;
}

/** Split a selector list on top-level commas (ignore commas inside `:is(…)`). */
function splitSelectors(prelude) {
  const out = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < prelude.length; i++) {
    const ch = prelude[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth--;
    else if (ch === "," && depth === 0) {
      out.push(prelude.slice(start, i));
      start = i + 1;
    }
  }
  out.push(prelude.slice(start));
  return out.map((s) => s.replace(/\s+/g, " ").trim()).filter(Boolean);
}

/** Selector of the rule that contains `index` (for a declaration index). */
function selectorAt(source, index) {
  let depth = 0;
  let i = index;
  for (; i >= 0; i--) {
    if (source[i] === "}") depth++;
    else if (source[i] === "{") {
      if (depth === 0) break;
      depth--;
    }
  }
  if (i < 0) return "";
  let j = i - 1;
  while (j >= 0 && source[j] !== "}" && source[j] !== "{" && source[j] !== ";") j--;
  return source.slice(j + 1, i).trim();
}

/** Selector of the rule that *starts* after `index` (for a selector index). */
function ruleSelectorAt(source, index) {
  let i = index;
  while (i < source.length && source[i] !== "{") i++;
  let j = i - 1;
  while (j >= 0 && source[j] !== "}" && source[j] !== "{" && source[j] !== ";") j--;
  return source.slice(j + 1, i).trim();
}

const clean = stripComments(css);

// --------------------------------------------------------------------------
// 1. static lint
// --------------------------------------------------------------------------

describe("assets/mobile.css — restraint lint", () => {
  test("the whole stylesheet lives inside @media (max-width: 900px)", () => {
    const blocks = topLevelBlocks(clean);
    assert.ok(blocks.length > 0, "stylesheet is empty");
    for (const block of blocks) {
      // One documented exception: the trailing remote-only block. It is gated
      // on `html[data-yuremote-remote]` (set only when the page was served to another
      // device), so it must apply at any width — a 1440px laptop on the LAN
      // still cannot open a file on the host.
      if (!block.prelude.startsWith("@") && /\[data-yuremote-remote\]/.test(block.prelude)) continue;
      assert.match(
        block.prelude,
        /^@media \(max-width: 900px\)( and \(pointer: coarse\))?$/,
        `top-level block is not the 900px gate: ${block.prelude}`,
      );
    }
  });

  test("every rule is gated on html[data-yuremote-mobile]", () => {
    const offenders = [];
    for (const media of topLevelBlocks(clean)) {
      if (!media.prelude.startsWith("@") && /\[data-yuremote-remote\]/.test(media.prelude)) continue;
      // one level deep: selectors and nested @media
      const inner = topLevelBlocks(media.body);
      for (const rule of inner) {
        if (rule.prelude.startsWith("@")) continue; // nested prefers-reduced-motion
        for (const selector of splitSelectors(rule.prelude)) {
          if (!selector.startsWith("html[data-yuremote-mobile]")) offenders.push(selector);
        }
      }
    }
    assert.deepEqual(offenders, [], "ungated selectors: " + offenders.join(" | "));
  });

  test("!important only where an inline style must lose", () => {
    const allowedProps = new Set(["grid-template-columns", "width", "--dsh-sidebar-width"]);
    const allowedAnchors = [
      '[data-slot="root"] > div',
      '[data-slot="sidebar"] > :first-child',
      "[data-sidebar-right-panel]",
    ];
    const found = [];
    const re = /([a-z-]+)\s*:\s*([^;{}]*?)!important/g;
    let match;
    while ((match = re.exec(clean)) !== null) {
      const prop = match[1];
      const selector = selectorAt(clean, match.index).replace(/\s+/g, " ");
      found.push({ prop, selector, value: match[2].trim() });
    }
    assert.ok(found.length > 0, "expected the frame override to still be there");
    for (const item of found) {
      assert.ok(
        allowedProps.has(item.prop),
        `unexpected !important on "${item.prop}" (selector: ${item.selector})`,
      );
      assert.ok(
        allowedAnchors.some((anchor) => item.selector.includes(anchor)),
        `!important outside a layout-solver override (selector: ${item.selector})`,
      );
    }
    // The frame is the one place a grid override is mandatory.
    assert.ok(
      found.some((i) => i.prop === "grid-template-columns" && i.selector.includes('[data-slot="root"] > div')),
      "the frame's inline grid-template-columns must be neutralised with !important",
    );
  });

  test("no CSS-module content hashes are used as hooks", () => {
    // e.g. .BynINW_frame, .Dc7zOa_header, ._9lTDKa_root — build-generated.
    const hashes = clean.match(/\.[A-Za-z0-9_-]{4,}_[A-Za-z][A-Za-z0-9_-]*/g) || [];
    assert.deepEqual([...new Set(hashes)], [], "hashed class names leaked into the layer");
  });

  test("theme is never taken over from the OS", () => {
    assert.equal(/prefers-color-scheme/.test(clean), false, "prefers-color-scheme must not be used");
    assert.match(clean, /var\(--dsw-alias-/, "colours should come from the --dsw-alias-* tokens");
  });

  test("the contract details are present", () => {
    // drawer geometry + motion
    assert.match(clean, /width:\s*min\(86vw, 320px\)/);
    assert.match(clean, /translateX\(-100%\)/);
    assert.match(clean, /240ms/);
    assert.match(clean, /prefers-reduced-motion: reduce/);
    // safe areas
    assert.match(clean, /env\(safe-area-inset-bottom/);
    // iOS zoom-on-focus
    assert.match(clean, /\[contenteditable="true"\]/);
    assert.match(clean, /font-size:\s*16px/);
    assert.match(clean, /-webkit-text-size-adjust:\s*100%/);
    // dialogs
    assert.match(clean, /max-width:\s*calc\(100vw - 24px\)/);
    assert.match(clean, /max-height:\s*calc\(100dvh - 24px\)/);
    // the portal panel is exempt from the modal bounds
    assert.match(clean, /\[role="dialog"\]\[data-yuremote="panel"\]/);
  });

  test("the layer's own classes cannot collide with client.js", () => {
    // client.js owns .yuremote-overlay/.yuremote-scrim/.yuremote-sheet/…; the layer only adds
    // .yuremote-drawer-*. The one exception is that the layer deliberately tightens
    // .yuremote-sheet-body inside [data-yuremote="panel"] — assert it stays scoped there.
    const re = /\.(yuremote-[a-z-]+)/g;
    let match;
    while ((match = re.exec(clean)) !== null) {
      const cls = match[1];
      const selector = ruleSelectorAt(clean, match.index).replace(/\s+/g, " ");
      if (cls.startsWith("yuremote-drawer-")) continue;
    // The layer also owns one marker class of its own: menu entries it removes
    // (native-only actions). It is namespaced and asserted here so a future
    // class from client.js cannot silently reuse the name.
    if (cls === "yuremote-hidden") continue;
      assert.ok(
        selector.includes('[data-yuremote="panel"]'),
        `layer styles client.js class .${cls} outside [data-yuremote="panel"] (${selector})`,
      );
    }
    assert.match(js, /yuremote-drawer-scrim/);
    assert.match(js, /yuremote-drawer-btn/);
    assert.equal(/yuremote-scrim/.test(js.replace(/yuremote-drawer-scrim/g, "")), false, "mobile.js must not use client.js's .yuremote-scrim");
  });
});

describe("assets/mobile.js — source contract", () => {
  test("is an idempotent, dependency-free IIFE", () => {
    assert.match(js, /window\.__YUREMOTE_MOBILE__/, "must expose the test API");
    assert.match(js, /if \(window\.__YUREMOTE_MOBILE__\)/, "must bail out when loaded twice");
    assert.equal(/^\s*import\s/m.test(js), false, "no ESM imports");
    assert.equal(/\brequire\(/.test(js), false, "no require()");
    assert.match(js, /\(function \(\) \{/, "wrapped in an IIFE");
  });

  test("never engages inside the desktop shell", () => {
    // The Electron app loads from file:// and needs its OS actions ("open in
    // Explorer", "open config file") at any window size. Gating the layer on
    // width alone hid them as soon as the window got narrow.
    assert.match(js, /function isDesktopShell\(\)/);
    assert.match(js, /if \(isDesktopShell\(\)\) \{ markDecision\("desktop-shell"\); return; \}/, "activate() must bail out in the shell");
    assert.match(js, /p === "file:"/, "file:// is the desktop shell");
    assert.match(js, /function activateRemote\(\) \{\n\s*if \(!isRemoteOrigin\(\)\) return;/);
    // Only loopback and file:// are "this machine": a LAN address is how a phone
    // reaches dsh, and treating it as local left phones with a fixed sidebar.
    assert.equal(/if \(isHostAddress\(h\)\) return false;/.test(js), false);
    assert.match(js, /function viaPortal\(\)/);
  });

  test("uses the same 900px boundary as the stylesheet", () => {
    assert.match(js, /\(max-width: 900px\)/);
    assert.match(clean, /max-width: 900px/);
  });

  test("sets viewport-fit=cover and restores the original content", () => {
    assert.match(js, /viewport-fit=cover/);
    assert.match(js, /restoreViewport/);
  });
});

// --------------------------------------------------------------------------
// browser checks
// --------------------------------------------------------------------------

function runCdp(args, { timeoutMs = 120000 } = {}) {
  return new Promise((resolve) => {
    const child = spawn(process.execPath, [CDP, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    const timer = setTimeout(() => {
      try { child.kill(); } catch { /* ignore */ }
    }, timeoutMs);
    child.stdout.on("data", (d) => { stdout += d.toString(); });
    child.stderr.on("data", (d) => { stderr += d.toString(); });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ code, stdout, stderr });
    });
  });
}

async function instanceReachable() {
  try {
    const response = await fetch(BASE, { method: "GET" });
    // 200 or 303 both mean "a dsh web server answered"
    return response.status > 0;
  } catch {
    return false;
  }
}

describe("mobile layer against the live dsh web UI", () => {
  let skipReason = "";
  let tmp = "";

  before(async () => {
    if (!existsSync(CHROME)) { skipReason = `no Chrome/Chromium found (looked for ${CHROME}); set CHROME_PATH to enable these tests`; return; }
    if (!existsSync(CDP)) { skipReason = `driver missing at ${CDP}`; return; }
    if (ENV_BASE && ENV_TOKEN) {
      BASE = (ENV_BASE.endsWith("/") ? ENV_BASE : ENV_BASE + "/") + "?yuremote=mobile";
      TOKEN_URL = BASE + "&token=" + encodeURIComponent(ENV_TOKEN);
    } else {
      try {
        TOKEN_URL = await startInstance();
      } catch (error) {
        skipReason = `could not start a dsh web instance: ${error?.message || error}`;
        return;
      }
    }
    if (!(await instanceReachable())) {
      skipReason = `no dsh web instance at ${BASE}`;
      return;
    }
    tmp = mkdtempSync(join(tmpdir(), "yuremote-mobile-test-"));
    // One pre-file: inject the shipped CSS + JS exactly as client.js does, and
    // expose a light/dark switch for the audit.
    const pre = `(async () => {
  for (const b of document.querySelectorAll('button')) {
    const t = (b.textContent || '').trim();
    if (t === '继续' || t === 'Continue') {
      b.click();
      for (let attempt = 0; attempt < 10; attempt++) {
        if (dismissWelcome()) break;
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
      break;
    }
  }
  dismissWelcome();
  function dismissWelcome() {
    const close = document.querySelector(
      '[role="dialog"][aria-label="Get started"] button[aria-label="Close"], ' +
      '[role="dialog"][aria-label="开始使用"] button[aria-label="关闭"]'
    );
    if (!close) return false;
    close.click();
    return true;
  }
  // A fresh profile without an API key opens a modal "Get started" dialog; the
  // layer correctly steps aside for modals, so close it before measuring.
  for (const d of document.querySelectorAll('[role="dialog"][aria-modal="true"]')) {
    const x = d.querySelector('button[aria-label="Close"], button[aria-label="关闭"]');
    if (x) x.click();
  }
  await new Promise((r) => setTimeout(r, 300));
  const style = document.createElement('style');
  style.id = 'yuremote-mobile-css';
  style.textContent = ${JSON.stringify(css)};
  document.head.appendChild(style);
  try { (0, eval)(${JSON.stringify(js)}); } catch (e) { window.__yuremoteJsError = String(e); }
  window.__YUREMOTE_AUDIT_THEME = (mode) => {
    const b = document.body;
    if (!window.__yuremoteOrigTheme) {
      window.__yuremoteOrigTheme = {
        dark: b.hasAttribute('data-ds-dark-theme'),
        skin: b.getAttribute('data-liang-skin'),
        stage: b.getAttribute('data-liang-stage'),
        backdrop: document.querySelector('.liang-skin-backdrop'),
      };
    }
    const o = window.__yuremoteOrigTheme;
    let light = document.getElementById('yuremote-audit-light');
    if (mode === 'light') {
      b.removeAttribute('data-ds-dark-theme');
      b.removeAttribute('data-liang-skin');
      b.removeAttribute('data-liang-stage');
      document.documentElement.style.colorScheme = 'light';
      if (o.backdrop) o.backdrop.style.display = 'none';
      if (!light) {
        light = document.createElement('style');
        light.id = 'yuremote-audit-light';
        light.textContent = ':root{color-scheme:light} body{background:#fff !important}';
        document.head.appendChild(light);
      }
    } else {
      if (o.dark) b.setAttribute('data-ds-dark-theme', '');
      if (o.skin !== null) b.setAttribute('data-liang-skin', o.skin);
      if (o.stage !== null) b.setAttribute('data-liang-stage', o.stage);
      if (o.backdrop) o.backdrop.style.display = '';
      if (light) light.remove();
    }
    if (window.__YUREMOTE_MOBILE__) window.__YUREMOTE_MOBILE__.refresh();
    return mode;
  };
  return 'ready';
})()`;
    writeFileSync(join(tmp, "pre.js"), pre);
  });

  after(() => {
    if (tmp) { try { rmSync(tmp, { recursive: true, force: true }); } catch { /* ignore */ } }
    // Never leave a dsh instance behind: the suite owns the one it started, and a
    // stray listener is exactly the kind of thing that makes the next run flaky.
    stopInstance();
  });

  test("long code, wide tables and big images stay inside the phone column", async (t) => {
    if (skipReason) return t.skip(skipReason);
    // Injected into the real page: the three element classes that break mobile
    // layouts. The rules are global element rules under `html[data-yuremote-mobile]`,
    // so a synthetic node exercises exactly what a real message would hit.
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      await sleep(200);
      const host = document.querySelector('[data-slot="conversation.chat.flow"]')
        || document.querySelector('[data-slot="conversation"]')
        || document.querySelector('main')
        || document.body;
      const box = document.createElement('div');
      box.id = 'yuremote-overflow-probe';
      box.innerHTML = ''
        + '<pre id="yuremote-probe-pre">' + 'curl -s https://example.invalid/' + 'a'.repeat(220) + '</pre>'
        + '<div class="_tableScroll_x1" id="yuremote-probe-wrap">'
        + '  <table id="yuremote-probe-table"><tbody><tr>'
        + Array.from({ length: 12 }, (_, i) => '<td>cell-' + i + '-padding</td>').join('')
        + '  </tr></tbody></table>'
        + '</div>'
        + '<img id="yuremote-probe-img" alt="" src="data:image/svg+xml;utf8,' +
        encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"></svg>') + '">';
      host.appendChild(box);
      await sleep(400);
      const r = (el) => el.getBoundingClientRect();
      const pre = document.getElementById('yuremote-probe-pre');
      const wrap = document.getElementById('yuremote-probe-wrap');
      const table = document.getElementById('yuremote-probe-table');
      const img = document.getElementById('yuremote-probe-img');
      const page = document.documentElement;
      const offenders = [...document.querySelectorAll("body *")]
        .filter((e) => e.getBoundingClientRect().right > innerWidth + 2)
        .slice(0, 8)
        .map((e) => {
          const b = e.getBoundingClientRect();
          return (e.tagName || "").toLowerCase() + "." + String(e.className || "").slice(0, 24)
            + "@" + Math.round(b.x) + "+" + Math.round(b.width);
        });
      const out = {
        vw: innerWidth,
        pageOverflow: page.scrollWidth - innerWidth,
        offenders,
        layer: document.documentElement.hasAttribute("data-yuremote-mobile"),
        host: (host.tagName || "").toLowerCase() + "/" + (host.getAttribute("data-slot") || ""),
        preW: Math.round(r(pre).width),
        preScrolls: pre.scrollWidth > pre.clientWidth + 1,
        preOverflowsPage: Math.round(r(pre).right) > innerWidth + 1,
        wrapScrolls: wrap.scrollWidth > wrap.clientWidth + 1,
        wrapOverflowsPage: Math.round(r(wrap).right) > innerWidth + 1,
        tableDisplay: getComputedStyle(table).display,
        imgW: Math.round(r(img).width),
        imgH: Math.round(r(img).height),
        imgFits: Math.round(r(img).width) <= innerWidth,
        aspectKept: Math.abs((r(img).width / r(img).height) - (1600 / 900)) < 0.15,
      };
      box.remove();
      return JSON.stringify(out);
    })()`;
    const { code, stdout, stderr } = await runCdp(["eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000", "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "2000"]);
    assert.equal(code, 0, "eval run failed: " + (stderr || "").slice(-800));
    const line = stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop();
    assert.ok(line, "no measurement returned: " + stdout.slice(-400));
    const m = JSON.parse(line);
    assert.equal(m.pageOverflow <= 1, true, `the page must not scroll sideways (overflow ${m.pageOverflow}px, host ${m.host}, offenders ${JSON.stringify(m.offenders)} layer=${m.layer})`);
    assert.equal(m.preScrolls, true, "a long code line must scroll inside its own block");
    assert.equal(m.preOverflowsPage, false, "the code block must not reach past the viewport");
    assert.equal(m.wrapScrolls, true, "a wide table wrapper must pan horizontally");
    assert.equal(m.wrapOverflowsPage, false, "the table wrapper must not reach past the viewport");
    assert.equal(m.imgFits, true, `an oversized image must be clamped to the viewport (was ${m.imgW}px)`);
    assert.equal(m.aspectKept, true, "a clamped image must keep its aspect ratio");
  });

  test("the right column never intercepts touches", async (t) => {
    if (skipReason) return t.skip(skipReason);
    // The real bug: with a session open, the right column's wrapper is a
    // full-size transparent grid cell stacked over the conversation, and it
    // swallowed every touch — the page looked frozen and could not be scrolled.
    // The page under test has no session, so the probe reproduces that shape
    // (wrapper + 0×0 pane) inside the real shell and checks the rule.
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const frame = document.querySelector('[data-slot="root"] > div');
      if (!frame) return JSON.stringify({ error: "no shell frame found" });
      const cover = document.createElement('div');
      cover.id = 'yuremote-cover-probe';
      cover.style.position = 'fixed';
      cover.style.inset = '0';
      cover.style.zIndex = '5';
      const pane = document.createElement('div');
      pane.setAttribute('data-slot', 'rightbar');
      pane.style.width = '0';
      pane.style.height = '0';
      cover.appendChild(pane);
      frame.appendChild(cover);
      await sleep(150);
      const x = Math.round(innerWidth / 2);
      const y = Math.round(innerHeight * 0.45);
      const hit = () => {
        const el = document.elementFromPoint(x, y);
        return el ? String(el.id || el.className || el.tagName) : null;
      };
      const fixed = { pointerEvents: getComputedStyle(cover).pointerEvents, hit: hit() };
      // Defeat the rule: if the probe is not on top now, the assertion above
      // proves nothing (it would pass even without the fix).
      cover.style.pointerEvents = 'auto';
      const broken = { pointerEvents: getComputedStyle(cover).pointerEvents, hit: hit() };
      cover.remove();
      return JSON.stringify({ fixed, broken });
    })()`;
    const { code, stdout, stderr } = await runCdp(["eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000", "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1500"]);
    assert.equal(code, 0, "eval run failed: " + (stderr || "").slice(-800));
    const line = stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop();
    assert.ok(line, "no measurement returned: " + stdout.slice(-400));
    const m = JSON.parse(line);
    assert.equal(m.error, undefined, m.error || "");
    assert.equal(m.fixed.pointerEvents, "none", "the stacked wrapper must not take pointer events");
    assert.equal(String(m.fixed.hit).includes("yuremote-cover-probe"), false, `a touch at the centre hits the wrapper (${m.fixed.hit})`);
    assert.equal(m.broken.pointerEvents, "auto");
    assert.equal(m.broken.hit, "yuremote-cover-probe", "the probe must be on top when the rule is defeated");
  });

  test("remote-only refinements: gutters, settings column, ledger pan, native items", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const seat = document.querySelector('[class*="composerSeat"]');
      const seatStyle = seat ? getComputedStyle(seat) : null;

      // A ledger pane, as the trajectory view builds it: the app clips it, the
      // mobile layer has to make it pan.
      const pane = document.createElement('div');
      pane.className = 'probe_tablePane';
      pane.innerHTML = '<div style="width:1600px;height:20px"></div>';
      document.body.appendChild(pane);
      await sleep(120);
      const paneOverflow = getComputedStyle(pane).overflowX;
      pane.scrollLeft = 200;
      const paneScrolls = pane.scrollLeft > 0;
      pane.remove();

      // A menu with a native-only entry: the layer must hide it.
      const menu = document.createElement('div');
      menu.setAttribute('role', 'menu');
      menu.innerHTML = '<button role="menuitem">在资源管理器…等中打开</button>'
        + '<button role="menuitem" id="yuremote-probe-keep">重命名</button>';
      document.body.appendChild(menu);
      await sleep(260);
      const nativeItem = menu.querySelector('[role="menuitem"]');
      const keepItem = menu.querySelector('#yuremote-probe-keep');
      const nativeHidden = nativeItem.classList.contains('yuremote-hidden')
        && getComputedStyle(nativeItem).display === 'none';
      const keepVisible = getComputedStyle(keepItem).display !== 'none';
      menu.remove();

      return JSON.stringify({
        seatPadLeft: seatStyle ? parseFloat(seatStyle.paddingLeft) : null,
        seatPadRight: seatStyle ? parseFloat(seatStyle.paddingRight) : null,
        paneOverflow,
        paneScrolls,
        nativeHidden,
        keepVisible,
        settingsColumn: (() => {
          const dlg = document.querySelector('[role="dialog"]');
          if (!dlg) return null;
          return getComputedStyle(dlg).flexDirection;
        })(),
      });
    })()`;
    const { code, stdout, stderr } = await runCdp(["eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000", "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "2500"]);
    assert.equal(code, 0, "eval run failed: " + (stderr || "").slice(-800));
    const line = stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop();
    assert.ok(line, "no measurement returned: " + stdout.slice(-400));
    const m = JSON.parse(line);
    assert.ok(m.seatPadLeft >= 8 && m.seatPadRight >= 8, `composer needs side gutters (got ${m.seatPadLeft}/${m.seatPadRight})`);
    assert.equal(m.paneOverflow, "auto", "the ledger pane must pan horizontally");
    assert.equal(m.paneScrolls, true, "the ledger pane must actually scroll");
    assert.equal(m.nativeHidden, false, "the layer must not hide host-only entries (it used to, and it broke the desktop app)");
    assert.equal(m.keepVisible, true, "other menu entries must stay");
  });

  test("activates at 390px and exposes a working drawer API", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const api = window.__YUREMOTE_MOBILE__;
      const html = document.documentElement;
      const out = {
        api: !!api,
        active: !!(api && api.active),
        htmlAttr: html.hasAttribute('data-yuremote-mobile'),
        buttons: document.querySelectorAll('.yuremote-drawer-btn').length,
        scrims: document.querySelectorAll('.yuremote-drawer-scrim').length,
        controls: (() => { const b = document.querySelector('.yuremote-drawer-btn'); return b ? { controls: b.getAttribute('aria-controls'), expanded: b.getAttribute('aria-expanded'), w: Math.round(b.getBoundingClientRect().width), h: Math.round(b.getBoundingClientRect().height) } : null; })(),
        viewport: (document.querySelector('meta[name=viewport]') || {}).content,
        sidebarId: !!document.getElementById('yuremote-sidebar'),
      };
      api.open(); await sleep(500);
      out.openAttr = html.getAttribute('data-yuremote-drawer');
      out.drawerBox = (() => { const col = document.getElementById('yuremote-sidebar'); if (!col) return null; const r = col.getBoundingClientRect(); return { x: Math.round(r.x), w: Math.round(r.width), right: Math.round(r.right) }; })();

      // A modal opening on top must retire the drawer.
      const modal = document.createElement('div');
      modal.setAttribute('role', 'dialog');
      modal.setAttribute('aria-modal', 'true');
      document.body.appendChild(modal);
      await sleep(400);
      out.drawerWhileModal = html.getAttribute('data-yuremote-drawer');
      modal.remove();
      await sleep(200);

      api.close(); await sleep(400);
      out.closedAttr = html.getAttribute('data-yuremote-drawer');
      api.refresh();
      return out;
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim());
    assert.equal(out.api, true, "__YUREMOTE_MOBILE__ API missing");
    assert.equal(out.active, true, "layer did not activate at 390px");
    assert.equal(out.htmlAttr, true, "data-yuremote-mobile not set on <html>");
    assert.equal(out.buttons, 1, "expected exactly one drawer button");
    assert.equal(out.scrims, 1, "expected exactly one scrim");
    assert.equal(out.controls.w, 44, "drawer button must be 44px wide");
    assert.equal(out.controls.h, 44, "drawer button must be 44px tall");
    assert.equal(out.controls.expanded, "false");
    assert.equal(out.controls.controls, "yuremote-sidebar");
    assert.equal(out.sidebarId, true, "aria-controls target missing");
    assert.match(out.viewport, /viewport-fit=cover/);
    assert.equal(out.openAttr, "open", "open() did not set data-yuremote-drawer");
    assert.ok(out.drawerBox, "sidebar column not found");
    assert.ok(out.drawerBox.right > 0 && out.drawerBox.right <= 390, "drawer is off screen when open");
    assert.ok(out.drawerBox.w <= 320 && out.drawerBox.w >= 250, "drawer width outside min(86vw,320px): " + out.drawerBox.w);
    assert.equal(out.drawerWhileModal, null, "drawer must close when a modal opens above it");
    assert.equal(out.closedAttr, null, "close() did not clear data-yuremote-drawer");
  });

  // 800px: dsh has no drawer of its own above 768px, so nothing but the layer
  // closes the drawer there (it used to stay open over the chosen page).
  for (const [w, name, label] of [
    [390, "Remote access", "Remote access|远程访问"],
    [800, "Remote access", "Remote access|远程访问"],
    [800, "Plugins", "Plugins|插件"],
  ]) test(`${name} opened from the drawer at ${w}px closes it${name === "Remote access" ? " and fills the width" : ""}`, async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const html = document.documentElement;
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(600);
      const entry = [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(${label})$/.test((b.getAttribute('aria-label') || b.textContent).trim()));
      if (!entry) return JSON.stringify({ entry: false });
      // Tap where a finger would: whatever is on top at the button's centre.
      const box = entry.getBoundingClientRect();
      const top = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
      const hitsEntry = !!top && entry.contains(top);
      (top || entry).click();
      await sleep(1200);
      const page = document.querySelector('[data-slot="main"] .yuremote-page');
      const r = page ? page.getBoundingClientRect() : null;
      return JSON.stringify({
        entry: true,
        hitsEntry,
        drawer: html.getAttribute('data-yuremote-drawer'),
        page: r ? { x: Math.round(r.x), w: Math.round(r.width) } : null,
        scrollW: document.documentElement.scrollWidth,
      });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", String(w), "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.entry, true, `${name} entry not found in the sidebar`);
    assert.equal(out.hitsEntry, true, "something covers the drawer: a tap on its rows never reaches them");
    assert.equal(out.drawer, null, "the drawer must close once a page is chosen");
    if (name !== "Remote access") return;
    assert.ok(out.page, "the Remote access page did not render in the main slot");
    assert.equal(out.page.x, 0, "the page must start at the left edge (was squeezed into an implicit column)");
    assert.equal(out.page.w, w, "the page must span the window width");
    assert.ok(out.scrollW <= w, "page overflows horizontally: " + out.scrollW);
  });

  for (const label of ["Plugins|插件", "Remote access|远程访问"]) {
    test(`switches and the password reveal keep their shape on touch (${label.split("|")[0]})`, async (t) => {
      if (skipReason) return t.skip(skipReason);
      const expr = `(async () => {
        const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
        document.querySelector('.yuremote-drawer-btn').click();
        await sleep(600);
        const entry = [...document.querySelectorAll('[data-slot="sidebar"] button')]
          .find((b) => /^(${label})$/.test(b.getAttribute('aria-label') || ''));
        if (!entry) return JSON.stringify({ entry: false });
        entry.click();
        await sleep(1500);
        const coarse = matchMedia('(pointer: coarse)').matches;
        const switches = [...document.querySelectorAll('[data-slot="main"] [role="switch"]')]
          .map((e) => e.getBoundingClientRect())
          .filter((r) => r.width > 0)
          .map((r) => ({ w: Math.round(r.width), h: Math.round(r.height) }));
        const pw = document.querySelector('[data-slot="main"] .yuremote-pw input');
        const eye = document.querySelector('[data-slot="main"] .yuremote-pw-eye');
        const ir = pw && pw.getBoundingClientRect();
        const er = eye && eye.getBoundingClientRect();
        return JSON.stringify({
          entry: true, coarse, switches,
          eye: ir && er ? { top: Math.round(er.top - ir.top), bottom: Math.round(ir.bottom - er.bottom) } : null,
        });
      })()`;
      const { code, stdout, stderr } = await runCdp([
        "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
        "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
      ]);
      assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
      const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
      assert.equal(out.entry, true, `${label} entry not found in the sidebar`);
      assert.equal(out.coarse, true, "the run must emulate a touch screen, or the coarse-pointer rules never apply");
      assert.ok(out.switches.length > 0, "no switch rendered on the page");
      for (const sw of out.switches) {
        assert.ok(sw.w >= sw.h * 1.5, `a switch was deformed to ${sw.w}x${sw.h}`);
      }
      if (out.eye) {
        assert.ok(out.eye.top >= 0 && out.eye.bottom >= 0, `the show/hide button sticks out of the password field: ${JSON.stringify(out.eye)}`);
      }
    });
  }

  // 768–900px (a phone in landscape, a small tablet): dsh pads its main panel
  // for its own menu button only below 768px, so the floating drawer button
  // used to sit on every page title there.
  for (const [w, h, label] of [
    [844, 390, "Remote access|远程访问"],
    [844, 390, "Plugins|插件"],
    [800, 1280, "Automation tasks|自动化任务"],
    [390, 844, "Remote access|远程访问"],
  ]) test(`the drawer button covers no text on ${label.split("|")[0]} at ${w}x${h}`, async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const btn = document.querySelector('.yuremote-drawer-btn');
      btn.click();
      await sleep(600);
      const entry = [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(${label})$/.test((b.getAttribute('aria-label') || b.textContent).trim()));
      if (!entry) return JSON.stringify({ entry: false });
      entry.click();
      await sleep(1500);
      const b = btn.getBoundingClientRect();
      const covered = [];
      const walk = document.createTreeWalker(document.querySelector('[data-slot="main"]'), NodeFilter.SHOW_TEXT);
      for (let n; (n = walk.nextNode());) {
        if (!n.textContent.trim()) continue;
        const range = document.createRange();
        range.selectNodeContents(n);
        for (const q of range.getClientRects()) {
          if (q.width && q.right > b.left && q.left < b.right && q.bottom > b.top && q.top < b.bottom) {
            covered.push(n.textContent.trim().slice(0, 30));
            break;
          }
        }
      }
      return JSON.stringify({ entry: true, visible: getComputedStyle(btn).display !== 'none', covered });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", String(w), "--h", String(h), "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.entry, true, `${label} entry not found in the sidebar`);
    assert.equal(out.visible, true, "the drawer button must be shown at this width");
    assert.deepEqual(out.covered, [], "the drawer button sits on page text");
  });

  // ≤560px: tabs used to share the width equally with no side padding, so at
  // 390px "Local network" ran into "Public access" and at 260px (390px at 150%
  // zoom) the last tab was cut off with nothing to show it was there.
  for (const w of [390, 260]) test(`Remote access tab labels stay apart and the chosen tab stays visible at ${w}px`, async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(600);
      const entry = [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(Remote access|远程访问)$/.test((b.getAttribute('aria-label') || b.textContent).trim()));
      if (!entry) return JSON.stringify({ entry: false });
      entry.click();
      await sleep(1500);
      const tabs = [...document.querySelectorAll('[data-slot="main"] [role="tab"]')];
      const text = (el) => { const r = document.createRange(); r.selectNodeContents(el); return r.getBoundingClientRect(); };
      const gaps = tabs.slice(1).map((tab, i) => Math.round(text(tab).left - text(tabs[i]).right));
      const last = tabs[tabs.length - 1];
      last.click();
      await sleep(800);
      const bar = last.parentElement.getBoundingClientRect();
      const lr = last.getBoundingClientRect();
      return JSON.stringify({ entry: true, gaps, lastVisible: lr.left >= bar.left - 1 && lr.right <= bar.right + 1, scrollW: document.documentElement.scrollWidth });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", String(w), "--h", "700", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.entry, true, "Remote access entry not found in the sidebar");
    for (const g of out.gaps) assert.ok(g >= 12, `two tab labels are only ${g}px apart: ${JSON.stringify(out.gaps)}`);
    assert.equal(out.lastVisible, true, "the chosen tab is scrolled out of view");
    assert.ok(out.scrollW <= w, "page overflows horizontally: " + out.scrollW);
  });

  // A phone turning remote access off cuts its own connection: it must be
  // asked first, and afterwards see that only the PC can turn it back on.
  test("turning remote access off from a phone asks first and then says the phone is disconnected", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const cfg = (body) => fetch('/yuremote/config', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }).then((r) => r.json());
      const enabled = async () => (await (await fetch('/yuremote/status')).json()).status.enabled;
      await cfg({ enabled: true });
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(600);
      [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(Remote access|远程访问)$/.test((b.getAttribute('aria-label') || b.textContent).trim())).click();
      await sleep(2000);
      const sw = () => document.querySelector('[data-slot="main"] [role="switch"]');
      const alerts = () => [...document.querySelectorAll('[data-slot="main"] [role="alert"]')].map((a) => a.textContent.trim());
      document.cookie = 'dsh_portal_client=1; path=/';
      let asked = '';
      window.confirm = (m) => { asked = m; return false; };
      sw().click();
      await sleep(1500);
      const declined = { asked: !!asked, enabled: await enabled(), checked: sw().getAttribute('aria-checked') };
      asked = '';
      window.confirm = (m) => { asked = m; return true; };
      sw().click();
      await sleep(2500);
      const accepted = { asked: !!asked, checked: sw().getAttribute('aria-checked'), alerts: alerts() };
      document.cookie = 'dsh_portal_client=; path=/; max-age=0';
      await cfg({ enabled: true });
      await sleep(4500);
      const back = { checked: sw().getAttribute('aria-checked'), alerts: alerts() };
      return JSON.stringify({ declined, accepted, back });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.declined.asked, true, "a phone must be asked before switching remote access off");
    assert.equal(out.declined.enabled, true, "declining must leave remote access on");
    assert.equal(out.accepted.checked, "false", "the switch must show off once it went through");
    assert.ok(out.accepted.alerts.some((a) => /PC|电脑/.test(a)), "the phone must be told only the PC can turn it back on: " + JSON.stringify(out.accepted.alerts));
    assert.equal(out.accepted.alerts.length, 1, "no generic connection error next to it: " + JSON.stringify(out.accepted.alerts));
    assert.equal(out.back.checked, "true", "turned back on from the PC, the panel follows");
    assert.ok(!out.back.alerts.some((a) => /PC|电脑/.test(a)), "the disconnected notice must clear");
  });

  test("a paired phone at 400px only shows password status after an authenticated poll", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const host = await runCdp(["eval", BASE, `(async () => {
      const r = await fetch('./yuremote/pair', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
      return (await r.json()).pairing?.url || '';
    })()`, "--token", TOKEN_URL, "--wait", "3000"]);
    assert.equal(host.code, 0, host.stderr.slice(-800));
    const pair = new URL(host.stdout.trim());
    const phone = await runCdp(["eval", pair.origin + "/", `(async () => {
      const wait = (ms) => new Promise(r => setTimeout(r, ms));
      const real = window.fetch;
      const polls = [];
      window.fetch = async (input, init) => {
        if (!String(input).endsWith('/status')) return real(input, init);
        const response = await real(input, polls.length ? init : { ...init, credentials: 'omit' });
        const data = await response.clone().json();
        polls.push([new URL(response.url).pathname, response.status, data.status?.passwordSet ?? null]);
        return response;
      };
      document.querySelector('.yuremote-drawer-btn').click();
      await wait(600);
      [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find(b => /^(Remote access|远程访问)$/.test((b.getAttribute('aria-label') || b.textContent).trim())).click();
      const badge = () => document.querySelector('[data-yuremote="password"] .yuremote-chip')?.textContent ?? null;
      const alert = () => document.querySelector('[data-slot="main"] [role="alert"]')?.textContent || '';
      for (let i = 0; i < 20 && !alert(); i++) await wait(100);
      const refused = { badge: badge(), alert: alert() };
      for (let i = 0; i < 60 && !badge(); i++) await wait(100);
      return { polls: polls.slice(0, 2), refused, badge: badge(), alert: alert() };
    })()`, "--token", pair.href, "--wait", "4000", "--w", "400", "--h", "754", "--mobile",
      "--pre-file", join(tmp, "pre.js"), "--settle", "1200"]);
    assert.equal(phone.code, 0, phone.stderr.slice(-800));
    const result = JSON.parse(phone.stdout.trim());
    assert.deepEqual(result.polls, [["/yuremote/status", 401, null], ["/yuremote/status", 200, true]]);
    assert.match(result.refused.alert, /authentication required/);
    assert.equal(result.refused.badge, null);
    assert.match(result.badge, /^(Set|已设置)$/);
    assert.equal(result.alert, "");
  });

  // The panel's note promises that a password change signs devices out; one
  // who lost a phone changes the password expecting exactly that.
  test("changing the password from the panel signs every device out and cancels unused pairing links", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const UA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
    const open = `const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(600);
      [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(Remote access|远程访问)$/.test((b.getAttribute('aria-label') || b.textContent).trim())).click();
      await sleep(2000);`;
    const change = (phone, accept, real = false) => `(async () => {
      ${open}
      const tab = async (re) => { const b = [...document.querySelectorAll('[data-slot="main"] [role="tab"], [data-slot="main"] button')].find((x) => re.test(x.textContent.trim())); if (b) b.click(); await sleep(900); };
      const shown = async () => { await tab(/^(局域网访问|Local network)$/); const src = document.querySelector('[data-yuremote="qr"] img')?.getAttribute('src') || ''; await tab(/^(基本设置|General)$/); return (decodeURIComponent(src).match(/https?:[^\\s"'&]*pair[^\\s"'&]*/) || [''])[0]; };
      const before = ${real} ? '' : await shown();
      if (${phone}) document.cookie = 'dsh_portal_client=1; path=/';
      let asked = '';
      window.confirm = (m) => { asked = m; return ${accept}; };
      const input = document.querySelector('input[name="yuremote-portal-password"]');
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(input, 'pw-test-' + Date.now());
      input.dispatchEvent(new Event('input', { bubbles: true }));
      await sleep(300);
      [...document.querySelectorAll('[data-yuremote="password"] button')].find((b) => /^(更新密码|Update password)$/.test(b.textContent.trim())).click();
      await sleep(900);
      const text = document.querySelector('[data-slot="main"]').textContent;
      if (${real}) {
        const page = await (await fetch('./', { headers: { accept: 'text/html' } })).text();
        return JSON.stringify({ asked: !!asked, text: text.slice(0, 4000), loginNext: /type="password"/.test(page) });
      }
      document.cookie = 'dsh_portal_client=; path=/; max-age=0';
      await sleep(2500);
      return JSON.stringify({ asked: !!asked, text: text.slice(0, 4000), before, after: await shown() });
    })()`;
    const run = async (expr, url = BASE, token = TOKEN_URL) => {
      const { code, stdout, stderr } = await runCdp([
        "eval", url, expr, "--token", token, "--wait", "4000",
        "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
      ]);
      assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
      return JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    };
    const links = await run(`(async () => {
      const post = (p, b) => fetch('/yuremote/' + p, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) }).then((r) => r.json());
      const st = (await (await fetch('/yuremote/status')).json()).status;
      return JSON.stringify({ port: st.port, a: (await post('pair', { ttlSeconds: 300 })).pairing.url, b: (await post('pair', { ttlSeconds: 300 })).pairing.url });
    })()`);
    const local = (link) => { const u = new URL(link); return `http://127.0.0.1:${links.port}${u.pathname}${u.search}`; };
    const pair = async (link) => {
      const r = await fetch(local(link), { redirect: "manual", headers: { "user-agent": UA, accept: "text/html" } });
      return (r.headers.getSetCookie?.() || []).map((c) => c.split(";")[0]).filter((c) => /^dsh_portal=./.test(c)).join("; ");
    };
    const signedIn = async (cookie) => {
      const r = await fetch(`http://127.0.0.1:${links.port}/`, { redirect: "manual", headers: { "user-agent": UA, accept: "text/html", cookie } });
      return r.status !== 401 && !/type="password"/.test(await r.text());
    };
    const phone = await pair(links.a);
    assert.ok(phone, "the test phone must pair");
    assert.equal(await signedIn(phone), true);

    const declined = await run(change(true, false));
    assert.equal(declined.asked, true, "a phone changing the password must be told it will be signed out");
    assert.equal(await signedIn(phone), true, "declining must change nothing");

    const pc = await run(change(false, true));
    assert.equal(pc.asked, false, "the PC is not signed out, so it is not asked");
    assert.match(pc.text, /所有设备已退出登录|every device has been signed out/);
    assert.equal(await signedIn(phone), false, "a signed-in phone must be signed out by the change");
    assert.equal(await pair(links.b), "", "a pairing link made before the change must no longer sign anyone in");
    assert.ok(pc.after && pc.after !== pc.before, "the panel must show a fresh pairing link, not the voided one: " + JSON.stringify([pc.before, pc.after]));
    assert.ok(await pair(pc.after), "the pairing link shown after the change must work");

    // A real phone, signed in through the portal (not the marker cookie on the PC).
    const fresh = await run(`(async () => {
      const r = await fetch('/yuremote/pair', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ ttlSeconds: 300 }) });
      return JSON.stringify({ c: (await r.json()).pairing.url });
    })()`);
    const self = await run(change(false, true, true), `http://127.0.0.1:${links.port}/`, local(fresh.c));
    assert.equal(self.asked, true, "a phone signed in through the portal must be asked");
    assert.match(self.text, /这台设备也已退出登录|This device has been signed out too/);
    assert.equal(self.loginNext, true, "after the change that phone must land on sign-in");
  });

  test("a slow /status link never has two polls open at once", async (t) => {
    if (skipReason) return t.skip(skipReason);
    // Every /status answer is held back 5 s, as on a slow relay. A fixed 3 s
    // interval used to keep two (at 9 s, three) of them open at the same time.
    const slow = `(() => {
      const real = window.fetch.bind(window);
      const poll = window.__yuremotePoll = { started: 0, ok: 0, open: 0, maxOpen: 0 };
      window.fetch = (input, init) => {
        const url = String(input && input.url ? input.url : input);
        if (!/\\/yuremote\\/status(\\?|$)/.test(url)) return real(input, init);
        poll.started++; poll.open++; poll.maxOpen = Math.max(poll.maxOpen, poll.open);
        return new Promise((r) => setTimeout(r, 5000)).then(() => real(input, init))
          .then((res) => { if (res.ok) poll.ok++; return res; })
          .finally(() => { poll.open--; });
      };
    })();`;
    writeFileSync(join(tmp, "slow-status.js"), slow);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(600);
      const entry = [...document.querySelectorAll('[data-slot="sidebar"] button')]
        .find((b) => /^(Remote access|远程访问)$/.test(b.getAttribute('aria-label') || ''));
      if (!entry) return JSON.stringify({ entry: false });
      window.__yuremotePoll.maxOpen = window.__yuremotePoll.open;
      const before = window.__yuremotePoll.started;
      const okBefore = window.__yuremotePoll.ok;
      entry.click();
      await sleep(14000);
      return JSON.stringify({ entry: true, started: window.__yuremotePoll.started - before, ok: window.__yuremotePoll.ok - okBefore, maxOpen: window.__yuremotePoll.maxOpen });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", "390", "--h", "844", "--mobile", "--pre-eval-file", join(tmp, "slow-status.js"),
      "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.entry, true, "Remote access entry not found in the sidebar");
    assert.ok(out.started >= 2, `the panel stopped polling: ${out.started} request(s) in 14 s`);
    assert.equal(out.maxOpen, 1, `${out.maxOpen} /status polls were open at once`);
    // 5 s is inside the 8 s timeout: the slowed polls must still be answered.
    assert.ok(out.ok >= 1, `no /status poll succeeded in 14 s (${out.started} sent)`);
  });

  test("every visible button in the open drawer is what a tap there hits", async (t) => {
    if (skipReason) return t.skip(skipReason);
    // A scripted .click() skips whatever sits on top, so it can pass while real
    // taps land on a mask (dsh's own drawer mask did exactly that).
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      document.querySelector('.yuremote-drawer-btn').click();
      await sleep(700);
      const sidebar = document.querySelector('[data-slot="sidebar"]');
      const buttons = sidebar ? [...sidebar.querySelectorAll('button')].filter((b) => {
        const r = b.getBoundingClientRect();
        return r.width > 0 && r.height > 0 && r.left >= 0 && r.top >= 0 && r.right <= innerWidth && r.bottom <= innerHeight;
      }) : [];
      const missed = buttons.filter((b) => {
        const r = b.getBoundingClientRect();
        const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
        // hit.contains(b): a button that ignores pointers itself (hover-only affordances).
        return !hit || !(b.contains(hit) || hit.contains(b));
      }).map((b) => {
        const r = b.getBoundingClientRect();
        const hit = document.elementFromPoint(r.x + r.width / 2, r.y + r.height / 2);
        return (b.getAttribute('aria-label') || b.textContent.trim()).slice(0, 30) + ' -> ' +
          (hit ? hit.tagName + '.' + String(hit.className).slice(0, 40) : 'nothing');
      });
      return JSON.stringify({ drawer: document.documentElement.getAttribute('data-yuremote-drawer'), candidates: buttons.length, missed });
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim().split("\n").filter((l) => l.trim().startsWith("{")).pop());
    assert.equal(out.drawer, "open", "the drawer did not open");
    assert.ok(out.candidates > 0, "no visible buttons in the open drawer");
    assert.deepEqual(out.missed, [], `drawer buttons covered by something else (of ${out.candidates})`);
  });

  test("no horizontal overflow at 320/360/390/430/768/900 in both themes", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const outPath = join(tmp, "audit.json");
    // Browser runs share one instance; a slow first paint can make the audit
    // start before the shell exists. One retry is cheaper than a flaky suite.
    let attempt = await runCdp([
      "audit", BASE, outPath,
      "--token", TOKEN_URL,
      "--pre-file", join(tmp, "pre.js"),
      "--widths", "320,360,390,430,768,900",
      "--heights", "700,780,844,932,1024,1100",
      "--themes", "dark,light",
      "--mobile", "--wait", "4000", "--settle", "450",
    ]);
    if (attempt.code !== 0) {
      attempt = await runCdp([
        "audit", BASE, outPath,
        "--token", TOKEN_URL,
        "--widths", "320,360,390,430,768,900",
        "--themes", "dark,light",
        "--wait", "5000",
        "--pre-file", join(tmp, "pre.js"),
        "--settle", "700",
      ]);
    }
    const { code, stdout, stderr } = attempt;
    assert.equal(code, 0, "audit run failed: " + String(stderr).slice(-800));
    assert.match(stdout, /failing=0/, "audit reported failing rows: " + stdout.trim());
    const rows = JSON.parse(readFileSync(outPath, "utf8"));
    assert.equal(rows.length, 12);
    for (const row of rows) {
      const where = `${row.requested.w}px/${row.requested.theme}`;
      assert.ok(
        row.docScrollWidth <= row.innerWidth,
        `${where}: documentElement.scrollWidth ${row.docScrollWidth} > innerWidth ${row.innerWidth}`,
      );
      assert.ok(
        row.bodyScrollWidth <= row.innerWidth,
        `${where}: body.scrollWidth ${row.bodyScrollWidth} > innerWidth ${row.innerWidth}`,
      );
      assert.deepEqual(row.offenders, [], `${where}: elements past the right edge`);
    }
  });
});











