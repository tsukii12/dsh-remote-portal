# DRP for Android

Fully native Kotlin / Jetpack Compose client for DeepSeek Harness's remote portal.
Requires Android 8.0 (API 26) or newer; application ID: `cn.tsukii.drp`. No WebView.

## Build and install

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
- Workspace/session drawer, pinned sessions, new chats, rename/archive and refresh.
- Streaming chat, Markdown and copyable horizontally scrolling code, expandable
  thinking and tool cards with command summaries and running/success/error status.
- Exact-input approval sheets, single/multiple-choice questions and custom answers.
  Requests only auto-open for the current chat; Later defers them without answering.
  Pending banners and drawer badges let you return to requests in any known session.
- Model selection, cancellation, history pagination, reconnect indicators and
  jump-to-bottom behavior.
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

Offline JVM tests port the iOS Connection, NativeState, Presentation, Transport and Listener contracts,
using the original sanitized JSON fixtures and MockWebServer HTTP/WebSocket listeners. iOS-specific
bundle/permission checks are replaced with Android branding/manifest checks. No live service test is
enabled and no real passwords/tokens are included.
