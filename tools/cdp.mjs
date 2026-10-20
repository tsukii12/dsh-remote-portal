// cdp.mjs — tiny Chrome DevTools Protocol driver (no dependencies).
//
// Commands:
//   node cdp.mjs dom  <url> <out.html> [--token <tokenUrl>] [--wait 3000] [--w 1440] [--h 900] [--mobile]
//   node cdp.mjs shot <url> <out.png>  [--token <tokenUrl>] [--wait 3000] [--w 1440] [--h 900] [--mobile]
//   node cdp.mjs eval <url> "<js>"     [--token <tokenUrl>] [--wait 3000] [--w ...] [--h ...] [--mobile]
//
// --token navigates to the token URL first (which sets the auth cookie), then
// navigates to the real URL in the same browser session.
//
// --pre-file <path> is the file form of --pre. It exists because the Windows
// command line tops out around 32k characters, and injecting a whole stylesheet
// plus script as one --pre argument fails with ENAMETOOLONG.
import { spawn } from "node:child_process";
import { writeFileSync, mkdirSync, rmSync, existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const CHROME = process.env.CHROME_PATH || "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe";

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const key = a.slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith("--")) out[key] = true;
      else { out[key] = next; i++; }
    } else out._.push(a);
  }
  return out;
}

const args = parseArgs(process.argv.slice(2));
const [cmd, url, target] = args._;
if (!cmd || !url) {
  console.error("usage: node cdp.mjs <dom|shot|eval> <url> <out|js> [--token u] [--wait ms] [--w px] [--h px] [--mobile]");
  process.exit(2);
}

const width = Number(args.w || 1440);
const height = Number(args.h || 900);
const mobile = !!args.mobile;
const settleMs = Number(args.wait || 3500);
const profileDir = join(tmpdir(), `dsh-cdp-${process.pid}-${Date.now()}`);
// Port 0 lets Chrome pick a free port and print it. A guessed fixed port
// collides with a Chrome that is still shutting down (bind() on IPv4 fails
// while Chrome silently falls back to IPv6, and the poll then hits a
// stranger's socket).
const port = 0;

mkdirSync(profileDir, { recursive: true });
const chrome = spawn(CHROME, [
  "--headless=new",
  "--disable-gpu",
  "--no-first-run",
  "--no-default-browser-check",
  "--disable-extensions",
  "--disable-background-networking",
  "--disable-sync",
  "--hide-scrollbars",
  "--mute-audio",
  // Self-signed TLS is the documented way to run the portal over HTTPS on a
  // LAN, so the driver has to be able to look at such a page: pass --ignore-cert
  // and Chrome skips the interstitial that would otherwise hide the whole UI.
  ...(args["ignore-cert"] ? ["--ignore-certificate-errors", "--allow-insecure-localhost"] : []),
  // `--host-map host=ip` pins one hostname to an address without touching DNS,
  // which is how a public deployment is verified before its A record exists.
  ...(typeof args["host-map"] === "string"
    ? [`--host-resolver-rules=MAP ${String(args["host-map"]).replace("=", " ")}`]
    : []),
  `--remote-debugging-port=${port}`,
  `--user-data-dir=${profileDir}`,
  "--window-size=" + width + "," + height,
  "about:blank",
], { stdio: ["ignore", "ignore", "pipe"] });

let chromeErr = "";
chrome.stderr.on("data", (d) => { chromeErr += d.toString(); });

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Evaluated once per width × theme in the `audit` command.
// Rules: the document may not scroll horizontally, and no visible element may
// stick out past the right edge — except things that live inside an explicit
// horizontal scroller (that is the sanctioned way to show wide content) and
// elements that are hidden (the parked drawer, an unopened panel).
const AUDIT_EXPRESSION = `(() => {
  const vw = window.innerWidth;
  const describe = (el) => {
    const cls = typeof el.className === "string" ? el.className.trim().split(/\\s+/).slice(0, 2).join(".") : "";
    const slot = el.getAttribute("data-slot");
    const role = el.getAttribute("role");
    return el.tagName.toLowerCase() +
      (el.id ? "#" + el.id : "") +
      (slot ? "[data-slot=" + slot + "]" : "") +
      (role ? "[role=" + role + "]" : "") +
      (cls ? "." + cls : "");
  };
  const inHorizontalScroller = (el) => {
    let p = el.parentElement;
    while (p && p !== document.body) {
      const s = getComputedStyle(p);
      // sanctioned horizontal scroller
      if (s.overflowX === "auto" || s.overflowX === "scroll") return true;
      // a viewport-anchored layer that clips cannot widen the document, so
      // decoration inside it (a full-bleed backdrop image) is not an overflow
      if (s.position === "fixed" && s.overflowX !== "visible") return true;
      p = p.parentElement;
    }
    return false;
  };
  const offenders = [];
  const seen = new Set();
  for (const el of document.querySelectorAll("body *")) {
    const cs = getComputedStyle(el);
    if (cs.display === "none" || cs.visibility === "hidden" || cs.opacity === "0") continue;
    const r = el.getBoundingClientRect();
    if (r.width === 0 && r.height === 0) continue;
    if (r.right <= vw + 1) continue;
    if (inHorizontalScroller(el)) continue;
    const key = describe(el) + "@" + Math.round(r.right);
    if (seen.has(key)) continue;
    seen.add(key);
    offenders.push({ el: describe(el), right: Math.round(r.right), width: Math.round(r.width) });
  }
  const doc = document.documentElement;
  const body = document.body;
  return {
    innerWidth: vw,
    docScrollWidth: doc.scrollWidth,
    bodyScrollWidth: body.scrollWidth,
    offenderCount: offenders.length,
    offenders: offenders.slice(0, 12),
    htmlAttrs: [...doc.attributes].map((a) => a.name).join(","),
    ok: doc.scrollWidth <= vw && body.scrollWidth <= vw && offenders.length === 0,
  };
})()`;

/** Chrome prints `DevTools listening on ws://…` as soon as the browser endpoint exists. */
async function waitForDevtools() {
  for (let i = 0; i < 160; i++) {
    const m = chromeErr.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) return { webSocketDebuggerUrl: m[1] };
    await sleep(250);
  }
  throw new Error("devtools endpoint never came up\n" + chromeErr.slice(-2000));
}

class CDP {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.seq = 0;
    this.pending = new Map();
    this.handlers = new Map();
    this.ready = new Promise((res, rej) => {
      this.ws.addEventListener("open", () => res());
      this.ws.addEventListener("error", (e) => rej(new Error("ws error: " + (e.message || "unknown"))));
    });
    this.ws.addEventListener("message", (ev) => {
      let msg;
      try { msg = JSON.parse(ev.data); } catch { return; }
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        if (msg.error) reject(new Error(JSON.stringify(msg.error)));
        else resolve(msg.result);
      } else if (msg.method) {
        const list = this.handlers.get(msg.method) || [];
        for (const fn of list) fn(msg.params, msg.sessionId);
      }
    });
  }
  send(method, params = {}, sessionId) {
    const id = ++this.seq;
    const payload = { id, method, params };
    if (sessionId) payload.sessionId = sessionId;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify(payload));
      setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error(`timeout: ${method}`)); }
      }, 60000);
    });
  }
  on(method, fn) {
    if (!this.handlers.has(method)) this.handlers.set(method, []);
    this.handlers.get(method).push(fn);
  }
  once(method) {
    return new Promise((resolve) => {
      const fn = (params) => {
        const list = this.handlers.get(method) || [];
        const i = list.indexOf(fn);
        if (i >= 0) list.splice(i, 1);
        resolve(params);
      };
      this.on(method, fn);
    });
  }
  close() { try { this.ws.close(); } catch { /* ignore */ } }
}

function cleanup() {
  try { chrome.kill("SIGKILL"); } catch { /* ignore */ }
  try { if (existsSync(profileDir)) rmSync(profileDir, { recursive: true, force: true }); } catch { /* ignore */ }
}

try {
  const version = await waitForDevtools();
  const cdp = new CDP(version.webSocketDebuggerUrl);
  await cdp.ready;

  const { targetId } = await cdp.send("Target.createTarget", { url: "about:blank" });
  const { sessionId } = await cdp.send("Target.attachToTarget", { targetId, flatten: true });

  await cdp.send("Page.enable", {}, sessionId);
  await cdp.send("Runtime.enable", {}, sessionId);
  await cdp.send("Network.enable", {}, sessionId);

  if (mobile) {
    await cdp.send("Emulation.setDeviceMetricsOverride", {
      width, height, deviceScaleFactor: 2, mobile: true,
      screenWidth: width, screenHeight: height,
    }, sessionId);
    await cdp.send("Emulation.setTouchEmulationEnabled", { enabled: true, maxTouchPoints: 5 }, sessionId);
    await cdp.send("Emulation.setUserAgentOverride", {
      userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
      platform: "iPhone",
    }, sessionId);
  }

  async function navigate(u) {
    const loaded = cdp.once("Page.loadEventFired");
    await cdp.send("Page.navigate", { url: u }, sessionId);
    await Promise.race([loaded, sleep(20000)]);
  }

  if (args.token) {
    await navigate(String(args.token));
    await sleep(1200);
  }
  await navigate(url);
  await sleep(settleMs);

  // Optional post-load script (e.g. dismiss a first-run dialog), then settle again.
  // `--pre-file` is the same thing read from disk, for payloads too large for argv.
  if (typeof args["pre-file"] === "string") {
    args.pre = readFileSync(args["pre-file"], "utf8");
  }
  if (args.pre && typeof args.pre === "string") {
    await cdp.send("Runtime.evaluate", { expression: String(args.pre), awaitPromise: true }, sessionId);
    await sleep(Number(args.settle || 1200));
  }

  async function evaluate(expression) {
    const r = await cdp.send("Runtime.evaluate", {
      expression, returnByValue: true, awaitPromise: true, userGesture: true,
    }, sessionId);
    if (r.exceptionDetails) throw new Error("eval failed: " + JSON.stringify(r.exceptionDetails).slice(0, 800));
    return r.result?.value;
  }

  if (cmd === "dom") {
    const html = await evaluate("document.documentElement.outerHTML");
    writeFileSync(target, html, "utf8");
    console.log(`ok dom -> ${target} (${html.length} bytes) url=${await evaluate("location.href")}`);
  } else if (cmd === "shot") {
    const { data } = await cdp.send("Page.captureScreenshot", { format: "png", captureBeyondViewport: false }, sessionId);
    writeFileSync(target, Buffer.from(data, "base64"));
    console.log(`ok shot -> ${target} url=${await evaluate("location.href")}`);
  } else if (cmd === "eval") {
    const value = await evaluate(target);
    console.log(typeof value === "string" ? value : JSON.stringify(value, null, 2));
  } else if (cmd === "audit") {
    // Horizontal-overflow audit across a width × theme matrix in ONE browser.
    // Re-launching Chrome per configuration takes ~8 s each; re-driving
    // Emulation.setDeviceMetricsOverride takes ~0.5 s.
    // The page must expose an optional `window.__DRP_AUDIT_THEME(mode)` hook
    // (the --pre-file payload usually defines it) to switch light/dark.
    const widths = String(args.widths || "320,360,390,430,768,900").split(",").map(Number);
    const heights = String(args.heights || "844").split(",").map(Number);
    const themes = String(args.themes || "dark,light").split(",");
    const rows = [];
    for (let i = 0; i < widths.length; i++) {
      const w = widths[i];
      const h = heights[Math.min(i, heights.length - 1)];
      await cdp.send("Emulation.setDeviceMetricsOverride", {
        width: w, height: h, deviceScaleFactor: mobile ? 2 : 1, mobile: !!mobile,
        screenWidth: w, screenHeight: h,
      }, sessionId);
      await sleep(Number(args["resize-settle"] || 450));
      for (const theme of themes) {
        await evaluate(`(() => { const f = window.__DRP_AUDIT_THEME; if (typeof f === "function") f(${JSON.stringify(theme)}); return true; })()`);
        await sleep(Number(args.settle || 350));
        const measured = await evaluate(AUDIT_EXPRESSION);
        rows.push({ requested: { w, h, theme }, ...measured });
      }
    }
    writeFileSync(target, JSON.stringify(rows, null, 2), "utf8");
    const bad = rows.filter((r) => !r.ok);
    console.log(`ok audit -> ${target} rows=${rows.length} failing=${bad.length}`);
  } else {
    console.error("unknown command " + cmd);
    process.exitCode = 2;
  }
  cdp.close();
} catch (e) {
  console.error("FAILED:", e?.stack || e);
  process.exitCode = 1;
} finally {
  cleanup();
  setTimeout(() => process.exit(process.exitCode || 0), 100);
}

