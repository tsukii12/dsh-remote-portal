// The panel's password route (`POST /dsh-remote-portal/password`).
import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { apply } from "../index.js";
import { MIN_PASSWORD_LENGTH } from "../lib/auth.mjs";

function passwordRoute(stateDir) {
  const routes = [];
  const warnings = [];
  const ctx = {
    logger: { info() {}, warn(msg) { warnings.push(String(msg)); }, error() {}, debug() {} },
    webServer: {
      host: "127.0.0.1", protocol: "http:", port: 0,
      register(route) { routes.push(route); return () => {}; },
    },
    get() { return undefined; },
    effect(fn, label) { if (/control routes$/.test(label)) fn(); },
  };
  apply(ctx, { stateDir, mobile: false });
  const route = routes.find((r) => r.path === "/dsh-remote-portal/password");
  assert.ok(route, "password route not registered");
  const post = (password) => new Promise((resolve) => {
    const req = Object.assign(Readable.from([Buffer.from(JSON.stringify({ password }))]), {
      method: "POST",
      url: "/dsh-remote-portal/password",
      headers: { host: "127.0.0.1:3080", "content-type": "application/json" },
    });
    const res = {
      headersSent: false,
      status: 0,
      writeHead(status) { this.status = status; this.headersSent = true; },
      end(body) { resolve({ status: this.status, body: JSON.parse(body) }); },
    };
    route.handler(req, res);
  });
  return { post, warnings };
}

test("a password shorter than the gateway's minimum is a clear 400, not a 500", async (t) => {
  // The route used to accept 6 characters and hand them to the gateway, which
  // requires 8: a 6- or 7-character password came back as an internal error.
  const root = mkdtempSync(join(tmpdir(), "drp-pw-"));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const { post, warnings } = passwordRoute(join(root, "state"));

  const short = await post("x".repeat(MIN_PASSWORD_LENGTH - 1));
  assert.equal(short.status, 400);
  assert.equal(short.body.code, "weak-password");
  assert.match(short.body.error, new RegExp(`at least ${MIN_PASSWORD_LENGTH} characters`));
  assert.deepEqual(warnings.filter((w) => /failed/.test(w)), [], "a short password must not be logged as a server failure");

  const ok = await post("x".repeat(MIN_PASSWORD_LENGTH));
  assert.equal(ok.status, 200);
  assert.equal(ok.body.status.passwordSet, true);
});
