# 文档 / Documentation

| 我想… / I want to… | 简体中文 | English |
| --- | --- | --- |
| 了解或安装插件 / Learn about or install the plugin | [项目首页](../README.md) | [Project overview](../README.en.md) |
| 连接第一台设备 / Connect my first device | [快速上手](GETTING-STARTED.zh-CN.md) | [Quickstart](GETTING-STARTED.md) |
| 部署公网中转 / Deploy a public relay | [部署摘要](DEPLOY-SERVER.zh-CN.md) | [Full deployment guide](DEPLOY-SERVER.md) |
| 了解架构或贡献代码 / Understand or contribute to the code | — | [Architecture](../ARCHITECTURE.md) · [Contributing](../CONTRIBUTING.md) · [Testing](TESTING.md) |
| 查阅更新或安全策略 / Check releases or security policy | — | [Changelog](../CHANGELOG.md) · [Security](../SECURITY.md) |

## 项目结构 / Repository map

| Path | 职责 / Responsibility |
| --- | --- |
| [`index.js`](../index.js), [`cordis.patch.yml`](../cordis.patch.yml) | 插件入口与宿主配置 / dsh plugin entry point and host configuration |
| [`lib/`](../lib/) | 网关、认证、状态、代理、二维码和中转客户端 / Gateway, authentication, state, proxying, QR encoding, and tunnel agent |
| [`client.js`](../client.js), [`assets/`](../assets/), [`locale/`](../locale/) | 远程访问面板、移动端样式与行为、翻译 / Remote Access panel, mobile styles and behavior, and locale strings |
| [`install.sh`](../install.sh), [`install.ps1`](../install.ps1) | dsh 主机上的插件安装脚本 / Plugin installers for the dsh host |
| [`tools/relay.mjs`](../tools/relay.mjs), [`tools/deploy-relay.sh`](../tools/deploy-relay.sh) | 公网服务器上的中转程序与安装脚本 / Relay and installer for the public server |
| [`test/`](../test/), [`tools/cdp.mjs`](../tools/cdp.mjs) | Node 测试与 Chrome 驱动 / Node tests and Chrome driver |
| [`docs/`](./), [`screenshots/`](screenshots/) | 使用指南与 README 截图 / Guides and README screenshots |
| [`package.json`](../package.json) | 插件导出、发布文件和兼容范围 / Plugin exports, package contents, and compatibility |
