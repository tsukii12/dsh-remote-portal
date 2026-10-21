<div align="center">

**简体中文** · [English](README.en.md)

# dsh-remote-portal

### 给 DeepSeek Harness 加一道登录门，手机和外面的电脑都能用。

**局域网扫码即用 · 自建服务器中转穿透公网 · 零依赖零构建**

[![license](https://img.shields.io/badge/license-MIT-0f1115?style=flat-square)](LICENSE)
[![dsh](https://img.shields.io/badge/dsh-0.2.x-4176e6?style=flat-square)](#兼容性)
[![tests](https://img.shields.io/badge/tests-76%20passing-22c55e?style=flat-square)](#测试)
[![runtime deps](https://img.shields.io/badge/runtime%20deps-0-22c55e?style=flat-square)](#)

[功能](#功能) · [快速开始](#快速开始) · [公网访问](#公网访问) · [工作原理](#工作原理) · [安全模型](#安全模型) · [常见问题](#常见问题) · [文档](#文档)

</div>

---

DeepSeek Harness 只监听 `127.0.0.1`，浏览器用一个**每次启动都会变的令牌**认证。这对本机是安全的默认值，也意味着**离开这台电脑就用不了**。

这个插件不改动 dsh 的任何安全机制，只在它前面加一道自己的门：一个独立端口上的网关，先验密码或一次性配对码，再把请求转发给本机的 dsh。手机在同一个 WiFi 下扫码就能用；不在同一个网络，就在你自己的服务器上跑一个中转，家里的 dsh **主动拨出**，公网地址随时可达。

<div align="center">

<img src="docs/screenshots/panel-main-area.png" alt="远程访问面板：主区域里的页面，侧边栏保持可用" width="1000" />

<sub>面板是主区域里的一个页面（和「插件」「自动化任务」同级），侧栏保持可见可用。</sub>

</div>

## 功能

| | |
|---|---|
| **一条局域网地址** | `http://<局域网IP>:3081/`，手机浏览器直接打开；不需要公网 IP、端口映射或穿透软件 |
| **公网访问（自建中转）** | 在**你自己的**服务器上跑 `tools/relay.mjs`，家里的 dsh 主动拨出 → 稳定的公网地址；不需要动路由器 |
| **扫码配对** | 面板里生成二维码，180 秒有效、一次即失效，扫完直接进，不用在手机上打密码 |
| **密码 + 设备管理** | `scrypt` 加盐、恒定时间比较、连错锁定；每台登录过的设备可单独移除 |
| **移动端重排** | 侧栏变抽屉、对话框不再溢出、输入框不被键盘顶飞、长代码/宽表格/大图不撑破页面 |
| **远程专属裁剪** | 手机看不到你桌面的文件管理器：`在资源管理器…等中打开`、`打开配置文件`、死掉的菜单项会被隐藏 |
| **服务器目录选择器** | 「添加工作区」列出**服务器**上的目录，可逐级进入、可新建文件夹，返回绝对路径 |
| **零依赖** | 只用 Node 内置模块；没有构建步骤，装完即用 |

<table>
<tr>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile.png" alt="手机上打开的 dsh" /><br /><sub><b>手机（局域网）</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile-drawer.png" alt="侧栏抽屉" /><br /><sub><b>侧栏抽屉</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/workspace-picker.png" alt="服务器目录选择器" /><br /><sub><b>服务器目录选择器</b></sub></td>
</tr>
</table>

## 快速开始

**前提**：dsh `0.2.x`（`dsh --version`），profile 为 `desktop` 或 `web`，Node ≥ 20（dsh 自带即可）。

```powershell
git clone <repo> dsh-remote-portal
cd dsh-remote-portal
.\install.ps1                       # 装进 desktop + web 两个 profile
```

```bash
# macOS / Linux（dsh web）
./install.sh                        # desktop + web
./install.sh -p web                 # 只装一个
./install.sh -p web --uninstall
```

两个脚本做同样三件事，全部可逆（先备份 `package.json`）：把插件以 `link:` 依赖写进 profile、
把 `dsh-remote-portal` 加进 `dsh.profile.bundles`、让包在 profile 的 `node_modules` 里可解析
（插件零依赖，所以直接建软链，不需要包管理器）。

> `desktop` profile 由 Electron 应用独占管理，CLI 拒绝 `--dump-config`；安装脚本会跳过那一步校验。

**然后重启 dsh**（桌面端退出再打开，命令行 `Ctrl+C` 后重新 `dsh web`）。

**首次使用（必做一步）**：侧栏 → **远程访问** → 设置访问密码。
在此之前门户**不会**监听局域网——宁可显示一条红字，也不让任何人的 dsh 裸奔在网络上。
设完 3 秒内状态变「运行中」，然后复制地址在手机上打开，或直接「扫码配对」。

## 公网访问（人不在局域网）

在**你自己的服务器**上跑中转。家里那台机器主动拨出，所以不需要公网 IP、不需要路由器映射。

```bash
# 服务器上（单文件、零依赖，不需要 npm install）
openssl rand -base64 32 > /var/lib/dsh-relay/token && chmod 600 /var/lib/dsh-relay/token
node tools/relay.mjs --token-file /var/lib/dsh-relay/token \
     --agent-port 9443 --http-port 127.0.0.1:8080 \
     --public-url https://dsh.example.com
```

```caddyfile
# 前面挂 Caddy 拿证书（关键：不缓冲，否则流式响应会卡住）
dsh.example.com { reverse_proxy 127.0.0.1:8080 { flush_interval -1 } }
```

回电脑：侧栏 → **远程访问** → **公网访问** → 中转服务器填 `tls://dsh.example.com:9443` + 令牌 →
「连接」。状态变**已连接**后，卡片上就是公网地址和二维码。

* 完整部署（systemd 单元、Caddy/nginx、自签证书、Docker、防火墙、排障表）→ [**docs/DEPLOY-SERVER.md**](docs/DEPLOY-SERVER.md)
* 客户端怎么连（扫码、PWA、笔记本、一次性链接）→ [**docs/CONNECT.md**](docs/CONNECT.md)

已在真实服务器上验证：经 `http://<公网IP>/__t/<id>/` 从外部网络打开登录页 → 登录 → 完整界面与会话列表（WebSocket）全部正常。

## 工作原理

```
手机 / 平板 / 外面的电脑
        │  ① http://192.168.1.5:3081/      ② https://dsh.example.com/__t/<id>/
        ▼
┌───────────────────────────────┐        ┌──────────────────────────┐
│ 门户网关  0.0.0.0:3081        │◀───────│ 你的服务器  relay.mjs     │
│  密码 / 扫码 / 设备锁 / 限流   │ 主动外连 │  只搬运字节，不碰 dsh     │
└───────────────┬───────────────┘   TLS   └──────────────────────────┘
                │ 反向代理，改写 Host/Origin
        dsh Web GUI 127.0.0.1:19887
```

三条链路，一套策略：**只有网关做认证**，它并不关心请求是从局域网还是中转来的。

* **为什么不能直接 `0.0.0.0`** — dsh 拒绝通配绑定，且没有"用户密码"这回事（只有一次性启动令牌）。
  网关是第二个监听器，用密码/配对码换一个自签的会话 Cookie，再从宿主凭据**在后台**换出 dsh 的浏览器 Cookie。
* **为什么必须改写 `Host`/`Origin`** — dsh 有一道浏览器信任围栏：`Host` 必须是回环或声明的地址，
  且 `Origin` 必须与之一致。原样转发访客的 Host 会 403，这也是很多"反向代理 dsh"失败的根因。
* **为什么中转用路径前缀** — Cookie 不区分端口，`/__t/<id>/` 让同一个 Cookie 在原站与中转站都有效；
  应用自身用 `<base href="./">`，所以前缀对它是透明的。
* **为什么面板是"主区域页面"** — 它量取中央列的矩形（`--drp-main-*`）再铺进去，侧栏保持可见可点，
  与「插件」「自动化任务」一致，而不是盖住整屏。

细节（含 15 条实测过的宿主事实）见 [ARCHITECTURE.md](ARCHITECTURE.md)。

## 安全模型

* **门户是唯一的门**：没有密码时拒绝在非回环地址上监听；`open` 模式只允许回环。
* **会话 Cookie** `dsh_portal`：`HttpOnly`、`SameSite=Lax`、签名里含 UA 指纹（换浏览器即失效），TLS 下自动带 `Secure`。
* **上游认证**：网关用宿主凭据在后台换取 dsh 浏览器 Cookie，令牌不出本机、不落日志、不回显给面板。
* **响应头**：门户自己的每个响应都带 `CSP(default-src 'none'; frame-ancestors 'none'; form-action 'self')`、
  `X-Frame-Options: DENY`、`CORP/COOP`、`Permissions-Policy`；**被代理的 dsh 响应一个字节都不改**（有测试钉死）。
* **不构成开放代理**：只转发到本机回环的一个固定上游，`/__portal/*` 永不外发。
* **目录接口**：`/fs` 只列目录名（不含文件内容），`/fs/mkdir` 只允许单段名字且必须落在父目录内；
  经门户访问需要会话，匿名请求 401（有测试钉死）。
* **中转不是凭据**：公网地址只是入口，进去仍要过密码或一次性配对码。
* **明文 HTTP 的边界**：同网段可抓包看到 Cookie。公网使用时浏览器↔服务器是 HTTPS，家里↔服务器是 TLS。

威胁模型与实现细节见 [SECURITY.md](SECURITY.md)。

## 兼容性

| | |
|---|---|
| dsh | `0.2.x`（在 `0.2.1-rc.2` 上逐项验证，桌面 Electron 与 `dsh web` 两种装法都试过） |
| profile | `desktop`（Electron 管理）与 `web`（`dsh web`）都可用 |
| 系统 | Windows / macOS / Linux（网关只用 Node 内置模块；一键安装脚本为 PowerShell 与 POSIX shell 各一份） |
| 浏览器 | Chrome / Edge / Safari 15.4+ / Firefox 121+（移动层用到 `:has()`；不支持时回落到桌面排版） |

## 测试

```console
$ node --test
ℹ tests 76
ℹ pass 76
ℹ fail 0
ℹ skipped 0
ℹ duration_ms ~71000
```

| 套件 | 覆盖 |
|---|---|
| `test/host.test.mjs` | 真监听：绑定/停止/重绑、登录、锁定、配对单次、Host/Origin 改写、WebSocket 隧道、不缓冲流式、Cookie 换取、状态持久化、绝不泄露密钥 |
| `test/security.test.mjs` | 每个门户响应都带齐安全头；**被代理的响应保持原样**；TLS 配置错误变成状态而不是异常 |
| `test/relay.test.mjs` | 真 relay + 真隧道 + 假上游：前缀剥离、请求头透传、WebSocket 逐字节、HTTPS 访客端口 + TLS 隧道、未知/离线隧道、错误令牌、断线重连、超时释放 |
| `test/qr.test.mjs` | 二维码正确性由**独立解码器**验证（不是自己解自己） |
| `test/mobile.test.mjs` | 打**真实页面**：抽屉 API、44px 点击区、320→900 六档 × 深浅两套的溢出审计、长代码/宽表格/大图探针、触摸命中检测 |

三项浏览器测试需要本机有 Chrome/Chromium（`CHROME_PATH` 可指定）；没装时会**显式跳过**而不是失败，
所以在没有浏览器的 Linux 服务器上 `node --test` 同样是绿的（73 通过 + 3 跳过）。

布局与性能的实测数据（8 组宽度×主题 0 溢出、登录页 48px 控件且 320×844 不需滚动、
`mobile.css` 20,783B→5,808B gzip、重载 304 零字节、网关每请求多 5–10ms）与复现命令见
[**docs/PERFORMANCE.md**](docs/PERFORMANCE.md)。

## 常见问题

<details>
<summary><strong>一定要重启 dsh 吗？</strong></summary>

**改配置不用**，面板里的开关立即生效。但**插件升级后必须重启**：宿主侧代码（`index.js`、`lib/*`）
只在 dsh 启动时加载，客户端每次刷新都会更新——两者版本不一致时，新界面会调用到旧宿主，
表现为「接口不存在」。面板遇到这种情况会明确提示「宿主未加载该接口：请重启 dsh 后重试」。

</details>

<details>
<summary><strong>手机上某些按钮点了没反应？</strong></summary>

多数是**只在桌面端有意义**的入口（在资源管理器/VS Code 中打开、下载会话日志、反馈）。
插件会在远程/移动端把这类入口隐藏；如果还有遗漏，说明它的文案没被识别规则覆盖。

</details>

<details>
<summary><strong>局域网打不开？</strong></summary>

按顺序检查：① 面板状态是否「运行中」；② 手机与电脑是否同一网段（公司 WiFi 常隔离客户端）；
③ 电脑防火墙是否放行端口（面板「连接诊断」里有可复制的 `netsh` 命令）；
④ 绑定地址是否为 `0.0.0.0` 或 `auto`（`127.0.0.1` 只有本机可访问）。

</details>

<details>
<summary><strong>公网地址打不开？</strong></summary>

先看面板「公网访问」的状态：**离线**说明家里的机器没连上中转（检查服务器 9443 是否放行、
令牌是否一致）；**已连接**但页面报 503/404，看 [DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) 的排障表
（常见是反代缓冲导致流式响应卡住）。

</details>

<details>
<summary><strong>撤销设备会踢掉 dsh 会话吗？</strong></summary>

不会。撤销只是让那台设备的**门户 Cookie** 失效，底层 dsh 身份是多设备共享的。
要全部重来就改密码并勾选「同时退出所有已登录设备」。

</details>

<details>
<summary><strong>多个 dsh 实例可以共用吗？</strong></summary>

同一个 `DSH_HOME` 下会争抢端口，后启动的实例会显示「端口已被占用」。给它们不同的 `port` 即可；
状态（密码、设备、隧道）按 `DSH_HOME` 隔离。

</details>

## 开发

```bash
node --test                            # 全部（无依赖、无需联网）
node --test test/relay.test.mjs        # 只跑中转
node tools/cdp.mjs shot <url> out.png  # 截图验证（支持 --mobile / --host-map / --ignore-cert）
node tools/cdp.mjs audit <url> out.json --widths 320,390,768 --themes dark,light
node tools/cdp.mjs gesture <url> --x 195 --y 400 --dy -400   # 真实触摸滑动 + 报告是否滚动
node tools/relay.mjs --help            # 中转服务
```

```
index.js                 宿主入口：网关生命周期 + 控制接口 + 移动层注入
lib/gateway.mjs          监听、登录、配对、设备、限流、隧道接线、状态
lib/proxy.mjs            HTTP / WebSocket 反向代理
lib/auth.mjs             scrypt、会话签名、配对码、锁定
lib/mint.mjs             用宿主凭据换取 dsh 浏览器 Cookie
lib/tunnel.mjs           外连隧道（鉴权、重连、心跳）
lib/login-page.mjs       登录页
lib/qr.mjs               纯 JS 二维码编码器
client.js                浏览器半：面板、目录选择器、设备、诊断
assets/mobile.css/.js    移动端呈现层
tools/relay.mjs          中转服务（单文件零依赖）
tools/cdp.mjs            截图/审计/手势用的 CDP 驱动
```

## 文档

- [ARCHITECTURE.md](ARCHITECTURE.md) — 设计、请求路径、15 条实测宿主事实
- [docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) — 服务端部署：systemd / Caddy / nginx / 自签 TLS / Docker / 防火墙
- [docs/CONNECT.md](docs/CONNECT.md) — 客户端连接：扫码、PWA、笔记本、一次性链接
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — 布局与传输的实测数据及复现命令
- [CHANGELOG.md](CHANGELOG.md) — 逐版本的改动与验证记录
- [SECURITY.md](SECURITY.md) — 安全策略与报告方式

## 已知限制

* 只在**同一网络**内可达，或经你自己部署的中转；插件不做 NAT 穿透，也不提供公共中转服务。
* 公网场景下，中转服务器的带宽就是上限；它只搬运字节，不做缓存。
* 明文 HTTP 下同网段可抓包看到 Cookie；介意就配 `tls` 或走中转（HTTPS）。
* 撤销设备只是拒绝其门户 Cookie，不会断开 dsh 侧的会话。
* Safari 与 iOS 刘海屏只用规则保证，未上真机；Electron 桌面窗口从 `file://` 加载，索引注入不生效。
* 面板/选择器以「主区域页面」的形式呈现（几何与交互等价），并没有替换宿主的主区域 DOM。

## 参与

Issue / PR 都欢迎。改动前请先跑 `node --test`；网络路径上的行为请补测试而不是只改文档。
细节见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

[MIT](LICENSE)
