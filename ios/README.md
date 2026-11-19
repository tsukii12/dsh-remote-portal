# dsh Remote — iOS preview

Native SwiftUI server management and sign-in, with the official dsh workspace in a persistent WKWebView. iOS 17+, no third-party dependencies. English/Chinese follow the device language.

## Build and run

Open `DSHRemote.xcodeproj` in Xcode, select **DSHRemote** and an iOS Simulator, then Run. For a physical device, select your signing team and a unique bundle identifier. The generated project is committed; XcodeGen is only needed after changing the project specification:

```sh
brew install xcodegen
xcodegen generate --spec ios/project.yml
xcodebuild -project ios/DSHRemote.xcodeproj -scheme DSHRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' build test
```

Tap **+** and enter a name and one HTTP(S) base address per line. Include relay path prefixes (`https://relay.example/__t/id/`). Alternatively paste a `.../__portal/pair?t=...` link; saving creates the server and opens native pairing confirmation. Long-press a server to edit; swipe to delete. Pairing tokens/passwords are not persisted by the app. Addresses are saved locally in UserDefaults.

Connecting races uncached health checks across all addresses with a three-second timeout. The first HTTP 200 wins; failed addresses do not end the race. The header shows the winning address, approximate latency and LAN/public classification. Login uses a shared keep-alive URLSession, never follows redirects, and transfers session cookies to the pre-warmed WKWebView with an identical User-Agent. Valid cookies survive app restarts. Session expiration returns to native login. Reload and logout are in the workspace toolbar; back returns to servers without logging out.

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
- The workspace is the server’s own UI, not a native rewrite. WebKit provides its standard camera/file picker (camera requires a physical device).
- No custom app icon in this preview. Server addresses are not encrypted; avoid embedding secrets in URLs. Session cookies use WebKit’s standard persistent data store.
- Tests cover normalization/path prefixes, pairing parsing/form encoding, and fastest-success/empty/failed races; real relay, physical camera, lockout and revoked-session flows need manual validation.
