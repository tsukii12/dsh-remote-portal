import test from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, lstatSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const skip = process.platform === "win32" ? "install.sh is for Linux / macOS" : false;
const deploy = readFileSync(join(ROOT, "tools", "deploy-relay.sh"), "utf8");

function shellFunction(name) {
  const body = new RegExp(`^${name}\\(\\) \\{[\\s\\S]*?^\\}`, "m").exec(deploy)?.[0];
  assert.ok(body, `missing installer function ${name}`);
  return body;
}

function home(profiles) {
  const dir = mkdtempSync(join(tmpdir(), "yuremote-install-"));
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
  assert.ok(bundles(dshHome, "web").includes("yuremote"));
  assert.ok(lstatSync(join(dshHome, "profiles", "web", "node_modules", "yuremote")).isSymbolicLink());
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

test("install.sh migrates the legacy profile and preserves state on repeated runs", { skip }, (t) => {
  const dshHome = home(["web"]);
  t.after(() => rmSync(dshHome, { recursive: true, force: true }));
  const legacy = "dsh-remote-portal";
  const profile = join(dshHome, "profiles", "web");
  const pkg = join(profile, "package.json");
  const oldState = join(dshHome, legacy);
  const oldLink = join(profile, "node_modules", legacy);
  mkdirSync(oldState);
  mkdirSync(dirname(oldLink));
  symlinkSync(ROOT, oldLink);
  const previous = JSON.stringify({
    dependencies: { [legacy]: `link:${ROOT}`, other: "1" },
    dsh: { profile: { bundles: ["other", legacy] } },
  });
  writeFileSync(pkg, "\uFEFF" + previous);
  const state = JSON.stringify({ password: "fixture-hash", devices: { phone: {} }, tunnel: { token: "fixture-token" } });
  writeFileSync(join(oldState, "state.json"), state, { mode: 0o600 });
  const patch = join(profile, "cordis.patch.yml");
  writeFileSync(patch, `- id: "${legacy}" # keep these overrides\n  config:\n    port: 3089\n`);

  const first = run(dshHome, "-p", "web");
  assert.equal(first.status, 0, first.stdout + first.stderr);
  assert.deepEqual(bundles(dshHome, "web"), ["other", "yuremote"]);
  assert.deepEqual(JSON.parse(readFileSync(pkg, "utf8")).dependencies, { other: "1", yuremote: `link:${ROOT}` });
  assert.equal(readFileSync(pkg + ".bak-yuremote", "utf8"), "\uFEFF" + previous);
  assert.equal(readFileSync(patch, "utf8"), '- id: "yuremote" # keep these overrides\n  config:\n    port: 3089\n');
  assert.equal(existsSync(oldLink), false);
  assert.equal(readFileSync(join(oldState, "state.json"), "utf8"), state);
  const newState = join(dshHome, "yuremote", "state.json");
  assert.equal(readFileSync(newState, "utf8"), state);
  assert.equal(lstatSync(newState).mode & 0o777, 0o600);

  writeFileSync(newState, "updated");
  const second = run(dshHome, "-p", "web");
  assert.equal(second.status, 0, second.stdout + second.stderr);
  assert.equal(readFileSync(newState, "utf8"), "updated");
  assert.equal(readFileSync(pkg + ".bak-yuremote", "utf8"), "\uFEFF" + previous);
});

test("legacy drp revokes a token from the active migrated relay, and works after rollback", { skip }, (t) => {
  const sandbox = home([]);
  t.after(() => rmSync(sandbox, { recursive: true, force: true }));
  const legacy = join(sandbox, "drp");
  const legacyUnit = join(sandbox, "dsh-relay.service");
  const unit = join(sandbox, "yuremote-relay.service");
  const tokenFile = join(sandbox, "token");
  const legacyToken = join(sandbox, "legacy-token");
  const tokens = "first-fixture-token\nsecond-fixture-token\n";
  const log = join(sandbox, "systemctl.log");
  writeFileSync(legacy, "#!/bin/sh\necho legacy-manager\n", { mode: 0o755 });
  writeFileSync(join(sandbox, "systemctl"), `#!/bin/sh\nprintf '%s\\n' "$*" >> "${log}"\n`, { mode: 0o755 });
  writeFileSync(tokenFile, tokens);
  writeFileSync(legacyToken, tokens);
  writeFileSync(unit, `ExecStart=relay.mjs --token-file ${tokenFile}\n`);
  symlinkSync(unit, legacyUnit);
  const setup = [
    'set -euo pipefail', 'BIN=$1/yuremote LEGACY_BIN=$1/drp LEGACY_UNIT=$1/dsh-relay.service UNIT=$1/yuremote-relay.service',
    'ok() { :; }', 't() { printf "%s" "$1"; }',
    shellFunction("install_yuremote").replaceAll("/var/lib/yuremote-relay", sandbox),
    shellFunction("install_legacy_command"), 'install_yuremote; install_legacy_command',
  ].join("\n");
  const prepared = spawnSync("bash", ["-s", "--", sandbox], { input: setup, encoding: "utf8" });
  assert.equal(prepared.status, 0, prepared.stderr);
  const env = { ...process.env, PATH: `${sandbox}:${process.env.PATH}` };
  const revoked = spawnSync(legacy, ["token", "remove", "2"], { env, encoding: "utf8" });
  assert.equal(revoked.status, 0, revoked.stderr);
  assert.equal(readFileSync(tokenFile, "utf8"), "first-fixture-token\n");
  assert.equal(readFileSync(legacyToken, "utf8"), tokens);
  assert.equal(readFileSync(log, "utf8"), "restart yuremote-relay\n");
  rmSync(legacyUnit);
  writeFileSync(legacyUnit, "[Service]\n");
  const rolledBack = spawnSync(legacy, ["status"], { env, encoding: "utf8" });
  assert.equal(rolledBack.status, 0, rolledBack.stderr);
  assert.equal(rolledBack.stdout, "legacy-manager\n");
});

for (const healthy of ["yes", "no"]) {
  test(`deploy-relay.sh migrates the unit and ${healthy === "yes" ? "keeps it when healthy" : "restores it on failure"}`, { skip }, (t) => {
    const sandbox = home([]);
    t.after(() => rmSync(sandbox, { recursive: true, force: true }));
    const oldDir = join(sandbox, "dsh-relay");
    const oldState = join(sandbox, "state-old");
    const newDir = join(sandbox, "yuremote-relay");
    const newState = join(sandbox, "state");
    const oldUnit = join(sandbox, "dsh-relay.service");
    const newUnit = join(sandbox, "yuremote-relay.service");
    const backup = oldUnit + ".bak-yuremote";
    const token = "first-fixture-token\nsecond-fixture-token\n";
    const listeners = "--http-port 127.0.0.1:8080 --tls-port 0.0.0.0:8443 --agent-port 9443 --public-url https://relay.test:8443";
    const legacy = `[Service]\nUser=dsh-relay\nEnvironment=DSH_RELAY_CACHE_MB=64\nExecStart=/usr/bin/env node ${oldDir}/relay.mjs --token-file ${oldState}/token ${listeners} --tls-cert ${oldState}/cert.pem --tls-key ${oldState}/key.pem\nReadWritePaths=${oldState}\n`;
    mkdirSync(oldDir);
    mkdirSync(oldState);
    writeFileSync(join(oldDir, "relay.mjs"), "legacy code");
    writeFileSync(join(oldState, "token"), token, { mode: 0o600 });
    writeFileSync(oldUnit, legacy);
    const migrate = shellFunction("migrate_relay");
    const setup = `
set -euo pipefail
LEGACY_RELAY_DIR=$1 LEGACY_STATE_DIR=$2 RELAY_DIR=$3 STATE_DIR=$4 LEGACY_UNIT=$5 UNIT=$6
PORTAL_DIR=$7 HEALTHY=$8 LEGACY_BACKUP=$5.bak-yuremote
CONF_FILE=$STATE_DIR/deploy.conf
LEGACY_SERVICE=dsh-relay SERVICE=yuremote-relay
install_brand() { :; }
install_yuremote() { :; }
install_legacy_command() { :; }
systemctl() { [ "$1" = show ] || printf '%s\\n' "$*" >&2; }
curl() { [ "$HEALTHY" = yes ]; }
sleep() { :; }
ok() { printf '%s\\n' "$*"; }
info() { printf '%s\\n' "$*"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
`;
    const result = spawnSync("bash", ["-s", "--", oldDir, oldState, newDir, newState, oldUnit, newUnit, join(ROOT, "tools"), healthy], {
      input: setup + migrate + "\nmigrate_relay\n",
      encoding: "utf8",
    });
    assert.equal(readFileSync(join(oldDir, "relay.mjs"), "utf8"), "legacy code");
    assert.equal(readFileSync(join(oldState, "token"), "utf8"), token);
    assert.equal(readFileSync(join(newState, "token"), "utf8"), token);
    if (healthy === "yes") {
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(readFileSync(backup, "utf8"), legacy);
      assert.ok(lstatSync(oldUnit).isSymbolicLink());
      const unit = readFileSync(newUnit, "utf8");
      assert.ok(unit.includes(`${newDir}/relay.mjs --token-file ${newState}/token ${listeners}`));
      assert.ok(unit.includes(`--tls-cert ${oldState}/cert.pem --tls-key ${oldState}/key.pem`));
      assert.ok(unit.includes("Environment=DSH_RELAY_CACHE_MB=64"));
      assert.match(result.stdout, /Rollback: sudo sh -c/);
    } else {
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.equal(readFileSync(oldUnit, "utf8"), legacy);
      assert.equal(existsSync(backup), false);
      assert.equal(existsSync(newUnit), false);
      assert.match(result.stderr, /start dsh-relay\.service/);
    }
  });
}
