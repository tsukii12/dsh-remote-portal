# 部署公网中转（摘要）

[完整英文指南](DEPLOY-SERVER.md) · [文档索引](README.md)

家里的 dsh 主机主动连到中转，访客通过中转的 HTTPS 地址访问。家里不需要公网 IP，也不需要设置路由器端口映射。访问密码或配对码仍由 dsh 主机上的门户验证。

1. 在 dsh 主机上[安装插件并设置访问密码](GETTING-STARTED.zh-CN.md)。
2. 准备自己控制的公网 Linux 服务器。推荐使用域名（例如 `relay.example.com`）和受信任的证书。先配置域名解析，再按[安装步骤](DEPLOY-SERVER.md#3-one-command-no-arguments)在服务器上运行安装器。对外访客端口通常为 `443`，主机连接中转的端口通常为 `9443`；以安装器输出为准，在防火墙放行所用端口。
3. 安装器会显示 **agent endpoint** 和 **tunnel token**。在 dsh 面板打开 **远程访问 → 公网访问**，填写中转地址（例如 `tls://relay.example.com:9443`）和隧道令牌，然后连接。不要公开令牌，也不要把它写进截图或日志。
4. 面板显示已连接后，在另一台设备上打开访客 HTTPS 地址（形如 `https://relay.example.com/__t/EXAMPLE_ID/`），再用门户密码或配对码登录。访客地址与中转端点不是同一个地址。

**排查连接：** 在服务器运行 `yuremote status`，查看服务、隧道状态和访客地址。如果隧道离线，先检查主机到中转端口的连通性、TLS 配置和令牌。浏览器到中转的 HTTPS 与主机到中转的 TLS 是两段连接，分别检查。不要在公网使用明文 HTTP。

**升级旧中转：** 安装器会把标准 `dsh-relay.service` 迁移至 `yuremote-relay`，保留隧道令牌、证书续期、监听端口和域名，不改代理或防火墙。旧目录 `/opt/dsh-relay` 保留，迁移成功后会输出一条回滚命令。自定义 systemd 覆盖配置须先人工检查。

更多细节见英文指南：[证书选择](DEPLOY-SERVER.md#33-certificates) · [手动部署与反向代理](DEPLOY-SERVER.md#6-manual-deployment-advanced) · [管理与多台主机](DEPLOY-SERVER.md#7-managing-it-with-yuremote) · [故障排查](DEPLOY-SERVER.md#10-operations-and-troubleshooting)。
