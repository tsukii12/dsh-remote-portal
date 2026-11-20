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
  const end = name === "install_yuremote" ? "^YUREMOTE_EOF\\n[\\s\\S]*?^\\}" : "^\\}";
  const body = new RegExp(`^${name}\\(\\) \\{[\\s\\S]*?${end}`, "m").exec(deploy)?.[0];
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

test("migrated manager applies HTTP_PORT without changing TLS or the other listeners", { skip }, (t) => {
  const sandbox = home([]);
  t.after(() => rmSync(sandbox, { recursive: true, force: true }));
  const unit = join(sandbox, "yuremote-relay.service");
  const legacyUnit = join(sandbox, "dsh-relay.service");
  const installer = join(sandbox, "deploy-relay.sh");
  const manager = join(sandbox, "yuremote");
  const log = join(sandbox, "systemctl.log");
  const line = "ExecStart=/usr/bin/env node relay.mjs --http-port 127.0.0.1:8080 --agent-port 9443 --tls-port 0.0.0.0:8443 --tls-cert /legacy/cert --tls-key /legacy/key\n";
  writeFileSync(unit, line);
  symlinkSync(unit, legacyUnit);
  writeFileSync(`${legacyUnit}.bak-yuremote`, "[Service]\n");
  writeFileSync(join(sandbox, "deploy.conf"), `HTTP_PORT=8080\nSCRIPT=${installer}\n`);
  const dispatch = deploy.slice(deploy.indexOf("if [ \"$HAVE_SYSTEMD\" = 1 ] && [ -f \"$LEGACY_UNIT\" ]"), deploy.indexOf("# ── 2. detection"));
  assert.match(dispatch, /is_migrated_relay/);
  writeFileSync(installer, [
    "set -euo pipefail",
    `HAVE_SYSTEMD=1 UNIT=${unit} LEGACY_UNIT=${legacyUnit} LEGACY_BACKUP=${legacyUnit}.bak-yuremote SERVICE=yuremote-relay`,
    `. "${sandbox}/deploy.conf"`,
    'APPLY_CONFIG=0; CONFIG_HTTP_ONLY=0; [ "$2" != --apply-http-port ] || { APPLY_CONFIG=1; CONFIG_HTTP_ONLY=1; }',
    't() { printf "%s" "$1"; }', 'die() { echo "$*" >&2; exit 1; }',
    `systemctl() { printf '%s\\n' "$*" >> "${log}"; }`,
    shellFunction("has_migrated_alias"), shellFunction("apply_migrated_http_port"), dispatch, "exit 99",
  ].join("\n"));
  const prepared = spawnSync("bash", ["-s"], {
    input: `BIN=${manager}\nok() { :; }\nt() { :; }\n${shellFunction("install_yuremote").replaceAll("/var/lib/yuremote-relay", sandbox)}\ninstall_yuremote\n`,
    encoding: "utf8",
  });
  assert.equal(prepared.status, 0, prepared.stderr);
  const result = spawnSync(manager, ["config", "HTTP_PORT=8081"], { encoding: "utf8" });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(readFileSync(unit, "utf8"), line.replace("8080", "8081"));
  assert.equal(readFileSync(log, "utf8"), "daemon-reload\nrestart yuremote-relay.service\n");
});

test("a migrated relay can be reinstalled after uninstall without reverting its unit", { skip }, (t) => {
  const sandbox = home([]);
  t.after(() => rmSync(sandbox, { recursive: true, force: true }));
  const state = join(sandbox, "state");
  const relay = join(sandbox, "relay");
  const unit = join(sandbox, "yuremote-relay.service");
  const oldUnit = join(sandbox, "dsh-relay.service");
  const backup = `${oldUnit}.bak-yuremote`;
  const bin = join(sandbox, "yuremote");
  mkdirSync(state);
  mkdirSync(relay);
  const line = `ExecStart=/usr/bin/env node ${relay}/relay.mjs --token-file ${state}/token --http-port 127.0.0.1:8081\n`;
  writeFileSync(unit, line);
  writeFileSync(backup, "legacy unit\n");
  symlinkSync(unit, oldUnit);
  writeFileSync(join(state, "token"), "fixture-token\n");
  writeFileSync(join(state, "relay.mjs"), "export {};\n");
  const setup = `
set -euo pipefail
UNINSTALL=$1 HAVE_SYSTEMD=1 APPLY_CONFIG=0 CONFIG_HTTP_ONLY=0
UNIT=${unit} LEGACY_UNIT=${oldUnit} LEGACY_BACKUP=${backup}
RELAY_DIR=${relay} STATE_DIR=${state} PORTAL_DIR=${state} BIN=${bin} SERVICE=yuremote-relay
as_root() { :; }
t() { printf '%s' "$1"; }
say() { :; }
ok() { :; }
warn() { :; }
install_brand() { :; }
prepare_installer() { :; }
save_migrated_installer() { :; }
install_yuremote() { touch "$BIN"; }
install_legacy_command() { :; }
systemctl() { printf '%s\\n' "$*"; }
${shellFunction("has_migrated_alias")}
`;
  const uninstall = deploy.slice(deploy.indexOf('if [ "$UNINSTALL" = 1 ]; then'), deploy.indexOf("# ── 1. environment"))
    .replaceAll("/opt/1panel", `${sandbox}/1panel`).replaceAll("/etc/nginx", `${sandbox}/nginx`).replaceAll("/etc/caddy", `${sandbox}/caddy`)
    .replace("command -v docker", "false");
  const removed = spawnSync("bash", ["-s", "--", "1"], { input: setup + uninstall, encoding: "utf8" });
  assert.equal(removed.status, 0, removed.stderr);
  assert.equal(existsSync(unit), false);
  assert.equal(existsSync(relay), false);
  const dispatch = deploy.slice(deploy.indexOf('if [ "$HAVE_SYSTEMD" = 1 ] && [ -f "$LEGACY_UNIT" ]'), deploy.indexOf("# ── 2. detection"));
  const restored = spawnSync("bash", ["-s", "--", "0"], { input: setup + dispatch + "\nexit 99", encoding: "utf8" });
  assert.equal(restored.status, 0, restored.stderr);
  assert.equal(readFileSync(unit, "utf8"), line);
  assert.equal(readFileSync(backup, "utf8"), "legacy unit\n");
  assert.equal(readFileSync(join(state, "token"), "utf8"), "fixture-token\n");
  assert.equal(readFileSync(join(relay, "relay.mjs"), "utf8"), "export {};\n");
  assert.ok(lstatSync(oldUnit).isSymbolicLink());
  assert.ok(existsSync(bin));
  assert.equal(restored.stdout, "daemon-reload\nenable --now yuremote-relay.service\n");
});

for (const [healthy, language] of [["yes", "en"], ["no", "en"], ["yes", "zh"], ["no", "zh"]]) {
  test(`deploy-relay.sh migrates the unit and ${healthy === "yes" ? "keeps it when healthy" : "restores it on failure"} (${language})`, { skip }, (t) => {
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
    writeFileSync(join(oldState, "deploy-relay.sh"), "#!/bin/bash\nexit 99\n");
    writeFileSync(join(oldState, "deploy.conf"), `HTTP_PORT=8080\nSCRIPT=${oldState}/deploy-relay.sh\n`);
    writeFileSync(oldUnit, legacy);
    const migrate = shellFunction("migrate_relay");
    const setup = `
set -euo pipefail
LEGACY_RELAY_DIR=$1 LEGACY_STATE_DIR=$2 RELAY_DIR=$3 STATE_DIR=$4 LEGACY_UNIT=$5 UNIT=$6
PORTAL_DIR=$7 HEALTHY=$8 LEGACY_BACKUP=$5.bak-yuremote
LANG_MODE=$9
SELF_VERSION=fixture-version
INSTALLER_REVISION=1
RAW_BASES="https://stale.invalid https://fixture.invalid"
TMP_RELAY_DIR=$3.download
mkdir "$TMP_RELAY_DIR"
CONF_FILE=$STATE_DIR/deploy.conf
LEGACY_SERVICE=dsh-relay SERVICE=yuremote-relay
install_brand() { :; }
install_yuremote() { :; }
install_legacy_command() { :; }
systemctl() { [ "$1" = show ] || printf '%s\\n' "$*" >&2; }
curl() {
  case "$*" in
    *https://stale.invalid/tools/deploy-relay.sh*) printf '#!/bin/bash\nSELF_VERSION="fixture-version"\nSERVICE=yuremote-relay\nexit 99\n' > "\${!#}" ;;
    *https://fixture.invalid/tools/deploy-relay.sh*) printf '#!/bin/bash\nSELF_VERSION="fixture-version"\nINSTALLER_REVISION=1\nSERVICE=yuremote-relay\nexit 0\n' > "\${!#}" ;;
    *) [ "$HEALTHY" = yes ] ;;
  esac
}
sleep() { :; }
ok() { printf '%s\\n' "$*"; }
info() { printf '%s\\n' "$*"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
`;
    const translate = /^t\(\) \{.*\}$/m.exec(deploy)?.[0];
    assert.ok(translate);
    const result = spawnSync("bash", ["-s", "--", oldDir, oldState, newDir, newState, oldUnit, newUnit, join(ROOT, "tools"), healthy, language], {
      input: [setup, translate, ...["prepare_installer", "save_migrated_installer", "write_migrated_unit"].map(shellFunction), migrate, "migrate_relay\n"].join("\n"),
      encoding: "utf8",
    });
    assert.equal(readFileSync(join(oldDir, "relay.mjs"), "utf8"), "legacy code");
    assert.equal(readFileSync(join(oldState, "token"), "utf8"), token);
    assert.equal(readFileSync(join(newState, "token"), "utf8"), token);
    const savedInstaller = join(newState, "deploy-relay.sh");
    assert.equal(readFileSync(savedInstaller, "utf8"), '#!/bin/bash\nSELF_VERSION="fixture-version"\nINSTALLER_REVISION=1\nSERVICE=yuremote-relay\nexit 0\n');
    assert.equal(readFileSync(join(newState, "deploy.conf"), "utf8"), `HTTP_PORT=8080\nSCRIPT=${savedInstaller}\n`);
    assert.equal(spawnSync(savedInstaller).status, 0);
    if (healthy === "yes") {
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.equal(readFileSync(backup, "utf8"), legacy);
      assert.ok(lstatSync(oldUnit).isSymbolicLink());
      const unit = readFileSync(newUnit, "utf8");
      assert.ok(unit.includes(`${newDir}/relay.mjs --token-file ${newState}/token ${listeners}`));
      assert.ok(unit.includes(`--tls-cert ${oldState}/cert.pem --tls-key ${oldState}/key.pem`));
      assert.ok(unit.includes("Environment=DSH_RELAY_CACHE_MB=64"));
      if (language === "zh") {
        assert.match(result.stdout, /已迁移至 yuremote-relay/);
        assert.match(result.stdout, /回滚命令： sudo sh -c/);
      } else {
        assert.match(result.stdout, /Rollback: sudo sh -c/);
      }
    } else {
      assert.equal(result.status, 1, result.stdout + result.stderr);
      assert.equal(readFileSync(oldUnit, "utf8"), legacy);
      assert.equal(existsSync(backup), false);
      assert.equal(existsSync(newUnit), false);
      assert.match(result.stderr, /start dsh-relay\.service/);
      assert.match(result.stderr, language === "zh" ? /新中转未通过健康检查，已恢复旧服务/ : /New relay did not become healthy; restored the legacy unit/);
    }
  });
}
