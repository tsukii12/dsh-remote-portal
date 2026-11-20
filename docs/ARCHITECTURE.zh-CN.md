# 鱼鱼远程架构与安全模型

[English](../ARCHITECTURE.md) · [文档目录](README.md#简体中文)

## 1. 网关与上游

浏览器或应用可以直连主机上的鱼鱼远程网关，也可通过中转用 HTTPS 访问。两种方式都由网关认证访客，再将流量代理给 dsh。不要公开 dsh Web 监听地址。dsh Web 使用启动令牌，并验证请求的 Host 和 Origin，不能替代门户。

网关将请求头中的上游地址改为 dsh 的地址，流式转发 HTTP 响应，并支持 WebSocket 升级。它仅在本机使用 dsh 启动凭据来签发上游 Cookie，不把启动凭据发给客户端。浏览器可以同时收到签发后的 Cookie 和网关自己的 Cookie；设备授权由网关执行。

## 2. 中转与应用

隧道代理从主机主动连接中转服务器，并在该连接上复用访客流量。中转根据隧道 ID 路由，登录仍由网关处理。终止 TLS 的中转运营方能看到访客流量，请在自己信任的基础设施上运行。

网页端使用 dsh 界面，并由鱼鱼远程优化布局和导航。Flutter 应用通过网关建立 Cookie 会话，使用 dsh RPC 和 `remote.mux` WebSocket。工作区和引擎都留在主机上。

## 3. 身份认证

- 密码使用 scrypt 哈希。默认失败五次后锁定，初始锁定为 60 秒。登录成功会注册设备会话。
- 签名的 `dsh_portal` Cookie 带有 HttpOnly 和 SameSite=Lax，绑定 User-Agent；网关识别为安全连接时还会设置 Secure。明文 HTTP 仍可能被截获。
- 配对码只能使用一次，按哈希存储，默认 180 秒过期。中转令牌是单独的凭据，只用于让代理连接中转，不用于登录 dsh。
- 密码模式下，非回环监听要求已设置密码。仅配对模式则需要配对码。开放模式仅限回环；不要通过隧道公开开放模式网关。

## 4. 仓库结构

| 路径 | 职责 |
| --- | --- |
| `index.js`、`cordis.patch.yml`、`install.*`、`tools/install-profile.mjs` | 插件注册、控制路由与安装 |
| `lib/` | 网关、登录页、代理、认证、状态、二维码与隧道代理 |
| `client.js`、`assets/`、`locale/` | 网页设置、工作区选择器、移动布局与本地化 |
| `tools/relay.mjs`、`tools/deploy-relay.sh` | 中转服务器与 systemd 部署 |
| `app/`、`packages/` | Flutter 应用和共享 Dart 包，包括门户和 dsh 客户端 |
| `test/`、`tools/cdp.mjs` | Node 测试和 Chrome DevTools 工具 |

## 5. 主机配置

`cordis.patch.yml` 的条目提供初始设置。重启后，门户面板保存的值优先。状态默认存放在 `$DSH_HOME/yuremote/`；未设置该变量时使用 `~/.dsh/yuremote/`。请将 `state.json` 保持为私有文件（权限 `0600`）。

| 键 | 默认值或用途 |
| --- | --- |
| `enabled`、`host`、`port` | `true`、`0.0.0.0`、`3081`；见[面板设置](GETTING-STARTED.zh-CN.md#远程访问设置) |
| `mobile` | `true`；启用移动浏览器布局 |
| `auth.mode` | `password`；也接受 `pair-only` 和仅限回环的 `open` |
| `auth.sessionDays`、`auth.maxFailures`、`auth.lockSeconds` | `30`、`5`、`60` |
| `tls` | 默认关闭；直连 HTTPS 时须同时指定 `certFile` 和 `keyFile`（PEM） |
| `tunnel` | 默认关闭；设置 `url` 和 `token` 才会连接，可选 `caFile` 或 `insecure` |
| `stateDir`、`brand` | 可选的状态目录和登录页名称 |
| `rateLimit` | 每个地址每 10 秒 `1200` 个请求；`0` 表示关闭 |

漏洞报告请见[安全政策](../SECURITY.md)。
