# DRP for Android

Fully native Kotlin / Jetpack Compose client for DeepSeek Harness's remote portal.
Requires Android 8.0 (API 26) or newer; application ID: `cn.tsukii.drp`. No WebView.

## Build and install

The drawer footer's Settings action opens native host defaults (model, effort and
access), provider catalog status, authorized devices with confirmed revoke, and
app version. Writes use namespace revisions; conflicts reload without replaying
the write. The portal does not identify the current device: revoking this phone
can sign out the app and requires explicit selection and confirmation.

Requires JDK 17 and Android SDK platform 35 / build-tools 35.0.0. Set `ANDROID_HOME`
to your SDK, or set `sdk.dir` in an untracked `local.properties`. The checked-in
Gradle wrapper downloads Gradle 8.9; dependencies use Google Maven and Maven Central.
From this directory:

```sh
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n cn.tsukii.drp/.MainActivity
```

Alternatively, copy `app/build/outputs/apk/debug/app-debug.apk` to your Android
device, open it, and permit installation from that source when Android asks.
Debug APKs are intended for development, not production distribution.

On the computer running dsh, install this repository's plugin and enable Remote
access with a password. In DRP, add a named server with one gateway address per
line, or paste a pairing link. LAN HTTP and HTTPS relay addresses are supported;
preserve the full relay path prefix. Use trusted networks for plain HTTP.

## Features

- Saved server names/addresses, editing/deletion, fastest-address health race,
  LAN/Public latency labels, pairing and password login.
- Persistent per-server cookies, logout and automatic sign-in expiration.
- Workspace/session drawer, pinned sessions, new chats, rename/archive/unarchive
  and refresh. Search locally by name or enable message-content search under
  **View options**; content-search failures retain name matches. View archived
  sessions from the same menu.
- **Add workspace** browses folders on the dsh host (roots, parent, direct paths
  and new folders). On older portals, enter an explicit host path and use it.
  Workspace menus rename or remove registrations, never host files.
- Streaming chat, Markdown and copyable horizontally scrolling code, expandable
  thinking and tool cards with command summaries and running/success/error status.
- Session token/context usage in the composer, completed-turn usage when the
  loaded history has complete attempt evidence, and a bilingual usage detail
  sheet. Unknown counts stay unknown; zero is not treated as missing. Account
  balances appear only when served and available from the host.
- System image/file pickers stream content URIs to staged uploads, with a
  progress/retry/remove rail and attachment-only messages. Host image limits
  control admission; receipts stay scoped to the current chat draft. File cards
  and authorized image previews render in messages (inline previews up to 8 MiB).
- Debounced, cancellable `@` completion for workspace files/directories (including
  quoted names) and host-provided session mentions, preserving cursor position.
- Chat-top-bar Files panel: session-scoped expandable workspace tree, name/path
  search, refresh and live change/reset invalidation. Read-only text previews use
  version-checked 200-line lazy pages with automatic loading, selection and copy
  (1,048,576-character preview cap); native
  images and shared downloads use bounded multipart reads (8 MiB, 256 KiB chunks).
  File rows/previews can insert a quoted `@` mention into the composer.
- Exact-input approval sheets, single/multiple-choice questions and custom answers.
  Requests only auto-open for the current chat; Later defers them without answering.
  Pending banners and drawer badges let you return to requests in any known session.
- Composer chips show the model, thinking effort, access mode and agent preset.
  Chat options refresh on opening: provider-grouped models, explicit/default
  effort, session access, plan mode and agent presets before the first message.
  Reselecting a model preserves its explicit effort. Full host access requires
  confirmation.
- Type `/` for host command suggestions. Commands use `commands/execute`, not
  prompts; `/model` opens options and `/export` downloads the portal ZIP and
  offers Android's native share sheet with a temporary read-only content URI.
- While running, queue or steer new messages separately from Stop. The queue
  dock edits, removes or steers host queue items and reconciles optimistic sends
  by `rpcId`.
- Cancellation, history pagination, reconnect indicators and jump-to-bottom.
- English/Chinese UI, system light/dark theme, and friendly errors with raw Details.

## Tests

```sh
./gradlew --no-daemon testDebugUnitTest assembleDebug
```

JVM tests use JUnit and MockWebServer, with sanitized iOS JSON fixtures under
`app/src/test/resources/Fixtures/`. Reports are generated at
`app/build/reports/tests/testDebugUnitTest/index.html`. They need no live server
or secrets. Live emulator testing uses `10.0.2.2` for a gateway on the development
computer; a phone needs the computer's LAN address or a relay URL. Never put real
passwords or tokens in source, fixtures, screenshots or committed logs.

## Architecture and iOS mapping

The native iOS client is the behavioral reference. Kotlin files live in
`app/src/main/java/cn/tsukii/drp/`:

| iOS source | Android equivalent |
| --- | --- |
| `App.swift` | `MainActivity.kt`, `AppUI.kt`: theme, server management, connection/login gate |
| `Connection.swift` | `Connection.kt`, `CookieVault.kt`: URL normalization, health, auth, storage |
| `PortalAPI.swift`, `PortalMux.swift` | `PortalAPI.kt`, `PortalMux.kt`: RPC and multiplexed WebSocket streams |
| `RemoteEvents.swift`, `SidebarStore.swift` | `RemoteEvents.kt`, `SidebarStore.kt`: shared events and navigation state |
| `ChatStore.swift` | `ChatStore.kt`: compact stream/surface reducers, optimistic messages, tool-result pairing |
| `WorkspaceView.swift`, `ChatView.swift` | `WorkspaceUI.kt`, `ChatUI.kt`: drawer, transcript and composer |
| `ChatOptionsView.swift`, `HostFolderView.swift` | `ChatOptionsUI.kt`, `HostFolderUI.kt`: native options and host folder sheets |
| `InteractionSheet.swift` | `InteractionUI.kt`, `Presentation.kt`: approval input loading and question drafts |
| Android interaction routing | `InteractionRouting.kt`: current-chat auto-presentation, deferred requests and session badges |
| `MarkdownView.swift` | `ChatUI.kt`, `Presentation.kt`: native Markdown and tool presentation |
| `JSON.swift` | `JSON.kt`: JSON helpers/localization; `ErrorPresentation.kt` classifies display errors |

## State and lifecycle

`PortalURL` normalizes full bases (including relay prefixes) and extracts pairing tokens.
`ServerStore` saves only server IDs/names/addresses to app-private SharedPreferences. Never save
passwords or pairing tokens. Create one `PortalClient(CookieVault(File(context.filesDir, "PortalCookies")))`
and share it across connections. Cookie jars are partitioned by full normalized base, including
port and path. Backups are disabled. TLS uses platform trust; HTTP LAN connections are allowed.

`PortalAPI` uses the iOS client's exact User-Agent for all HTTP requests and the mux handshake,
plus Origin. Redirects are deliberately disabled. Observe `sessionExpired` to return to sign-in.
`NativeConnection.start/stop` own sidebar and shared events; create chats via `connection.chat(id)`.
Call chat `start/stop` with its screen lifecycle. Stopping a connection does not log out or clear cookies.
`state` on `SidebarStore`, `RemoteEvents`, `ChatStore`, and `ApprovalInputLoader` is an immutable
StateFlow snapshot. Reducers and lifecycle methods are main-dispatcher confined, like the iOS
MainActor implementation; scopes can be injected for tests. Cancel the owning scope after final teardown.
The mux exposes cold, single-subscription logical Flows: collection opens a stream and cancellation
sends cancel. It shares one OkHttp WebSocket, injects connection-reset on loss, reopens subscriptions
with exponential backoff (1–30 seconds), and fails active streams on HTTP 401 or logout.

For binary RPCs, `rpcBinary()` returns the JSON metadata in `value` and exact
byte arrays through `bytes("data")` (or the corresponding nested value path).
Multipart responses reject missing/duplicate/unreferenced parts and invalid
attachment paths, with a 64 MiB aggregate limit. Ordinary `rpc()` remains JSON-only
and refuses to silently discard binary attachments.

`mux.openDuplex()` returns a single-generation handle with `frames`, `send`,
`endInput` and suspending `close`. Close it in `finally`. Connection loss ends
that handle: callers must explicitly open a new one and recover from its snapshot.
Input is never queued offline or replayed; stale handles refuse writes even once
the shared socket reconnects. Duplex receive queues and outgoing frame/socket
buffers are bounded. Protocol-specific acknowledgements and input windows remain
the caller's responsibility. Existing chat/event Flows still reopen automatically.

Offline JVM tests port the iOS Connection, NativeState, Presentation, Transport and Listener contracts,
using the original sanitized JSON fixtures and MockWebServer HTTP/WebSocket listeners. iOS-specific
bundle/permission checks are replaced with Android branding/manifest checks. No live service test is
enabled and no real passwords/tokens are included.

`NativeControlsTests` ports the latest iOS options/commands/queue/workspace tests:
exact RPC arguments, projection cursor ordering and resets, metadata refresh,
queue reconciliation, archive/search filtering, Portal folder HTTP routes and
ZIP validation, plus empty/error/401 cases. `session/control` and
`session/observeState` follow changes while a chat is open.

侧栏可按名称或消息内容搜索、查看与恢复归档会话；工作区支持主机文件夹浏览、
新建文件夹、重命名和移除记录（不删除文件）。输入区显示模型和思考强度；聊天
选项在打开时刷新，并提供访问模式、计划模式和首次发送前的代理预设。输入 `/`
查看命令建议，`/export` 分享会话日志；运行中可排队或立即引导消息，队列支持
编辑、移除和引导，停止按钮保持独立。
