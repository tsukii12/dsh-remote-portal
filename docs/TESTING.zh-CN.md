# 开发与测试

[English](TESTING.md) · [文档目录](README.md#简体中文)

插件和中转需要 Node.js 20 或更高版本。修改前可查阅[仓库结构](ARCHITECTURE.zh-CN.md#4-仓库结构)。保持改动聚焦，并在对应组件的测试套件中补充覆盖。

```sh
npm test                          # 鱼鱼远程 Node 测试，与 CI 相同
node --test test/host.test.mjs     # 网关与主机集成
node --test test/relay.test.mjs    # 中转与隧道集成
```

移动端套件包含真实 Chrome 检查。在另一个终端运行 `dsh web --port 3080 --no-open`，确保已安装鱼鱼远程。使用不带查询字符串的回环地址，以及启动链接中的令牌。不要分享该令牌。

```sh
CHROME_PATH=/path/to/chrome \
DSH_WEB_TEST_URL=http://127.0.0.1:3080 \
DSH_WEB_TEST_TOKEN='<local launch token>' \
npm test
```

Windows 下如果能找到 `dsh.cmd`，测试套件可以自动启动 dsh。Chrome 或运行中的实例不可用时，真实浏览器测试会跳过；报告浏览器验证之前请确认跳过数。

直接运行 `node --test` 还会找到仓库内的 Tavern 差分测试。其中的浏览器适配器测试需要 Node 的 `--experimental-vm-modules` 参数，不属于鱼鱼远程网关工作流。

Flutter 环境见[从源码构建](APP.zh-CN.md#从源码构建)。应用工作流使用以下检查；继承的旧测试不是当前应用的 CI 门槛。

```sh
cd app
flutter pub get
flutter analyze lib
flutter test test/portal
```

CI 在 Linux 上安装 Noto CJK 字体，并设置 `DSH_TEST_FONT_DIR=/usr/share/fonts/opentype/noto`。同一工作流还会分别在 `packages/dsh_client` 和 `packages/dsh_portal` 运行 `dart pub get`、`dart analyze`、`dart test`。
