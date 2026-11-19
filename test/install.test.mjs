import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, lstatSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const skip = process.platform === "win32" ? "install.sh is for Linux / macOS" : false;

function home(profiles) {
  const dir = mkdtempSync(join(tmpdir(), "drp-install-"));
  for (const name of profiles) {
    mkdirSync(join(dir, "profiles", name), { recursive: true });
    writeFileSync(join(dir, "profiles", name, "package.json"),
      JSON.stringify({ dsh: { profile: { bundles: ["@deepseek-ai/dsh-base"] } } }));
  }
  return dir;
}

function run(dshHome, ...args) {
  return spawnSync("sh", [join(ROOT, "install.sh"), ...args], {
    env: { ...process.env, DSH_HOME: dshHome },
    encoding: "utf8",
  });
}

const bundles = (dshHome, name) =>
  JSON.parse(readFileSync(join(dshHome, "profiles", name, "package.json"), "utf8")).dsh.profile.bundles;

test("install.sh with no -p installs into the profiles that exist (a server with only dsh web)", { skip }, (t) => {
  const dshHome = home(["web"]);
  t.after(() => rmSync(dshHome, { recursive: true, force: true }));
  const r = run(dshHome);
  assert.equal(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /\[desktop\] no profile .* skipped/);
  assert.ok(bundles(dshHome, "web").includes("dsh-remote-portal"));
  assert.ok(lstatSync(join(dshHome, "profiles", "web", "node_modules", "dsh-remote-portal")).isSymbolicLink());
  assert.match(r.stdout, /Remote access in the sidebar/);
});

test("install.sh still refuses a profile named with -p that does not exist, or no profile at all", { skip }, (t) => {
  const dshHome = home(["web"]);
  const empty = home([]);
  t.after(() => { rmSync(dshHome, { recursive: true, force: true }); rmSync(empty, { recursive: true, force: true }); });
  const named = run(dshHome, "-p", "desktop");
  assert.equal(named.status, 1);
  assert.match(named.stdout, /\[desktop\] profile does not exist/);
  const none = run(empty);
  assert.equal(none.status, 1, "nothing installed must not report success");
  assert.match(none.stderr, /no dsh profile found/);
  assert.doesNotMatch(none.stdout, /Installed\./);
});
