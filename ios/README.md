# DRP — native iOS client

Native SwiftUI server management, sign-in, workspace sidebar and chat on a Foundation networking/state layer. iOS 17+, no third-party dependencies or embedded browser. English/Chinese follow the device language; system appearance controls light/dark mode. DRP keeps the existing bundle identifier.

## Build and run

Open `DSHRemote.xcodeproj` in Xcode, select **DSHRemote** and an iOS Simulator, then Run. For a physical device, select your signing team and a unique bundle identifier. The generated project is committed; XcodeGen is only needed after changing the project specification:

```sh
brew install xcodegen
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build test
```

Tap **+** and enter a name and one HTTP(S) base address per line. Include relay path prefixes (`https://relay.example/__t/id/`). Alternatively paste a `.../__portal/pair?t=...` link; saving creates the server and opens native pairing confirmation. Long-press a server to edit; swipe to delete. Pairing tokens/passwords are not persisted by the app. Addresses are saved locally in UserDefaults.

Connecting races uncached health checks across all addresses with a three-second timeout. The first HTTP 200 wins; failed addresses do not end the race. A single keep-alive URLSession serves HTTP and WebSocket requests with the same User-Agent and Origin. Login redirects are not followed. All response cookies enter HTTPCookieStorage and an explicit, file-protected cookie jar partitioned by the full server base (including port/path). Cookies survive app restarts; only that base's jar is sent. Session expiration returns to native login. Servers returns to the server list without logging out.

## Native interface

The server list and sidebar use **DeepSeek Remote** as the home title; the home-screen icon is still **DRP**. The adaptive sidebar is a separate column on iPad and native sidebar navigation on iPhone. Pinned chats come first, then workspaces and ungrouped chats. Tap a workspace's **+** for a new chat; long-press or swipe conversations to rename, pin/unpin or archive. Pull down to refresh. Switch servers or log out from the sidebar footer.

Search session names from the sidebar. **View options** enables message-content search and the archived view; archived rows offer **Unarchive**. Content-search errors retain local name filtering. **Add workspace** opens the Portal-backed host folder browser, including roots, parent navigation, direct paths and new folders. Workspace menus rename or remove the registration without deleting host files. Older Portals without folder routes can still register an explicit host path.

Chat supports live Markdown, expandable thinking, fenced code with copy/horizontal scrolling and compact tool cards with expandable results. Earlier history loads from the top. Scrolling up pauses automatic following; use the down arrow to return to the live edge. The prominent composer chip shows the model and thinking effort; its options group models by provider, allow explicit/default effort, access mode, plan mode and an agent preset before the first message. Reselecting a model preserves its explicit effort. Type `/` for host command suggestions or `/model` for native options. Commands use `commands/execute`, not ordinary prompts; `/export` offers a native share link. While running, send queues or steers a prompt separately from Stop. The queue dock supports edit, remove and steer using the host's item id. Native sheets handle tool approvals and single/multiple-choice questions with custom answers. A connection banner reports reconnects without hiding the transcript.

服务器列表和侧栏标题为 **DeepSeek Remote**，主屏幕图标名称仍为 **DRP**。侧栏支持按名称或消息内容搜索、查看与恢复归档会话，以及通过门户主机文件夹浏览器创建、重命名和移除工作区。聊天输入区显示模型与思考强度，可选择访问权限、计划模式及首次发送前的代理预设；输入 `/` 查看命令建议。运行中可排队或立即引导消息，并编辑、移除或引导队列项目，停止按钮保持独立。

`Assets.xcassets/AppIcon.appiconset` contains the supplied opaque 1024px whale icon as a single-size iOS AppIcon.

## Native state layer

- `PortalAPI`: RPC envelopes, login/logout, HTTP/business errors and session-expired state.
- `PortalMux`: multiplexed logical AsyncThrowingStreams, unsubscribe/end/error, reconnect backoff and fresh stream openings. URLSession answers protocol pings automatically.
- `NativeConnection`: owns a shared `RemoteEvents` stream and `SidebarStore`; call `start()`/`stop()` with screen lifecycle. Create chats with `chat(sessionID)` so they share that event generation.
- `SidebarStore`: ordered workspace/session grouping, pinned/archive membership, live projections/status/activity and mutation actions. Grouping waits for the workspace baseline on first connection and reconnect; the sidebar shows a loading state until then. 初次连接与重连时等待工作区基线到达后再分组，期间显示加载状态，避免工作区会话闪现在“未分组”中。
- `ChatStore`: snapshot/page/surface reducers, transient assistant blocks, compact stream expansion, paired tool results, optimistic request reconciliation, prompt/cancel/model actions. Call `start()`/`stop()` with chat lifecycle. `transcript` contains durable/optimistic items; `inProgress` is the separate transient assistant item.
- `RemoteEvents`: pending approval/question requests, current clientId, cancellation and generation-safe answers. Approval decisions are `allowed-once`/`rejected`, not booleans on the wire.

Sanitized `live-*.json` files in `DSHRemoteTests/Fixtures` are test-bundle resources. Reducer and transport-contract tests run offline by default.

### Relay tool-output verification

The real-relay `run tool` → **Allow once** capture contains a successful `ls` result with the literal text `(no output)` in `tool/result.data.message.content[0].text`. Its working folder contained only a hidden entry, so ordinary `ls` had nothing to print. A control session in a populated workspace returned its file listing through exactly the same field. The test model gave the same generic “The tool returned a result” response in both cases; that response does not establish nonempty stdout. No reducer change was needed.

`live-relay-tool-results.json` retains the captured empty/nonempty tool-call and result shapes and output text, with identifiers/paths replaced and unrelated model replay metadata removed. The fixture test verifies exact output preservation and tool-call pairing. Credentials, cookies and relay addresses are not included.

真实中继的 `run tool` → **Allow once** 抓包表明，成功执行的 `ls` 已在 `tool/result.data.message.content[0].text` 中返回字面值 `(no output)`。该工作文件夹仅有隐藏条目，普通 `ls` 因此没有输出；对照会话在有文件的工作区通过同一字段返回了文件列表。测试模型在两种情况下都回复相同的通用“工具已返回结果”文本，不能据此判断标准输出非空，无需修改归约器。

`live-relay-tool-results.json` 保留两种抓包的调用、结果结构及输出文本，替换标识符与路径，并移除无关模型回放元数据；测试验证输出原样保留且正确关联工具调用，不含凭据、Cookie 或中继地址。

### Opt-in live smoke test

Requires the local fake model setup at `~/fake-llm/README.md`, dsh on 3080 and the portal on 3081. It uses the throwaway password `demo-pass-123`, creates then archives one session, and allows only the requested fixture's pwd escalation. Never enable it against another service.

```sh
TEST_RUNNER_DSH_LIVE_SMOKE=1 xcodebuild -project ios/DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -collect-test-diagnostics never -only-testing:DSHRemoteTests/LiveSmokeTests test
```

Xcode passes the `TEST_RUNNER_`-prefixed variable into the test runner as `DSH_LIVE_SMOKE`. Output prefixed `LIVE PASS` proves native URLSession login, sidebar baseline, session creation, two local fake routes (`native-demo` and `native-demo-fast`) with explicit Off/High thinking effort, access-mode commands, Portal folder browsing, incremental text, reconnect, approval answer and committed tool/final response. Both fixture routes must be configured outside the repository; see `~/fake-llm/README.md`.

Pending approvals and questions can be closed or swiped away without answering. The pending-request banner remains available in chat and opens the oldest request; session badges open that session's request directly. Only requests for the open session appear automatically. Navigation matches the waterfall envelope's `agentId` exactly to a known session ID, never the tool's request body or an inferred parent session. Unknown agents remain reviewable without changing chats.

待处理的授权或问题可通过关闭按钮或下滑暂时收起，不会发送答复。聊天中的待处理请求横幅可重新打开最早的请求，会话角标可直接查看该会话的请求。仅当前会话的请求会自动弹出；导航使用 waterfall 信封中的 `agentId` 精确匹配已知会话 ID，不使用工具请求体中的字段，也不推测父会话。未知代理的请求仍可查看，但不会切换对话。

## Local demo

From the repository root:

```sh
npm i -g @deepseek-ai/dsh
dsh --profile web --dump-config
sh install.sh -p web
dsh web --port 3080 --no-open
```

Set a throwaway password in dsh Settings → Remote access (or POST JSON `{"password":"demo-pass-123"}` to `http://127.0.0.1:3080/dsh-remote-portal/password` with `Origin: http://127.0.0.1:3080`). Add `http://127.0.0.1:3081/` in the Simulator and sign in. On a physical device use the Mac’s LAN address instead.

## Limits

- HTTP LAN connections are allowed by ATS. **Self-signed TLS is not bypassed**: use a trusted certificate or install and trust your local CA on the device. There is deliberately no global certificate bypass.
- Attachments, settings and terminal UI are not implemented.
- Server addresses are not encrypted; avoid embedding secrets in URLs. Cookie files are in Application Support with iOS data protection; deleting a saved server does not revoke its remote session (log out first).
- Real relay, physical-device networking, lockout and certificate flows need manual validation.
