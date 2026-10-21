# Changelog

All notable changes to this project. The format is loosely [Keep a Changelog](https://keepachangelog.com/);
versions are the plugin's own, not dsh's.

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









