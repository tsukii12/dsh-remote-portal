# Changelog

All notable changes to this project. The format is loosely [Keep a Changelog](https://keepachangelog.com/);
versions are the plugin's own, not dsh's.

## 0.4.4 — 2026-10-21

### Fixed — the desktop app lost its "open in …" actions
The mobile layer engaged purely on window width, so a narrow desktop window was
treated as a phone: the remote-only trimming then hid "在资源管理器/VS Code 中打开",
"打开配置文件" and similar entries **inside the local Electron app**, where they are
perfectly valid.

- `activate()` now returns immediately when the page is loaded from `file:`
  (or `chrome-extension:`): the desktop shell is never a phone, at any width
- the remote path was already origin-gated and is unchanged
- a regression test asserts both guards so this cannot come back

### Tests
- 79 tests green (one new).

## 0.4.3 — 2026-10-21

### Removed
- **"同时退出所有已登录设备"** from the password section, per request. Changing the
  password no longer touches other sessions — it only replaces the credential.
  Devices can still be revoked one by one in 已授权设备. The state field, the
  request key and the two locale strings went with it.

### Tests
- 78 tests green. (One browser test timed out once under parallel load at 64 s and
  passed on its own in 10.8 s; a full re-run was green.)

## 0.4.2 — 2026-10-21

### Changed — the relay field takes an address and a port, nothing else
Typing a scheme was busywork: you had to know whether the server speaks TLS, and
getting it wrong produced `ECONNRESET` with no explanation. The field now accepts
`203.0.113.10:9443` (or a hostname) and the transport is detected on connect:

- new `auto://` transport: try TLS, and if the handshake fails, drop to plain TCP
  and remember it, so the retry succeeds without the user seeing an error
- the gateway normalises a bare `host:port` to `auto://` and rejects nonsense with
  a readable message instead of a silent default
- `createTunnel` accepts a bare address too, so programmatic callers behave the same

Verified against the live relay: `43.153.152.119:9443` connected over TLS and came
online with no scheme typed.

### Changed — gateway status text is translated in the panel
`upstream 127.0.0.1:19887 did not answer` is a log line, not a sentence. The
gateway stays language-neutral (it feeds logs and JSON too); the panel now renders
it as "连不上本机 dsh（127.0.0.1:19887）。它可能没在运行，或端口变了。" (or the
English equivalent), and translates "the local listener is not running" as well.

### Tests
- 78 tests green.

## 0.4.1 — 2026-10-21

### Fixed — the bare IP started showing the panel's default site
After switching from proxy mode to direct mode, `http://<ip>/` displayed the
1Panel welcome page instead of being refused. The cause was a **stale nginx
config**: the generated `dsh-relay.conf` had been deleted but nginx was never
reloaded, so it kept serving the old block — which handled only `/__t/` and let
every other path fall through to the default site.

- Direct mode now deletes a leftover proxy block **and reloads** nginx.
- The generated nginx block ends with `location / { return 404; }`, so even in
  proxy mode the rest of that host answers 404 instead of the default site.

Verified from outside: `http://<ip>/` closes the connection (444, the rule the
server already had for direct IP access), while
`http://<ip>:10003/__t/<id>/` still returns the login page.

### Tests
- 78 tests green.

## 0.4.0 — 2026-10-21

### Changed — the panel is redesigned around density
The old layout put the address and the pairing code in two columns of very
different height, which left a large empty block under the address. It is now two
horizontal strips: the address on its own line, then the pairing block laid out in
a row (code, explanation, buttons). Nothing is left floating:

- the QR is 112 px in the connect strip and 150 px inside the public card (it was
  216 px and drove the card height)
- the actions row is under the address strip, sized to its content
- below the strips, a two-column grid: 访问控制 | 公网访问, with 已授权设备 spanning
  both columns so it never sits alone in a half-empty row
- settings-page type scale kept (15 px titles, 13.5 px labels, 36 px inputs)

### Added — `drp`, a management command
The installer now writes `/usr/local/bin/drp`:

```console
$ drp            # service, ports, tunnel state, traffic, public URL
$ drp url        # just the public URL
$ drp token      # just the tunnel token
$ drp start|stop|restart
$ drp log -f
$ drp config     # the saved answers
```

It reads the saved configuration, so it keeps working regardless of where the
installer lives.

### Changed — the installer speaks English by default
All prompts and messages are English; `--lang zh` (or the first question in
interactive mode) switches the whole run to Chinese. Same script, same behaviour.

### Fixed
- **`--yes` no longer changes the entry point.** It used to answer the proxy
  question with its default, so an unattended re-run flipped a direct install to
  nginx. It now keeps what the saved config says.
- **Direct mode keeps its port consistent**: the public port *is* the listening
  port, so both are now kept in step instead of drifting apart in the summary.

### Tests
- 78 tests green.

## 0.3.9 — 2026-10-21

### Fixed — the public URL worked only if you typed it exactly right
Accessing `/__t/<id>` **without the trailing slash** produced
`Unknown tunnel: No tunnel named __portal is registered here.` The page loads, but
relative links resolve against the parent directory, so the login form posted to
`/__t/__portal/login` — and the relay read `__portal` as a tunnel id.

- The relay now **301-redirects** `/__t/<id>` to `/__t/<id>/` before proxying.
- The URL it reports (and the panel shows, and the QR encodes) carries the
  trailing slash.

### Fixed — redirects escaped the tunnel
After a pairing login the browser was sent to `/`, i.e. the relay's own root page
instead of the app. The relay strips its prefix before forwarding, so the gateway
had no idea it was mounted somewhere.

- The relay now sends `X-Forwarded-Prefix: /__t/<id>`.
- The gateway prefixes its redirects with it (`withMount`), so login, logout and
  stray `/__portal/*` paths all land back on the app — and a direct visitor (no
  header) still gets plain `/`.

Verified through the live relay on port 10003: bare URL 301 → `/__t/<id>/`, login
page 200 (29,666 B), pairing 303 → `/__t/<id>/`, app 200 with `__DSH_BOOT__`.

### Tests
- 78 tests (two new: the relay's slash redirect, and the gateway prefixing its
  redirects when a proxy reports a mount point).

## 0.3.8 — 2026-10-21

### Changed — the installer asks, it does not require arguments
`deploy-relay.sh` is now an interactive installer: run it with **no arguments** and
it detects the environment, asks six questions (every one has a default, so Enter
Enter Enter works), and finishes the whole setup. Answers are written to
`/var/lib/dsh-relay/deploy.conf`, so a re-run offers what is already installed.

### nginx is optional now
The entry point is chosen from what the machine already has:

| Detected | What the script does |
|---|---|
| Caddy | writes a Caddy site (automatic HTTPS) |
| nginx, including 1Panel's containerised openresty | writes one `server` block for `/__t/` only, validates with the *running* server, then reloads |
| neither | **no proxy at all** — the relay listens publicly on the chosen port |

Everything is validated before it is applied: a rejected nginx/Caddy config is
removed instead of reloaded.

### Fixed
- **Ports drifted on every re-run.** The occupancy check counted the relay's own
  listener as "in use", so 9443/8080 walked to 9444/8081 and then 9445/8082. The
  script now reads its own ports out of the unit file and treats them as free.
- Self-signed certificates are generated for the actual host (SAN = `IP:…` or
  `DNS:…`), not a fixed name.

Verified on a real host, twice in a row: identical ports both times, TLS on 9443,
health on 8080, nginx reloaded from inside the container, tunnel `online`, and
`http://<ip>/__t/<id>/` serving the login page (200).

### Tests
- 76 tests green.

## 0.3.7 — 2026-10-21

### Added
- **"信任自签名证书（跳过证书校验）"** in the 公网访问 card. A relay with a
  self-signed certificate cannot be verified by name, so TLS was impossible to use
  from the UI at all — the only way was the config API. The choice is sent with the
  endpoint, persisted, and `status.public.insecure` reports it back so the box shows
  what is actually in effect after a reload.

### Fixed
- **Re-running the installer silently downgraded encryption.** `./deploy-relay.sh`
  without `--tls-cert/--tls-key` rewrote the unit as plain TCP, so a relay that was
  serving `tls://` came back as `tcp://` and every client that had been told to use
  `tls://` started getting `ECONNRESET`. The script now reuses the certificate pair
  already installed in `/var/lib/dsh-relay/tls` when no flags are given, and says so.

Verified: `status.public.insecure = true`, tunnel `online`, `http://<ip>/__t/<id>/`
serving the login page (200), and the checkbox rendering checked on reload.

### Tests
- 76 tests green.

## 0.3.6 — 2026-10-21

### Fixed — three bugs that together made public access impossible
1. **A re-run never applied its new flags.** The installer used
   `systemctl enable --now`, which is a no-op on an already-running unit, so
   `--tls-cert` (or a new port) was written into the unit file and then ignored:
   the old process kept serving. It now restarts the unit.
2. **TLS could not be configured at all.** `--tls-cert` / `--tls-key` were not
   accepted, so the agent port could only ever be plain TCP. Both flags exist now,
   the pair is validated, and `tls://` is printed when TLS is on.
3. **The nginx snippet was unusable.** The unit heredoc was unquoted, so nginx's
   own `$http_upgrade` was expanded by the shell (`unbound variable`).

### Added
- **`--nginx`**: writes a scoped `dsh-relay.conf` (one `server` block for this
  host, `/__t/` only), validates it **with the running server** — inside the
  1Panel/openresty container when that is how nginx runs — and only then reloads.
  A config that fails validation is removed instead of reloaded.

Verified end to end on a real server: `tls://<ip>:9443` accepted a hand-built
HELLO (`REPLY 174B type=2`), the panel reported the tunnel **online**, and
`http://<ip>/__t/<id>/` returned the login page (200, 29,666 B, Harness mark) and
then the app (200, `__DSH_BOOT__` present) after a pairing login.

### Tests
- 76 tests green.

## 0.3.5 — 2026-10-21

### Fixed
- **The script addresses a copy that lost its mode bits.** A checkout, a paste or a
  tar from a Windows host arrives as `-rw-r--r--`, so `./deploy-relay.sh` fails
  with `command not found` even though the file is fine. It now re-applies its own
  exec bit before doing anything else.
- **The endpoint line prints the real host.** It used to say
  `tcp://<this-server-ip>:9443`, which is not something you can paste; it now
  derives the host from the resolved public URL, so the line reads
  `tcp://43.153.152.119:9443`.

Verified on the deployment host: service `active` + `enabled`, 9443 plain TCP,
8080 loopback-only, and a hand-built HELLO frame answered with
`REPLY 174B type=2` (WELCOME).

### Tests
- 10 relay tests green.

## 0.3.4 — 2026-10-21

### Fixed — the relay endpoint printed the wrong scheme
`deploy-relay.sh` told the operator to paste **`tls://<ip>:9443`** even though the
agent port is **plain TCP** unless the relay was started with `--tls-cert` /
`--tls-key`. Following the printed instruction made every connection fail, and the
server could only report `frame too large: <garbage>` because it was reading a TLS
ClientHello as a frame header.

- The script now prints the scheme it actually configured (`tcp://` by default) and
  explains how to switch to `tls://`.
- The panel's placeholder was `tls://relay.example.com:9443`; it is now
  `tcp://203.0.113.10:9443`, the form that works out of the box.
- `docs/DEPLOY-SERVER.md` has a table for "which scheme do I fill in", states that
  443's HTTPS protects the *visitor* hop and has nothing to do with the agent hop,
  and spells out that plain `tcp://` is visible in transit.
- The relay now names this mistake instead of leaking a framing error: a TLS
  ClientHello is reported as such, and an HTTP request line is reported as
  "something between the host and this port is rewriting the connection".

Verified with a hand-built HELLO frame against a live relay: `REPLY 174B type=2`
(WELCOME) once the transport was a raw TCP stream.

### Tests
- 76 tests green; the 10 relay tests cover both transports end to end.

## 0.3.3 — 2026-10-21

### Changed — the panel is smaller, and only shows what you act on
Recomposed around the two things a user does: **connect a device**, and **change
a setting**.

- **A connect banner at the top**: the LAN address and the pairing code sit side
  by side, because they are two halves of the same action.
- **Two columns below**: 访问控制 + 已授权设备 on the left, 公网访问 on the right.
- **Removed**: the "运行中 / 出错" status pill, 连接诊断, 最近访问, and the firewall
  hint. The state is still visible where it matters (the first-run banner, the
  pairing note) but the page no longer carries a read-only diagnostics dump.
  Their loaders and fetches are gone too, so no request is made for a card that
  does not exist.
- **Typography tightened** to settings-page scale: 15 px section titles, 13.5 px
  labels, 13 px hints, 36 px inputs, 34 px buttons (`drp-btn-sm` at 28 px), 7 px
  radii. The page header keeps the host's 20/500 title.
- **The empty pairing slot is a dashed well**, not a white QR plate — a blank
  white square reads as a broken image. The white plate now appears only around
  an actual code (`:has(.drp-qr-img)`).

### Tests
- 76 tests green (~66 s).

## 0.3.2 — 2026-10-21

### Added
- **`tools/deploy-relay.sh` — one command to put the relay on a server.** It
  checks Node, installs to `/opt/dsh-relay`, generates the tunnel token, writes
  and starts a systemd unit, optionally adds a Caddy site with `--caddy` (no
  buffering), then prints the two values to paste into the panel and the public
  address. `--no-systemd` installs beside the script for a rootless trial;
  `--uninstall` reverses everything. Verified on Debian 12: a relay installed by
  the script carried a real tunnel end to end — login page 200 (29,802 B, whale
  mark), pairing 303 → `/`, app 200 with `__DSH_BOOT__`, `/__relay/health` green.

### Fixed
- **`--http-port 127.0.0.1:8080` was silently ignored** and fell back to
  `0.0.0.0:8080` — the opposite of what the flag asked for, and the form the
  documents told people to use. All three listener flags now accept `port` or
  `host:port`, the HTTP visitor port defaults to **loopback**, and a malformed
  value is an error instead of a silent default.
- The generated usage text contained a backtick inside a template literal, which
  broke the module at load time.

### Tests
- 76 tests green.

## 0.3.1 — 2026-10-21

### Reverted
- **The session status line is untouched again.** 0.2.9 shortened it ("16 轮 1270
  步" removed, "缓存命中" → "缓存"); the host's own wording is back, verbatim, on
  every width. The rewriting helper and its call site are gone rather than
  disabled, so no future change can bring it back by accident.

### Tests
- 76 tests green.

## 0.3.0 — 2026-10-21

### Changed — the panel is a real page, not an overlay
The host exposes two slots that together make a page: `sidebar.panellist` (the
button) and `main` (a keyed slot dispatched by that entry's **id**). Registering
the same id in both — which is exactly what `client-ui-plugin-manager` and
`client-ui-schedule` do — gives a page switch with no overlay at all:

- selecting 插件 or a session now **leaves** the panel by itself; the X is gone
- the conversation DOM is replaced instead of being covered, so the sidebar and
  every navigation path keep working
- the sidebar entry is a first-class row with the Harness mark, next to 插件 /
  自动化任务, and shows the active state the host gives it
- `?panel=1` selects that row instead of forcing a view

Verified in a live instance: `pageRendered: true`, `conversationGone: true`,
`sidebarWidth: 280`, and `panelGoneAfterSwitch: true` after clicking 插件.

### Changed — the page follows the host's own typography
Measured off the 插件 page and applied: 48 px page gutters, **20 px/500 title**
with a 16 px supporting line, sections as divider-separated groups instead of
cards, 16 px body text, 14 px labels and hints, full-width inputs, two columns
when the page is wide and one when it is not. The duplicate title (page header +
section header) is gone.

### Removed
- the `shell.overlay` sheet and the `sidebar.footer.action` entry: one home, one
  navigation path.

### Tests
- 76 tests green (~64 s).

## 0.2.9 — 2026-10-21

### Changed
- **One home for the panel.** The Settings → 远程访问 section is gone: the sidebar
  entry is the destination, and a second copy inside Settings duplicated every
  control and read like a different page.
- **The folder picker is framed like the panel** — it measures the centre column
  too, so a desktop window keeps its sidebar instead of getting a full-screen
  cover. Phones still get the whole screen (there is no sidebar there).
- **The phone status line is trimmed.** "16 轮 1270 步 · 263 tok/s" loses the round
  and step counters, and "缓存命中" becomes "缓存": those two segments are what
  pushed the numbers off a 390 px screen, and the rest of the line already carries
  the useful information. Rewritten at the text level — the host component has no
  stable hook, so the pattern is the contract.
- **README rewritten to a publishable shape** (zh + en, same structure): centred
  header with badges and a table of contents, one screenshot of the real panel, a
  features table, a three-step quick start, a "how it works" section that explains
  *why* each layer exists, a security model, a real test table, an FAQ with
  collapsible answers (restart, dead buttons, LAN/public troubleshooting, device
  revocation, shared `DSH_HOME`), the file map, and known limitations — including
  the honest one: the panel presents as a main-area page without replacing the
  host's DOM.

### Tests
- 76 tests green (~68 s).

## 0.2.8 — 2026-10-21

### Changed
- **The panel is a page of the main area, not a full-screen cover.** It is
  measured against the centre column (`--drp-main-*` published from the live
  geometry) so it occupies exactly the region that 插件 / 自动化任务 use, and the
  sidebar stays visible and clickable. The entry reads as the active row while it
  is open, like the host's own panel rows.
- **Plugin metadata rewritten** — "为 DeepSeek Harness 添加远程访问能力，支持局域网和
  公网访问。" — and the plugin icon is now the Harness mark itself, so the plugin
  manager shows it as part of the product.
- **The login page's favicon is the Harness whale** (inline data URI, no extra
  request), matching the mark in the page header.

### Fixed
- `frameOverlay()` referenced a helper that does not exist in that closure, so the
  framing silently did nothing and the panel still covered the window.

### Tests
- 76 tests green.

## 0.2.7 — 2026-10-21

### Added
- **New folder while picking a workspace.** `POST /dsh-remote-portal/fs/mkdir`
  creates one directory inside a parent: the name has to be a single path
  segment (no separators, no `..`, resolved target must stay inside the parent),
  and an existing name is a 409 rather than a silent success. The picker grows a
  "新建文件夹" action that creates the folder and walks straight into it.
- Verified live: name a folder → create → the picker's cwd becomes the new
  directory; `..\evil` and `a/b` are refused with 400.

### Changed
- **The login page uses the Harness mark** (the whale the app serves as its
  favicon, inlined so it needs no request and follows the theme) instead of the
  generic rounded square.
- **Gateway codes are translated.** `session-unauthorized` and friends are now
  sentences in the page's language — "登录状态已失效，请重新输入访问密码。" — and
  the raw code no longer leaks into the UI (it stays in the JSON response).
- **The setup hint is gone** ("密码在桌面端…"), per report.
- **The login page no longer stores a theme.** The toggle lasts for the visit and
  the page follows the system scheme; nothing it does can change the desktop
  app's appearance.
- The eyebrow reads as one label ("远程访问" / "Remote access") instead of a
  mixed-language pair.

### Tests
- 76 tests: the login page is asserted to be localized, to carry the mark, and to
  contain no `localStorage`; the previously asserted raw `session-unauthorized`
  text is now asserted *absent*.

## 0.2.6 — 2026-10-21

### Fixed
- **The picker rendered `[object Object]` and collapsed on a wide screen.** Two
  separate bugs: the error path passed the whole response object into a formatter
  that expects a string, and the layer's generic `[role="dialog"]` sizing rule
  (a 24 px inset meant for the app's own dialogs) also matched our page surface,
  pinning it to `calc(100% - 24px)`. Our surfaces now carry `data-drp` and opt
  out of that rule; the error text falls back to a real message.
- **A host that had not been restarted looked like a broken picker.** If `/fs` is
  missing (older host half), the picker now says "宿主未加载该接口：请重启 dsh
  后重试。" instead of a generic failure.
- **The picker was laid out for a narrow phone only.** It is now a proper page at
  any width: an 880 px content column on a 1920 px screen, the directory list
  fills the height and scrolls on its own, the footer stays put.
- The header "…" (更多操作) is hidden up front: hiding it after the first click
  left an empty popover in between.

### Tests
- The overflow audit retries once: a slow first paint in a shared browser run
  made it flaky. 75 tests green.

## 0.2.5 — 2026-10-21

### Added — a workspace directory picker that resolves paths on the *host*
"Add workspace" used the browser's own directory picker, so a phone either got
nothing (Safari has no `showDirectoryPicker`) or a directory on the phone — which
the host cannot open. The plugin now takes the pick over:

- `GET /dsh-remote-portal/fs?path=…` lists one directory level on the host:
  directories only, entry cap, 4 s timeout, no file contents. Unknown path → 404
  `not-found`, a file → 400 `not-a-directory`.
- The picker is registered through `globalThis.__DSH_DIRECTORY_PICKER__`, the
  hook the shipped native picker already consults
  (`@deepseek-ai/dsh-client-ui-directory-picker-native`), so the app's own
  "Add workspace" calls it and receives an absolute host path.
- The UI is a full page in the panel's language: up button, monospace path, root
  chips (home, drives), folder rows with chevrons, 取消 / 使用此目录.
- Verified end to end on a live instance: menu → 添加工作区… → picker opens at the
  home directory → navigate → 使用此目录 resolves with `C:\Users\Tsuki\.agents`.
- The entry is no longer hidden on mobile — it works now.

### Fixed
- A menu whose entries were all removed left an empty "…" popover behind; the
  trigger is hidden with it.
- The drawer button no longer floats on top of the panel/picker header.

### Tests
- 75 tests: the picker endpoint is asserted to be behind the portal gate (an
  anonymous caller gets 401 and no listing).

## 0.2.4 — 2026-10-21

Second pass on the phone report: the previous build hid native entries only when
they already existed at mount, so anything opened later (a menu, the file
preview, the right panel) came back untouched.

### Fixed
- **Native entries are re-hidden as the UI changes.** The scan ran once when the
  layer mounted; menus and panels appear later, so "在用文件资源管理器打开",
  "更多打开方式", "下载 Session 日志" and "反馈" all survived. The layer now
  rescans (200 ms debounce) on every DOM change and covers the whole shell —
  verified with the right sidebar open: triggers `hidden`, menu items `hidden`.
- **Remote pages at any width.** Layout is width-gated, this is not: a 1440 px
  laptop on the LAN still cannot open a file on the host. `html[data-drp-remote]`
  is set when the page is served to another device (never for the desktop shell
  or loopback), and the hidden markers apply there too.
- **`?v=` on the injected assets.** The layer URL was stable across upgrades, so
  browsers (Safari especially) kept serving the previous `mobile.js`. Reloading
  now really loads the new file — every release invalidates it.
- **The `overflow-wrap: anywhere` blanket is gone.** It wrapped button and switch
  labels and deformed the settings rows; children can still shrink, wrapping is
  opt-in again.
- **Diagnostics speak the panel's language** (`?lang=`), instead of English
  bullets under a Chinese UI.

### Changed
- **The panel is a page at every width** (no card, no floating frame), with a
  36×36 centred close button and terse copy ("从其他设备访问此 dsh。需要访问密码
  或一次性配对码。") instead of tutorial paragraphs.
- **Sidebar entry aligned to the app's own rows.** Measured the account row
  (row x=10, icon x=16/24 px, label x=48, h=44) and matched it exactly, so the
  entry and the avatar line up instead of sitting 6 px off.

## 0.2.3 — 2026-10-21

Fixes from a real phone session on the public link.

### Fixed
- **Scanned pairing links landed on a JSON 404.** The post-login redirect was
  relative (`"./"`), so a browser resolved it against `/__portal/pair` →
  `/__portal/`, which is not an endpoint: the phone showed
  `{"ok":false,"code":"not-found"}` and the app only opened after typing the
  origin by hand. The redirect is now absolute (`"/"`), and a browser that lands
  on any portal path that is not an endpoint is sent to the app instead of
  getting JSON. Both login and logout were affected. Locked with assertions —
  the old tests only checked the status code, which is why this slipped through.
- **"在用文件资源管理器打开" / "更多打开方式" survived** the native-action filter:
  they are header *triggers*, not menu items, so the text scan never saw them
  (the label is on `aria-label`). Both are hidden now, and so is the menu they
  open. `下载 Session 日志` and `反馈` — dead buttons on a phone — are hidden too.
- **"添加工作区…" is hidden on mobile.** It opens the *browser's* directory
  picker: on Android it selects a directory on the phone (which the host cannot
  use), on iOS Safari the API does not exist and the entry does nothing. A
  server-side picker is a separate feature (see 0.3.0 notes in the README).
- **Settings panes clipped on both edges**: their children could exceed the pane
  and it clipped them instead of wrapping. Long paths/URLs now wrap and flex
  children may shrink (`min-width: 0`).

### Changed
- **The panel is a page, not a card**: full width/height from 900 px down (it was
  only edge-to-edge below 640), so a tablet or a landscape phone gets the whole
  screen.
- **Sidebar entry redrawn**: a broadcast glyph (dot + two arcs, legible at 16 px)
  in a 20 px box, 40 px row height, 14 px/500 label — the same rhythm as the
  app's own footer rows instead of a pasted-in 13 px row.

### Tests
- 74 tests, ~68 s. The pairing test now asserts the redirect *target*, and a new
  case covers a browser landing on `/__portal/`.

## 0.2.2 — 2026-10-21

Remote-only UI pass. The layer stops being "the desktop UI at phone width" and
adapts the surfaces that assume a native shell, a mouse, or a 1400 px window.
Everything is scoped to `html[data-drp-mobile]`, so the desktop window is
untouched.

### Adapted for remote use
- **Native-only actions are removed from menus.** "在资源管理器…等中打开",
  "Open in VS Code", "打开配置文件" and friends act on the host's desktop, which
  the phone cannot see; they are hidden from the menu they appear in (class-based
  marker, inert as soon as the layer is off). Keyboard hints (`⌘,` …) go with
  them.
- **Composer gutters** — the composer card was flush with both screen edges; it
  now breathes with 12 px (plus safe-area) on each side.
- **The ledger/轨迹 view pans.** Its table pane was `overflow-x: hidden` with
  content 2220 px wide inside a 388 px viewport: the timeline was clipped with no
  way to reach the rest of it. The pane scrolls horizontally now.
- **Settings is one column.** The two-pane dialog (188 px nav + 178 px body)
  squeezed labels into a one-character-wide column; the sections are a horizontal
  strip on top and the body gets the full width.
- **Tapping a session closes the drawer.** Folder rows still only expand. The
  listener runs on `document` in the capture phase, because React's synthetic
  handlers live on the root and a `stopPropagation()` there would hide the click.

### Tests
- New live-page test asserts the composer gutters, the pane's horizontal
  scrolling, and that a native-only menu entry is hidden while its neighbours
  stay — with an injected menu, since that label only appears in a session that
  produced files.
- 74 tests (lint included), ~75 s.

## 0.2.1 — 2026-10-21

Mobile hotfix, reported from a phone on the public link.

### Fixed
- **The page could not be scrolled with a thumb.** With a session open, the
  right column's wrapper (a full-size, transparent grid cell that the mobile
  layer stacks over the centre column) was the topmost hit target for the whole
  screen: every swipe ended on it, and since it has no scrollable ancestor
  nothing moved — the app looked frozen. The wrapper no longer takes pointer
  events; only its actual pane does, and that pane is 0 × 0 while the panel is
  closed. Verified with an input-level touch gesture: before, `scrollTop` stayed
  put and `document.elementFromPoint` returned the wrapper; after, the same
  swipe moves the conversation by 385 px. A regression test reproduces the
  stacked shape in the real shell and fails if the wrapper ever takes input
  again.
- **The drawer clipped its own content.** It is exactly one screen tall, so a
  long workspace/session list ran past the fold with no way to scroll; it now
  scrolls inside itself (`overflow-y: auto`).

### Tooling
- `tools/cdp.mjs gesture <url> --x --y --dy` dispatches a real touch swipe
  (synthesised gesture, then a raw touch sequence) and reports whether anything
  scrolled — the only way to test "can a finger scroll this". Touch emulation is
  enabled first, because without it a synthesised touch is silently dropped and
  every layout looks unscrollable.

## 0.2.0 — 2026-10-21

First release shaped as a product: public access through a self-hosted relay,
hardened responses, a mobile layout that holds up, and a test suite that runs on
real sockets.

### Public access through your own server
- **`tools/relay.mjs`** — a single-file, dependency-free relay: a TLS agent port
  the dsh host dials *out* to, a visitor port for browsers, per-tunnel tokens
  (the tunnel id is the token hash, so the public path survives restarts),
  path-prefix routing (`/__t/<id>/…`), WebSocket pass-through, stream timeouts
  and a `/__relay/health` endpoint. No port forwarding, public IP or NAT
  traversal is needed on the machine running dsh.
- **`lib/tunnel.mjs`** — the agent side: one multiplexed connection, binary
  framing (no base64 on user traffic), request/response streaming, raw WebSocket
  piping, reconnect with 1 s→30 s backoff and a ping/pong keepalive that detects
  dead NAT mappings.
- Wired into the gateway lifecycle (`start`/`stop`/`applyConfig`) and the panel:
  a **公网访问** card with state, public URL, copy button, QR code and the
  endpoint/token form. The token is write-only — the host never sends it back.
- Mount-relative URLs: the login form posts to `__portal/login` and the panel
  calls `./dsh-remote-portal/…`, so the same build works at the root
  (`http://lan:3081/`) and under a relay prefix (`https://host/__t/<id>/`).
- `?panel=1` opens the panel from a URL (a hash would stop the shell from
  booting — it routes on `location.hash`).
- Docs: [`docs/DEPLOY-SERVER.md`](docs/DEPLOY-SERVER.md) (systemd, Caddy/nginx,
  firewall, self-signed TLS, Docker, troubleshooting),
  [`docs/CONNECT.md`](docs/CONNECT.md) (phone, PWA, laptop, one-time links) and
  [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md) (measured layout/transfer numbers
  with the commands to reproduce them).

### Security hardening
- Every portal-generated response now carries `Content-Security-Policy`
  (`default-src 'none'`, `frame-ancestors 'none'`, `form-action 'self'`,
  `base-uri 'none'`), `X-Frame-Options: DENY`, `Cross-Origin-Opener-Policy` /
  `Resource-Policy: same-origin`, a restrictive `Permissions-Policy` and
  `Referrer-Policy: no-referrer`. The login form was framable, which is the
  classic clickjacking target on a password gate.
- Proxied responses are explicitly untouched — a test pins that the app keeps its
  own CSP and gains no XFO header.
- Same-origin guard on the portal's own endpoints (a foreign `Origin` or
  `sec-fetch-site: cross-site` is refused; the QR entry link is exempt because it
  arrives as a cross-site navigation and the token is the credential).

### Reliability
- **A paired phone survives a dsh restart**, and a missing or tampered `dsh-auth`
  cookie is re-minted once and handed back to the client.
- **`stats.bytesOut` counts real bytes** (a 38,578 B page moves the counter by
  exactly 38,578); chunked/streamed responses no longer count as zero.
- **`diagnose()` probes the upstream before answering**, so a freshly booted host
  no longer reports "unreachable" for a healthy server, and "not probed yet" is a
  third, distinct state.
- A port collision is reported in the panel instead of disabling it; the
  diagnostics card explains that another dsh instance probably holds the port.
- Control-route registration is per-route fault tolerant: one colliding path
  costs that endpoint, not the plugin.
- The gateway retries its bind with backoff, so a quick dsh restart (port in
  `TIME_WAIT`) does not leave the portal dead.

### Mobile and desktop
- **The session title is no longer squeezed to 14 px.** Measured at 390 px, the
  "N subagents" badge took 92 of the title cluster's 116 px. The title now has a
  readable minimum (110 px at 320, 134 at 390, 174 at 430), the badge yields
  first and hides below 430 px.
- Dialog fix: a tall dialog's action button used to sit at y=1836 in an 844 px
  viewport (unreachable); dialogs now bound their height, scroll internally and
  pin the action row.
- The sidebar becomes an off-canvas drawer with a 44 px floating button, a
  scrim, Escape/scrim/route-change close, and full teardown when the breakpoint
  stops matching.
- The layer keys only on stable hooks (`[data-slot=…]`, `[role=dialog]`,
  `:has()`) — never on CSS-module hashes, which change with every dsh build.
- **Long code, wide tables and big images stop widening the page.** A 250-char
  unbroken line now scrolls inside its `<pre>`, every table scroller pans on
  mobile (dsh only adds its own scroller when the table looked wide at *desktop*
  width), and oversized images are clamped with their aspect ratio. Measured:
  the same probe used to push the document 212 px wider than the viewport; now 0.

### Performance
- Asset caching: `ETag` + `304` + gzip on both asset routes — `mobile.css`
  20,783 B → 5,808 B gzip, and a reload costs zero bytes.
- The panel's 3 s status poll compares the payload and skips the state update
  when nothing changed.

### Panel
- First-run banner ("还差一步：设置访问密码") with a jump-to-password button.
- Pairing card is honest when the portal is down: no QR, no dead link, both
  buttons disabled.
- **复制配对链接**, a **连接诊断** card (bind address, upstream reachability,
  primary LAN address, copyable firewall command) and a **最近访问** card.
- Device labels fall back to a UA-derived name (`iPhone · Safari`); scripted
  clients show as `CLI`.
- Asset requests no longer flood the access log (they still count toward
  `stats.requests`).
- The panel stylesheet mounts into `<head>`: the sidebar entry used to be
  unstyled until a panel had been opened once.

### Tests and docs
- 72 tests, no mocks on network paths: gateway, security headers, relay +
  tunnel end-to-end, QR against an independent decoder, mobile layer against a
  live page.
- The live mobile tests provision their own `dsh web` (random port, token read
  from the startup line, process tree killed afterwards) instead of carrying a
  hardcoded launch token — which used to make them test a 401 page and call it a
  layer bug.
- README (zh + en), ARCHITECTURE, SECURITY, CONTRIBUTING, LICENSE, CHANGELOG,
  and two operator guides under `docs/`.

### Fixed
- Relay crashed on the agent's very first frame (`tunnel` is null until HELLO
  authenticates).
- The relay never answered `PING`, so every tunnel reconnected every ~35 s and
  in-flight requests failed with 502.
- `/dsh-remote-portal/config` dropped `tls`, and a partial patch carrying
  `enabled: undefined` switched the portal off.

### Verified on real infrastructure
- Windows 11 + dsh 0.2.1-rc.2 (desktop profile and `dsh web`), LAN access on a
  390 px viewport, a real dsh restart, and a self-signed TLS listener.
- Debian 12 server (1Panel + openresty + public IP): dsh installed from npm, the
  plugin loaded, the relay running, the tunnel online, and the full
  login → app path checked from an external network through `/__t/<id>/`.

## 0.1.0 — 2026-10-19

Initial version: authenticated gateway (HTTP + WebSocket reverse proxy), password
/ one-time QR pairing / device registry / lockout, dsh browser-cookie minting,
login wall, Settings panel, mobile presentation layer, install script, 51 tests.































