#!/usr/bin/env bash
#
# dsh-remote-portal — 一键部署公网中转服务。
#
# 不带任何参数直接运行，脚本会：
#   1. 检查环境（Node、root、systemd）
#   2. 自动探测：公网 IP、是否已有 nginx / Caddy / 1Panel、可用端口
#   3. 逐项询问（每项都有默认值，直接回车即可）
#   4. 安装 relay、生成令牌、装 systemd、按需配 TLS、按需配反向代理
#   5. 自检并打印「粘进面板就能用」的两行
#
#   sudo ./deploy-relay.sh             交互式安装
#   sudo ./deploy-relay.sh --yes       全默认（无人值守）
#   sudo ./deploy-relay.sh --uninstall 卸载
#
# 可选覆盖（一般不需要）：
#   --host <域名或IP> --agent-port <n> --http-port <n> --public-port <n>
#   --no-proxy   不用已有反向代理，直接对外暴露 relay 端口
#   --plain      中转端口不加密（不推荐）
#
set -euo pipefail

# 从 Windows 拷过来/解压出来的副本可能没有执行位，先自愈再继续。
if [ ! -x "$0" ] && [ -f "$0" ]; then chmod +x "$0" 2>/dev/null || true; fi

RELAY_DIR=/opt/dsh-relay
STATE_DIR=/var/lib/dsh-relay
UNIT=/etc/systemd/system/dsh-relay.service
SERVICE=dsh-relay
PORTAL_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

# ── 默认值（交互时会展示并允许修改） ────────────────────────────────────────
HOST=""
AGENT_PORT=9443
HTTP_PORT=8080
PUBLIC_PORT=80
WANT_TLS=1
PROXY_MODE=""
ASSUME_YES=0
UNINSTALL=0
FORCE_PLAIN=0
FORCE_NO_PROXY=0

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --host) HOST=$2; shift 2 ;;
    --agent-port) AGENT_PORT=$2; shift 2 ;;
    --http-port) HTTP_PORT=$2; shift 2 ;;
    --public-port) PUBLIC_PORT=$2; shift 2 ;;
    --no-proxy) FORCE_NO_PROXY=1; shift ;;
    --plain) FORCE_PLAIN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：$1（用 --help 查看）" ;;
  esac
done

as_root() { [ "$(id -u)" = "0" ]; }

# 上次安装的选择。重跑时用它做默认值，端口不会因为"自己占着自己"而漂移。
CONF_FILE="$STATE_DIR/deploy.conf"
if [ "$UNINSTALL" = 0 ] && [ -r "$CONF_FILE" ]; then
  . "$CONF_FILE" 2>/dev/null || true
  HOST=${HOST:-}
  AGENT_PORT=${AGENT_PORT:-9443}
  HTTP_PORT=${HTTP_PORT:-8080}
  PUBLIC_PORT=${PUBLIC_PORT:-80}
  WANT_TLS=${WANT_TLS:-1}
  PROXY_MODE=${PROXY_MODE:-}
fi

# 我们自己正在用的端口不算"被占用"：重装就是要复用它们。
OWN_PORTS=""
if [ -f "$UNIT" ]; then
  OWN_PORTS=$(grep -oE '\-\-(agent|http)-port [^ ]+' "$UNIT" 2>/dev/null | awk '{print $2}' | sed 's/.*://' | tr '\n' ' ' || true)
fi


# 交互：有 TTY 才询问，否则用默认值（便于自动化）
can_ask() { [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ]; }

ask() { # ask <提示> <默认值>
  local prompt=$1 def=$2 reply=""
  if can_ask; then
    printf '  %s [%s]: ' "$prompt" "$def" >/dev/tty
    read -r reply </dev/tty || reply=""
  fi
  printf '%s' "${reply:-$def}"
}

ask_yn() { # ask_yn <提示> <y|n>
  local prompt=$1 def=$2 reply=""
  if can_ask; then
    printf '  %s [%s]: ' "$prompt" "$def" >/dev/tty
    read -r reply </dev/tty || reply=""
  fi
  case "${reply:-$def}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

reload_proxy() { # 供卸载时使用
  if command -v docker >/dev/null 2>&1; then
    local c
    c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'openresty|nginx' | head -1 || true)
    [ -n "$c" ] && docker exec "$c" nginx -s reload >/dev/null 2>&1 || true
  fi
  command -v nginx >/dev/null 2>&1 && nginx -s reload >/dev/null 2>&1 || true
}

# ── 卸载 ────────────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  say "卸载公网中转"
  if as_root && [ -f "$UNIT" ]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT"
    systemctl daemon-reload || true
    ok "systemd 服务已移除"
  fi
  rm -rf "$RELAY_DIR" && ok "$RELAY_DIR 已删除"
  for f in /opt/1panel/www/conf.d/dsh-relay.conf /etc/nginx/conf.d/dsh-relay.conf /etc/caddy/sites/dsh-relay.caddy; do
    [ -f "$f" ] && { rm -f "$f"; ok "已删除 $f"; }
  done
  reload_proxy
  warn "保留了 $STATE_DIR（令牌与证书）；彻底删除：rm -rf $STATE_DIR"
  exit 0
fi

# ── 1. 环境检查 ─────────────────────────────────────────────────────────────
say "1/6 检查环境"
command -v node >/dev/null 2>&1 || die "需要 Node 20+：https://nodejs.org"
NODE_MAJOR=$(node -p 'process.versions.node.split(".")[0]')
[ "$NODE_MAJOR" -ge 20 ] || die "Node 版本过旧（$NODE_MAJOR），需要 20+"
ok "Node $(node -v) → $(command -v node)"
[ -f "$PORTAL_DIR/relay.mjs" ] || die "同目录下找不到 relay.mjs（本脚本要和 relay.mjs 放在一起）"
ok "relay.mjs 就位"

HAVE_SYSTEMD=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then HAVE_SYSTEMD=1; fi
if [ "$HAVE_SYSTEMD" = 1 ] && ! as_root; then
  die "安装 systemd 服务需要 root：请用 sudo 运行"
fi
if [ "$HAVE_SYSTEMD" = 1 ]; then ok "systemd 可用"; else warn "没有 systemd：relay 将以非托管方式启动"; fi

# ── 2. 探测环境 ─────────────────────────────────────────────────────────────
say "2/6 探测运行环境"

PUBLIC_IP=""
for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  PUBLIC_IP=$(curl -fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$PUBLIC_IP" ] && break
done
if [ -z "$PUBLIC_IP" ]; then PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}'); fi
if [ -n "$PUBLIC_IP" ]; then ok "公网 IP：$PUBLIC_IP"; else warn "未能探测公网 IP，稍后手动填"; fi

DETECTED_PROXY=none
CADDY_BIN=""
NGINX_RUN=""
NGINX_CONF_DIR=""
if command -v caddy >/dev/null 2>&1; then
  CADDY_BIN=$(command -v caddy)
  DETECTED_PROXY=caddy
  ok "检测到 Caddy（$CADDY_BIN），可自动签发 HTTPS 证书"
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'openresty|nginx'; then
  NGINX_RUN=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'openresty|nginx' | head -1)
  if [ -d /opt/1panel/www/conf.d ]; then
    NGINX_CONF_DIR=/opt/1panel/www/conf.d
  else
    NGINX_CONF_DIR=$(docker inspect "$NGINX_RUN" --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null | awk '$2 ~ /conf\.d$/ {print $1; exit}')
  fi
  [ -n "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR=/opt/1panel/www/conf.d
  DETECTED_PROXY=nginx
  ok "检测到容器内 nginx（$NGINX_RUN），站点目录 $NGINX_CONF_DIR"
elif [ -d /etc/nginx/conf.d ] && command -v nginx >/dev/null 2>&1; then
  NGINX_CONF_DIR=/etc/nginx/conf.d
  DETECTED_PROXY=nginx
  ok "检测到系统 nginx，站点目录 $NGINX_CONF_DIR"
else
  warn "未发现 nginx / Caddy：relay 将直接对外监听一个端口（同样可用，只是少了 80/443 的 HTTPS 入口）"
fi

USED_PORTS=$( { ss -tln 2>/dev/null || netstat -tln 2>/dev/null || true; } | awk 'NR>1{split($4,a,":"); print a[length(a)]}' | sort -un | tr '\n' ' ')
port_free() {
  case " $OWN_PORTS " in *" $1 "*) return 0 ;; esac
  case " $USED_PORTS " in *" $1 "*) return 1 ;; *) return 0 ;; esac
}
while ! port_free "$AGENT_PORT"; do AGENT_PORT=$((AGENT_PORT + 1)); done
while ! port_free "$HTTP_PORT"; do HTTP_PORT=$((HTTP_PORT + 1)); done

# ── 3. 询问配置 ─────────────────────────────────────────────────────────────
say "3/6 配置（直接回车 = 括号里的默认值）"

[ -n "$HOST" ] || HOST=$(ask "对外访问用的域名或 IP" "${PUBLIC_IP:-127.0.0.1}")
[ -n "$HOST" ] || die "主机名不能为空"

if [ "$FORCE_NO_PROXY" = 1 ]; then
  PROXY_MODE=direct
elif [ "$DETECTED_PROXY" = none ]; then
  PROXY_MODE=direct
elif ask_yn "用已有$([ "$DETECTED_PROXY" = caddy ] && echo Caddy || echo nginx)做 80/443 入口（推荐）" y; then
  PROXY_MODE=$DETECTED_PROXY
else
  PROXY_MODE=direct
fi

if [ "$PROXY_MODE" = direct ]; then
  PUBLIC_PORT=$(ask "对外暴露的端口（需在云安全组放行）" "$PUBLIC_PORT")
  HTTP_PORT=$PUBLIC_PORT
  info "relay 直接监听 0.0.0.0:$PUBLIC_PORT"
else
  HTTP_PORT=$(ask "relay 本地端口（仅回环，由反代转发）" "$HTTP_PORT")
  if [ "$DETECTED_PROXY" = caddy ]; then PUBLIC_PORT=443; else PUBLIC_PORT=80; fi
fi

AGENT_PORT=$(ask "中转端口（家里的 dsh 拨出到这里）" "$AGENT_PORT")

if [ "$FORCE_PLAIN" = 1 ]; then
  WANT_TLS=0
elif ask_yn "加密中转端口（自签证书，自动生成）" y; then
  WANT_TLS=1
else
  WANT_TLS=0
fi

printf '\n'
info "汇总："
info "  对外主机    $HOST"
info "  中转端口    $AGENT_PORT（$([ "$WANT_TLS" = 1 ] && echo TLS || echo 明文)）"
if [ "$PROXY_MODE" = direct ]; then
  info "  访客入口    relay 直接监听 0.0.0.0:$PUBLIC_PORT"
else
  info "  访客入口    $PROXY_MODE → 127.0.0.1:$HTTP_PORT（对外 $PUBLIC_PORT）"
fi
if can_ask; then ask_yn "确认安装" y || die "已取消"; fi

# ── 4. 安装 relay ───────────────────────────────────────────────────────────
say "4/6 安装 relay"
if [ "$HAVE_SYSTEMD" = 1 ]; then
  useradd --system --home "$STATE_DIR" --shell /usr/sbin/nologin dsh-relay 2>/dev/null || true
  install -d -o dsh-relay -g dsh-relay -m 0750 "$STATE_DIR"
  install -d -o dsh-relay -g dsh-relay -m 0755 "$RELAY_DIR"
  install -o dsh-relay -g dsh-relay -m 0644 "$PORTAL_DIR/relay.mjs" "$RELAY_DIR/relay.mjs"
else
  RELAY_DIR="$PWD/.relay-run"; STATE_DIR="$PWD/.relay-state"
  install -d -m 0755 "$RELAY_DIR"; install -d -m 0700 "$STATE_DIR"
  install -m 0644 "$PORTAL_DIR/relay.mjs" "$RELAY_DIR/relay.mjs"
fi
ok "$RELAY_DIR/relay.mjs"

TOKEN_FILE="$STATE_DIR/token"
TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(head -n 1 "$TOKEN_FILE"); chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  ok "沿用已存在的隧道令牌"
else
  TOKEN=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64url"))')
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
  [ "$HAVE_SYSTEMD" = 1 ] && chown dsh-relay:dsh-relay "$TOKEN_FILE"
  ok "生成隧道令牌 → $TOKEN_FILE"
fi

TLS_CERT=""; TLS_KEY=""
if [ "$WANT_TLS" = 1 ]; then
  CERT_DIR="$STATE_DIR/tls"; CERT="$CERT_DIR/agent-cert.pem"; KEY="$CERT_DIR/agent-key.pem"
  install -d -m 0750 "$CERT_DIR"
  if [ -r "$CERT" ] && [ -r "$KEY" ]; then
    ok "复用已安装的证书"
  elif command -v openssl >/dev/null 2>&1; then
    case "$HOST" in
      *[!0-9.]*) SAN="DNS:$HOST,DNS:localhost" ;;
      *) SAN="IP:$HOST,DNS:localhost" ;;
    esac
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -keyout "$KEY" -out "$CERT" -subj "/CN=dsh-relay" \
      -addext "subjectAltName=$SAN" >/dev/null 2>&1 || die "生成证书失败"
    chmod 600 "$KEY"; chmod 644 "$CERT"
    ok "已生成自签证书（SAN=$SAN）"
  else
    warn "没有 openssl，跳过加密（装好后重跑即可）"
    WANT_TLS=0
  fi
  if [ "$HAVE_SYSTEMD" = 1 ]; then chown -R dsh-relay:dsh-relay "$STATE_DIR"; fi
  if [ "$WANT_TLS" = 1 ]; then TLS_CERT="$CERT"; TLS_KEY="$KEY"; fi
fi

# ── 5. 服务与入口 ───────────────────────────────────────────────────────────
say "5/6 启动服务并配置入口"
if [ "$PROXY_MODE" = direct ]; then BIND_HOST=0.0.0.0; else BIND_HOST=127.0.0.1; fi
case "$PUBLIC_PORT" in
  80) URL_BASE="http://$HOST" ;;
  443) URL_BASE="https://$HOST" ;;
  *) URL_BASE="http://$HOST:$PUBLIC_PORT" ;;
esac

RELAY_ARGS="$RELAY_DIR/relay.mjs --token-file $TOKEN_FILE --agent-port $AGENT_PORT --http-port $BIND_HOST:$HTTP_PORT --prefix /__t --public-url $URL_BASE"
[ -n "$TLS_CERT" ] && RELAY_ARGS="$RELAY_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"

if [ "$HAVE_SYSTEMD" = 1 ]; then
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
  # 已在运行时 enable --now 不会换掉旧进程，必须 restart
  systemctl restart "$SERVICE"
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 15 --no-pager || true
    die "服务启动失败"
  fi
  ok "dsh-relay.service 运行中（开机自启）"
else
  ok "非 systemd 环境：稍后按末尾命令前台启动"
fi

write_nginx() {
  local target="$NGINX_CONF_DIR/dsh-relay.conf"
  cat > "$target" <<NGINX_EOF
# dsh-remote-portal — 公网中转入口（由 deploy-relay.sh 生成）
# 只转发 /__t/，不影响本机其他站点。
map \$http_upgrade \$dsh_relay_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen $PUBLIC_PORT;
    server_name $HOST;

    location /__t/ {
        proxy_pass http://127.0.0.1:$HTTP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$dsh_relay_upgrade;
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
NGINX_EOF
  if [ -n "$NGINX_RUN" ]; then
    if docker exec "$NGINX_RUN" nginx -t >/tmp/nginx-t.log 2>&1; then
      docker exec "$NGINX_RUN" nginx -s reload
      ok "nginx（容器 $NGINX_RUN）已重载"
    else
      rm -f "$target"; tail -3 /tmp/nginx-t.log
      die "nginx 校验失败，已删除配置、未重载"
    fi
  elif command -v nginx >/dev/null 2>&1; then
    if nginx -t >/tmp/nginx-t.log 2>&1; then
      nginx -s reload; ok "nginx 已重载"
    else
      rm -f "$target"; tail -3 /tmp/nginx-t.log
      die "nginx 校验失败，已删除配置、未重载"
    fi
  else
    warn "写好了 $target，但没找到可重载的 nginx"
  fi
}

write_caddy() {
  local site_dir=/etc/caddy/sites
  mkdir -p "$site_dir"
  grep -qs "import $site_dir" /etc/caddy/Caddyfile || printf '\nimport %s/*.caddy\n' "$site_dir" >> /etc/caddy/Caddyfile
  cat > "$site_dir/dsh-relay.caddy" <<CADDY_EOF
$HOST {
	encode zstd gzip
	reverse_proxy 127.0.0.1:$HTTP_PORT {
		header_up X-Forwarded-Proto {scheme}
		flush_interval -1
	}
}
CADDY_EOF
  if "$CADDY_BIN" validate --config /etc/caddy/Caddyfile >/tmp/caddy-t.log 2>&1; then
    systemctl reload caddy 2>/dev/null || "$CADDY_BIN" reload --config /etc/caddy/Caddyfile
    ok "Caddy 站点已安装并重载（自动 HTTPS）"
  else
    rm -f "$site_dir/dsh-relay.caddy"; tail -3 /tmp/caddy-t.log
    die "Caddy 校验失败，已回滚"
  fi
}

case "$PROXY_MODE" in
  nginx) write_nginx ;;
  caddy) write_caddy ;;
  direct) ok "relay 直接监听 0.0.0.0:$PUBLIC_PORT（不需要反向代理）" ;;
esac

# ── 6. 自检与交付 ───────────────────────────────────────────────────────────
say "6/6 自检"
sleep 1
if curl -fsS --max-time 4 "http://127.0.0.1:$HTTP_PORT/__relay/health" >/dev/null 2>&1; then
  ok "relay 健康检查通过（127.0.0.1:$HTTP_PORT）"
else
  warn "健康检查未通过；日志：$([ "$HAVE_SYSTEMD" = 1 ] && echo "journalctl -u $SERVICE -n 30" || echo 前台输出)"
fi

# 记住这次的选择，下次重跑直接沿用（端口、主机、加密方式、入口方式）。
mkdir -p "$STATE_DIR" 2>/dev/null || true
cat > "$CONF_FILE" <<CONF_EOF
HOST=$HOST
AGENT_PORT=$AGENT_PORT
HTTP_PORT=$HTTP_PORT
PUBLIC_PORT=$PUBLIC_PORT
WANT_TLS=$([ -n "$TLS_CERT" ] && echo 1 || echo 0)
PROXY_MODE=$PROXY_MODE
CONF_EOF
chmod 644 "$CONF_FILE" 2>/dev/null || true
if [ "$HAVE_SYSTEMD" = 1 ]; then chown dsh-relay:dsh-relay "$CONF_FILE" 2>/dev/null || true; fi

TUNNEL_ID=$(node -e 'const c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(process.argv[1]).digest("base64url").slice(0,12))' "$TOKEN")
SCHEME=$([ -n "$TLS_CERT" ] && echo tls || echo tcp)

cat <<DONE_EOF

────────────────────────────────────────────────────────────────────────
把下面两行填进 dsh → 侧栏「远程访问」→ 公网访问：

  中转服务器   $SCHEME://$HOST:$AGENT_PORT
  隧道令牌     $TOKEN
DONE_EOF
if [ "$SCHEME" = tls ]; then printf '  %s\n' "（自签证书：同时勾选「信任自签名证书」）"; fi

cat <<DONE_EOF

连接成功后，公网地址是：

  $URL_BASE/__t/$TUNNEL_ID/

还需要在云安全组 / 防火墙放行（否则外面连不进来）：

  $AGENT_PORT/tcp   ← 家里的 dsh 拨出
  $PUBLIC_PORT/tcp   ← 访客入口

本机防火墙：
  ufw allow $AGENT_PORT/tcp && ufw allow $PUBLIC_PORT/tcp
  # firewalld: firewall-cmd --add-port=$AGENT_PORT/tcp --add-port=$PUBLIC_PORT/tcp --permanent && firewall-cmd --reload

本次创建：
  $RELAY_DIR/relay.mjs
  $TOKEN_FILE（令牌，0600）
DONE_EOF
if [ -n "$TLS_CERT" ]; then printf '  %s\n' "$TLS_CERT（自签证书）"; fi
if [ "$HAVE_SYSTEMD" = 1 ]; then printf '  %s\n' "$UNIT"; fi
if [ "$PROXY_MODE" = nginx ]; then printf '  %s\n' "$NGINX_CONF_DIR/dsh-relay.conf"; fi
if [ "$PROXY_MODE" = caddy ]; then printf '  %s\n' "/etc/caddy/sites/dsh-relay.caddy"; fi

printf '\n卸载：sudo ./deploy-relay.sh --uninstall\n'
if [ "$HAVE_SYSTEMD" = 1 ]; then
  printf '日志：journalctl -u %s -f\n' "$SERVICE"
else
  printf '前台启动：\n  node %s\n' "$RELAY_ARGS"
fi
