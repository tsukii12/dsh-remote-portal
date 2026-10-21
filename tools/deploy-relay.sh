#!/usr/bin/env bash
#
# dsh-remote-portal — one-command relay setup for a public server.
#
# What it does, in order, and nothing else:
#   1. checks Node ≥ 20 and the OS user it will run as
#   2. writes the relay to /opt/dsh-relay and a token to /var/lib/dsh-relay
#   3. installs a systemd unit (or prints a no-root command with --no-systemd)
#   4. optionally adds a Caddy site for automatic HTTPS
#   5. prints the exact values to paste into the plugin panel + a health check
#
# It does not touch existing services: its own ports, its own unit, its own
# directories. Everything it creates is listed at the end with a one-line undo.
#
# Usage:
#   sudo ./deploy-relay.sh --domain dsh.example.com
#   sudo ./deploy-relay.sh --domain dsh.example.com --caddy
#   ./deploy-relay.sh --no-systemd --port 8080          # try it without root
#   ./deploy-relay.sh --uninstall
#
set -euo pipefail

# A copy that arrived without mode bits (Windows checkout, paste, some tars) fails
# as "command not found" when invoked as ./deploy-relay.sh. Fix it once and carry on.
if [ ! -x "$0" ] && [ -f "$0" ]; then chmod +x "$0" 2>/dev/null || true; fi

RELAY_DIR=/opt/dsh-relay
STATE_DIR=/var/lib/dsh-relay
UNIT=/etc/systemd/system/dsh-relay.service
SERVICE=dsh-relay

AGENT_PORT=9443
HTTP_PORT=8080
DOMAIN=""
PUBLIC_URL=""
PREFIX=/__t
WITH_CADDY=0
WITH_NGINX=0
TLS_CERT=""
TLS_KEY=""
# The agent port is plain TCP unless a certificate pair is supplied.
AGENT_SCHEME=tcp
WITH_SYSTEMD=1
UNINSTALL=0
TOKEN=""

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN=$2; shift 2 ;;
    --public-url) PUBLIC_URL=$2; shift 2 ;;
    --agent-port) AGENT_PORT=$2; shift 2 ;;
    --port) HTTP_PORT=$2; shift 2 ;;
    --prefix) PREFIX=$2; shift 2 ;;
    --tls-cert) TLS_CERT=$2; shift 2 ;;
    --tls-key) TLS_KEY=$2; shift 2 ;;
    --caddy) WITH_CADDY=1; shift ;;
    --nginx) WITH_NGINX=1; shift ;;
    --no-systemd) WITH_SYSTEMD=0; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

as_root() { [ "$(id -u)" = "0" ]; }

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  say "Removing the relay"
  if [ "$WITH_SYSTEMD" = 1 ] && as_root && [ -f "$UNIT" ]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload || true
    ok "unit removed"
  fi
  rm -rf "$RELAY_DIR"
  ok "$RELAY_DIR removed"
  warn "kept $STATE_DIR (tokens and logs). Remove it with: rm -rf $STATE_DIR"
  [ -n "$DOMAIN" ] && warn "if you added a Caddy site, remove /etc/caddy/sites/$DOMAIN.caddy and reload Caddy"
  exit 0
fi

# ── 1. prerequisites ────────────────────────────────────────────────────────
say "Checking the host"
command -v node >/dev/null 2>&1 || die "node is required (v20+). Install it first: https://nodejs.org"
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 20 ] || die "node $NODE_MAJOR is too old; the relay needs 20 or newer"
ok "node $(node -v) at $(command -v node)"

[ -f "$(dirname "$0")/relay.mjs" ] || die "relay.mjs not found next to this script — run it from the plugin's tools/ directory"
ok "relay.mjs found"

# Re-running the installer must never silently downgrade encryption. If a
# certificate pair is already installed and no flags were given, keep using it.
INSTALLED_CERT="$STATE_DIR/tls/agent-cert.pem"
INSTALLED_KEY="$STATE_DIR/tls/agent-key.pem"
if [ -z "$TLS_CERT" ] && [ -z "$TLS_KEY" ] && [ -r "$INSTALLED_CERT" ] && [ -r "$INSTALLED_KEY" ]; then
  TLS_CERT="$INSTALLED_CERT"
  TLS_KEY="$INSTALLED_KEY"
  ok "keeping the installed certificate ($INSTALLED_CERT)"
fi

if [ -n "$TLS_CERT" ] || [ -n "$TLS_KEY" ]; then
  [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] || die "give both --tls-cert and --tls-key"
  [ -r "$TLS_CERT" ] || die "cannot read $TLS_CERT"
  [ -r "$TLS_KEY" ] || die "cannot read $TLS_KEY"
  AGENT_SCHEME=tls
  ok "agent port will speak TLS ($TLS_CERT)"
fi

if [ "$WITH_SYSTEMD" = 1 ] && ! as_root; then
  die "systemd setup needs root. Re-run with sudo, or pass --no-systemd for a foreground run"
fi

# ── 2. install the relay + token ────────────────────────────────────────────
if [ "$WITH_SYSTEMD" != 1 ]; then
  # A foreground run is often a non-root trial: keep everything beside the script.
  RELAY_DIR="$PWD/.relay-run"
  STATE_DIR="$PWD/.relay-state"
fi
say "Installing the relay"
if [ "$WITH_SYSTEMD" = 1 ]; then
  useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin dsh-relay 2>/dev/null || true
  install -d -o dsh-relay -g dsh-relay -m 0750 "$STATE_DIR"
  install -d -o dsh-relay -g dsh-relay -m 0755 "$RELAY_DIR"
  install -o dsh-relay -g dsh-relay -m 0644 "$(dirname "$0")/relay.mjs" "$RELAY_DIR/relay.mjs"
else
  install -d -m 0755 "$RELAY_DIR" || die "cannot create $RELAY_DIR"
  install -m 0644 "$(dirname "$0")/relay.mjs" "$RELAY_DIR/relay.mjs"
fi
ok "$RELAY_DIR/relay.mjs"

TOKEN_FILE="$STATE_DIR/token"
if [ "$WITH_SYSTEMD" != 1 ]; then
  install -d -m 0700 "$STATE_DIR"
fi
if [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(head -n 1 "$TOKEN_FILE")
  ok "reusing the existing tunnel token"
else
  TOKEN=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64url"))')
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
  [ "$WITH_SYSTEMD" = 1 ] && chown dsh-relay:dsh-relay "$TOKEN_FILE"
  ok "new tunnel token in $TOKEN_FILE"
fi
chmod 600 "$TOKEN_FILE" 2>/dev/null || true

TUNNEL_ID=$(node -e 'const c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(process.argv[1]).digest("base64url").slice(0,12))' "$TOKEN")

# ── 3. public URL ───────────────────────────────────────────────────────────
if [ -z "$PUBLIC_URL" ]; then
  if [ -n "$DOMAIN" ]; then
    PUBLIC_URL="https://$DOMAIN"
  else
    IP=$(curl -fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
    [ -n "$IP" ] || IP=$(hostname -I 2>/dev/null | awk '{print $1}')
    PUBLIC_URL="http://${IP:-127.0.0.1}"
  fi
fi
# Host portion, used for the agent endpoint below. `PUBLIC_URL` is already
# "https://domain" or "http://<ip>" by now, so this is always concrete.
PUBLIC_HOST=$(printf '%s' "$PUBLIC_URL" | sed -E 's#^[a-z]+://##; s#/.*$##; s#:[0-9]+$##')
[ -n "$PUBLIC_HOST" ] || PUBLIC_HOST=127.0.0.1
ok "agent endpoint host: $PUBLIC_HOST"

# ── 4. service ──────────────────────────────────────────────────────────────
if [ "$WITH_SYSTEMD" = 1 ]; then
  say "Installing the systemd unit"
  # One line, no continuations: a stray backslash in a heredoc is a silent
  # unit-file corruption that only shows up when systemd tries to parse it.
  RELAY_ARGS="$RELAY_DIR/relay.mjs --token-file $TOKEN_FILE --agent-port $AGENT_PORT --http-port 127.0.0.1:$HTTP_PORT --prefix $PREFIX --public-url $PUBLIC_URL"
  if [ -n "$TLS_CERT" ]; then
    RELAY_ARGS="$RELAY_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"
  fi

  cat > "$UNIT" <<UNIT_EOF
[Unit]
Description=dsh-remote-portal relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dsh-relay
Group=dsh-relay
ExecStart=/usr/bin/env node $RELAY_ARGS
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6
ReadOnlyPaths=$RELAY_DIR
ReadWritePaths=$STATE_DIR

[Install]
WantedBy=multi-user.target
UNIT_EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  # `enable --now` is a no-op on an already-running unit, so a re-run with new
  # flags (ports, TLS certificates) would silently keep the OLD process. Restart.
  systemctl restart "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" || {
    journalctl -u "$SERVICE" -n 20 --no-pager || true
    die "the service did not start"
  }
  ok "dsh-relay.service is running"
else
  say "No systemd (--no-systemd): start it yourself with"
  cat <<RUN_EOF
  node $RELAY_DIR/relay.mjs --token-file $TOKEN_FILE --agent-port $AGENT_PORT \\
       --http-port 127.0.0.1:$HTTP_PORT --prefix $PREFIX --public-url $PUBLIC_URL
RUN_EOF
fi

# ── 5. Caddy ────────────────────────────────────────────────────────────────
if [ "$WITH_CADDY" = 1 ]; then
  say "Configuring Caddy"
  if [ -z "$DOMAIN" ]; then
    warn "no --domain given: skipping Caddy (certificates need a hostname)"
  elif ! command -v caddy >/dev/null 2>&1; then
    warn "caddy is not installed. Install it, then add this site manually:"
    cat <<CADDY_HINT
  $DOMAIN {
    encode zstd gzip
    reverse_proxy 127.0.0.1:$HTTP_PORT {
      header_up X-Forwarded-Proto {scheme}
      flush_interval -1
    }
  }
CADDY_HINT
  else
    SITE_DIR=/etc/caddy/sites
    mkdir -p "$SITE_DIR"
    if ! grep -qs "import $SITE_DIR" /etc/caddy/Caddyfile; then
      printf '\nimport %s/*.caddy\n' "$SITE_DIR" >> /etc/caddy/Caddyfile
      ok "added \`import $SITE_DIR/*.caddy\` to /etc/caddy/Caddyfile"
    fi
    cat > "$SITE_DIR/$DOMAIN.caddy" <<CADDY_EOF
$DOMAIN {
	encode zstd gzip
	# No buffering: dsh streams responses, and a buffered proxy makes them stall.
	reverse_proxy 127.0.0.1:$HTTP_PORT {
		header_up X-Forwarded-Proto {scheme}
		flush_interval -1
	}
}
CADDY_EOF
    if caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
      systemctl reload caddy 2>/dev/null || caddy reload --config /etc/caddy/Caddyfile
      ok "Caddy site $SITE_DIR/$DOMAIN.caddy installed and reloaded"
    else
      rm -f "$SITE_DIR/$DOMAIN.caddy"
      die "Caddy rejected the configuration; nothing was changed. Run: caddy validate --config /etc/caddy/Caddyfile"
    fi
  fi
fi

# ── 5b. nginx / openresty ───────────────────────────────────────────────────
if [ "$WITH_NGINX" = 1 ]; then
  say "Configuring nginx"
  NGINX_DONE=0
  # 1Panel keeps its sites in a mounted directory and runs nginx in a container;
  # a plain install keeps them in /etc/nginx/conf.d. Support both.
  if [ -d /opt/1panel/www/conf.d ]; then
    NGINX_CONF_DIR=/opt/1panel/www/conf.d
    NGINX_RUN="$(command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -i openresty | head -1 || true)"
  elif [ -d /etc/nginx/conf.d ]; then
    NGINX_CONF_DIR=/etc/nginx/conf.d
    NGINX_RUN=""
  else
    NGINX_CONF_DIR=""
    warn "no nginx conf.d found. Add this to your server by hand:"
    printf '    location /__t/ { proxy_pass http://127.0.0.1:%s; proxy_buffering off; }\n' "$HTTP_PORT"
  fi

  if [ -n "$NGINX_CONF_DIR" ]; then
    NGINX_TARGET="$NGINX_CONF_DIR/dsh-relay.conf"
    cat > "$NGINX_TARGET" <<"NGINX_EOF"
# dsh-remote-portal relay -- public entry for the tunnel (added by deploy-relay.sh).
# Scoped to this host: nothing else on the server is touched.
map $http_upgrade $dsh_relay_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen 80;
    server_name __PUBLIC_HOST__;

    location /__t/ {
        proxy_pass http://127.0.0.1:__HTTP_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $dsh_relay_upgrade;
        # dsh streams responses and upgrades to WebSocket.
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX_EOF
    sed -i "s/__PUBLIC_HOST__/$PUBLIC_HOST/; s/__HTTP_PORT__/$HTTP_PORT/" "$NGINX_TARGET"
    ok "wrote $NGINX_TARGET"

    # Validate with the *running* server, then reload that same one: a config that
    # fails validation must never reach a reload.
    if [ -n "$NGINX_RUN" ]; then
      if docker exec "$NGINX_RUN" nginx -t >/tmp/nginx-t.log 2>&1; then
        docker exec "$NGINX_RUN" nginx -s reload
        ok "reloaded nginx inside container $NGINX_RUN"
        NGINX_DONE=1
      else
        rm -f "$NGINX_TARGET"
        tail -3 /tmp/nginx-t.log
        die "nginx rejected the configuration; file removed, nothing reloaded"
      fi
    elif command -v nginx >/dev/null 2>&1; then
      if nginx -t >/tmp/nginx-t.log 2>&1; then
        nginx -s reload
        ok "reloaded nginx"
        NGINX_DONE=1
      else
        rm -f "$NGINX_TARGET"
        tail -3 /tmp/nginx-t.log
        die "nginx rejected the configuration; file removed, nothing reloaded"
      fi
    else
      warn "wrote $NGINX_TARGET but found no running nginx to reload"
    fi
  fi
  [ "$NGINX_DONE" = 1 ] && ok "public entry ready: http://$PUBLIC_HOST$PREFIX/<id>/"
fi

# ── 6. health + next steps ──────────────────────────────────────────────────
say "Checking the relay"
if [ "$WITH_SYSTEMD" != 1 ]; then
  warn "not started yet (no systemd): run the command above, then check"
  printf '     curl -s http://127.0.0.1:%s/__relay/health\n' "$HTTP_PORT"
elif curl -fsS --max-time 4 "http://127.0.0.1:$HTTP_PORT/__relay/health" >/dev/null 2>&1; then
  ok "health endpoint answers on 127.0.0.1:$HTTP_PORT"
else
  warn "health endpoint did not answer yet — check: journalctl -u $SERVICE -n 30"
fi

cat <<DONE_EOF

────────────────────────────────────────────────────────────────────────
Paste these two values into dsh → 侧栏「远程访问」→ 公网访问:

  中转服务器   $AGENT_SCHEME://$PUBLIC_HOST:$AGENT_PORT
  隧道令牌     $TOKEN

（中转服务器用 tcp:// 还是 tls://，取决于服务器上的 agent 端口有没有配证书。
  本脚本没有传 --tls-cert/--tls-key，所以是明文 tcp://；要加密就用
  --tls-cert/--tls-key 指向 PEM 再跑一次，然后把这里改成 tls://。）

Then press 连接. The public address becomes:

  $PUBLIC_URL$PREFIX/$TUNNEL_ID/

Firewall (only these two need to be reachable from the internet):

  ufw allow 443/tcp        # visitors, through Caddy or the relay's own TLS
  ufw allow $AGENT_PORT/tcp        # the dsh host dials OUT to this port

  # nginx/openresty instead of Caddy? Re-run with --nginx and this script writes
  # the site itself (validated first, then reloaded).

Everything this script created:

  $RELAY_DIR/relay.mjs       the relay
  $STATE_DIR/token           the tunnel token (0600)$( [ "$WITH_SYSTEMD" = 1 ] && printf '\n  %s                      systemd unit' "$UNIT" )
  ${DOMAIN:+$SITE_DIR/$DOMAIN.caddy + a one-line import in /etc/caddy/Caddyfile}

Undo it all:

  ./deploy-relay.sh --uninstall${DOMAIN:+ --domain $DOMAIN}

$( [ "$WITH_SYSTEMD" = 1 ] && printf 'Logs:  journalctl -u %s -f' "$SERVICE" || printf 'Run it in the foreground to watch the log.' )
DONE_EOF
