import { chmodSync, copyFileSync, cpSync, existsSync, lstatSync, mkdirSync, readFileSync, realpathSync, renameSync, symlinkSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

const NAME = "yuremote";
const LEGACY = "dsh-remote-portal";
const [mode, pluginDir, profile, home] = process.argv.slice(2);
const manifest = join(profile, "package.json");
const original = readFileSync(manifest, "utf8");
const pkg = JSON.parse(original.replace(/^\uFEFF/, ""));
const modules = join(profile, "node_modules");
const link = join(modules, NAME);
const oldLink = join(modules, LEGACY);

function stat(path) {
  try { return lstatSync(path); } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

function rewrite(path, previous, next) {
  if (previous === next) return;
  const backup = path + ".bak-yuremote";
  if (!stat(backup)) copyFileSync(path, backup);
  const temp = path + ".yuremote-" + process.pid;
  writeFileSync(temp, next, { mode: stat(path).mode & 0o777, flag: "wx" });
  try { renameSync(temp, path); } catch (error) {
    unlinkSync(temp);
    throw error;
  }
}

if (mode === "uninstall") {
  if (pkg.dependencies) delete pkg.dependencies[NAME];
  if (Array.isArray(pkg.dsh?.profile?.bundles)) pkg.dsh.profile.bundles = pkg.dsh.profile.bundles.filter(item => item !== NAME);
  rewrite(manifest, original, JSON.stringify(pkg, null, 2));
  if (stat(link)?.isSymbolicLink()) unlinkSync(link);
  console.log(`[${basename(profile)}] removed (restart dsh to unload)`);
} else {
  const ownManifest = JSON.parse(readFileSync(join(pluginDir, "package.json"), "utf8").replace(/^\uFEFF/, ""));
  if (ownManifest.name !== NAME) throw Error("Plugin manifest does not declare " + NAME);
  pkg.dependencies ||= {};
  pkg.dsh ||= {};
  pkg.dsh.profile ||= {};
  const bundles = Array.isArray(pkg.dsh.profile.bundles) ? pkg.dsh.profile.bundles : [];
  const migrating = bundles.includes(LEGACY) || Object.hasOwn(pkg.dependencies, LEGACY) || !!stat(oldLink);
  const currentLink = stat(link);
  if (currentLink && !currentLink.isSymbolicLink()) throw Error("Refusing to replace a non-link: " + link);
  const oldPackage = stat(oldLink);
  const oldBackup = join(profile, "node_modules." + NAME + "-legacy");
  if (oldPackage && !oldPackage.isSymbolicLink() && stat(oldBackup)) throw Error("Legacy plugin backup already exists: " + oldBackup);
  if (migrating) {
    const legacyState = join(home, LEGACY);
    const state = join(home, NAME);
    if (existsSync(legacyState) && !stat(state)) {
      const temp = state + ".migrate-" + process.pid;
      cpSync(legacyState, temp, { recursive: true, preserveTimestamps: true, errorOnExist: true, force: false });
      chmodSync(temp, stat(legacyState).mode & 0o777);
      renameSync(temp, state);
    }
    const patch = join(profile, "cordis.patch.yml");
    if (existsSync(patch)) {
      const previous = readFileSync(patch, "utf8");
      const updated = previous.replace(/^(\s*(?:-\s*)?(?:id|name|disable):\s*)(["']?)dsh-remote-portal\2(?=[\t ]*(?:#|\r?$))/gm, `$1$2${NAME}$2`);
      rewrite(patch, previous, updated);
    }
  }
  mkdirSync(dirname(link), { recursive: true });
  let correctLink = false;
  if (currentLink) {
    try { correctLink = realpathSync(link) === realpathSync(pluginDir); } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    if (!correctLink) unlinkSync(link);
  }
  if (!correctLink) symlinkSync(pluginDir, link, process.platform === "win32" ? "junction" : "dir");
  delete pkg.dependencies[LEGACY];
  pkg.dependencies[NAME] = `link:${pluginDir.replaceAll("\\", "/")}`;
  if (!bundles.includes(LEGACY) && !bundles.includes(NAME)) bundles.push(NAME);
  const active = bundles.map(item => item === LEGACY ? NAME : item);
  pkg.dsh.profile.bundles = active.filter((item, position) => item !== NAME || active.indexOf(NAME) === position);
  rewrite(manifest, original, JSON.stringify(pkg, null, 2));
  if (oldPackage?.isSymbolicLink()) unlinkSync(oldLink);
  else if (oldPackage) renameSync(oldLink, oldBackup);
  console.log(`[${basename(profile)}] linked ${NAME} → ${pluginDir}`);
  console.log(`[${basename(profile)}] bundles: ${pkg.dsh.profile.bundles.join(", ")}`);
}
