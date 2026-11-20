# 公网访问与中转部署

[English](DEPLOY-SERVER.md) · [文档目录](README.md#简体中文)

鱼鱼远程中转运行在**你自己的服务器**上，项目不提供托管服务。先确保[本地门户](GETTING-STARTED.zh-CN.md)可用。不要公开 dsh 自带的 Web 端口，也不要通过不可信的 HTTP 传输门户密码、Cookie、配对链接或中转令牌。

## 安装项目中转

在使用 systemd 的 Linux 服务器上，将 `relay.example.com` 之类的域名指向服务器。下载脚本，阅读后运行：

```sh
curl -fsSLO https://raw.githubusercontent.com/tsukii12/dsh-YuRemote/master/tools/deploy-relay.sh
sudo bash deploy-relay.sh
```

访客连接选 **HTTPS**。脚本支持通过 HTTP 验证（需开放入站 TCP 80）或 DNS 验证申请 Let's Encrypt 证书，也可以使用自己的 PEM 证书和私钥，或生成自签名证书。浏览器和应用不会自动信任自签名证书。脚本会安装 `yuremote-relay` 服务和 `yuremote` 命令；需要时也会安装 Node。再次运行可更新中转并保留配置。使用 `--reconfigure` 修改证书、反向代理或访客监听设置。

在服务器开放选定的访客端口（HTTPS 通常是 TCP **443**）和代理端口（通常是 TCP **9443**）。dsh 主机只需能向代理端口建立出站连接，不需要入站端口映射。两段连接相互独立：访客端启用 HTTPS 不会给明文代理端口启用 TLS。

## 连接 dsh 主机

1. 在服务器运行 `yuremote` 查看 **中转地址（endpoint）**，并私下用 `yuremote token` 获取令牌。
2. 在 dsh 打开 **远程访问 → 公网访问**，填入中转地址（例如 `tls://relay.example.com:9443`）和令牌，然后连接。只有在可信链路上明确配置明文代理端口时，才用 `tcp://relay.example.com:9443`。不写协议的地址会尝试 TLS，不会回退到 TCP。
3. 连通后打开 HTTPS **访客**地址，例如 `https://relay.example.com/__t/EXAMPLE_ID/`，登录门户。在应用中添加主机时保留完整路径。这个地址不是登录凭据。

| 命令 | 用途 |
| --- | --- |
| `yuremote` / `yuremote url` | 查看状态和访客地址 |
| `yuremote log -f` | 实时查看服务日志 |
| `yuremote restart` | 重启中转服务 |
| `yuremote token add` / `yuremote tokens` / `yuremote urls` | 添加另一台主机并查看隧道和地址 |
| `yuremote token remove <id>` | 移除一台主机的中转令牌 |
| `yuremote uninstall` | 卸载中转 |

每台主机使用不同的令牌和隧道路径。令牌泄露时，删除旧令牌，生成新令牌并重连。如果代理无法连接，检查 DNS、代理端口、令牌和 TLS 模式。优先使用有效证书；自建 CA 时可在主机配置中使用 `tunnel.caFile`，而不是关闭验证。

## 在反向代理后手动运行

手动安装需要 Node.js 20 或更高版本、私有令牌文件（权限 `0600`，每行一个令牌）和自行管理的服务。例如，中转用证书加密代理连接，另用 HTTPS 反向代理接收访客：

```sh
node tools/relay.mjs --token-file /path/to/tokens \
  --agent-port 9443 --http-port 127.0.0.1:8080 \
  --tls-cert /path/to/fullchain.pem --tls-key /path/to/key.pem \
  --public-url https://relay.example.com
```

将 HTTPS 请求转发到 `127.0.0.1:8080`，保留完整访客路径，转发 WebSocket 升级，不要缓冲流式响应。不要公开 8080；公开的是 HTTPS 反向代理和代理端口。鱼鱼远程中填入 `tls://relay.example.com:9443`。

## 使用已有隧道

已有私有组网或反向隧道时，不必部署项目中转。若隧道客户端运行在 dsh 主机上，将 **绑定地址** 设为 `127.0.0.1`，然后把隧道指向网关（默认 `http://127.0.0.1:3081`）。如果设备直接通过私有组网访问，则将网关绑定到该组网的地址。确保隧道转发流式 HTTP 和 WebSocket，并保留门户认证。经公网访问应使用受信任的 HTTPS，不要直接转发 dsh Web。
