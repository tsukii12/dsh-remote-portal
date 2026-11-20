#!/usr/bin/env sh
#
# yuremote — install into one or more dsh profiles (Linux / macOS).
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

NAME="yuremote"
PLUGIN_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
DSH_HOME=${DSH_HOME:-"$HOME/.dsh"}
PROFILES="desktop web"
EXPLICIT=0
UNINSTALL=0
INSTALLED=0

while [ $# -gt 0 ]; do
  case "$1" in
    -p|--profile) PROFILES=$2; EXPLICIT=1; shift 2 ;;
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
    if [ "$EXPLICIT" = "0" ]; then
      # The default covers both apps; a server with only dsh web has no desktop profile.
      echo "[$profile] no profile at $dir — skipped"
      continue
    fi
    echo "[$profile] profile does not exist; create it first: dsh --profile $profile --dump-config >/dev/null"
    exit 1
  fi

  mode=install
  [ "$UNINSTALL" = "0" ] || mode=uninstall
  node "$PLUGIN_DIR/tools/install-profile.mjs" "$mode" "$PLUGIN_DIR" "$dir" "$DSH_HOME"
  INSTALLED=$((INSTALLED + 1))
done

[ "$UNINSTALL" = "1" ] && exit 0
if [ "$INSTALLED" = "0" ]; then
  echo "$NAME: no dsh profile found under $DSH_HOME/profiles — run dsh (or dsh --profile web) once, then install again" >&2
  exit 1
fi
cat <<'DONE'

Installed. Restart the profile (quit and reopen the desktop app, or Ctrl+C then
`dsh web`), then open 远程访问 / Remote access in the sidebar and set an access password — the portal
refuses to listen on the network until one exists.
DONE
