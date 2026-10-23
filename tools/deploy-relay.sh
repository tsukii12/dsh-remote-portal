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

SELF_VERSION="0.6.0"

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
hi()   { printf '\033[36m%s\033[0m' "$*"; }   # addresses, URLs
key()  { printf '\033[33m%s\033[0m' "$*"; }   # tokens
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
  if command -v dig >/dev/null 2>&1; then
    out=$(dig +short +time=3 +tries=1 A "$name" @1.1.1.1 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    if [ -z "$out" ]; then
      out=$(dig +short +time=3 +tries=1 A "$name" @8.8.8.8 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    fi
  fi
  if [ -z "$out" ] && command -v curl >/dev/null 2>&1; then
    out=$(curl -fsS --max-time 5 -H 'accept: application/dns-json' \
      "https://cloudflare-dns.com/dns-query?name=$name&type=A" 2>/dev/null \
      | tr ',' '\n' | grep -o '"data":"[0-9.]*"' | head -n 1 | sed -e 's/.*:"//' -e 's/"//')
  fi
  if [ -z "$out" ] && command -v getent >/dev/null 2>&1; then
    out=$(getent ahostsv4 "$name" 2>/dev/null | awk 'NR==1{print $1}')
  fi
  if [ -z "$out" ] && command -v nslookup >/dev/null 2>&1; then
    out=$(nslookup "$name" 2>/dev/null | awk '/^Address:[ ]*[0-9]/{print $2; exit}')
  fi
  printf '%s' "$out"
}

choose_dns_mode() { # sets ACME_MODE (and CF_Token for Cloudflare)
  printf '\n  %s\n' "$(t "How should DNS be validated?" "DNS 怎么验证？")"
  printf '    1) %s\n' "$(t "Cloudflare API token (renews itself)" "Cloudflare API 令牌（可自动续期）")"
  printf '    2) %s\n' "$(t "Manual TXT record (any provider; renewal repeats this step)" "手工添加 TXT 记录（任意服务商；续期时需重复一次）")"
  dns_pick=$(ask "$(t "Choose" "选择")" "1")
  if [ "$dns_pick" = 1 ]; then
    CF_TOKEN=$(ask "$(t "Cloudflare API token (Zone:DNS:Edit)" "Cloudflare API 令牌（需 Zone:DNS:Edit）")" "")
    [ -n "$CF_TOKEN" ] || die "$(t "a token is required for the Cloudflare check" "Cloudflare 校验需要令牌")"
    export CF_Token="$CF_TOKEN"
    ACME_MODE=dns-cf
  else
    ACME_MODE=dns-manual
  fi
  CERT_SOURCE=acme
  VISITOR_TLS=1
}

# One answer for a deliverable that may be a file or a block of text: a provider hands
# out PEM text (Cloudflare Origin CA, a cloud console), and asking people to scp it in
# first is a step they skip.
ask_pem() { # ask_pem <label> <marker>
  local label=$1 marker=$2 first abs tmp
  if ! can_ask; then
    printf '%s' ""
    return 0
  fi
  printf '  %s\n' "$(t "$label — paste the PEM and finish with a line reading END, or type the absolute path of the file" "$label —— 粘贴 PEM 内容（最后单独一行输入 END 结束），或直接填文件的绝对路径")" >/dev/tty
  printf '  > ' >/dev/tty
  if ! read -r first </dev/tty; then
    printf '\n' >/dev/tty
    die "$(t "input closed; nothing was changed" "输入已结束，未做任何修改")"
  fi
  case "$first" in
    "-----BEGIN"*)
      tmp=$(mktemp)
      printf '%s\n' "$first" > "$tmp"
      while IFS= read -r line </dev/tty; do
        [ "$line" = "END" ] && break
        printf '%s\n' "$line" >> "$tmp"
      done
      grep -q "$marker" "$tmp" || die "$(t "that block is not what this field expects" "粘贴的内容与这里要求的类型不符")"
      printf '%s' "$tmp"
      ;;
    "")
      printf '%s' ""
      ;;
    *)
      case "$first" in "~/"*) first="$HOME/${first#\~/}" ;; esac
      printf '%s' "$first"
      ;;
  esac
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
      info "$(t "if the record was changed recently, wait for the TTL (300 s) and check again" "如果刚改过解析，等 TTL（300 秒）走完再重新检测")" >&2
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
  SAVED_CERT_SOURCE=${CERT_SOURCE:-}
  SAVED_ACME_MODE=${ACME_MODE:-}
  SAVED_PUBLIC_PORT=${PUBLIC_PORT:-}
  ADVERTISED_URL=${ADVERTISED_URL:-}
  SAVED_CERT_FILE=${CERT_FILE:-}
  SAVED_KEY_FILE=${KEY_FILE:-}
fi
SAVED_PROXY=${SAVED_PROXY:-}
OWN_PORTS=""
if [ -f "$UNIT" ]; then
  OWN_PORTS=$(grep -oE '\-\-(agent|http|tls)-port [^ ]+' "$UNIT" 2>/dev/null | awk '{print $2}' | sed 's/.*://' | tr '\n' ' ' || true)
fi

install_drp() {
  cat > "$BIN" <<'DRP_EOF'
#!/bin/sh
# drp — manage the dsh-remote-portal relay.
#   drp                     status (default)
#   drp url                 public URL to open
#   drp token               tunnel token (the value to paste into dsh)
#   drp start|stop|restart
#   drp log [-f]
#   drp config              show the saved answers
#   drp config K=V [K=V…]   change them and reinstall the unit
#   drp uninstall           remove the service, /opt/dsh-relay and this command
#   drp help
CONF=/var/lib/dsh-relay/deploy.conf
TOKEN_FILE=/var/lib/dsh-relay/token
SERVICE=dsh-relay
set -u

# Colour only when someone is looking at a terminal.
if [ -t 1 ]; then
  R=$(printf '\033[0m'); B=$(printf '\033[1m')
  RED=$(printf '\033[31m'); GRN=$(printf '\033[32m')
  YEL=$(printf '\033[33m'); CYA=$(printf '\033[36m'); GRY=$(printf '\033[2m')
else
  R=; B=; RED=; GRN=; YEL=; CYA=; GRY=
fi
green() { printf '%s%s%s' "$GRN" "$1" "$R"; }
red() { printf '%s%s%s' "$RED" "$1" "$R"; }
cyan() { printf '%s%s%s' "$CYA" "$1" "$R"; }
yellow() { printf '%s%s%s' "$YEL" "$1" "$R"; }
grey() { printf '%s%s%s' "$GRY" "$1" "$R"; }

# Bytes as something a person can read.
human() {
  awk -v n="${1:-0}" 'BEGIN{
    split("B KiB MiB GiB TiB", u, " "); i = 1
    while (n >= 1024 && i < 5) { n /= 1024; i++ }
    if (i == 1) printf "%d %s", n, u[i]; else printf "%.1f %s", n, u[i]
  }'
}

load() {
  [ -r "$CONF" ] && . "$CONF"
  HOST=${HOST:-127.0.0.1}; AGENT_PORT=${AGENT_PORT:-9443}; HTTP_PORT=${HTTP_PORT:-8080}
  PUBLIC_PORT=${PUBLIC_PORT:-80}; PROXY_MODE=${PROXY_MODE:-none}
  SCHEME=${SCHEME:-http}; VISITOR_TLS=${VISITOR_TLS:-0}; AGENT_TLS=${AGENT_TLS:-1}
  CERT_SOURCE=${CERT_SOURCE:-self}
  SCRIPT=${SCRIPT:-}
}
health() { curl -fsS --max-time 3 "http://127.0.0.1:${HTTP_PORT:-8080}/__relay/health" 2>/dev/null; }
token() { [ -r "$TOKEN_FILE" ] && head -n 1 "$TOKEN_FILE"; }
tunnel_id() { tid=$(token); [ -n "$tid" ] && node -e 'const c=require("node:crypto");process.stdout.write(c.createHash("sha256").update(process.argv[1]).digest("base64url").slice(0,12))' "$tid"; }
url_base() {
  if [ -n "${ADVERTISED_URL:-}" ]; then printf '%s' "$ADVERTISED_URL"; return 0; fi
  if [ "${SCHEME:-http}" = https ]; then
    case "${PUBLIC_PORT:-443}" in 443) printf 'https://%s' "$HOST" ;; *) printf 'https://%s:%s' "$HOST" "$PUBLIC_PORT" ;; esac
  else
    case "${PUBLIC_PORT:-80}" in 80) printf 'http://%s' "$HOST" ;; *) printf 'http://%s:%s' "$HOST" "$PUBLIC_PORT" ;; esac
  fi
}
endpoint() { if [ "${AGENT_TLS:-1}" = 1 ]; then printf 'tls://%s:%s' "$HOST" "$AGENT_PORT"; else printf 'tcp://%s:%s' "$HOST" "$AGENT_PORT"; fi; }

service_state() {
  if systemctl is-active "$SERVICE" >/dev/null 2>&1; then
    if [ "$(systemctl is-enabled "$SERVICE" 2>/dev/null || echo no)" = enabled ]; then
      printf '%s · autostart on' "$(green running)"
    else
      printf '%s · autostart off' "$(green running)"
    fi
  else
    printf '%s' "$(red stopped)"
  fi
}

uptime_line() {
  started=$(systemctl show -p ActiveEnterTimestamp --value "$SERVICE" 2>/dev/null || true)
  [ -n "$started" ] || return 0
  since=$(date -d "$started" +%s 2>/dev/null) || return 0
  [ -n "$since" ] || return 0
  awk -v d=$(( $(date +%s) - since )) 'BEGIN{
    if (d < 0) exit
    if (d >= 86400) printf "%dd %dh", d/86400, (d%86400)/3600
    else if (d >= 3600) printf "%dh %dm", d/3600, (d%3600)/60
    else if (d >= 60) printf "%dm %ds", d/60, d%60
    else printf "%ds", d
  }'
}

case "${1:-status}" in
  status)
    load
    printf 'service     %s\n' "$(service_state)"
    up=$(uptime_line); [ -n "${up:-}" ] && printf 'uptime      %s\n' "$up"
    printf 'agent port  %s %s\n' "$(cyan "$HOST:$AGENT_PORT")" "$([ "${AGENT_TLS:-1}" = 1 ] && echo '(TLS)' || echo '(plain)')"
    if [ "$PROXY_MODE" = none ]; then
      if [ "${VISITOR_TLS:-0}" = 1 ]; then
        case "${CERT_SOURCE:-self}" in
          acme) printf 'visitor     %s (TLS, CA certificate)\n' "$(cyan "0.0.0.0:$PUBLIC_PORT")" ;;
          user) printf 'visitor     %s (TLS, your certificate)\n' "$(cyan "0.0.0.0:$PUBLIC_PORT")" ;;
          *) printf 'visitor     %s (TLS, self-signed)\n' "$(cyan "0.0.0.0:$PUBLIC_PORT")" ;;
        esac
      else
        printf 'visitor     %s %s\n' "$(cyan "0.0.0.0:$PUBLIC_PORT")" "$(red '(plain, NOT encrypted)')"
      fi
    else
      printf 'visitor     %s -> 127.0.0.1:%s, public %s (%s)\n' "$PROXY_MODE" "$HTTP_PORT" "$PUBLIC_PORT" "$SCHEME"
    fi
    printf 'endpoint    %s\n' "$(cyan "$(endpoint)")"

    h=$(health)
    if [ -n "$h" ]; then
      printf 'relay       %s\n' "$(green reachable)"
      printf '%s' "$h" | node -e '
        let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
          const paint=(code,v)=>process.stdout.isTTY?`\u001b[${code}m${v}\u001b[0m`:v;
          let j;try{j=JSON.parse(s)}catch(e){console.log("tunnel      unreadable response");return}
          const t=j.tunnels[0];
          if(!t){console.log("tunnel      "+paint(33,"none registered"));return}
          const st=t.connected?paint(32,"connected"):paint(31,"offline");
          const bits=[st,`${t.streams} stream${t.streams===1?"":"s"}`];
          if(t.reconnects) bits.push(`${t.reconnects} reconnect${t.reconnects===1?"":"s"}`);
          console.log("tunnel      "+bits.join(" · "));
          if(t.reconnects&&t.lastDropAt){
            const ago=Math.max(0,Math.round((Date.now()-t.lastDropAt)/1000));
            const human=ago>=3600?`${Math.floor(ago/3600)}h ago`:ago>=60?`${Math.floor(ago/60)}m ago`:`${ago}s ago`;
            console.log("last drop   "+human+(t.lastDropReason?` (${t.lastDropReason})`:""));
          }
          const b=v=>{const u=["B","KiB","MiB","GiB","TiB"];let i=0;while(v>=1024&&i<4){v/=1024;i++}return (i===0?`${v} ${u[0]}`:`${v.toFixed(1)} ${u[i]}`)};
          const reqs = t.requests ?? j.stats.requests ?? 0;
          const clients = t.clients ?? 0;
          console.log(`traffic     in ${b(j.stats.bytesIn)} · out ${b(j.stats.bytesOut)} · ${reqs} requests · ${clients} client${clients===1?"":"s"}`);
          if(t.agentVersion) console.log("agent       "+t.agentVersion);
        })'
    else
      printf 'relay       %s\n' "$(red "NOT reachable on 127.0.0.1:$HTTP_PORT")"
    fi

    printf 'public      %s\n' "$(cyan "$(url_base)/__t/$(tunnel_id)/")"
    if [ "${AGENT_TLS:-1}" = 1 ]; then
      printf 'note        self-signed certificate: tick "trust" in the dsh panel\n'
    fi
    if [ "${SCHEME:-http}" = http ]; then
      printf 'warn        visitors connect over plain HTTP: the password and the whole session are readable on the way\n'
    fi
    ;;

  url) load; printf '%s/__t/%s/\n' "$(url_base)" "$(tunnel_id)" ;;
  token) token; echo ;;
  start) systemctl start "$SERVICE" && echo started ;;
  stop) systemctl stop "$SERVICE" && echo stopped ;;
  restart) systemctl restart "$SERVICE" && echo restarted ;;
  log) if [ "${2:-}" = "-f" ]; then journalctl -u "$SERVICE" -f; else journalctl -u "$SERVICE" -n "${2:-40}" --no-pager; fi ;;

  config)
    shift
    if [ $# -eq 0 ]; then
      load
      [ -r "$CONF" ] && cat "$CONF" || echo "no saved configuration"
      exit 0
    fi
    load
    changed=0
    for pair in "$@"; do
      k=${pair%%=*}; v=${pair#*=}
      case "$k" in
        HOST|SCHEME|VISIT_MODE|VISITOR_TLS|AGENT_TLS|AGENT_PORT|HTTP_PORT|PUBLIC_PORT|PROXY_MODE) ;;
        *) printf 'unknown key: %s\n  allowed: HOST SCHEME VISIT_MODE VISITOR_TLS AGENT_TLS AGENT_PORT HTTP_PORT PUBLIC_PORT PROXY_MODE\n' "$k" >&2; exit 2 ;;
      esac
      [ "$pair" = "$k" ] && { printf 'expected K=V, got %s\n' "$pair" >&2; exit 2; }
      if grep -q "^$k=" "$CONF" 2>/dev/null; then
        sed -i "s|^$k=.*|$k=$v|" "$CONF"
      else
        printf '%s=%s\n' "$k" "$v" >> "$CONF"
      fi
      printf '  %s = %s\n' "$k" "$(cyan "$v")"
      changed=1
    done
    [ "$changed" = 1 ] || exit 0
    # Ports and certificates live in the unit's command line, so editing the file is
    # not enough: reinstall from the saved answers.
    if [ -n "${SCRIPT:-}" ] && [ -r "$SCRIPT" ]; then
      echo "reinstalling with the new settings"
      bash "$SCRIPT" --yes
    else
      echo "re-run the installer to apply these (the saved answers are now defaults)"
    fi
    ;;

  uninstall)
    load
    if [ -n "${SCRIPT:-}" ] && [ -r "$SCRIPT" ]; then
      printf 'removing the relay via %s\n' "$SCRIPT"
      exec bash "$SCRIPT" --uninstall
    fi
    # No installer on disk (older release): do the same steps by hand.
    systemctl disable --now "$SERVICE" >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/dsh-relay.service
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf /opt/dsh-relay /usr/local/bin/drp
    printf 'removed the service, /opt/dsh-relay and drp\n'
    printf 'kept /var/lib/dsh-relay (token and certificates), remove it yourself if you want a clean slate\n'
    ;;

  help|--help|-h) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//' ;;
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
node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }

install_node() {
  local arch base ver tarball dir
  case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    armv7l) arch=armv7l ;;
    *) die "$(t "unsupported architecture: $(uname -m)" "不支持的架构：$(uname -m)")" ;;
  esac

  local bases="https://nodejs.org/dist https://npmmirror.com/mirrors/node https://cdn.npmmirror.com/binaries/node"
  ver=""
  for base in $bases; do
    # index.json is pretty-printed, so squash it and split per release before
    # asking for the ones flagged as LTS. A Current release works too, but it needs
    # newer system libraries and a plain cloud image usually lacks them.
    local index
    index=$(curl -fsSL --max-time 25 "$base/index.json" 2>/dev/null | tr -d '\n' | sed 's/},/}\n/g') || index=""
    [ -n "$index" ] || continue
    ver=$(printf '%s' "$index" | grep -F '"lts":"' \
      | grep -o '"version":"v[0-9]*\.[0-9]*\.[0-9]*"' \
      | sed -e 's/.*"v//' -e 's/"//' | sort -V | tail -n 1) || true
    if [ -n "$ver" ]; then
      ok "$(t "latest LTS from" "最新 LTS 来自") $(printf '%s' "$base" | sed -e 's#https\?://##' -e 's#/.*##') -> v$ver"
      break
    fi
  done
  [ -n "$ver" ] || die "$(t "could not reach nodejs.org or its mirrors" "无法访问 nodejs.org 或镜像")"

  tarball="node-v$ver-linux-$arch.tar.gz"
  dir=/usr/local/lib/nodejs/node-v$ver-linux-$arch
  install -d -m 0755 /usr/local/lib/nodejs
  local tmp got=""
  tmp=$(mktemp -d)
  for base in $bases; do
    if curl -fsSL --max-time 180 "$base/v$ver/$tarball" -o "$tmp/$tarball" 2>/dev/null; then got=$base; break; fi
  done
  [ -n "$got" ] || die "$(t "could not download Node $ver" "下载 Node $ver 失败")"
  tar -xzf "$tmp/$tarball" -C "$tmp" || die "$(t "could not unpack Node" "解压 Node 失败")"
  rm -rf "$dir"
  mv "$tmp/node-v$ver-linux-$arch" "$dir"
  ln -sf "$dir/bin/node" /usr/local/bin/node
  ln -sf "$dir/bin/npm" /usr/local/bin/npm
  ln -sf "$dir/bin/npx" /usr/local/bin/npx
  rm -rf "$tmp"
  hash -r 2>/dev/null || true
  command -v node >/dev/null 2>&1 || die "$(t "Node was unpacked but is not on PATH" "Node 已解压但不在 PATH 上")"

  # Verify by running it. A slim image can have the file and still fail to load it
  # (libatomic.so.1 is the usual one), which used to be reported as success.
  if ! node -v >/dev/null 2>&1; then
    local missing
    missing=$(node -v 2>&1 | sed -n 's/.*\(lib[a-z0-9._+-]*\.so[^ :]*\).*/\1/p' | head -n 1)
    warn "$(t "the runtime cannot load yet" "运行时还不能加载")${missing:+ ($missing)}"
    if command -v apt-get >/dev/null 2>&1; then
      apt-get install -y libatomic1 >/dev/null 2>&1 || apt-get update -qq >/dev/null 2>&1 && apt-get install -y libatomic1 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1; then
      dnf install -y libatomic >/dev/null 2>&1 || true
    elif command -v yum >/dev/null 2>&1; then
      yum install -y libatomic >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache libatomic >/dev/null 2>&1 || true
    fi
    hash -r 2>/dev/null || true
    node -v >/dev/null 2>&1 || die "$(t "Node was installed but does not start; missing libraries on this image. Install the matching libatomic/glibc and run again." "Node 已安装但无法启动：该系统缺少所需库（通常是 libatomic/glibc）。装好后重新运行。")"
  fi
  ok "$(t "installed" "已安装") node $(node -v) → $(command -v node)"
}

# A fresh cloud host has no Node, and stopping there made the one-liner look broken.
# The runtime is installed from the official tarball (with the mirrors used in
# China): nothing is added to apt or yum, and everything lands in /usr/local.
ensure_node() {
  if command -v node >/dev/null 2>&1 && [ "$(node_major)" -ge 20 ]; then
    ok "node $(node -v) → $(command -v node)"
    return 0
  fi
  if command -v node >/dev/null 2>&1; then
    warn "$(t "Node $(node -v) is too old (need 20+)" "Node $(node -v) 版本过旧（需要 20+）")"
  else
    warn "$(t "Node 20+ is not installed" "未安装 Node 20+")"
  fi
  info "$(t "it is installed as a self-contained tarball: nothing is added to apt/yum, the files live in /usr/local/lib/nodejs" "将以独立运行时安装：不动 apt/yum，文件放在 /usr/local/lib/nodejs")"
  if ask_yn "$(t "Install Node 20+ now" "现在安装 Node 20+")" y; then
    install_node
  else
    die "$(t "Node 20+ is required: https://nodejs.org" "需要 Node 20+：https://nodejs.org")"
  fi
}

if can_ask && [ "$ASSUME_YES" = 0 ]; then
  printf '\n  Language / 语言 (en|zh) [en]: ' >/dev/tty
  if ! read -r LANG_PICK < /dev/tty; then
    printf '\n' >/dev/tty
    die "$(t "input closed; nothing was changed" "输入已结束，未做任何修改")"
  fi
  case "$LANG_PICK" in zh|ZH|Zh|中文) LANG_MODE=zh ;; *) LANG_MODE=en ;; esac
fi

say "1/6 $(t "Checking the host" "检查环境")"
ensure_node
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

if [ ! -f "$PORTAL_DIR/relay.mjs" ] && [ -f "$STATE_DIR/relay.mjs" ]; then
  PORTAL_DIR=$STATE_DIR
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
# An operator-supplied address wins: PUBLIC_IP=203.0.113.10 ./deploy-relay.sh
PUBLIC_IP=${PUBLIC_IP:-}
if [ -n "$PUBLIC_IP" ]; then
  ok "$(t "public IP" "公网 IP"): $PUBLIC_IP ($(t "from the environment" "来自环境变量"))"
else
for u in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
  PUBLIC_IP=$(curl -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$PUBLIC_IP" ] && break
done
[ -n "$PUBLIC_IP" ] || PUBLIC_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [ -n "$PUBLIC_IP" ]; then ok "$(t "public IP" "公网 IP"): $PUBLIC_IP"; else warn "$(t "could not detect the public IP" "未能探测公网 IP")"; fi
fi

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
  # Reuse what was chosen before: a saved domain must not decay into an IP on an
  # unattended run, which would also invalidate the certificate.
  if [ "$ASSUME_YES" = 1 ] && [ -n "${HOST:-}" ]; then
    case "$HOST" in
      *[!0-9.]*) IS_DOMAIN=1 ;;
      *) IS_DOMAIN=0 ;;
    esac
  else
    DOMAIN_TARGET=$(ask "$(t "HTTPS with a domain (no browser warning) or with the IP (self-signed, warning once)? [domain/ip]" "HTTPS 用域名（浏览器不报警）还是用 IP（自签，会警告一次）？[domain/ip]")" "ip")
    IS_DOMAIN=0
    case "$(printf '%s' "$DOMAIN_TARGET" | tr 'A-Z' 'a-z')" in
      d*|域名*) IS_DOMAIN=1 ;;
    esac
  fi

  if [ "$IS_DOMAIN" = 1 ]; then
    HOST=$(pick_domain)
    [ -n "$HOST" ] || die "$(t "a domain is required for this mode" "这个模式需要填域名")"
  else
    HOST=${HOST:-$PUBLIC_IP}
    HOST=$(ask "$(t "IP address" "IP 地址")" "$HOST")
  fi
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
  elif [ "${DOMAIN_FILTERED:-0}" = 1 ]; then
    warn "$(t "picking a self-signed certificate instead: the HTTP check cannot pass" "改用自签证书：HTTP 校验无法通过")"
    VISITOR_TLS=1
    CERT_SOURCE=self
  elif [ "${IS_DOMAIN:-0}" = 1 ] && [ "$ASSUME_YES" = 1 ]; then
    # Unattended: reuse what was chosen last time; never reach out to a CA on a
    # re-run the operator did not ask for.
    case "${SAVED_CERT_SOURCE:-self}" in
      acme) VISITOR_TLS=1; CERT_SOURCE=acme; ACME_MODE=${SAVED_ACME_MODE:-http}; ACME_EMAIL=${ACME_EMAIL:-admin@$HOST} ;;
      user) VISITOR_TLS=1; CERT_SOURCE=user; USER_CERT=$SAVED_CERT_FILE; USER_KEY=$SAVED_KEY_FILE ;;
      *) VISITOR_TLS=1; CERT_SOURCE=self ;;
    esac
  elif [ "${IS_DOMAIN:-0}" = 1 ]; then
    printf '\n  %s\n' "$(t "How should the certificate be provided?" "证书怎么来？")"
    printf '    1) %s\n' "$(t "Automatic, HTTP check on port 80 (blocked on unfiled domains)" "自动申请，HTTP 校验走 80 端口（未备案域名会被拦）")"
    printf '    2) %s\n' "$(t "Automatic, DNS check (works when 80/443 are blocked)" "自动申请，DNS 校验（80/443 被拦时可用）")"
    printf '    3) %s\n' "$(t "I already have a certificate for this domain (fullchain + key)" "我已经有这个域名的证书（fullchain + key）")"
    printf '    4) %s\n' "$(t "Generate a self-signed one (the browser will warn)" "生成自签证书（浏览器会提示不安全）")"
    # Where 80 is filtered the HTTP check cannot pass, so lead with DNS.
    if [ "${DOMAIN_FILTERED:-0}" = 1 ]; then cert_default=2; else cert_default=1; fi
    cert_pick=$(ask "$(t "Choose" "选择")" "$cert_default")
    case "$cert_pick" in
      2) choose_dns_mode ;;
      3)
        # With a proxy, it terminates TLS; without one, the relay does — either way
        # the certificate is the operator's.
        if [ "$DETECTED_PROXY" = nginx ]; then PROXY_MODE=nginx; else VISITOR_TLS=1; fi
        CERT_SOURCE=user
        ;;
      4) VISITOR_TLS=1; CERT_SOURCE=self ;;
      *) VISITOR_TLS=1; CERT_SOURCE=acme; ACME_MODE=http ;;
    esac
  else
    # An IP cannot have a public certificate, so there is nothing to ask.
    VISITOR_TLS=1
    CERT_SOURCE=self
  fi
fi

# A domain that answers on the bare IP but not on its own name is filtered on
# 80/443 (ICP filing). Say so now instead of letting a certificate attempt hang.
DOMAIN_FILTERED=0
if [ "${IS_DOMAIN:-0}" = 1 ]; then
  code_domain=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$HOST/" 2>/dev/null || echo 000)
  code_ip=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${PUBLIC_IP:-127.0.0.1}/" 2>/dev/null || echo 000)
  case "$code_domain" in
    403|000|451) [ "$code_ip" != "$code_domain" ] && DOMAIN_FILTERED=1 ;;
  esac
  if [ "$DOMAIN_FILTERED" = 1 ]; then
    warn "$(t "this domain is blocked on ports 80/443 from here (no ICP filing): http://$HOST → $code_domain, http://$PUBLIC_IP → $code_ip" "这个域名在本机被 80/443 拦截（通常是没有 ICP 备案）：http://$HOST → $code_domain，http://$PUBLIC_IP → $code_ip")"
    info "$(t "consequences: an automatic certificate cannot pass the HTTP check, and a browser cannot reach the domain on 443 either" "后果：自动申请证书的 HTTP 校验无法通过；浏览器也无法通过 443 访问这个域名")"
    info "$(t "options: use another port (e.g. 8443, open it in the cloud firewall), use the IP, or complete the filing" "可选：换一个端口（如 8443，需在云安全组放行）、直接用 IP、或完成备案")"
    ns=$(curl -fsS --max-time 5 -H 'accept: application/dns-json' "https://cloudflare-dns.com/dns-query?name=$HOST&type=NS" 2>/dev/null || true)
    case "$ns" in
      *cloudflare*)
        info "$(t "this domain is on Cloudflare: proxy it and the browser never touches your port" "这个域名在 Cloudflare 上：开启代理后，浏览器根本不会直连你的端口")"
        info "$(t "1) Cloudflare DNS: A record → this IP, proxy ON (orange cloud)" "1) Cloudflare DNS：A 记录指向本机 IP，开启代理（橙色云）")"
        info "$(t "2) SSL/TLS mode: Full (not Full strict), since the origin is self-signed" "2) SSL/TLS 模式设为 Full（不要 Full strict），因为回源是自签证书")"
        info "$(t "3) serve this relay on 8443 — Cloudflare proxies HTTPS on that port" "3) 把中转跑在 8443 —— Cloudflare 支持该端口的 HTTPS 回源")"
        info "$(t "4) open 8443 in the cloud firewall" "4) 在云安全组放行 8443")"
        ;;
    esac
  fi
fi

if [ "$SCHEME" = https ] && [ "$VISITOR_TLS" = 1 ]; then
  # 80/443 are filtered for an unfiled domain, so a domain setup that has to work
  # today belongs on another port.
  if [ "${IS_DOMAIN:-0}" = 1 ] && [ "${DOMAIN_FILTERED:-0}" = 1 ]; then default_public=8443; else default_public=443; fi
elif [ "$SCHEME" = https ]; then
  default_public=443
elif [ "$PROXY_MODE" = nginx ]; then
  default_public=80
else
  default_public=10003
fi

PUBLIC_PORT=$(ask_port "$(t "Public port (open it in your cloud firewall)" "对外端口（需在云安全组放行）")" "${SAVED_PUBLIC_PORT:-$default_public}")
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

if [ "$SCHEME" = https ] && [ "${IS_DOMAIN:-0}" = 1 ] && [ "${DOMAIN_FILTERED:-0}" = 1 ]; then
  if ask_yn "$(t "Through Cloudflare (proxy on)? Visitors then reach https://$HOST and the edge comes back to port $PUBLIC_PORT" "是否经 Cloudflare 代理访问？这样访客访问 https://$HOST，由 CF 回源到 $PUBLIC_PORT 端口")" y; then
    ADVERTISED_URL="https://$HOST"
  fi
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
if [ "$CERT_SOURCE" = user ] && [ "$ASSUME_YES" = 1 ] && [ -n "${USER_CERT:-}" ]; then
  [ -r "$USER_CERT" ] && [ -r "${USER_KEY:-}" ] || die "$(t "the saved certificate pair is no longer readable: $USER_CERT" "保存的证书文件读不到了：$USER_CERT")"
  AGENT_TLS=1
elif [ "$CERT_SOURCE" = user ]; then
  USER_CERT=$(ask_pem "$(t "Certificate chain" "证书链")" "BEGIN CERTIFICATE")
  [ -n "$USER_CERT" ] || die "$(t "a certificate is required here: paste it, or give the path to fullchain.pem" "这里需要证书：粘贴内容，或填写 fullchain.pem 的路径")"
  USER_KEY=$(ask_pem "$(t "Private key" "私钥")" "PRIVATE KEY")
  [ -n "$USER_KEY" ] || die "$(t "a private key is required here: paste it, or give the path to privkey.pem" "这里需要私钥：粘贴内容，或填写 privkey.pem 的路径")"
  [ -r "$USER_CERT" ] || die "$(t "cannot read $USER_CERT" "读不到 $USER_CERT")"
  [ -r "$USER_KEY" ] || die "$(t "cannot read $USER_KEY" "读不到 $USER_KEY")"
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

if [ -f "$0" ] && [ -r "$0" ]; then
  install -m 0755 "$0" "$STATE_DIR/deploy-relay.sh" 2>/dev/null || true
fi
if [ -f "$PORTAL_DIR/relay.mjs" ]; then
  install -m 0644 "$PORTAL_DIR/relay.mjs" "$STATE_DIR/relay.mjs" 2>/dev/null || true
  PORTAL_DIR=$STATE_DIR
fi

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
if [ "$CERT_SOURCE" = self ]; then NEED_CERT=1; fi
if [ "$AGENT_TLS" = 1 ] && [ -z "$TLS_CERT" ]; then NEED_CERT=1; fi

acmesh_install() { # sets ACME_BIN / ACME_HOME, or dies
  if ! command -v curl >/dev/null 2>&1; then
    die "$(t "curl is required to fetch acme.sh" "需要 curl 才能获取 acme.sh")"
  fi
  # get.acme.sh is a 1 KB bootstrap, not acme.sh: the real script is ~300 KB, and
  # --install copies ./acme.sh from the working directory, so it has to run from the
  # directory holding the download.
  local bases="https://ghfast.top/https://raw.githubusercontent.com/acmesh-official/acme.sh/master https://gh-proxy.com/https://raw.githubusercontent.com/acmesh-official/acme.sh/master https://raw.githubusercontent.com/acmesh-official/acme.sh/master"
  local tmp got="" size
  tmp=$(mktemp -d)
  for base in $bases; do
    if curl -fsSL --max-time 40 "$base/acme.sh" -o "$tmp/acme.sh" 2>/dev/null; then
      size=$(wc -c < "$tmp/acme.sh" | tr -d ' ')
      if [ "${size:-0}" -gt 100000 ] && grep -q "acme.sh" "$tmp/acme.sh"; then got=$base; break; fi
    fi
  done
  [ -n "$got" ] || die "$(t "could not download acme.sh (all mirrors)" "无法下载 acme.sh（所有镜像都不通））")"

  if ! ( cd "$tmp" && sh ./acme.sh --install --nocron >/tmp/acme-install.log 2>&1 ); then
    tail -n 8 /tmp/acme-install.log
    die "$(t "acme.sh could not be installed" "acme.sh 安装失败")"
  fi
  ACME_HOME="$HOME/.acme.sh"
  ACME_BIN="$ACME_HOME/acme.sh"
  [ -x "$ACME_BIN" ] || die "$(t "acme.sh did not install itself" "acme.sh 没有安装成功")"
}

acme_install_cert() { # acme_install_cert <domain> <fullchain-out> <key-out>
  local domain=$1 earned=$2 ekey=$3
  if ! "$ACME_BIN" --home "$ACME_HOME" --install-cert -d "$domain" --ecc \
      --key-file "$ekey" --fullchain-file "$earned" \
      --reloadcmd "systemctl restart $SERVICE 2>/dev/null || true" >/tmp/acme-install.log 2>&1; then
    if [ -s "$earned" ] && [ -s "$ekey" ]; then
      warn "$(t "the certificate is in place, but acme.sh reported an error while installing it" "证书已就位，但 acme.sh 报告了一个错误")"
      tail -n 6 /tmp/acme-install.log
    else
      tail -n 12 /tmp/acme-install.log
      die "$(t "could not install the certificate" "证书安装失败")"
    fi
  fi
  chmod 600 "$ekey"; chmod 644 "$earned"
  [ "$HAVE_SYSTEMD" = 1 ] && chown -R dsh-relay:dsh-relay "$STATE_DIR" 2>/dev/null || true
}

acme_renewal_timer() {
  [ "$HAVE_SYSTEMD" = 1 ] || return 0
  # acme.sh was installed with --nocron, so its own cron entry point runs from a
  # timer instead. Twice a day is what acme.sh's crontab would have done.
  cat > /etc/systemd/system/dsh-relay-acme.service <<ACME_UNIT
[Unit]
Description=dsh-remote-portal certificate renewal (acme.sh)

[Service]
Type=oneshot
ExecStart=/bin/sh -c '"'"'$ACME_BIN' --home '$ACME_HOME' --cron >/var/log/dsh-relay-acme.log 2>&1'"'"'
ACME_UNIT
  cat > /etc/systemd/system/dsh-relay-acme.timer <<ACME_TIMER
[Unit]
Description=Daily dsh-remote-portal certificate renewal

[Timer]
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
ACME_TIMER
  systemctl daemon-reload
  systemctl enable --now dsh-relay-acme.timer >/dev/null 2>&1 || true
  ok "$(t "renewal timer installed" "已安装续期定时器") (dsh-relay-acme.timer)"
}

issue_cert_acme() { # issue_cert_acme <domain> [http|dns-cf|dns-manual]
  local domain=$1 mode=${2:-http} earned ekey challenge
  case "$mode" in
    dns-cf) challenge="--dns dns_cf" ;;
    dns-manual) challenge="--dns" ;;
    *) challenge="--standalone --httpport 80" ;;
  esac

  if [ "$mode" = http ] && ! port_free 80; then
    warn "$(t "port 80 is in use (often a web panel): the standalone HTTP check needs it to itself" "80 端口被占用（常见于面板/nginx）：独立模式必须独占它")"
    if [ "$ASSUME_YES" = 1 ]; then
      die "$(t "use the DNS option for this domain, or free port 80" "这个域名请改用 DNS 校验，或释放 80 端口")"
    fi
    if ask_yn "$(t "switch to the DNS check instead? (no port needed)" "改用 DNS 校验？它不需要任何端口")" y; then
      choose_dns_mode
      mode=$ACME_MODE
      case "$mode" in
        dns-cf) challenge="--dns dns_cf" ;;
        dns-manual) challenge="--dns" ;;
      esac
    else
      die "$(t "nothing to do without port 80" "没有 80 端口就无法继续")"
    fi
  fi

  acmesh_install

  CERT_DIR="$STATE_DIR/tls"
  install -d -m 0750 "$CERT_DIR"
  earned="$CERT_DIR/visitor-cert.pem"
  ekey="$CERT_DIR/visitor-key.pem"

  if [ "$mode" = dns-cf ]; then
    : > /tmp/acme-issue.log
    info "$(t "requesting a certificate for $domain (DNS-01 via Cloudflare)" "正在为 $domain 申请证书（DNS-01，走 Cloudflare）")"
    if ! "$ACME_BIN" --home "$ACME_HOME" --issue -d "$domain" --keylength ec-256 \
        --server letsencrypt $challenge >>/tmp/acme-issue.log 2>&1; then
      tail -n 14 /tmp/acme-issue.log
      die "$(t "Cloudflare validation failed; check the token's Zone:DNS:Edit permission" "Cloudflare 校验失败；检查令牌是否有 Zone:DNS:Edit 权限")"
    fi
  elif [ "$mode" = dns-manual ]; then
    local manual_flags="--server letsencrypt --yes-I-know-dns-manual-mode-enough-go-ahead-please"
    local certfile="$ACME_HOME/${domain}_ecc/${domain}.cer"
    if [ -s "$certfile" ] && openssl x509 -checkend 604800 -noout -in "$certfile" >/dev/null 2>&1; then
      info "$(t "the certificate on disk for $domain is still valid; reusing it" "$domain 的证书仍在有效期内，直接复用")"
    else
    can_ask || die "$(t "the manual DNS check needs a terminal: run the installer interactively" "手工 DNS 校验需要终端：请交互式运行安装脚本")"
    : > /tmp/acme-issue.log

    "$ACME_BIN" --home "$ACME_HOME" --issue -d "$domain" --keylength ec-256 \
      $manual_flags $challenge >>/tmp/acme-issue.log 2>&1 || true

    local txt
    txt=$(sed -n "s/.*TXT value: '\([^']*\)'.*/\1/p" /tmp/acme-issue.log | head -n 1)
    if [ -n "$txt" ]; then
      printf '\n  %s\n\n' "$(t "Add this record at your DNS provider:" "到你的 DNS 服务商处添加这条记录：")"
      printf '    %-46s TXT  %s\n' "_acme-challenge.$domain" "$txt"
      printf '\n  %s\n' "$(t "Cloudflare or another fast provider: a few seconds. Then press Enter here." "Cloudflare 这类服务商几秒就生效。生效后回到这里按回车。")"
      printf '  > ' >/dev/tty
      if ! read -r _ </dev/tty; then
        printf '\n' >/dev/tty
        die "$(t "input closed; run again once the record is in place" "输入已结束；记录添加好后重跑即可")"
      fi
      info "$(t "validating" "正在验证")"
      "$ACME_BIN" --home "$ACME_HOME" --renew -d "$domain" --ecc $manual_flags >>/tmp/acme-issue.log 2>&1 || true
    else
      info "$(t "a certificate for $domain is already on disk; reusing it" "$domain 的证书已经在本地，直接复用")"
    fi

    fi

    # Judge by the artefact: acme exits 0 for "nothing due" and non-zero for a dozen
    # harmless reasons, but the certificate file is the thing that matters.
    if [ ! -s "$certfile" ]; then
      tail -n 14 /tmp/acme-issue.log
      die "$(t "no certificate was issued; see the log above" "没有签发成功，见上面的日志")"
    fi
  else
    if ! curl -fsS --max-time 8 https://acme-v02.api.letsencrypt.org/directory >/dev/null 2>&1; then
      warn "$(t "the CA API answers slowly from this host; this may take a minute" "从本机访问 CA 接口较慢，可能要等一分钟")"
    fi
    info "$(t "requesting a certificate for $domain (HTTP-01 on port 80)" "正在为 $domain 申请证书（HTTP-01，走 80 端口）")"
    : > /tmp/acme-issue.log
    if ! "$ACME_BIN" --home "$ACME_HOME" --issue -d "$domain" --keylength ec-256 \
        --server letsencrypt $challenge >>/tmp/acme-issue.log 2>&1; then
      tail -n 14 /tmp/acme-issue.log
      die "$(t "certificate issuance failed; see the log above. If port 80 is filtered, use the DNS option." "证书申请失败，见上面的日志。若 80 端口被拦截，请改用 DNS 校验。")"
    fi
  fi

  "$ACME_BIN" --home "$ACME_HOME" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  acme_install_cert "$domain" "$earned" "$ekey"
  acme_renewal_timer

  TLS_CERT=$earned
  TLS_KEY=$ekey
  AGENT_TLS=1
  ok "$(t "certificate issued and installed" "证书已签发并安装")"
}

if [ "$CERT_SOURCE" = user ]; then
  install -d -m 0750 "$STATE_DIR/tls" 2>/dev/null || true
  case "$USER_CERT" in
    /tmp/*) install -m 0644 "$USER_CERT" "$STATE_DIR/tls/user-fullchain.pem"; USER_CERT="$STATE_DIR/tls/user-fullchain.pem" ;;
  esac
  case "$USER_KEY" in
    /tmp/*) install -m 0600 "$USER_KEY" "$STATE_DIR/tls/user-key.pem"; USER_KEY="$STATE_DIR/tls/user-key.pem" ;;
  esac
fi

if [ "$CERT_SOURCE" = acme ]; then
  issue_cert_acme "$HOST" "${ACME_MODE:-http}"
elif [ "$CERT_SOURCE" = user ]; then
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
if [ -n "${ADVERTISED_URL:-}" ]; then
  URL_BASE=$ADVERTISED_URL
elif [ "$SCHEME" = https ]; then
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

CAPS=""
if [ "$PUBLIC_PORT" -lt 1024 ] || [ "$AGENT_PORT" -lt 1024 ] || [ "$HTTP_PORT" -lt 1024 ]; then
  CAPS="AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE"
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
$CAPS
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
    if journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null | grep -q "EACCES"; then
      warn "$(t "a privileged port was refused. The unit gets CAP_NET_BIND_SERVICE for ports below 1024; if this persists, pick a port above 1024 or check that systemd supports AmbientCapabilities (v229+)." "特权端口被拒绝。低于 1024 的端口会在单元里获得 CAP_NET_BIND_SERVICE；若仍失败，改用 1024 以上的端口，或确认 systemd 支持 AmbientCapabilities（v229+）。")"
    fi
    if journalctl -u "$SERVICE" -n 40 --no-pager 2>/dev/null | grep -q "EADDRINUSE"; then
      warn "$(t "that port is already taken by another process; pick a free one" "该端口已被其它进程占用，请换一个空闲端口")"
    fi
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
CERT_SOURCE=$CERT_SOURCE
ACME_MODE=${ACME_MODE:-http}
ADVERTISED_URL=${ADVERTISED_URL:-}
CERT_FILE=$TLS_CERT
KEY_FILE=$TLS_KEY
SCRIPT=$STATE_DIR/deploy-relay.sh
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
printf '\n  %s  %s\n' "$(t "Relay endpoint " "中转服务器   ")" "$(hi "$AGENT_SCHEME://$HOST:$AGENT_PORT")"
printf '  %s  %s\n' "$(t "Tunnel token   " "隧道令牌     ")" "$(key "$TOKEN")"
if [ "$AGENT_SCHEME" = tls ]; then
  printf '  %s\n' "$(t "also tick \"trust a self-signed certificate\" in the panel" "同时勾选「信任自签名证书」")"
fi
printf '\n%s\n\n  %s\n' "$(t "Public URL once connected:" "连接成功后的公网地址：")" "$(hi "$URL_BASE/__t/$TUNNEL_ID/")"

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
