#!/usr/bin/env bash
#
# dsh-remote-portal — deploy the public relay.
#
# Run it with no arguments: it detects the environment, asks a few questions
# (every answer has a default, so Enter works throughout) and finishes the setup.
# It prints the two values to paste into dsh, and installs a `drp` command for
# day-to-day management.
#
#   sudo ./deploy-relay.sh              interactive (English)
#   sudo ./deploy-relay.sh --lang zh    interactive, Chinese
#   sudo ./deploy-relay.sh --yes        accept every default (unattended)
#   sudo ./deploy-relay.sh --uninstall  remove the relay and the `drp` command
#
# Everything else is asked interactively (HTTP or HTTPS, domain or IP, ports).
# Only two switches exist: --yes (take the defaults) and --uninstall.
#
set -euo pipefail

if [ ! -x "$0" ] && [ -f "$0" ]; then chmod +x "$0" 2>/dev/null || true; fi

SELF_VERSION="0.5.4"

RELAY_DIR=/opt/dsh-relay
STATE_DIR=/var/lib/dsh-relay
UNIT=/etc/systemd/system/dsh-relay.service
SERVICE=dsh-relay
BIN=/usr/local/bin/drp
PORTAL_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd || echo .)"

HOST=""; AGENT_PORT=9443; HTTP_PORT=8080; PUBLIC_PORT=80
PROXY_MODE=""; ASSUME_YES=0; UNINSTALL=0; LANG_MODE=en
VISIT_MODE=""; SCHEME=http; VISITOR_TLS=0; AGENT_TLS=1; CERT_SOURCE=none

while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_MODE=$2; shift 2 ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1 (try --help)" >&2; exit 1 ;;
  esac
done

# t "English" "中文" — one message, two languages.
t() { if [ "$LANG_MODE" = zh ]; then printf '%s' "$2"; else printf '%s' "$1"; fi; }
say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

as_root() { [ "$(id -u)" = "0" ]; }
can_ask() { [ "$ASSUME_YES" = 0 ] && [ -r /dev/tty ]; }

ask() {
  local prompt=$1 def=$2 reply=""
  if can_ask; then
    printf '  %s [%s]: ' "$prompt" "$def" >/dev/tty
    if ! read -r reply </dev/tty; then
      printf '\n' >/dev/tty
      die "$(t "input closed; nothing was changed" "输入已结束，未做任何修改")"
    fi
  fi
  printf '%s' "${reply:-$def}"
}
ask_port() { # ask_port <prompt> <default>
  local prompt=$1 def=$2 reply=""
  while :; do
    reply=$(ask "$prompt" "$def")
    case "$reply" in
      ""|*[!0-9]*) warn "$(t "enter a number between 1 and 65535" "请输入 1–65535 之间的数字")"; def=$def; continue ;;
    esac
    if [ "$reply" -lt 1 ] || [ "$reply" -gt 65535 ]; then
      warn "$(t "port out of range" "端口超出范围")"
      continue
    fi
    printf '%s' "$reply"
    return 0
  done
}

resolve_ipv4() { # resolve_ipv4 <name>; empty when there is no A record
  local name=$1 out=""
  if command -v getent >/dev/null 2>&1; then
    out=$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1{print $1}')
  fi
  if [ -z "$out" ] && command -v dig >/dev/null 2>&1; then
    out=$(dig +short A "$name" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
  fi
  if [ -z "$out" ] && command -v nslookup >/dev/null 2>&1; then
    out=$(nslookup "$name" 2>/dev/null | awk '/^Address:[ ]*[0-9]/{print $2; exit}')
  fi
  if [ -z "$out" ] && command -v host >/dev/null 2>&1; then
    out=$(host -t A "$name" 2>/dev/null | awk '/has address/{print $4; exit}')
  fi
  printf '%s' "$out"
}

# Ask for a domain and prove it points here before going further: an automatic
# certificate cannot be issued for a name that does not resolve to this host, and a
# visitor would land wherever the record points today. Status goes to stderr so the
# caller captures only the name.
pick_domain() {
  local name ip ans last=""
  if ! can_ask; then
    printf '%s' "${HOST:-}"
    return 0
  fi
  while :; do
    name=$(ask "$(t "Domain name" "域名")" "$last")
    if [ -z "$name" ]; then
      warn "$(t "a domain is required for this mode" "这个模式需要填域名")" >&2
      continue
    fi
    last=$name
    ip=$(resolve_ipv4 "$name")
    if [ -z "$ip" ]; then
      warn "$(t "$name has no A record yet" "$name 还没有 A 记录")" >&2
      info "$(t "point an A record at ${PUBLIC_IP:-this host}, then check again" "先加一条 A 记录指向 ${PUBLIC_IP:-本机}，再重新检测")" >&2
      ans=$(ask "$(t "r = check again, u = use it anyway, anything else = another domain" "r = 重新检测，u = 仍然使用，其他 = 换域名")" "r")
      case "$ans" in
        [Uu]*) printf '%s' "$name"; return 0 ;;
        *) continue ;;
      esac
    fi
    if [ -n "${PUBLIC_IP:-}" ] && [ "$ip" != "$PUBLIC_IP" ]; then
      warn "$(t "$name resolves to $ip, this host is $PUBLIC_IP" "$name 解析到 $ip，本机公网 IP 是 $PUBLIC_IP")" >&2
      info "$(t "normal behind Cloudflare or another CDN: the CDN answers and reaches you" "如果走了 Cloudflare 等 CDN，这是正常的：由 CDN 回源到本机")" >&2
      info "$(t "automatic certificate issuance needs the record to point here directly" "自动申请证书需要解析直接指向本机")" >&2
      ans=$(ask "$(t "c = continue, r = check again, anything else = another domain" "c = 继续，r = 重新检测，其他 = 换域名")" "c")
      case "$ans" in
        [Cc]*) printf '%s' "$name"; return 0 ;;
        *) continue ;;
      esac
    fi
    ok "$(t "DNS points here" "解析已指向本机")" >&2
    printf '%s' "$name"
    return 0
  done
}

ask_yn() {
  local prompt=$1 def=$2 reply=""
  if can_ask; then
    printf '  %s [%s]: ' "$prompt" "$def" >/dev/tty
    if ! read -r reply </dev/tty; then
      printf '\n' >/dev/tty
      die "$(t "input closed; nothing was changed" "输入已结束，未做任何修改")"
    fi
  fi
  case "${reply:-$def}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# Previous choices, so a re-run offers what is installed and ports never drift.
CONF_FILE="$STATE_DIR/deploy.conf"
if [ "$UNINSTALL" = 0 ] && [ -r "$CONF_FILE" ]; then
  . "$CONF_FILE" 2>/dev/null || true
  HOST=${HOST:-}; AGENT_PORT=${AGENT_PORT:-9443}; HTTP_PORT=${HTTP_PORT:-8080}
  PUBLIC_PORT=${PUBLIC_PORT:-80}; PROXY_MODE=${PROXY_MODE:-}
  SAVED_PROXY=$PROXY_MODE
  SAVED_VISIT_MODE=${VISIT_MODE:-}
  SAVED_AGENT_TLS=${AGENT_TLS:-}
fi
SAVED_PROXY=${SAVED_PROXY:-}
OWN_PORTS=""
if [ -f "$UNIT" ]; then
  OWN_PORTS=$(grep -oE '\-\-(agent|http)-port [^ ]+' "$UNIT" 2>/dev/null | awk '{print $2}' | sed 's/.*://' | tr '\n' ' ' || true)
fi

install_drp() {
  cat > "$BIN" <<'DRP_EOF'
#!/bin/sh
# drp — manage the dsh-remote-portal relay.
#   drp            status (default)
#   drp url        public URL to open
#   drp token      tunnel token (the value to paste into dsh)
#   drp start|stop|restart
#   drp log [-f]
#   drp config     the saved answers
#   drp help
CONF=/var/lib/dsh-relay/deploy.conf
TOKEN_FILE=/var/lib/dsh-relay/token
SERVICE=dsh-relay
set -u

load() {
  [ -r "$CONF" ] && . "$CONF"
  HOST=${HOST:-127.0.0.1}; AGENT_PORT=${AGENT_PORT:-9443}; HTTP_PORT=${HTTP_PORT:-8080}
  PUBLIC_PORT=${PUBLIC_PORT:-80}; PROXY_MODE=${PROXY_MODE:-none}
  SCHEME=${SCHEME:-http}; VISITOR_TLS=${VISITOR_TLS:-0}; AGENT_TLS=${AGENT_TLS:-${WANT_TLS:-1}}
}
health() { curl -fsS --max-time 3 "http://127.0.0.1:${HTTP_PORT:-8080}/__relay/health" 2>/dev/null; }
token() { [ -r "$TOKEN_FILE" ] && head -n 1 "$TOKEN_FILE"; }
tunnel_id() { tid=$(token); [ -n "$tid" ] && node -e 'const c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(process.argv[1]).digest("base64url").slice(0,12))' "$tid"; }
url_base() {
  if [ "${SCHEME:-http}" = https ]; then
    case "${PUBLIC_PORT:-443}" in 443) echo "https://$HOST" ;; *) echo "https://$HOST:$PUBLIC_PORT" ;; esac
  else
    case "${PUBLIC_PORT:-80}" in 80) echo "http://$HOST" ;; *) echo "http://$HOST:$PUBLIC_PORT" ;; esac
  fi
}
endpoint() { if [ "${AGENT_TLS:-1}" = 1 ]; then echo "tls://$HOST:$AGENT_PORT"; else echo "tcp://$HOST:$AGENT_PORT"; fi; }

case "${1:-status}" in
  status)
    load
    printf 'service     '
    if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
      echo "running (enabled: $(systemctl is-enabled $SERVICE 2>/dev/null || echo no))"
    else
      echo "stopped"
    fi
    printf 'agent port  %s:%s (%s)\n' "$HOST" "$AGENT_PORT" "$([ "${AGENT_TLS:-1}" = 1 ] && echo TLS || echo plain)"
    printf 'visitor     '
    if [ "$PROXY_MODE" = none ]; then
      if [ "${VISITOR_TLS:-0}" = 1 ]; then echo "0.0.0.0:$PUBLIC_PORT (TLS, self-signed)"
      else echo "0.0.0.0:$PUBLIC_PORT (plain, NOT encrypted)"; fi
    else
      echo "$PROXY_MODE -> 127.0.0.1:$HTTP_PORT, public $PUBLIC_PORT ($SCHEME)"
    fi
    printf 'endpoint    %s\n' "$(endpoint)"
    h=$(health)
    if [ -n "$h" ]; then
      printf '%s' "$h" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);const t=j.tunnels[0];console.log("relay       reachable");console.log("tunnel      "+(t?((t.connected?"connected":"offline")+", streams="+t.streams):"none"));console.log("traffic     in="+j.stats.bytesIn+"B out="+j.stats.bytesOut+"B visitors="+j.stats.visitors);}catch(e){console.log("relay       unreadable response")}})'
    else
      printf 'relay       NOT reachable on 127.0.0.1:%s\n' "$HTTP_PORT"
    fi
    printf 'public      %s/__t/%s/\n' "$(url_base)" "$(tunnel_id)"
    if [ "${AGENT_TLS:-1}" = 1 ]; then printf '\nnote        self-signed certificate: tick "trust" in the dsh panel\n'; fi
    if [ "$SCHEME" = http ] && { [ "$PROXY_MODE" = none ] || [ "$PUBLIC_PORT" = 80 ]; }; then
      printf 'warn        visitors connect over plain HTTP: the password and the whole session are readable on the way\n'
    fi
    ;;
  url) load; printf '%s/__t/%s/\n' "$(url_base)" "$(tunnel_id)" ;;
  token) token; echo ;;
  start) systemctl start "$SERVICE" && echo started ;;
  stop) systemctl stop "$SERVICE" && echo stopped ;;
  restart) systemctl restart "$SERVICE" && echo restarted ;;
  log) if [ "${2:-}" = "-f" ]; then journalctl -u "$SERVICE" -f; else journalctl -u "$SERVICE" -n "${2:-40}" --no-pager; fi ;;
  config) [ -r "$CONF" ] && cat "$CONF" || echo "no saved configuration" ;;
  help|--help|-h) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *) echo "unknown command: $1 (try: drp help)" >&2; exit 1 ;;
esac
DRP_EOF
  chmod 755 "$BIN"
  ok "$(t "installed the management command: drp" "已安装管理命令：drp")"
}

# ── uninstall ───────────────────────────────────────────────────────────────
if [ "$UNINSTALL" = 1 ]; then
  say "$(t "Removing the relay" "卸载公网中转")"
  if as_root && [ -f "$UNIT" ]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "$UNIT"; systemctl daemon-reload || true
    ok "$(t "service removed" "服务已移除")"
  fi
  rm -rf "$RELAY_DIR"; ok "$RELAY_DIR removed"
  for f in /opt/1panel/www/conf.d/dsh-relay.conf /etc/nginx/conf.d/dsh-relay.conf /etc/caddy/sites/dsh-relay.caddy; do
    [ -f "$f" ] && { rm -f "$f"; ok "removed $f"; }
  done
  rm -f "$BIN" && ok "$BIN removed"
  if command -v docker >/dev/null 2>&1; then
    c=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'openresty|nginx' | head -1 || true)
    [ -n "$c" ] && docker exec "$c" nginx -s reload >/dev/null 2>&1 || true
  fi
  warn "$(t "kept $STATE_DIR (token and certificate)" "保留了 $STATE_DIR（令牌与证书）")"
  exit 0
fi

# ── 1. environment ──────────────────────────────────────────────────────────
say "1/6 $(t "Checking the host" "检查环境")"
command -v node >/dev/null 2>&1 || die "$(t "Node 20+ is required: https://nodejs.org" "需要 Node 20+：https://nodejs.org")"
[ "$(node -p 'process.versions.node.split(".")[0]')" -ge 20 ] || die "$(t "Node is too old (need 20+)" "Node 版本过旧，需要 20+")"
ok "node $(node -v) → $(command -v node)"
# A one-line install pipes this script into bash, where no directory holds
# relay.mjs. Fetch it from the repository instead of asking for a clone — and try
# mirrors, because the raw host is often unreachable from mainland China.
if [ -n "${RELAY_RAW_BASE:-}" ]; then
  RAW_BASES=$RELAY_RAW_BASE
else
  RAW_BASES="https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master \
https://cdn.jsdelivr.net/gh/tsukii12/dsh-remote-portal@v${SELF_VERSION} \
https://ghfast.top/https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master \
https://gh-proxy.com/https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master"
fi

if [ ! -f "$PORTAL_DIR/relay.mjs" ]; then
  TMP_RELAY=$(mktemp -d)/relay.mjs
  got=""
  for base in $RAW_BASES; do
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --max-time 25 "$base/tools/relay.mjs" -o "$TMP_RELAY" 2>/dev/null || continue
    elif command -v wget >/dev/null 2>&1; then
      wget -qT 25 -O "$TMP_RELAY" "$base/tools/relay.mjs" 2>/dev/null || continue
    else
      die "$(t "need curl or wget to fetch relay.mjs" "需要 curl 或 wget 才能下载 relay.mjs")"
    fi
    node --check "$TMP_RELAY" >/dev/null 2>&1 || continue
    got=$base
    break
  done
  [ -n "$got" ] || die "$(t "could not fetch relay.mjs from GitHub or any mirror. Download it once on a machine that can reach GitHub and put it next to this script, then run again." "GitHub 和所有镜像都取不到 relay.mjs。在一台能访问 GitHub 的机器上下载它，放到本脚本旁边，再重新运行。")"
  PORTAL_DIR=$(dirname "$TMP_RELAY")
  ok "relay.mjs $(t "downloaded" "已下载") ($(printf '%s' "$got" | sed -e 's#^https\?://##' -e 's#/.*##'))"
else
  ok "relay.mjs"
fi

HAVE_SYSTEMD=0
if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then HAVE_SYSTEMD=1; fi
if [ "$HAVE_SYSTEMD" = 1 ] && ! as_root; then
  die "$(t "installing a service needs root: run with sudo" "安装服务需要 root：请用 sudo 运行")"
fi
if [ "$HAVE_SYSTEMD" = 1 ]; then ok "systemd"; else warn "$(t "no systemd: the relay will run unmanaged" "没有 systemd：relay 不会被托管")"; fi

# ── 2. detection ────────────────────────────────────────────────────────────
say "2/6 $(t "Detecting the environment" "探测运行环境")"
PUBLIC_IP=""
for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  PUBLIC_IP=$(curl -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$PUBLIC_IP" ] && break
done
[ -n "$PUBLIC_IP" ] || PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$PUBLIC_IP" ]; then ok "$(t "public IP" "公网 IP"): $PUBLIC_IP"; else warn "$(t "could not detect the public IP" "未能探测公网 IP")"; fi

DETECTED_PROXY=none; CADDY_BIN=""; NGINX_RUN=""; NGINX_CONF_DIR=""
if command -v caddy >/dev/null 2>&1; then
  CADDY_BIN=$(command -v caddy); DETECTED_PROXY=caddy
  ok "$(t "found Caddy (automatic HTTPS)" "检测到 Caddy（可自动签发 HTTPS）")"
elif command -v docker >/dev/null 2>&1 && docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'openresty|nginx'; then
  NGINX_RUN=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -iE 'openresty|nginx' | head -1)
  if [ -d /opt/1panel/www/conf.d ]; then
    NGINX_CONF_DIR=/opt/1panel/www/conf.d
  else
    NGINX_CONF_DIR=$(docker inspect "$NGINX_RUN" --format '{{range .Mounts}}{{.Source}} {{.Destination}}{{"\n"}}{{end}}' 2>/dev/null | awk '$2 ~ /conf\.d$/ {print $1; exit}')
  fi
  [ -n "$NGINX_CONF_DIR" ] || NGINX_CONF_DIR=/opt/1panel/www/conf.d
  DETECTED_PROXY=nginx
  ok "$(t "found nginx in container" "检测到容器内 nginx"): $NGINX_RUN"
elif [ -d /etc/nginx/conf.d ] && command -v nginx >/dev/null 2>&1; then
  NGINX_CONF_DIR=/etc/nginx/conf.d; DETECTED_PROXY=nginx
  ok "$(t "found system nginx" "检测到系统 nginx")"
else
  warn "$(t "no nginx/Caddy: the relay will listen publicly on its own port" "未发现 nginx/Caddy：relay 将直接对外监听端口")"
fi

USED_PORTS=$( { ss -tln 2>/dev/null || netstat -tln 2>/dev/null || true; } | awk 'NR>1{split($4,a,":"); print a[length(a)]}' | sort -un | tr '\n' ' ')
port_free() {
  case " $OWN_PORTS " in *" $1 "*) return 0 ;; esac
  case " $USED_PORTS " in *" $1 "*) return 1 ;; *) return 0 ;; esac
}
while ! port_free "$AGENT_PORT"; do AGENT_PORT=$((AGENT_PORT + 1)); done
while ! port_free "$HTTP_PORT"; do HTTP_PORT=$((HTTP_PORT + 1)); done

# ── 3. questions ────────────────────────────────────────────────────────────
say "3/6 $(t "Configuration (Enter accepts the default)" "配置（回车即用默认值）")"

if can_ask && [ "$ASSUME_YES" = 0 ]; then
  lang_pick=$(ask "Language / 语言 (en|zh)" "$LANG_MODE")
  [ "$lang_pick" = zh ] && LANG_MODE=zh
fi

# Visitor transport. This is the decision that matters for safety: plain HTTP over
# the internet sends the password and every conversation in the clear.
if [ "$ASSUME_YES" = 1 ] && [ -n "$SAVED_VISIT_MODE" ]; then
  VISIT_MODE=$SAVED_VISIT_MODE
elif [ "$ASSUME_YES" = 1 ]; then
  VISIT_MODE=http
  warn "$(t "--yes picked plain HTTP; the password and the whole session travel unencrypted. Re-run without --yes to choose HTTPS." "--yes 选了明文 HTTP：密码和全部会话内容都不加密。想用 HTTPS 请去掉 --yes 重跑。")"
else
  printf '\n  %s\n' "$(t "How will visitors connect?" "访客如何连接？")"
  printf '    1) HTTP   %s\n' "$(t "- no encryption. Anyone on the path can read the password and the whole session. Only for a trusted LAN." "— 不加密。路径上任何人都能读到密码和全部会话内容。仅限可信局域网。")"
  printf '    2) HTTPS  %s\n' "$(t "- encrypted. Recommended for anything reachable from the internet." "— 加密。只要能从公网访问，就选这个。")"
  pick=$(ask "$(t "Choose" "选择")" "2")
  case "$pick" in
    1) VISIT_MODE=http ;;
    *) VISIT_MODE=https ;;
  esac
fi

if [ "$VISIT_MODE" = http ]; then
  SCHEME=http
  PUBLIC_PORT=$([ "$DETECTED_PROXY" = none ] && echo 10003 || echo 80)
  HOST=$(ask "$(t "Public host (domain or IP)" "对外访问的域名或 IP")" "${PUBLIC_IP:-127.0.0.1}")
else
  SCHEME=https
  DOMAIN_TARGET=$(ask "$(t "HTTPS with a domain (no browser warning) or with the IP (self-signed, warning once)? [domain/ip]" "HTTPS 用域名（浏览器不报警）还是用 IP（自签，会警告一次）？[domain/ip]")" "ip")
  IS_DOMAIN=0
  case "$(printf '%s' "$DOMAIN_TARGET" | tr 'A-Z' 'a-z')" in
    d*|域名*)
      IS_DOMAIN=1
      HOST=$(pick_domain)
      [ -n "$HOST" ] || die "$(t "a domain is required for this mode" "这个模式需要填域名")"
      ;;
    *)
      HOST=${PUBLIC_IP:-127.0.0.1}
      HOST=$(ask "$(t "IP address" "IP 地址")" "$HOST")
      ;;
  esac
fi
[ -n "$HOST" ] || die "$(t "host cannot be empty" "主机名不能为空")"

# Who terminates TLS, and where the certificate comes from.
VISITOR_TLS=0
PROXY_MODE=none
CERT_SOURCE=none
if [ "$SCHEME" = https ]; then
  if [ "$DETECTED_PROXY" = caddy ]; then
    PROXY_MODE=caddy
    info "$(t "Caddy will obtain and renew the certificate for you" "Caddy 会自动申请并续签证书")"
  elif [ "$DETECTED_PROXY" = nginx ] && [ "${IS_DOMAIN:-0}" = 1 ]; then
    printf '\n  %s\n' "$(t "How should the certificate be provided?" "证书怎么来？")"
    printf '    1) %s\n' "$(t "I already have a certificate for this domain (fullchain + key)" "我已经有这个域名的证书（fullchain + key）")"
    printf '    2) %s\n' "$(t "Generate a self-signed one (browser warns once)" "生成自签证书（浏览器会警告一次）")"
    cert_pick=$(ask "$(t "Choose" "选择")" "2")
    if [ "$cert_pick" = 1 ]; then
      PROXY_MODE=nginx
      CERT_SOURCE=user
    else
      VISITOR_TLS=1
    fi
  else
    VISITOR_TLS=1
  fi

  # The relay's own TLS listener needs a certificate; self-signed is generated
  # later, right next to the agent certificate.
  [ "$VISITOR_TLS" = 1 ] && CERT_SOURCE=self
fi

if [ "$SCHEME" = https ] && [ "$VISITOR_TLS" = 1 ]; then
  default_public=443
elif [ "$SCHEME" = https ]; then
  default_public=443
elif [ "$PROXY_MODE" = nginx ]; then
  default_public=80
else
  default_public=10003
fi

PUBLIC_PORT=$(ask_port "$(t "Public port (open it in your cloud firewall)" "对外端口（需在云安全组放行）")" "$default_public")
while ! port_free "$PUBLIC_PORT"; do
  warn "$(t "port $PUBLIC_PORT is in use" "端口 $PUBLIC_PORT 已被占用")"
  PUBLIC_PORT=$(ask_port "$(t "Public port" "对外端口")" "$((PUBLIC_PORT + 1))")
done

while :; do
  AGENT_PORT=$(ask_port "$(t "Agent port (the dsh host dials out to it)" "中转端口（家里的 dsh 拨出到这里）")" "$AGENT_PORT")
  if [ "$AGENT_PORT" = "$PUBLIC_PORT" ] || [ "$AGENT_PORT" = "$HTTP_PORT" ]; then
    warn "$(t "that port is already used by this setup; pick another" "这个端口已被本次安装占用，请换一个")"
    continue
  fi
  break
done

if [ "$VISITOR_TLS" = 1 ]; then
  # The public port speaks TLS; keep a loopback plain port for health checks and
  # for anything that only speaks HTTP on this machine.
  HTTP_PORT=18080
  while ! port_free "$HTTP_PORT"; do HTTP_PORT=$((HTTP_PORT + 1)); done
elif [ "$PROXY_MODE" = none ]; then
  HTTP_PORT=$PUBLIC_PORT
else
  HTTP_PORT=$(ask "$(t "Local port behind the proxy (loopback only)" "反代后面的本地端口（仅回环）")" "$HTTP_PORT")
fi

if [ "$ASSUME_YES" = 1 ] && [ -n "$SAVED_AGENT_TLS" ]; then
  AGENT_TLS=$SAVED_AGENT_TLS
elif ask_yn "$(t "Encrypt the agent port as well (recommended)" "中转端口也加密（推荐）")" y; then
  AGENT_TLS=1
else
  AGENT_TLS=0
fi

# The relay needs one certificate for both listeners; a user-supplied pair is only
# used for nginx (which terminates TLS itself), so the agent hop still gets its own.
if [ "$CERT_SOURCE" = user ]; then
  USER_CERT=$(ask "$(t "Certificate chain (fullchain.pem)" "证书链（fullchain.pem）")" "")
  USER_KEY=$(ask "$(t "Private key (privkey.pem)" "私钥（privkey.pem）")" "")
  [ -r "$USER_CERT" ] && [ -r "$USER_KEY" ] || die "$(t "cannot read that certificate pair" "读不到这对证书文件")"
  AGENT_TLS=1
fi

printf '\n'
info "$(t "Summary" "汇总"):"
if [ "${IS_DOMAIN:-0}" = 1 ]; then
  info "  $(t "visitors" "访客")  $SCHEME://$HOST:$PUBLIC_PORT  ($(t "DNS" "解析") → $(resolve_ipv4 "$HOST"))"
else
  info "  $(t "visitors" "访客")  $SCHEME://$HOST:$PUBLIC_PORT$( [ "$SCHEME" = https ] && echo "" || echo "  ($(t "unencrypted" "未加密"))")"
fi
if [ "$PROXY_MODE" = none ]; then
  info "  $(t "entry" "入口")     $(t "relay listens itself" "relay 自己监听") ($([ "$VISITOR_TLS" = 1 ] && echo "TLS, $(t "self-signed" "自签")" || echo "plain"))"
else
  info "  $(t "entry" "入口")     $PROXY_MODE → 127.0.0.1:$HTTP_PORT"
fi
info "  $(t "agent" "中转")     $HOST:$AGENT_PORT ($([ "$AGENT_TLS" = 1 ] && echo TLS || echo plain))"
if can_ask; then ask_yn "$(t "Install with these settings" "确认安装")" y || die "$(t "cancelled" "已取消")"; fi

# ── 4. install ──────────────────────────────────────────────────────────────
say "4/6 $(t "Installing the relay" "安装 relay")"
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

TOKEN_FILE="$STATE_DIR/token"; TOKEN=""
if [ -s "$TOKEN_FILE" ]; then
  TOKEN=$(head -n 1 "$TOKEN_FILE"); chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  ok "$(t "reusing the existing token" "沿用已存在的令牌")"
else
  TOKEN=$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64url"))')
  ( umask 077; printf '%s\n' "$TOKEN" > "$TOKEN_FILE" )
  [ "$HAVE_SYSTEMD" = 1 ] && chown dsh-relay:dsh-relay "$TOKEN_FILE"
  ok "$(t "generated a tunnel token" "已生成隧道令牌")"
fi

TLS_CERT=""; TLS_KEY=""
NEED_CERT=0
if [ "$CERT_SOURCE" = self ] || [ "$AGENT_TLS" = 1 ]; then NEED_CERT=1; fi

if [ "$CERT_SOURCE" = user ]; then
  TLS_CERT=$USER_CERT
  TLS_KEY=$USER_KEY
  ok "$(t "using the certificate you provided" "使用你提供的证书")"
elif [ "$NEED_CERT" = 1 ]; then
  CERT_DIR="$STATE_DIR/tls"; CERT="$CERT_DIR/agent-cert.pem"; KEY="$CERT_DIR/agent-key.pem"
  install -d -m 0750 "$CERT_DIR"
  if [ -r "$CERT" ] && [ -r "$KEY" ]; then
    ok "$(t "reusing the installed certificate" "复用已安装的证书")"
  elif command -v openssl >/dev/null 2>&1; then
    case "$HOST" in
      *[!0-9.]*) SAN="DNS:$HOST,DNS:localhost" ;;
      *) SAN="IP:$HOST,DNS:localhost" ;;
    esac
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$KEY" -out "$CERT" \
      -subj "/CN=dsh-relay" -addext "subjectAltName=$SAN" >/dev/null 2>&1 || die "openssl failed"
    chmod 600 "$KEY"; chmod 644 "$CERT"
    ok "$(t "generated a self-signed certificate" "已生成自签证书") ($SAN)"
  else
    warn "$(t "openssl is missing: continuing unencrypted" "没有 openssl：以不加密方式继续")"
    NEED_CERT=0
    AGENT_TLS=0
    VISITOR_TLS=0
  fi
  [ "$HAVE_SYSTEMD" = 1 ] && chown -R dsh-relay:dsh-relay "$STATE_DIR"
  if [ "$NEED_CERT" = 1 ]; then TLS_CERT="$CERT"; TLS_KEY="$KEY"; fi
fi

# ── 5. service and entry point ──────────────────────────────────────────────
say "5/6 $(t "Starting the service" "启动服务")"
if [ "$PROXY_MODE" = none ] && [ "$VISITOR_TLS" = 0 ]; then BIND_HOST=0.0.0.0; else BIND_HOST=127.0.0.1; fi
if [ "$SCHEME" = https ]; then
  if [ "$PUBLIC_PORT" = 443 ]; then URL_BASE="https://$HOST"; else URL_BASE="https://$HOST:$PUBLIC_PORT"; fi
else
  if [ "$PUBLIC_PORT" = 80 ]; then URL_BASE="http://$HOST"; else URL_BASE="http://$HOST:$PUBLIC_PORT"; fi
fi
RELAY_ARGS="$RELAY_DIR/relay.mjs --token-file $TOKEN_FILE --agent-port $AGENT_PORT --http-port $BIND_HOST:$HTTP_PORT --prefix /__t --public-url $URL_BASE"
if [ "$VISITOR_TLS" = 1 ]; then
  # Public TLS on all interfaces; the plain listener stays on loopback (health
  # checks, and nothing else needs it).
  RELAY_ARGS="$RELAY_ARGS --tls-port 0.0.0.0:$PUBLIC_PORT"
fi
if [ -n "$TLS_CERT" ] && { [ "$VISITOR_TLS" = 1 ] || [ "$AGENT_TLS" = 1 ]; }; then
  RELAY_ARGS="$RELAY_ARGS --tls-cert $TLS_CERT --tls-key $TLS_KEY"
fi

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
  # enable --now does nothing to a running unit, so a re-run with new flags would
  # keep the old process. Restart instead.
  systemctl restart "$SERVICE"
  sleep 1
  if ! systemctl is-active --quiet "$SERVICE"; then
    journalctl -u "$SERVICE" -n 15 --no-pager || true
    die "$(t "the service did not start" "服务启动失败")"
  fi
  ok "$SERVICE $(t "running and enabled" "运行中，已开机自启")"
else
  ok "$(t "not a systemd host: start it from the printed command" "非 systemd 环境：按末尾命令前台启动")"
fi

write_nginx() {
  local target="$NGINX_CONF_DIR/dsh-relay.conf"
  local tls=""
  if [ "$SCHEME" = https ]; then
    tls="    ssl_certificate     $TLS_CERT;
    ssl_certificate_key $TLS_KEY;
    http2 on;"
  fi
  cat > "$target" <<NGINX_EOF
# dsh-remote-portal — public entry for the tunnel (generated by deploy-relay.sh).
# Only /__t/ is forwarded; nothing else on this host is touched.
map \$http_upgrade \$dsh_relay_upgrade {
    default upgrade;
    ""      close;
}

server {
    listen $PUBLIC_PORT$([ "$SCHEME" = https ] && echo " ssl");
    server_name $HOST;
$tls

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

    # Everything else on this host answers 404 instead of falling through to the
    # default site.
    location / { return 404; }
}
NGINX_EOF
  if [ -n "$NGINX_RUN" ]; then
    if docker exec "$NGINX_RUN" nginx -t >/tmp/nginx-t.log 2>&1; then
      docker exec "$NGINX_RUN" nginx -s reload; ok "nginx ($NGINX_RUN) $(t "reloaded" "已重载")"
    else
      rm -f "$target"; tail -3 /tmp/nginx-t.log; die "$(t "nginx rejected the config; removed it, nothing reloaded" "nginx 校验失败，已删除配置")"
    fi
  elif command -v nginx >/dev/null 2>&1; then
    if nginx -t >/tmp/nginx-t.log 2>&1; then nginx -s reload; ok "nginx $(t "reloaded" "已重载")"
    else rm -f "$target"; tail -3 /tmp/nginx-t.log; die "$(t "nginx rejected the config; removed it" "nginx 校验失败，已删除配置")"; fi
  else
    warn "$(t "wrote $target but found no nginx to reload" "已写入 $target，但没找到可重载的 nginx")"
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
    ok "Caddy $(t "site installed and reloaded" "站点已安装并重载")"
  else
    rm -f "$site_dir/dsh-relay.caddy"; tail -3 /tmp/caddy-t.log; die "Caddy $(t "rejected the config; rolled back" "校验失败，已回滚")"
  fi
}

case "$PROXY_MODE" in
  nginx) write_nginx ;;
  caddy) write_caddy ;;
  none)
    if [ "$VISITOR_TLS" = 1 ]; then
      ok "$(t "the relay terminates TLS on the public port" "relay 在对外端口终止 TLS") ($PUBLIC_PORT)"
    else
      ok "$(t "the relay serves the public port directly" "relay 直接对外监听") ($PUBLIC_PORT)"
    fi
    # A block left over from a previous proxy-mode install would keep handling this
    # host (and serve the default site on /). Remove it and reload.
    stale="$NGINX_CONF_DIR/dsh-relay.conf"
    if [ -n "$NGINX_CONF_DIR" ] && [ -f "$stale" ]; then
      rm -f "$stale"
      if [ -n "$NGINX_RUN" ]; then docker exec "$NGINX_RUN" nginx -s reload >/dev/null 2>&1 || true
      elif command -v nginx >/dev/null 2>&1; then nginx -s reload >/dev/null 2>&1 || true; fi
      ok "$(t "removed the previous proxy block" "已移除上次的反代站点")"
    fi
    ;;
esac

# Remember the answers so the next run offers the same thing.
mkdir -p "$STATE_DIR" 2>/dev/null || true
cat > "$CONF_FILE" <<CONF_EOF
HOST=$HOST
SCHEME=$SCHEME
VISIT_MODE=$VISIT_MODE
VISITOR_TLS=$VISITOR_TLS
AGENT_TLS=$AGENT_TLS
AGENT_PORT=$AGENT_PORT
HTTP_PORT=$HTTP_PORT
PUBLIC_PORT=$PUBLIC_PORT
PROXY_MODE=$PROXY_MODE
CONF_EOF
chmod 644 "$CONF_FILE" 2>/dev/null || true
[ "$HAVE_SYSTEMD" = 1 ] && chown dsh-relay:dsh-relay "$CONF_FILE" 2>/dev/null || true

install_drp

# ── 6. verify and hand over ─────────────────────────────────────────────────
say "6/6 $(t "Checking" "自检")"
sleep 1
if curl -fsS --max-time 4 "http://127.0.0.1:$HTTP_PORT/__relay/health" >/dev/null 2>&1; then
  ok "$(t "relay answers on 127.0.0.1:$HTTP_PORT" "relay 健康检查通过")"
else
  warn "$(t "health check failed; see: drp log" "健康检查未通过；查看：drp log")"
fi

TUNNEL_ID=$(node -e 'const c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(process.argv[1]).digest("base64url").slice(0,12))' "$TOKEN")
AGENT_SCHEME=$([ "$AGENT_TLS" = 1 ] && echo tls || echo tcp)

printf '\n────────────────────────────────────────────────────────────────────────\n'
printf '%s\n' "$(t "Paste these into dsh → sidebar 远程访问 → 公网访问:" "把下面两行填进 dsh → 侧栏「远程访问」→ 公网访问：")"
printf '\n  %s  %s://%s:%s\n' "$(t "Relay endpoint " "中转服务器   ")" "$AGENT_SCHEME" "$HOST" "$AGENT_PORT"
printf '  %s  %s\n' "$(t "Tunnel token   " "隧道令牌     ")" "$TOKEN"
if [ "$AGENT_SCHEME" = tls ]; then
  printf '  %s\n' "$(t "also tick \"trust a self-signed certificate\" in the panel" "同时勾选「信任自签名证书」")"
fi
printf '\n%s\n\n  %s/__t/%s/\n' "$(t "Public URL once connected:" "连接成功后的公网地址：")" "$URL_BASE" "$TUNNEL_ID"

printf '\n%s\n\n  %s/tcp   ← %s\n  %s/tcp   ← %s\n' \
  "$(t "Open these in your cloud firewall, or nothing outside can connect:" "还需在云安全组/防火墙放行这两个端口：")" \
  "$AGENT_PORT" "$(t "the dsh host dials out" "家里的 dsh 拨出")" \
  "$PUBLIC_PORT" "$(t "visitors" "访客入口")"

printf '\n%s\n' "$(t "Manage it later with:" "以后用这条命令管理：")"
printf '  drp            # %s\n' "$(t "status" "状态")"
printf '  drp url        # %s\n' "$(t "public URL" "公网地址")"
printf '  drp token      # %s\n' "$(t "tunnel token" "隧道令牌")"
printf '  drp restart    # %s\n' "$(t "restart" "重启")"
printf '  drp log -f     # %s\n' "$(t "follow the log" "跟踪日志")"
printf '\n%s sudo ./deploy-relay.sh --uninstall\n' "$(t "Uninstall:" "卸载：")"
