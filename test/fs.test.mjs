// The workspace picker's directory listing (`GET /yuremote/fs`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, symlinkSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { apply } from "../index.js";

function fsRoute(stateDir) {
  const routes = [];
  const ctx = {
    logger: { info() {}, warn() {}, error() {}, debug() {} },
    webServer: {
      host: "127.0.0.1", protocol: "http:", port: 0,
      register(route) { routes.push(route); return () => {}; },
    },
    get() { return undefined; },
    // Only the control routes: the listener and index rows are not under test.
    effect(fn, label) { if (/control routes$/.test(label)) fn(); },
  };
  apply(ctx, { stateDir, mobile: false });
  const route = routes.find((r) => r.path === "/yuremote/fs");
  assert.ok(route, "fs route not registered");
  return (path) => new Promise((resolve) => {
    const res = {
      headersSent: false,
      status: 0,
      writeHead(status) { this.status = status; this.headersSent = true; },
      end(body) { resolve({ status: this.status, body: JSON.parse(body) }); },
    };
    route.handler({
      method: "GET",
      url: "/yuremote/fs?path=" + encodeURIComponent(path),
      headers: { host: "127.0.0.1:3080" },
    }, res);
  });
}

test("the picker lists directories and directory symlinks, never files or dangling links", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "yuremote-fs-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = join(root, "list");
  mkdirSync(join(dir, "alpha"), { recursive: true });
  mkdirSync(join(dir, ".hidden"));
  writeFileSync(join(dir, "file.txt"), "x");
  try {
    symlinkSync(join(dir, "alpha"), join(dir, "to-dir"), "dir");
    symlinkSync(join(dir, "file.txt"), join(dir, "to-file"), "file");
    symlinkSync(join(dir, "missing"), join(dir, "dangling"), "dir");
  } catch (error) {
    return t.skip(`cannot create symlinks here: ${error.code}`);
  }

  const list = fsRoute(join(root, "state"));
  const out = await list(dir);
  assert.equal(out.status, 200);
  const { listing } = out.body;
  assert.deepEqual(listing.entries.map((e) => e.name), [".hidden", "alpha", "to-dir"]);
  assert.equal(listing.entries.find((e) => e.name === ".hidden").hidden, true);
  assert.equal(listing.entries.find((e) => e.name === "alpha").path, join(listing.path, "alpha"));
  assert.equal(listing.truncated, false, "skipping links to files is not truncation");
});

test("the picker caps a huge directory at 400 entries and says so", async (t) => {
  const root = mkdtempSync(join(tmpdir(), "yuremote-fs-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const dir = join(root, "many");
  for (let i = 0; i < 405; i++) mkdirSync(join(dir, `d${i}`), { recursive: true });

  const out = await fsRoute(join(root, "state"))(dir);
  assert.equal(out.status, 200);
  assert.equal(out.body.listing.entries.length, 400);
  assert.equal(out.body.listing.truncated, true);
});
