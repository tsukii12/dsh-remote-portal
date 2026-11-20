# Security policy · 安全政策

## Reporting a vulnerability

**Do not open a public issue.** Use GitHub **Security → Advisories → Report a vulnerability**, or contact the maintainer privately if that option is unavailable. Include the affected YuRemote version, platform, LAN or relay setup, the impact and a minimal reproduction. Remove credentials, pairing links and private data. Please allow time for a fix before public disclosure.

The project handles reports about the YuRemote gateway, browser UI, relay, installers and mobile app. Report dsh and other third-party issues upstream. See [architecture and security model](ARCHITECTURE.md#3-authentication) and [safe relay deployment](docs/DEPLOY-SERVER.md) for the trust model.

## 漏洞报告

**不要公开创建 Issue。** 请使用 GitHub **Security → Advisories → Report a vulnerability**，若入口不可用，请私下联系维护者。请说明受影响的鱼鱼远程版本、平台、局域网或中转配置、影响及最小复现步骤；请删除凭据、配对链接和私有数据。公开披露之前，请留出修复时间。

项目处理鱼鱼远程网关、网页界面、中转、安装脚本及移动应用的问题。dsh 和其他第三方组件的问题请报告给对应上游。信任模型见[架构与安全模型](docs/ARCHITECTURE.zh-CN.md#3-身份认证)和[安全部署中转](docs/DEPLOY-SERVER.zh-CN.md)。
