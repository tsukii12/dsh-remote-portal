<div align="center">

**简体中文** · [English](README.en.md)

# dsh-remote-portal

**给 DeepSeek Harness 加一道登录门：手机扫码即用，不在局域网也能远程访问。**

[![license](https://img.shields.io/badge/license-MIT-0f1115?style=flat-square)](LICENSE)
[![dsh](https://img.shields.io/badge/dsh-0.2.x-4176e6?style=flat-square)](#兼容性)
[![tests](https://img.shields.io/badge/tests-79%20passing-22c55e?style=flat-square)](#测试)
[![deps](https://img.shields.io/badge/runtime%20deps-0-22c55e?style=flat-square)](#)

[安装](#安装) · [公网访问](#公网访问) · [功能](#功能) · [安全](#安全) · [常见问题](#常见问题)

</div>

---

dsh 只监听 `127.0.0.1`，用一次性启动令牌认证——离开这台电脑就用不了。这个插件不改动 dsh 的任何机制，只在它前面加一道自己的门：独立端口上的网关，先验密码或一次性配对码，再转发给本机 dsh。

<div align="center">

<img src="docs/screenshots/panel-main-area.png" alt="远程访问面板" width="900" />

<sub>面板是主区域里的一个页面（和「插件」「自动化任务」同级），侧栏保持可用。</sub>

</div>

## 安装

**从 dsh 里装（推荐）**：插件 → 添加插件 → 填入

```
https://github.com/tsukii12/dsh-remote-portal
```

**从命令行装**：

```bash
git clone https://github.com/tsukii12/dsh-remote-portal
cd dsh-remote-portal
./install.sh            # macOS / Linux，装进 desktop + web
.\install.ps1           # Windows
```

装完**重启 dsh**（桌面端退出重开；命令行 `Ctrl+C` 后重新 `dsh web`）。

**首次必做一步**：侧栏 → **远程访问** → 设置访问密码。在此之前门户不会监听局域网——宁可显示一条红字，也不让你的 dsh 裸奔在网络上。

## 国内网络

GitHub 直连不稳时，用镜像。**插件安装**（把地址换成镜像的 tarball）：

```bash
dsh plugin --profile web add \
  https://ghfast.top/https://github.com/tsukii12/dsh-remote-portal/archive/refs/heads/master.tar.gz
```

**部署脚本**（任选一个能通的）：

```bash
# 推荐：ghfast 代理（跟 master，永远是最新版）
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh | sudo bash

# 备用：jsDelivr（同样跟 master，但它有缓存，可能滞后数小时）
curl -fsSL https://cdn.jsdelivr.net/gh/tsukii12/dsh-remote-portal@master/tools/deploy-relay.sh | sudo bash
```

脚本下载 `relay.mjs` 时会**自动依次尝试** raw → jsDelivr → ghfast → gh-proxy，用到哪个会打印出来。

想固定某一来源：`sudo -E RELAY_RAW_BASE=https://ghfast.top/https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master bash deploy-relay.sh`

**完全离线**：在一台能上网的机器上取一次 `relay.mjs`，和 `deploy-relay.sh` 放同一目录，脚本就不再下载。

## 更新

**先移除，再安装**——直接重复"添加插件"不一定会拉新代码（源地址不变时 pnpm 会回一句 `Already up to date`）：

```bash
dsh plugin --profile web remove dsh-remote-portal
dsh plugin --profile web add    https://github.com/tsukii12/dsh-remote-portal
```

桌面端把 `--profile web` 换成 `--profile desktop`，两个 profile 都装了就跑两遍。

更新后**必须重启 dsh**：宿主侧代码（`index.js`、`lib/*`）只在启动时加载，光刷新页面只换到客户端一半。

> 网络慢或 GitHub 抖动时，`add` 可能失败并打印 `ETIMEDOUT`。重跑一次即可，已下载的部分会复用。

**锁定版本**（不想被动升级）：

```bash
dsh plugin --profile web add https://github.com/tsukii12/dsh-remote-portal#v0.4.9
```

版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 功能

| | |
|---|---|
| **局域网一条地址** | `http://<局域网IP>:3081/`，手机浏览器直接打开，不需要公网 IP 或端口映射 |
| **扫码配对** | 面板生成二维码，180 秒有效、一次即失效 |
| **公网访问** | 在**你自己的**服务器上跑中转，家里主动拨出，得到稳定公网地址 |
| **密码与设备** | scrypt 加盐、连错锁定、逐台设备撤销 |
| **移动端重排** | 侧栏变抽屉、对话框不溢出、长代码/宽表格/大图不撑破页面 |
| **服务器目录选择器** | 「添加工作区」列出服务器上的目录，可逐级进入、可新建文件夹 |
| **零依赖** | 只用 Node 内置模块，无构建步骤 |

<table>
<tr>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile.png" alt="手机访问" /><br /><sub><b>手机（局域网）</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile-drawer.png" alt="侧栏抽屉" /><br /><sub><b>侧栏抽屉</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/workspace-picker.png" alt="目录选择器" /><br /><sub><b>服务器目录选择器</b></sub></td>
</tr>
</table>

## 公网访问

在**你自己的**服务器上跑中转（单文件、零依赖）。**不用拉代码**，一条命令：

没有 Node 也没关系——脚本会自己装一个独立运行时（官方 tarball，不动 apt/yum，放在 `/usr/local/lib/nodejs`），装完继续。

```bash
curl -fsSL https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh | sudo bash
```

脚本会自己下载 `relay.mjs`，探测环境、逐项提问（回车即默认），完成安装并注册 `drp` 命令。

**它会问你访客怎么连**：

| 提问 | 说明 |
|---|---|
| 访客如何连接 | `1) HTTP` 不加密 / `2) HTTPS` |
| HTTPS 用域名还是 IP | **域名**：配好证书后浏览器不报警；**IP**：自签证书，浏览器警告一次，之后照常加密 |
| 域名解析 | 填完域名会**实际解析一次**：指向本机才继续；指向别处（如走了 CDN）会提示并让你决定继续还是换域名；没有 A 记录会提示先加记录 |
| 端口 | 对外端口、中转端口（自动跳过已占用的） |

⚠️ 选 HTTP 时，访问密码和**全部会话内容**（聊天、文件、命令输出）在公网上是明文。只有完全可信的局域网才该这么做。

不想用管道、想先看内容：下载后运行，效果一样。

```bash
curl -fsSLO https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh
sudo bash deploy-relay.sh
```

装完：

```console
$ drp
service     running (enabled: enabled)
agent port  1.2.3.4:9443 (TLS)
visitor     0.0.0.0:8080 (direct)
tunnel      connected, streams=0
public      http://1.2.3.4/__t/ab12cd34ef56/
```

**更新中转**：再跑一次同一条命令即可——令牌与证书会复用，端口不会漂移。

面板里「中转服务器」只填 **`IP:端口`**（如 `1.2.3.4:9443`），协议自动识别（先试 TLS，失败回退明文）。完整部署见 [docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md)。

## 安全

* 门户是唯一的门：没设密码就不会监听非回环地址。
* 会话 Cookie `dsh_portal`：`HttpOnly`、`SameSite=Lax`、绑定 UA，TLS 下自动 `Secure`。
* 门户自己的每个响应都带严格 CSP / `X-Frame-Options: DENY`；**被代理的 dsh 响应一个字节都不改**（有测试钉死）。
* 上游认证用宿主凭据在后台换取，令牌不出本机、不落日志、不回显面板。
* 明文 HTTP 下同网段可抓包看到 Cookie；介意就配 TLS 或走中转。

详见 [SECURITY.md](SECURITY.md)。

## 常见问题

<details>
<summary><strong>一定要重启 dsh 吗？</strong></summary>

改配置不用，面板开关立即生效。但**插件升级后必须重启**：宿主侧代码只在 dsh 启动时加载，客户端每次刷新都会更新。版本不一致时面板会提示「宿主未加载该接口：请重启 dsh 后重试」。
</details>

<details>
<summary><strong>手机上某些按钮点了没反应？</strong></summary>

多数是只在桌面端有意义的入口（在资源管理器/VS Code 中打开、下载会话日志）。插件会在远程/移动端隐藏它们；**本机访问时不会隐藏**（包括用局域网地址访问本机）。
</details>

<details>
<summary><strong>局域网打不开？</strong></summary>

① 面板状态是否「运行中」；② 手机与电脑是否同一网段；③ 防火墙是否放行端口；④ 监听地址是否为 `0.0.0.0` 或 `auto`。
</details>

<details>
<summary><strong>公网地址打不开？</strong></summary>

`drp status` 看隧道状态：`offline` 说明家里没连上中转（检查 9443 是否放行、令牌是否一致）；`connected` 但 503 说明反代缓冲（见部署文档排障表）。
</details>

<details>
<summary><strong>撤销设备会踢掉 dsh 会话吗？</strong></summary>

不会。撤销只让那台设备的门户 Cookie 失效，底层 dsh 身份是多设备共享的。
</details>

## 兼容性

| | |
|---|---|
| dsh | `0.2.x`（在 `0.2.1-rc.2` 上逐项验证） |
| profile | `desktop`（Electron）与 `web`（`dsh web`） |
| 系统 | Windows / macOS / Linux |
| 浏览器 | Chrome / Edge / Safari 15.4+ / Firefox 121+ |

## 测试

```console
$ node --test
ℹ tests 79   ℹ pass 79   ℹ fail 0
```

真监听、真隧道、真页面：网关认证与转发、安全头、relay + 隧道端到端（HTTP/HTTPS/WebSocket）、二维码用独立解码器校验、移动层对真实 dsh 实例做触摸命中与六档宽度溢出审计。浏览器测试缺 Chrome 时会显式跳过。

## 文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 设计与实测宿主事实
- [docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) — 服务端部署（systemd / Caddy / nginx / TLS）
- [docs/CONNECT.md](docs/CONNECT.md) — 客户端连接
- [CHANGELOG.md](CHANGELOG.md) — 逐版本记录
- [SECURITY.md](SECURITY.md) — 安全策略

## 已知限制

* 只在同一网络内可达，或经你自己部署的中转；不做 NAT 穿透。
* 撤销设备不断开 dsh 侧会话。
* Safari 与 iOS 刘海屏只用规则保证，未上真机。

## 许可

[MIT](LICENSE)
