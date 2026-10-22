## 前置：把插件装进 dsh

在 dsh 里：插件 → 添加插件 → 填 `https://github.com/tsukii12/dsh-remote-portal`；或用命令行：

```bash
git clone https://github.com/tsukii12/dsh-remote-portal
cd dsh-remote-portal && ./install.sh      # Windows 用 .\install.ps1
```

装完重启 dsh。下面所有部署步骤都以本仓库的 `tools/` 为前提。
# 在服务器上部署中转，人在任何网络都能访问

> 目标：dsh 跑在家里的电脑上，你在公司/地铁/酒店用手机或笔记本打开一个**公网地址**就能用。
> 家里不需要公网 IP、不需要路由器端口映射、不需要内网穿透软件。

```
家/办公室的电脑                          你的服务器（有公网 IP）                手机 / 笔记本
┌───────────────────────┐   主动外连    ┌────────────────────────┐   普通 HTTPS   ┌──────────────┐
│ dsh + dsh-remote-portal│  一条 TLS 连接 │ relay.mjs              │  ◀────────────  │ 浏览器         │
│   gateway  127.0.0.1:3081 │ ───────────▶ │  :9443  代理端口（TLS） │                │ 扫码 / 打开链接 │
│   tunnel   ────────────┼──────────────│  :8080  访客端口（HTTP）│                └──────────────┘
└───────────────────────┘               └────────────────────────┘
```

隧道由**家里的电脑主动拨出**，所以家里那侧什么都不用开放。访客只看到你的服务器；密码 / 扫码
那一关仍然由家里的门户把守，中转只负责搬运字节。

---

## 0. 三种部署形态，选一个

| 形态 | 适合 | 需要的 | 命令要点 |
|---|---|---|---|
| **A. 服务器 + Caddy 自动 HTTPS**（推荐） | 有域名 | 域名解析到服务器 | relay 只开 HTTP，Caddy 在 443 终止 TLS |
| **B. 服务器 + 自签证书直连 HTTPS** | 没域名，内网/自用 | 无 | relay 用 `--tls-port` 直接说 HTTPS |
| **C. 仅 HTTP（自己在前面套隧道）** | 已有 frp / cloudflared | 无 | relay 只做 `:8080` |

下面以 **A** 为主线，B/C 的差异单独标注。

---

## 0. 最快的方式：一键脚本（不需要任何参数）

把 `tools/` 里的 `deploy-relay.sh` 和 `relay.mjs` 传到服务器同一目录，然后：

```bash
chmod +x deploy-relay.sh      # 从 git clone 下来已可执行；解压/复制后可能需要一次
sudo ./deploy-relay.sh
```

**不带参数**。脚本会自己探测环境、逐项提问（每项都有默认值，直接回车即可），然后完成全部配置：

| 步骤 | 做什么 |
|---|---|
| 1 | 检查 Node ≥ 20、root、systemd |
| 2 | 探测公网 IP、**已有的 nginx / Caddy / 1Panel**、可用端口 |
| 3 | 询问：对外主机、中转端口、是否加密、用哪个入口 |
| 4 | 装 relay、生成令牌、按需生成自签证书 |
| 5 | 装 systemd 并启动、按需写反代站点（**校验通过才 reload**） |
| 6 | 自检并打印可粘贴的两行 + 需要放行的端口 |

### 一定要装 nginx 吗？不需要

脚本按环境自动选入口，三种都支持，无需你指定：

| 环境 | 脚本的选择 |
|---|---|
| 已有 Caddy | 写一个 Caddy 站点，自动签 HTTPS |
| 已有 nginx（含 1Panel 的容器内 openresty） | 写一个只转发 `/__t/` 的 server 块，先 `nginx -t` 再 reload |
| 什么都没有 | **不用 nginx**：relay 直接对外监听一个端口，公网地址形如 `http://<ip>:8080/__t/<id>/` |

也就是说：有反代就用反代（能蹭 80/443 的 HTTPS），没有就直连，**两种都能用**。

### 管理命令：`drp`

安装时脚本会写入 `/usr/local/bin/drp`，之后不用再碰部署目录：

```console
$ drp
service     running (enabled: enabled)
agent port  1.2.3.4:9443 (TLS)
visitor     0.0.0.0:8080 (direct)
endpoint    tls://1.2.3.4:9443
relay       reachable
tunnel      connected, streams=0
traffic     in=110B out=0B visitors=2
public      http://1.2.3.4/__t/ab12cd34ef56/

$ drp url      # 只打印公网地址
$ drp token    # 只打印隧道令牌
$ drp restart  # 重启服务
$ drp log -f   # 跟踪日志
$ drp config   # 上次保存的配置
```

### 语言

脚本默认英文。想用中文：`sudo ./deploy-relay.sh --lang zh`，交互模式第一问也可以直接选。

### 其它用法

```bash
sudo ./deploy-relay.sh --yes        # 全默认，无人值守（也用于反复重跑）
sudo ./deploy-relay.sh --uninstall  # 卸载（保留令牌与证书目录并提示）
```

可选覆盖（一般不需要）：`--host <域名或IP>`、`--agent-port <n>`、`--http-port <n>`、
`--public-port <n>`、`--no-proxy`（强制直连）、`--plain`（中转端口不加密）。

> **重跑是安全的**：脚本把这次的选择写进 `/var/lib/dsh-relay/deploy.conf`，下次运行沿用；
> 已装的令牌和证书会复用（**不会**把加密降级）；自己占用的端口不算被占用，端口不会漂移。

下面的 1–6 节是**手动版**：脚本做的事逐步展开，便于你按自己的规范改造。

## 1. 服务器准备

一台 Linux VPS（1 核 512 MB 足够：中继本身只转发字节，不做任何计算），假设：

- 公网 IPv4：`203.0.113.10`
- 域名：`dsh.example.com`（A 记录指向上面那个 IP）

```bash
# 一个不登录的系统用户来跑它
sudo useradd --system --home /var/lib/dsh-relay --create-home dsh-relay
sudo mkdir -p /opt/dsh-relay && sudo chown dsh-relay:dsh-relay /opt/dsh-relay

# 只需要 Node 20+；发行版仓库的版本通常够
node --version        # v20 或更高
```

把插件目录里的 `tools/relay.mjs` 复制过去（它是**单文件、零依赖**，不需要 `npm install`）：

```bash
sudo -u dsh-relay cp tools/relay.mjs /opt/dsh-relay/
```

## 2. 生成隧道令牌

令牌就是"哪台电脑可以接进来"的凭据。**每条隧道一个**，用 32 字节随机值：

```bash
openssl rand -base64 32        # 例：8f3k...（保存好，客户端要用同一条）
```

写进一个只有服务用户可读的文件：

```bash
sudo -u dsh-relay bash -c 'printf "%s\n" "8f3k…你的令牌…" > /var/lib/dsh-relay/token'
sudo chmod 600 /var/lib/dsh-relay/token
```

> 可以放多行，每行一条隧道（多台机器 → 各自的公网路径互不干扰）。
> 令牌泄露 = 别人能连进你的 dsh，但仍要过门户密码；怀疑泄露就换一条并重启双方。

## 3. 启动中继（形态 A）

```bash
sudo -u dsh-relay node /opt/dsh-relay/relay.mjs \
  --token-file /var/lib/dsh-relay/token \
  --agent-port 9443 \
  --http-port 8080 \
  --public-url https://dsh.example.com
```

启动后会打印每条隧道的公网地址：

```
[relay] agent  tcp 0.0.0.0:9443
[relay] visitor http  0.0.0.0:8080
[relay] tunnel 3TerRaeZuv7S → https://dsh.example.com/__t/3TerRaeZuv7S/
```

这个 `/__t/<id>/` 就是**要填进插件面板的公网入口**（id 由令牌算出来，重启不变）。

### 交给 systemd

`/etc/systemd/system/dsh-relay.service`：

```ini
[Unit]
Description=dsh-remote-portal relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=dsh-relay
Group=dsh-relay
ExecStart=/usr/bin/node /opt/dsh-relay/relay.mjs \
  --token-file /var/lib/dsh-relay/token \
  --agent-port 9443 --http-port 127.0.0.1:8080 \
  --public-url https://dsh.example.com
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
RestrictAddressFamilies=AF_INET AF_INET6
ReadOnlyPaths=/opt/dsh-relay
ReadWritePaths=/var/lib/dsh-relay

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now dsh-relay
sudo systemctl status dsh-relay
journalctl -u dsh-relay -f          # 看隧道连接/断开
```

> 注意 `--http-port 127.0.0.1:8080` 的写法：Caddy 在同一台机器上，所以访客端口只绑回环，
> 不直接暴露到公网 —— 这样 443 是唯一入口，防火墙也只需要开 80/443/9443。

## 4. 用 Caddy 拿证书并转发

`/etc/caddy/Caddyfile`：

```caddyfile
dsh.example.com {
    encode zstd gzip

    # 门户自己的静态资源已经带 ETag/304，Caddy 不用再缓存
    reverse_proxy 127.0.0.1:8080 {
        # 让门户知道访客本来用的是 HTTPS（Cookie 的 Secure 判定与日志都用得到）
        header_up X-Forwarded-Proto https
        flush_interval -1          # 不缓冲：SSE / 流式响应必须直通
        transport http {
            read_timeout 0         # 长连接（WebSocket、下载）不设上限
        }
    }
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
```

Caddy 会自动申请并续期证书。**这一步没有别的配置**——路径前缀路由由 relay 负责，Caddy 只做
TLS 与转发。

nginx 等价配置（如果更习惯 nginx）：

```nginx
server {
  listen 443 ssl http2;
  server_name dsh.example.com;
  ssl_certificate     /etc/letsencrypt/live/dsh.example.com/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/dsh.example.com/privkey.pem;

  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Upgrade $http_upgrade;      # WebSocket
    proxy_set_header Connection $connection_upgrade;
    proxy_buffering off;                          # 流式响应
    proxy_read_timeout 3600s;
  }
}
# map $http_upgrade $connection_upgrade { default upgrade; "" close; } 放在 http{} 里
```

## 5. 防火墙

```bash
sudo ufw allow 80,443/tcp        # Caddy
sudo ufw allow 9443/tcp          # 家里的电脑拨进来
sudo ufw enable
```

云厂商的安全组同样要放行 **9443**（代理端口）和 **443**（访客端口）。`8080` 不需要开 —— 它只
绑在回环上给 Caddy 用。

## 6. 家里那台电脑：把隧道接上

1. 打开 dsh → 设置 → **远程访问** → 找到「**公网访问**」卡片；
2. 「中转服务器」按**服务器上 agent 端口有没有证书**二选一：

   | 服务器怎么起的 | 填什么 |
   |---|---|
   | 默认（没有 `--tls-cert` / `--tls-key`） | `tcp://43.153.152.119:9443` |
   | 带证书（`--tls-cert … --tls-key …`） | `tls://dsh.example.com:9443` |

   > **这是最容易踩的一步。** agent 端口默认是**明文 TCP**；填 `tls://` 会握手失败，
   > 服务器日志里会写明「sent a TLS ClientHello, but this port serves plain TCP」。
   > 反过来，端口配了证书却填 `tcp://` 也一样连不上。前端 443 的 HTTPS 与此无关：
   > 它保护的是**访客**那一跳，agent 端口是另一跳。

   > 明文 `tcp://` 表示「家里 → 服务器」这段可被中间人看到；介意就按第 5 节配证书。
3. 「隧道令牌」粘贴第 2 步那条；
4. 点「连接」。状态变成 **已连接**，卡片上出现公网地址与二维码。

也可以在 `cordis.patch.yml` 里写死（令牌建议只写文件路径，见下）：

```yaml
- id: dsh-remote-portal
  name: dsh-remote-portal
  config:
    tunnel:
      url: tcp://43.153.152.119:9443    # 配了证书就换成 tls://
      token: 8f3k…你的令牌…
```

> 面板里填过之后会存进 `~/.dsh/dsh-remote-portal/state.json`（0600），并优先于 YAML。
> `status()` / 面板**永远不会**把令牌回显出来。

## 7. 客户端怎么连

拿到公网地址（形如 `https://dsh.example.com/__t/3TerRaeZuv7S/`）之后：

| 场景 | 做法 |
|---|---|
| **手机（推荐）** | 面板「公网访问」卡片上的二维码 → 相机扫码 → 输一次访问密码 → 进入 |
| **手机长期用** | 打开后 Safari「分享 → 添加到主屏幕」/ Chrome「添加到主屏幕」，得到全屏图标，像 App 一样 |
| **笔记本** | 把地址存书签，第一次输密码，之后 30 天内免登录 |
| **发给别人（临时）** | 面板「扫码配对」生成一次性配对链接（180 秒、单次），对方打开即可，无需告知密码 |

登录页会**相对路径**提交（`__portal/login`），所以同一个地址在没有前缀（局域网 `:3081`）和
有前缀（公网 `/__t/<id>/`）两种情况下都能用；门户自己页面、面板、二维码里的地址也都是这个
公网地址。

## 8. 形态 B：没有域名，自签证书直连

```bash
# 在服务器上生成（CN 用 IP，现代浏览器看的是 SAN）
openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout /opt/dsh-relay/key.pem -out /opt/dsh-relay/cert.pem \
  -subj "/CN=203.0.113.10" \
  -addext "subjectAltName=IP:203.0.113.10"
sudo chown dsh-relay: /opt/dsh-relay/*.pem && sudo chmod 600 /opt/dsh-relay/key.pem

sudo -u dsh-relay node /opt/dsh-relay/relay.mjs \
  --token-file /var/lib/dsh-relay/token \
  --agent-port 9443 --http-port 8080 \
  --tls-port 8443 --tls-cert /opt/dsh-relay/cert.pem --tls-key /opt/dsh-relay/key.pem \
  --public-url https://203.0.113.10:8443
```

家里那侧填 `tls://203.0.113.10:9443`；因为证书不是公共 CA 签的，需要让代理信任它：

```yaml
tunnel:
  url: tls://203.0.113.10:9443
  token: …
  caFile: D:/path/to/cert.pem     # 或面板里先用 tcp:// 冒险一次
```

手机第一次打开会看到一次「证书不受信任」，手动继续即可 —— 这是自签证书的正常代价，**只建议
在自己的设备上这么用**。

## 9. 形态 C：已经有隧道工具

如果你已经在用 `cloudflared` / `frp` / Tailscale，**根本不需要 relay**：把门户的 host 设成
`127.0.0.1`，用它们把 `http://127.0.0.1:3081` 暴露出去即可。插件不接管传输层，只要求流量能
到网关。

```yaml
config:
  host: '127.0.0.1'
```

## 10. 运维与排障

```bash
curl -s https://dsh.example.com/__relay/health | jq
# {"ok":true,"tunnels":[{"id":"3TerRaeZuv7S","connected":true,"streams":0,...}],"stats":{...}}

journalctl -u dsh-relay -f     # 隧道连上/断开
```

| 现象 | 原因 | 处理 |
|---|---|---|
| 公网页 503「The host is offline」 | 家里的 dsh 没连上来 | 面板看「公网访问」状态；确认 9443 可达、令牌一致 |
| 面板「公网访问」一直是**连接中** | 域名/端口写错，或服务器防火墙没放行 9443 | `nc -vz dsh.example.com 9443`；看 relay 日志 |
| 打开公网页是 relay 的 404 | 路径 id 不对（令牌变了） | 用面板显示的新地址 |
| 页面能开但登录后空白 | 反向代理缓冲了流式响应 | Caddy 加 `flush_interval -1`；nginx 关 `proxy_buffering` |
| 登录后过一会儿掉线 | 代理有 idle timeout | Caddy `read_timeout 0`；nginx `proxy_read_timeout 3600s` |
| 手机扫码打不开 | 二维码是**局域网**地址（走「扫码配对」那张卡） | 用「公网访问」卡上的二维码，或直接打开公网链接 |
| 每次都要重新登录 | 浏览器清了 Cookie / 换 UA | 会话绑定 UA 指纹，换浏览器需重新登录 |

### 它到底安全吗

* 中转只看得到**加密的 TLS 载荷**（形态 A 里 Caddy↔浏览器是 TLS，家里的 dsh ↔ relay 也是 TLS；
  只有 relay 进程内存里有一瞬间的明文——那是你自己的服务器）。
* 公网链接本身不是凭据：`/__t/<id>/` 只是一个入口，进去还是要过门户密码或一次性配对码。
* 令牌泄露不会直接拿到 dsh，但仍应立刻更换（面板断开 → 服务器换令牌 → 重连）。
* 建议在服务器上再叠一层：`--max-streams` 限制并发（默认 256）、Caddy 侧的 `rate_limit`
  （需要 xcaddy 插件）或云防火墙的 IP 白名单。

---

## 附：Docker（可选）

```dockerfile
FROM node:22-alpine
WORKDIR /app
COPY tools/relay.mjs /app/relay.mjs
USER node
EXPOSE 8080 9443
ENTRYPOINT ["node", "/app/relay.mjs"]
```

```yaml
# docker-compose.yml
services:
  relay:
    build: .
    command:
      - --token-file=/run/secrets/relay-token
      - --agent-port=9443
      - --http-port=8080
      - --public-url=https://dsh.example.com
    ports:
      - "9443:9443"       # 家里的电脑拨进来
      # 8080 不映射到宿主机；由同网络的 Caddy 容器直连
    secrets: [relay-token]
    restart: unless-stopped

secrets:
  relay-token:
    file: ./relay-token
```

Caddy 容器里把 `reverse_proxy dsh-relay:8080` 指向上面的服务名即可。



