#!/usr/bin/env sh
#
# dsh-remote-portal — install into one or more dsh profiles (Linux / macOS).
#
# The plugin has no dependencies, so installing it is three steps: point the
# profile's package.json at this directory, add the bundle row, and make the
# package resolvable under the profile's node_modules. That last step is a
# symlink, which is what the package manager would create anyway — this script
# does it directly so it works on a machine without a package manager.
#
# Usage:
#   ./install.sh                      # desktop + web
#   ./install.sh -p web               # one profile
#   ./install.sh -p web --uninstall
#   DSH_HOME=/opt/dsh/home ./install.sh -p web
#
set -eu

NAME="dsh-remote-portal"
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DSH_HOME=${DSH_HOME:-"$HOME/.dsh"}
PROFILES="desktop web"
UNINSTALL=0

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile) PROFILES=$2; shift 2 ;;
    -u|--uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

command -v node >/dev/null 2>&1 || { echo "$NAME: node is required" >&2; exit 1; }
[ -f "$PLUGIN_DIR/package.json" ] || { echo "$NAME: $PLUGIN_DIR is not the plugin directory" >&2; exit 1; }

for profile in $PROFILES; do
  dir="$DSH_HOME/profiles/$profile"
  pkg="$dir/package.json"

  if [ ! -f "$pkg" ]; then
    if [ "$UNINSTALL" = "1" ]; then
      echo "[$profile] no profile at $dir — skipped"
      continue
    fi
    echo "[$profile] profile does not exist; create it first: dsh --profile $profile --dump-config >/dev/null"
    exit 1
  fi

  if [ "$UNINSTALL" = "1" ]; then
    node - "$pkg" "$NAME" "$dir" <<'NODE'
const fs = require("fs");
const [pkgPath, name, dir] = process.argv.slice(2);
const j = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
if (j.dependencies) delete j.dependencies[name];
if (j.dsh?.profile?.bundles) j.dsh.profile.bundles = j.dsh.profile.bundles.filter((b) => b !== name);
fs.writeFileSync(pkgPath, JSON.stringify(j, null, 2));
try { fs.unlinkSync(`${dir}/node_modules/${name}`); } catch { /* not linked */ }
console.log(`[${dir.split("/").pop()}] removed (restart dsh to unload)`);
NODE
    continue
  fi

  cp "$pkg" "$pkg.bak-portal"
  node - "$pkg" "$NAME" "$PLUGIN_DIR" "$dir" <<'NODE'
const fs = require("fs");
const [pkgPath, name, pluginDir, profileDir] = process.argv.slice(2);
const j = JSON.parse(fs.readFileSync(pkgPath, "utf8"));
j.dependencies = j.dependencies || {};
j.dependencies[name] = `link:${pluginDir}`;
j.dsh = j.dsh || {};
j.dsh.profile = j.dsh.profile || {};
const bundles = Array.isArray(j.dsh.profile.bundles) ? j.dsh.profile.bundles : [];
if (!bundles.includes(name)) bundles.push(name);
j.dsh.profile.bundles = bundles;
fs.writeFileSync(pkgPath, JSON.stringify(j, null, 2));

const nm = `${profileDir}/node_modules`;
fs.mkdirSync(nm, { recursive: true });
const link = `${nm}/${name}`;
try { fs.unlinkSync(link); } catch { /* nothing there */ }
fs.symlinkSync(pluginDir, link, "dir");
console.log(`[${profileDir.split("/").pop()}] linked ${name} → ${pluginDir}`);
console.log(`[${profileDir.split("/").pop()}] bundles: ${bundles.join(", ")}`);
NODE
done

[ "$UNINSTALL" = "1" ] && exit 0
cat <<'DONE'

Installed. Restart the profile (quit and reopen the desktop app, or Ctrl+C then
`dsh web`), then open Settings → 远程访问 and set an access password — the portal
refuses to listen on the network until one exists.
DONE
