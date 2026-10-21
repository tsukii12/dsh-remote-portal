<div align="center">

[简体中文](README.md) · **English**

# dsh-remote-portal

### An authenticated front door for DeepSeek Harness — usable from a phone, a tablet, or any machine outside your LAN.

**Scan-to-pair on the LAN · self-hosted relay for public access · zero runtime dependencies, no build step**

[![license](https://img.shields.io/badge/license-MIT-0f1115?style=flat-square)](LICENSE)
[![dsh](https://img.shields.io/badge/dsh-0.2.x-4176e6?style=flat-square)](#compatibility)
[![tests](https://img.shields.io/badge/tests-76%20passing-22c55e?style=flat-square)](#tests)
[![runtime deps](https://img.shields.io/badge/runtime%20deps-0-22c55e?style=flat-square)](#)

[Features](#features) · [Quick start](#quick-start) · [Public access](#public-access) · [How it works](#how-it-works) · [Security](#security-model) · [FAQ](#faq) · [Docs](#documentation)

</div>

---

dsh listens on `127.0.0.1` and authenticates browsers with a **per-process launch token**. That is a good default, and it also means the UI is unreachable from anywhere else.

This plugin leaves that model untouched and puts its own gate in front of it: a second listener that asks for a password (or a one-time pairing code) and then reverse-proxies to the local dsh. On the same network a phone just opens an address; off the network, a small relay on **your** server is dialled *from* the dsh machine, so no port forwarding or public IP is needed at home.

<div align="center">

<img src="docs/screenshots/panel-main-area.png" alt="The remote access panel as a page of the main area, sidebar still usable" width="1000" />

<sub>The panel is a page of the main area (same place as Plugins / Automation), and the sidebar stays usable.</sub>

</div>

## Features

| | |
|---|---|
| **One LAN address** | `http://<lan-ip>:3081/`, opened straight from a phone; no public IP, NAT mapping or tunneling software |
| **Public access through your own server** | run `tools/relay.mjs`; the dsh machine dials out and gets a stable public URL |
| **QR pairing** | a 180-second, single-use code; scan and you are in, no typing |
| **Password + device registry** | scrypt hashing, constant-time compare, lockout, per-device revocation |
| **Mobile layout** | sidebar becomes a drawer, dialogs stop overflowing, long code / wide tables / large images no longer widen the page |
| **Remote-only trimming** | entries that only act on the host's desktop ("open in Explorer", "open config file", dead menu items) are hidden |
| **Server-side folder picker** | "Add workspace" lists folders **on the host**, lets you walk and create them, and returns an absolute path |
| **Zero dependencies** | Node built-ins only; no build step |

<table>
<tr>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile.png" alt="dsh on a phone" /><br /><sub><b>Phone (LAN)</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile-drawer.png" alt="Sidebar drawer" /><br /><sub><b>Sidebar drawer</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/workspace-picker.png" alt="Server folder picker" /><br /><sub><b>Server folder picker</b></sub></td>
</tr>
</table>

## Quick start

**Prerequisites**: dsh `0.2.x`, profile `desktop` or `web`, Node ≥ 20 (the one dsh ships with is fine).

```powershell
git clone <repo> dsh-remote-portal
cd dsh-remote-portal
.\install.ps1                  # both profiles
```

```bash
# macOS / Linux (dsh web)
./install.sh                   # desktop + web
./install.sh -p web            # just one
./install.sh -p web --uninstall
```

Both scripts do the same three things, all reversible (the profile's `package.json` is backed up
first): point the profile at this directory with a `link:` dependency, add `dsh-remote-portal` to
`dsh.profile.bundles`, and make the package resolvable under the profile's `node_modules` (a
symlink — the plugin has no dependencies, so no package manager is needed).

> The `desktop` profile is managed exclusively by the Electron app and the CLI refuses
> `--dump-config` there; the installer skips that check.

**Then restart dsh** (quit and reopen the desktop app, or `Ctrl+C` and `dsh web`).

**First use (required)**: sidebar → **远程访问** → set an access password. Until one exists the
portal refuses to listen on the network — a red line in the panel is better than an unprotected
dsh. The status turns to running within a second or two; copy the address, or use the QR code.

## Public access

```bash
# on your server (single file, no npm install)
openssl rand -base64 32 > /var/lib/dsh-relay/token && chmod 600 /var/lib/dsh-relay/token
node tools/relay.mjs --token-file /var/lib/dsh-relay/token \
     --agent-port 9443 --http-port 127.0.0.1:8080 \
     --public-url https://dsh.example.com
```

```caddyfile
# terminate TLS in front of it (no buffering — otherwise streaming stalls)
dsh.example.com { reverse_proxy 127.0.0.1:8080 { flush_interval -1 } }
```

Then, on the dsh machine: sidebar → **远程访问** → **公网访问** → endpoint
`tls://dsh.example.com:9443` + token → Connect.

Full guides: [server deployment](docs/DEPLOY-SERVER.md) (systemd, Caddy/nginx, self-signed TLS,
Docker, firewall, troubleshooting) and [client connection](docs/CONNECT.md) (phone, PWA, laptop,
one-time links).

## How it works

```
phone / laptop / desktop app
        │  ① http://192.168.1.5:3081/      ② https://dsh.example.com/__t/<id>/
        ▼
┌───────────────────────────────┐        ┌──────────────────────────┐
│ portal gateway 0.0.0.0:3081   │◀───────│ your relay (tools/relay) │
│ password / pairing / lockout  │ outbound│  moves bytes, nothing    │
└───────────────┬───────────────┘   TLS   │  else                    │
                │ reverse proxy, Host/Origin rewritten
        dsh Web GUI 127.0.0.1:19887
```

Three transports, one policy: **only the gateway authenticates**, and it does not care whether the
request arrived over the LAN or through a relay.

* **Why not just bind `0.0.0.0`** — dsh refuses wildcard binds and has no notion of a user password
  (only a per-process launch token). The gateway is a second listener that trades a password or
  pairing code for its own signed cookie, then mints a dsh browser cookie from the host's own
  credential in the background.
* **Why `Host`/`Origin` must be rewritten** — dsh has a browser trust fence: `Host` must be loopback
  or a declared address, and `Origin` must agree with it. Forwarding the visitor's `Host` unchanged
  gets a 403 on every request, which is why most "reverse proxy dsh" attempts fail.
* **Why the relay uses a path prefix** — cookies ignore ports, so `/__t/<id>/` keeps the same cookie
  valid at the origin and through the relay; the app uses `<base href="./">`, so the prefix is
  transparent to it.
* **Why the panel is a "main-area page"** — it measures the centre column (`--drp-main-*`) and sits
  inside it, leaving the sidebar visible and clickable, like Plugins / Automation.

More detail (including 15 verified host facts) in [ARCHITECTURE.md](ARCHITECTURE.md).

## Security model

* The portal is the only gate: no password ⇒ it refuses a non-loopback bind; `open` mode is
  loopback-only.
* `dsh_portal` cookie: `HttpOnly`, `SameSite=Lax`, UA-bound signature, `Secure` under TLS.
* Upstream authentication is minted in-process from the host's own credential; the launch token
  never leaves the machine and is never logged.
* Every portal response carries a strict CSP (`default-src 'none'`, `frame-ancestors 'none'`),
  `X-Frame-Options: DENY`, CORP/COOP and a restrictive `Permissions-Policy`. Proxied dsh responses
  are passed through **byte for byte** (a test pins this).
* The portal is not an open proxy: it forwards to one fixed loopback upstream, and `/__portal/*`
  never leaves the machine.
* Folder endpoints: `/fs` lists names only (no file contents); `/fs/mkdir` accepts a single path
  segment that must resolve inside its parent. Through the portal they require a session —
  anonymous calls get 401 (a test pins this).
* The public URL is not a credential; the relay forwards to one fixed upstream.

See [SECURITY.md](SECURITY.md) for reporting and the operator checklist.

## Compatibility

| | |
|---|---|
| dsh | `0.2.x` (verified item by item on `0.2.1-rc.2`, both the Electron app and `dsh web`) |
| profile | `desktop` (managed by the Electron app) and `web` |
| OS | Windows / macOS / Linux (Node built-ins only; installers for PowerShell and POSIX shell) |
| Browsers | Chrome / Edge / Safari 15.4+ / Firefox 121+ (the mobile layer uses `:has()`; otherwise it falls back to the desktop layout) |

## Tests

```console
$ node --test
ℹ tests 76   ℹ pass 76   ℹ fail 0   ℹ skipped 0
```

Real listeners on every network path: gateway auth and proxying, security headers, relay + tunnel
end-to-end (HTTP, HTTPS and WebSocket), QR correctness against an independent decoder, and the
mobile layer driven against a live dsh instance the suite starts itself — including touch-hit
testing and an overflow audit across six widths in both themes.

The three browser tests need Chrome/Chromium (`CHROME_PATH` overrides the lookup) and **skip
explicitly** when it is missing, so `node --test` is green on a headless Linux box too (73 pass +
3 skipped).

Layout and transfer measurements, with the commands to reproduce them, are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## FAQ

<details>
<summary><strong>Do I have to restart dsh?</strong></summary>

**Not for configuration changes** — panel switches apply immediately. But **after a plugin upgrade,
yes**: the host half (`index.js`, `lib/*`) is only loaded when dsh starts, while the client half
reloads on every page load. A new UI calling an old host shows up as "endpoint missing"; the panel
says so explicitly ("the host has not loaded this endpoint yet — restart dsh").

</details>

<details>
<summary><strong>Some buttons do nothing on my phone</strong></summary>

They are usually entries that only act on the host's desktop ("open in Explorer", "download session
log", "feedback"). The plugin hides those on remote/mobile; anything still visible is a label its
rules do not cover yet.

</details>

<details>
<summary><strong>The LAN address does not open</strong></summary>

In order: ① is the panel "running"? ② are phone and computer on the same network (guest/company
WiFi often isolates clients)? ③ is the port allowed through the firewall (the panel's diagnostics
card has a copyable `netsh` command)? ④ is the bind address `0.0.0.0` or `auto` (`127.0.0.1` is
loopback only)?

</details>

<details>
<summary><strong>The public URL does not open</strong></summary>

Check the **公网访问** card: *offline* means the host has not dialled the relay (port 9443 open?
token identical?). *Connected* but 503/404 means the reverse proxy, see the troubleshooting table in
[DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) — buffering is the usual culprit.

</details>

<details>
<summary><strong>Does revoking a device end its dsh session?</strong></summary>

No. Revoking invalidates that device's **portal** cookie; the underlying dsh identity is shared
across devices. To start over, change the password and tick "sign out all devices".

</details>

<details>
<summary><strong>Can several dsh instances share this?</strong></summary>

They will fight over the port if they share a `DSH_HOME`; the later one reports "port in use". Give
each a different `port`. State (password, devices, tunnel) is per `DSH_HOME`.

</details>

## Development

```bash
node --test                            # everything (no deps, no network)
node --test test/relay.test.mjs        # the relay only
node tools/cdp.mjs shot <url> out.png  # screenshot with a real browser
node tools/cdp.mjs audit <url> out.json --widths 320,390,768 --themes dark,light
node tools/cdp.mjs gesture <url> --x 195 --y 400 --dy -400   # real touch swipe, reports scrolling
node tools/relay.mjs --help            # the relay
```

```
index.js                 host entry: gateway lifecycle, control routes, layer injection
lib/gateway.mjs          listener, login, pairing, devices, rate limit, tunnel wiring
lib/proxy.mjs            HTTP / WebSocket reverse proxy
lib/auth.mjs             scrypt, session signing, pairing tokens, lockout
lib/mint.mjs             dsh browser-cookie minting from the host credential
lib/tunnel.mjs           outbound tunnel (auth, reconnect, keepalive)
lib/login-page.mjs       the login page
lib/qr.mjs               pure-JS QR encoder
client.js                browser half: panel, folder picker, devices, diagnostics
assets/mobile.css/.js    mobile presentation layer
tools/relay.mjs          the relay (single file, no dependencies)
tools/cdp.mjs            CDP driver used for screenshots, audits and gestures
```

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — design, request path, 15 verified host facts
- [docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) — server deployment: systemd / Caddy / nginx / TLS / Docker / firewall
- [docs/CONNECT.md](docs/CONNECT.md) — client connection: QR, PWA, laptop, one-time links
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md) — measured layout and transfer numbers
- [CHANGELOG.md](CHANGELOG.md) — per-release changes and what was verified
- [SECURITY.md](SECURITY.md) — policy and reporting

## Known limitations

* Reachable only on the **same network**, or through a relay you deploy yourself. No NAT traversal,
  no public relay service.
* With a relay, that server's bandwidth is the ceiling; it moves bytes and does not cache.
* Plain HTTP is sniffable on the same network; configure `tls` or go through the relay.
* Revoking a device does not end its dsh session.
* Safari and iOS safe areas are covered by rules, not by a physical device test; the Electron
  window loads from `file://`, where index injection does not apply.
* The panel and picker *present as* main-area pages (same geometry and interaction) without
  replacing the host's main-area DOM.

## Contributing

Issues and PRs are welcome. Run `node --test` before sending a change, and add a test for anything
on a network path rather than only editing prose. See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
