/**
 * test/mobile.test.mjs — the mobile presentation layer (assets/mobile.css +
 * assets/mobile.js) under `node --test`.
 *
 * Three layers of checking, cheapest first:
 *
 *  1. **Static lint** (no browser): the stylesheet is one @media block, every
 *     selector is gated on `html[data-drp-mobile]`, `!important` is used only
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
  BASE = `http://127.0.0.1:${port}/`;
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
      assert.match(
        block.prelude,
        /^@media \(max-width: 900px\)( and \(pointer: coarse\))?$/,
        `top-level block is not the 900px gate: ${block.prelude}`,
      );
    }
  });

  test("every rule is gated on html[data-drp-mobile]", () => {
    const offenders = [];
    for (const media of topLevelBlocks(clean)) {
      // one level deep: selectors and nested @media
      const inner = topLevelBlocks(media.body);
      for (const rule of inner) {
        if (rule.prelude.startsWith("@")) continue; // nested prefers-reduced-motion
        for (const selector of splitSelectors(rule.prelude)) {
          if (!selector.startsWith("html[data-drp-mobile]")) offenders.push(selector);
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
    assert.match(clean, /\[role="dialog"\]\[data-drp="panel"\]/);
  });

  test("the layer's own classes cannot collide with client.js", () => {
    // client.js owns .drp-overlay/.drp-scrim/.drp-sheet/…; the layer only adds
    // .drp-drawer-*. The one exception is that the layer deliberately tightens
    // .drp-sheet-body inside [data-drp="panel"] — assert it stays scoped there.
    const re = /\.(drp-[a-z-]+)/g;
    let match;
    while ((match = re.exec(clean)) !== null) {
      const cls = match[1];
      const selector = ruleSelectorAt(clean, match.index).replace(/\s+/g, " ");
      if (cls.startsWith("drp-drawer-")) continue;
      assert.ok(
        selector.includes('[data-drp="panel"]'),
        `layer styles client.js class .${cls} outside [data-drp="panel"] (${selector})`,
      );
    }
    assert.match(js, /drp-drawer-scrim/);
    assert.match(js, /drp-drawer-btn/);
    assert.equal(/drp-scrim/.test(js.replace(/drp-drawer-scrim/g, "")), false, "mobile.js must not use client.js's .drp-scrim");
  });
});

describe("assets/mobile.js — source contract", () => {
  test("is an idempotent, dependency-free IIFE", () => {
    assert.match(js, /window\.__DRP_MOBILE__/, "must expose the test API");
    assert.match(js, /if \(window\.__DRP_MOBILE__\)/, "must bail out when loaded twice");
    assert.equal(/^\s*import\s/m.test(js), false, "no ESM imports");
    assert.equal(/\brequire\(/.test(js), false, "no require()");
    assert.match(js, /\(function \(\) \{/, "wrapped in an IIFE");
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
      BASE = ENV_BASE.endsWith("/") ? ENV_BASE : ENV_BASE + "/";
      TOKEN_URL = BASE + "?token=" + ENV_TOKEN;
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
    tmp = mkdtempSync(join(tmpdir(), "drp-mobile-test-"));
    // One pre-file: inject the shipped CSS + JS exactly as client.js does, and
    // expose a light/dark switch for the audit.
    const pre = `(async () => {
  for (const b of document.querySelectorAll('button')) {
    const t = (b.textContent || '').trim();
    if (t === '继续' || t === 'Continue') { b.click(); break; }
  }
  const style = document.createElement('style');
  style.id = 'drp-mobile-css';
  style.textContent = ${JSON.stringify(css)};
  document.head.appendChild(style);
  try { (0, eval)(${JSON.stringify(js)}); } catch (e) { window.__drpJsError = String(e); }
  window.__DRP_AUDIT_THEME = (mode) => {
    const b = document.body;
    if (!window.__drpOrigTheme) {
      window.__drpOrigTheme = {
        dark: b.hasAttribute('data-ds-dark-theme'),
        skin: b.getAttribute('data-liang-skin'),
        stage: b.getAttribute('data-liang-stage'),
        backdrop: document.querySelector('.liang-skin-backdrop'),
      };
    }
    const o = window.__drpOrigTheme;
    let light = document.getElementById('drp-audit-light');
    if (mode === 'light') {
      b.removeAttribute('data-ds-dark-theme');
      b.removeAttribute('data-liang-skin');
      b.removeAttribute('data-liang-stage');
      document.documentElement.style.colorScheme = 'light';
      if (o.backdrop) o.backdrop.style.display = 'none';
      if (!light) {
        light = document.createElement('style');
        light.id = 'drp-audit-light';
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
    if (window.__DRP_MOBILE__) window.__DRP_MOBILE__.refresh();
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
    // layouts. The rules are global element rules under `html[data-drp-mobile]`,
    // so a synthetic node exercises exactly what a real message would hit.
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      await sleep(200);
      const host = document.querySelector('[data-slot="conversation.chat.flow"]')
        || document.querySelector('[data-slot="conversation"]')
        || document.querySelector('main')
        || document.body;
      const box = document.createElement('div');
      box.id = 'drp-overflow-probe';
      box.innerHTML = ''
        + '<pre id="drp-probe-pre">' + 'curl -s https://example.invalid/' + 'a'.repeat(220) + '</pre>'
        + '<div class="_tableScroll_x1" id="drp-probe-wrap">'
        + '  <table id="drp-probe-table"><tbody><tr>'
        + Array.from({ length: 12 }, (_, i) => '<td>cell-' + i + '-padding</td>').join('')
        + '  </tr></tbody></table>'
        + '</div>'
        + '<img id="drp-probe-img" alt="" src="data:image/svg+xml;utf8,' +
        encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="900"></svg>') + '">';
      host.appendChild(box);
      await sleep(400);
      const r = (el) => el.getBoundingClientRect();
      const pre = document.getElementById('drp-probe-pre');
      const wrap = document.getElementById('drp-probe-wrap');
      const table = document.getElementById('drp-probe-table');
      const img = document.getElementById('drp-probe-img');
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
        layer: document.documentElement.hasAttribute("data-drp-mobile"),
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
      cover.id = 'drp-cover-probe';
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
    assert.equal(String(m.fixed.hit).includes("drp-cover-probe"), false, `a touch at the centre hits the wrapper (${m.fixed.hit})`);
    assert.equal(m.broken.pointerEvents, "auto");
    assert.equal(m.broken.hit, "drp-cover-probe", "the probe must be on top when the rule is defeated");
  });

  test("activates at 390px and exposes a working drawer API", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const expr = `(async () => {
      const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
      const api = window.__DRP_MOBILE__;
      const html = document.documentElement;
      const out = {
        api: !!api,
        active: !!(api && api.active),
        htmlAttr: html.hasAttribute('data-drp-mobile'),
        buttons: document.querySelectorAll('.drp-drawer-btn').length,
        scrims: document.querySelectorAll('.drp-drawer-scrim').length,
        controls: (() => { const b = document.querySelector('.drp-drawer-btn'); return b ? { controls: b.getAttribute('aria-controls'), expanded: b.getAttribute('aria-expanded'), w: Math.round(b.getBoundingClientRect().width), h: Math.round(b.getBoundingClientRect().height) } : null; })(),
        viewport: (document.querySelector('meta[name=viewport]') || {}).content,
        sidebarId: !!document.getElementById('drp-sidebar'),
      };
      api.open(); await sleep(500);
      out.openAttr = html.getAttribute('data-drp-drawer');
      out.drawerBox = (() => { const col = document.getElementById('drp-sidebar'); if (!col) return null; const r = col.getBoundingClientRect(); return { x: Math.round(r.x), w: Math.round(r.width), right: Math.round(r.right) }; })();

      // A modal opening on top must retire the drawer.
      const modal = document.createElement('div');
      modal.setAttribute('role', 'dialog');
      modal.setAttribute('aria-modal', 'true');
      document.body.appendChild(modal);
      await sleep(400);
      out.drawerWhileModal = html.getAttribute('data-drp-drawer');
      modal.remove();
      await sleep(200);

      api.close(); await sleep(400);
      out.closedAttr = html.getAttribute('data-drp-drawer');
      api.refresh();
      return out;
    })()`;
    const { code, stdout, stderr } = await runCdp([
      "eval", BASE, expr, "--token", TOKEN_URL, "--wait", "4000",
      "--w", "390", "--h", "844", "--mobile", "--pre-file", join(tmp, "pre.js"), "--settle", "1200",
    ]);
    assert.equal(code, 0, "cdp run failed: " + stderr.slice(-800));
    const out = JSON.parse(stdout.trim());
    assert.equal(out.api, true, "__DRP_MOBILE__ API missing");
    assert.equal(out.active, true, "layer did not activate at 390px");
    assert.equal(out.htmlAttr, true, "data-drp-mobile not set on <html>");
    assert.equal(out.buttons, 1, "expected exactly one drawer button");
    assert.equal(out.scrims, 1, "expected exactly one scrim");
    assert.equal(out.controls.w, 44, "drawer button must be 44px wide");
    assert.equal(out.controls.h, 44, "drawer button must be 44px tall");
    assert.equal(out.controls.expanded, "false");
    assert.equal(out.controls.controls, "drp-sidebar");
    assert.equal(out.sidebarId, true, "aria-controls target missing");
    assert.match(out.viewport, /viewport-fit=cover/);
    assert.equal(out.openAttr, "open", "open() did not set data-drp-drawer");
    assert.ok(out.drawerBox, "sidebar column not found");
    assert.ok(out.drawerBox.right > 0 && out.drawerBox.right <= 390, "drawer is off screen when open");
    assert.ok(out.drawerBox.w <= 320 && out.drawerBox.w >= 250, "drawer width outside min(86vw,320px): " + out.drawerBox.w);
    assert.equal(out.drawerWhileModal, null, "drawer must close when a modal opens above it");
    assert.equal(out.closedAttr, null, "close() did not clear data-drp-drawer");
  });

  test("no horizontal overflow at 320/360/390/430/768/900 in both themes", async (t) => {
    if (skipReason) return t.skip(skipReason);
    const outPath = join(tmp, "audit.json");
    const { code, stdout, stderr } = await runCdp([
      "audit", BASE, outPath,
      "--token", TOKEN_URL,
      "--pre-file", join(tmp, "pre.js"),
      "--widths", "320,360,390,430,768,900",
      "--heights", "700,780,844,932,1024,1100",
      "--themes", "dark,light",
      "--mobile", "--wait", "4000", "--settle", "450",
    ]);
    assert.equal(code, 0, "audit run failed: " + stderr.slice(-800));
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








