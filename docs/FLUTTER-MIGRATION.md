# Flutter milestone 1 / Flutter 第一阶段

DRP imports dsh-Go v1.2.0 at
`c1a84e3f833ad59ff07a5027994dae3935907a2d`. The gateway remains MIT;
`app/` and imported Dart packages are AGPL-3.0. See their NOTICE files.
The original Swift client in root `ios/` is migration reference, not the
Flutter platform target (`app/ios/`).

DRP 基于上述 dsh-Go v1.2.0 提交。网关仍为 MIT；Flutter 应用及导入的 Dart
包为 AGPL-3.0，来源见 NOTICE。根目录 `ios/` 中的 Swift 客户端仅供迁移参考，
Flutter 的 iOS 工程为 `app/ios/`。

## Tests / 测试

Delivery-priority update: only the dedicated milestone portal tests are active
under `app/test/`. Imported legacy suites are quarantined in `app/legacy_test/`
and `app/legacy_integration_test/`; their full manifest, known failures and
restoration TODOs are in `app/LEGACY_TESTS_TODO.md`. No full-suite pass is claimed.

交付优先级调整后，默认只运行 `app/test/` 中第一阶段 portal 测试。旧测试暂放
`app/legacy_test/` 和 `app/legacy_integration_test/`；完整清单、已知失败和恢复
待办见 `app/LEGACY_TESTS_TODO.md`。没有宣称完整测试集通过。

The import omits upstream suites and probes for removed local runtime/bootstrap,
SSH, DSHarness Remote, WebViews/islands, on-device phone control, companion
and protected mascot/sprite features. Cross-feature tests that require those
implementations are omitted too. Shared generic fixtures and applicable
chat/session/provider tests are retained; their synthetic host identities use
portal hosts. Portal profile persistence, cookie isolation/removal, missing or
corrupt credentials, and expiry-to-login have dedicated app tests in
`app/test/portal/`. HTTP/WS authentication, pairing, QR parsing and prefixed
routes are covered by `packages/dsh_portal/test/`.

已移除针对本地运行时及引导、SSH、DSHarness Remote、WebView/island、本机
手机操控、伙伴和受保护吉祥物/精灵图的旧测试与探针，以及必须依赖这些实现的
交叉功能测试。保留通用夹具和适用的聊天、会话、模型渠道测试，测试主机身份
改为 portal。新应用测试覆盖保存主机、Cookie 隔离与删除、缺失或损坏凭据及
登录过期；适配包覆盖 HTTP/WS 认证、配对、二维码和路径前缀。

### Local validation environment / 本地验证环境

Use Flutter 3.47.7 (Dart 3.13.5). Widget tests need the upstream CJK font
collections; set `DSH_TEST_FONT_DIR` to an external directory containing
`NotoSansCJK-Light.ttc`, `NotoSansCJK-Regular.ttc` and `NotoSansCJK-Bold.ttc`.
Do not commit SDKs, font downloads, build outputs or golden failure images.
Golden regeneration is separate from normal snapshot verification. DRP branding
replaces upstream artwork; regenerated baselines must be reviewed accordingly.

使用 Flutter 3.47.7（Dart 3.13.5）。Widget 测试需要上游使用的 CJK 字体集合，
通过 `DSH_TEST_FONT_DIR` 指向含上述三个 TTC 文件的仓库外目录。不要提交 SDK、
下载的字体、构建输出或 golden 失败图。更新 golden 基线与普通快照验证是两件事；
DRP 品牌素材替换上游图像后，需检查更新的基线。

### Upstream heartbeat flake / 上游心跳不稳定测试

Only `healthy control ping/pong does not reconnect a quiet live surface`
in `packages/dsh_client/test/dsh_go_heartbeat_test.dart` is explicitly skipped.
On Flutter 3.47.7 / Dart 3.13.5 the unchanged v1.2.0 upstream checkout reproduced
`Bad state: StreamSink is closed` at its fixture's `_HostConnection.send`
(line 302). The skip is limited to that test, not the file or heartbeat
implementation. Other heartbeat/reconnect tests remain enabled.

仅显式跳过上述单项测试。未修改的 v1.2.0 上游在相同 SDK 下也复现夹具向已关闭
WebSocket 写入的错误。没有跳过整个文件，也未改变心跳实现；其余心跳和重连测试
继续运行。后续升级上游或修复夹具后应重新启用此项。
