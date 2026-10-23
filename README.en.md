<div align="center">

[简体中文](README.md) · **English**

# dsh-remote-portal

**Remote access for DeepSeek Harness — over your LAN or through your own server.**

[![license](https://img.shields.io/badge/license-MIT-0f1115?style=flat-square)](LICENSE)
[![dsh](https://img.shields.io/badge/dsh-0.2.x-4176e6?style=flat-square)](#compatibility)
[![tests](https://img.shields.io/badge/tests-82%20passing-22c55e?style=flat-square)](#tests)
[![deps](https://img.shields.io/badge/runtime%20deps-0-22c55e?style=flat-square)](#)

[Features](#features) · [Install](#install) · [Update](#update) · [Public access](#public-access) · [Security](#security) · [FAQ](#faq)

</div>

---

DeepSeek Harness listens on `127.0.0.1` only and authenticates with a one-time launch
token, so it is unusable from any other device. This plugin changes nothing inside dsh:
it puts its own gate in front — a gateway on a separate port that asks for a password or
a one-time pairing code, then forwards to dsh on loopback.

<div align="center">
<img src="docs/screenshots/panel-main-area.png" alt="The remote access panel" width="900" />

<sub>The panel is a page in the main column (a sibling of Plugins / Scheduled tasks); the sidebar keeps working.</sub>

</div>

## Features

| | |
|---|---|
| **One LAN address** | `http://<lan-ip>:3081/`, open it in a phone browser — no public IP, no port forwarding |
| **Scan to pair** | the panel draws a QR code: valid 180 s, single use |
| **Public access** | run the relay on **your own** server; the home machine dials out and gets a stable public URL |
| **Password and devices** | scrypt with a salt, lockout on repeated failures, per-device revocation |
| **Mobile layout** | the sidebar becomes a drawer, dialogs stop overflowing, wide tables and long code lines stop stretching the page |
| **Server-side folder picker** | "Add workspace" lists directories on the host, one level at a time, and can create one |
| **No dependencies** | Node built-ins only, no build step |

<table>
<tr>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile.png" alt="Phone over LAN" /><br /><sub><b>Phone (LAN)</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/remote-mobile-drawer.png" alt="Sidebar drawer" /><br /><sub><b>Sidebar drawer</b></sub></td>
<td width="33%" align="center"><img src="docs/screenshots/workspace-picker.png" alt="Folder picker" /><br /><sub><b>Server-side folder picker</b></sub></td>
</tr>
</table>

## Install

**From inside dsh (recommended)**: Plugins → Add plugin → paste

```
https://github.com/tsukii12/dsh-remote-portal
```

**From a shell**:

```bash
git clone https://github.com/tsukii12/dsh-remote-portal
cd dsh-remote-portal
./install.sh            # macOS / Linux, desktop + web profiles
.\install.ps1           # Windows
```

**Where GitHub is unreachable**, install from a mirror tarball instead of the URL above:

```bash
dsh plugin --profile web add \
  https://ghfast.top/https://github.com/tsukii12/dsh-remote-portal/archive/refs/heads/master.tar.gz
```

Then **restart dsh** (quit and reopen the desktop app, or `Ctrl+C` and `dsh web`).

**One required step**: sidebar → **远程访问** → set an access password. Until one exists
the portal refuses to listen beyond loopback.

## Update

**Remove, then add** — repeating "add plugin" with the same source may not fetch new
code (pnpm answers `Already up to date` when the spec is unchanged):

```bash
dsh plugin --profile web remove dsh-remote-portal
dsh plugin --profile web add    https://github.com/tsukii12/dsh-remote-portal
```

Use `--profile desktop` for the desktop app; run it once per profile you installed into.

**Restart dsh afterwards.** The host half (`index.js`, `lib/*`) only loads at startup;
reloading the page swaps just the client half.

> On a slow link `add` can fail with `ETIMEDOUT`. Run it again — what was downloaded is
> reused.

**Pin a version**:

```bash
dsh plugin --profile web add https://github.com/tsukii12/dsh-remote-portal#v0.6.0
```

See [CHANGELOG.md](CHANGELOG.md) for what changed.

## Public access

Run the relay on **your own** server (one file, no dependencies). **No checkout
needed** — one command:

No Node? The installer installs a self-contained runtime itself (official tarball,
nothing added to apt/yum, kept in `/usr/local/lib/nodejs`) and carries on.

```bash
curl -fsSL https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh | sudo bash
```

**Behind a restrictive network** (any one of these):

```bash
# recommended: the ghfast proxy (tracks master, always the newest release)
curl -fsSL https://ghfast.top/https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh | sudo bash

# fallback: jsDelivr (also tracks master, but it caches and can lag by hours)
curl -fsSL https://cdn.jsdelivr.net/gh/tsukii12/dsh-remote-portal@master/tools/deploy-relay.sh | sudo bash
```

It downloads `relay.mjs` itself, inspects the host, asks a few questions (Enter accepts
every default), installs, and registers a `drp` command.

**It asks how visitors connect**:

| Question | Meaning |
|---|---|
| HTTP or HTTPS | `1) HTTP` unencrypted / `2) HTTPS` |
| HTTPS with a domain or the IP | **Domain**: no browser warning once a certificate is in place. **IP**: self-signed, one warning, encrypted from then on |
| DNS | the domain is **actually resolved**: it continues only when it points here; pointing elsewhere (a CDN, say) is reported so you can continue or pick another name; a missing A record is reported before anything is written |
| Certificate | `1) issue a free one` (Let's Encrypt, needs port 80 free, no browser warning) / `2) I have one` / `3) self-signed` (the browser will warn) |
| Ports | public port and agent port (ports already in use are skipped) |

⚠️ With HTTP the password and **the entire session** (chat, files, command output)
travel in the clear. Only acceptable on a fully trusted LAN.

Prefer to read before running? Download it, then run it — same result.

```bash
curl -fsSLO https://raw.githubusercontent.com/tsukii12/dsh-remote-portal/master/tools/deploy-relay.sh
sudo bash deploy-relay.sh
```

When it finishes:

```console
$ drp
service     running · autostart on
uptime      2h 14m
agent port  1.2.3.4:9443 (TLS)
visitor     0.0.0.0:443 (TLS, self-signed)
endpoint    tls://1.2.3.4:9443
relay       reachable
tunnel      connected · 2 streams
traffic     in 8.0 MiB · out 7.9 MiB · 2140 requests · 3 clients
public      https://1.2.3.4/__t/ab12cd34ef56/
```

**Updating the relay**: run the same command again — the token and certificate are
reused and the ports do not move. `drp config K=V …` changes a saved answer and
reinstalls the unit; `drp uninstall` removes everything.

In the panel, the relay field takes an **`address:port`** (e.g. `1.2.3.4:9443`); the
transport is detected on connect (TLS first, plain TCP as fallback). Full guide:
[docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md).

## Security

* The portal is the only door: with no password set it refuses to listen beyond loopback.
* Session cookie `dsh_portal`: `HttpOnly`, `SameSite=Lax`, bound to the user agent, and
  `Secure` automatically over TLS.
* Every portal response carries a strict CSP and `X-Frame-Options: DENY`; **proxied dsh
  responses are not modified at all** (a test pins this).
* The upstream cookie is minted in the background from a host credential; the token
  never leaves the machine, never reaches a log, and is never echoed in the panel.
* Over plain HTTP a sniffer on the same network can read the cookie. Use TLS, or go
  through the relay.

Details in [SECURITY.md](SECURITY.md).

## FAQ

<details>
<summary><strong>Some buttons do nothing when I'm remote?</strong></summary>
Usually they are entries that only make sense on the host's desktop (open in Explorer,
open in VS Code, and similar).
</details>

<details>
<summary><strong>The LAN address does not open?</strong></summary>
① Is the panel state "running"? ② Is the phone on the same network? ③ Does the firewall
allow the port? ④ Is the bind address `0.0.0.0` or `auto`?
</details>

<details>
<summary><strong>The public URL does not open?</strong></summary>
`drp status` shows the tunnel: `offline` means the home machine never attached (check
that 9443 is open and the token matches); `connected` with a 503 means a proxy is
buffering (see the troubleshooting table in the deployment guide).
</details>

<details>
<summary><strong>Does revoking a device end my dsh session?</strong></summary>
No. Revoking only invalidates that device's portal cookie; the underlying dsh identity is
shared across devices.
</details>

## Compatibility

| | |
|---|---|
| dsh | `0.2.x` (verified item by item on `0.2.1-rc.2`) |
| profiles | `desktop` (Electron) and `web` (`dsh web`) |
| systems | Windows / macOS / Linux |
| browsers | Chrome / Edge / Safari 15.4+ / Firefox 121+ |

## Tests

`node --test` → **82 tests**, roughly 75 s, no mocks on the network paths: real listeners
for the gateway, a real relay plus a real agent for the tunnel (HTTP, HTTPS and
WebSocket), QR output checked by an independent decoder, and the mobile layer driven
against a live dsh that the suite starts itself. Browser tests skip explicitly when
Chrome is missing.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md) — how it works, and the host facts behind it
- [docs/DEPLOY-SERVER.md](docs/DEPLOY-SERVER.md) — server deployment (systemd / Caddy / nginx / TLS)
- [CHANGELOG.md](CHANGELOG.md) — per-release notes
- [SECURITY.md](SECURITY.md) — policy

## Known limitations

* Reachable on the local network only; public access needs a relay on a server you own.
  No NAT traversal.

## License

[MIT](LICENSE)
