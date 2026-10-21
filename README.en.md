# dsh-remote-portal

**An authenticated front door for the DeepSeek Harness Web GUI — usable from a
phone, a tablet, or any machine outside your LAN.**

Scan-to-pair on the LAN · self-hosted relay for public access · a mobile layout
the stock UI does not have · zero runtime dependencies, no build step.

[中文说明 →](README.md)

---

dsh listens on `127.0.0.1` and authenticates browsers with a **per-process launch
token**. That is a good default, and it also means the UI is unreachable from
anywhere else.

This plugin leaves that model untouched and puts its own gate in front of it: a
second listener that asks for a password (or a one-time pairing code) and then
reverse-proxies to the local dsh. On the same network a phone just opens an
address; off the network, a small relay on **your** server is dialled *from* the
dsh machine, so no port forwarding or public IP is needed at home.

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

## Features

- **One LAN address** — `http://<lan-ip>:3081/`, opened straight from a phone
  browser; no public IP, NAT mapping or tunneling software.
- **Public access through your own server** — run `tools/relay.mjs`; the dsh
  machine dials out and gets a stable public URL.
- **QR pairing** — a 180-second, single-use code; scan and you are in, no typing.
- **Password + device registry** — scrypt hashing, constant-time compare,
  lockout, per-device revocation.
- **Mobile layout** — the stock UI has exactly one `@media` rule in 77 KB of CSS.
  The layer turns the sidebar into a drawer, bounds dialogs, keeps the composer
  above the keyboard and respects safe-area insets. Desktop is untouched.
- **Native settings panel** — Settings → 远程访问: status, address, QR, switch,
  port, password, devices, diagnostics, recent access.
- **Session self-healing** — the remote browser never sees dsh's launch token;
  after a dsh restart the phone stays logged in, and a stale cookie is re-minted.

## Install

Prerequisites: dsh **0.2.x**, profile `desktop` or `web`, Node ≥ 20 (the one dsh
ships with is fine).

```powershell
git clone <repo> dsh-remote-portal; cd dsh-remote-portal
.\install.ps1                  # both profiles
.\install.ps1 -Profile web     # or just one
```

Then restart dsh (quit and reopen the desktop app, or `Ctrl+C` and `dsh web`).
On first use open **Settings → 远程访问** and set an access password — until one
exists the portal refuses to listen on the network, on purpose. Append
`?panel=1` to any Harness URL to jump straight to the panel.

## Public access

```bash
# on your server (single file, no npm install)
openssl rand -base64 32 > /var/lib/dsh-relay/token && chmod 600 /var/lib/dsh-relay/token
node tools/relay.mjs --token-file /var/lib/dsh-relay/token \
     --agent-port 9443 --http-port 127.0.0.1:8080 \
     --public-url https://dsh.example.com

# terminate TLS in front of it (no buffering — otherwise streaming stalls)
dsh.example.com { reverse_proxy 127.0.0.1:8080 { flush_interval -1 } }
```

Then, on the dsh machine: panel → **公网访问** → endpoint
`tls://dsh.example.com:9443` + token → Connect.

Full guides: [server deployment](docs/DEPLOY-SERVER.md) (systemd, Caddy/nginx,
self-signed TLS, Docker, firewall, troubleshooting) and
[client connection](docs/CONNECT.md) (phone, PWA, laptop, one-time links).

## Security model

- The portal is the only gate: no password ⇒ it refuses a non-loopback bind;
  `open` mode is loopback-only.
- `dsh_portal` cookie: `HttpOnly`, `SameSite=Lax`, UA-bound signature, `Secure`
  under TLS.
- Upstream authentication is minted in-process from the host's own credential;
  the launch token never leaves the machine and is never logged.
- Every portal response carries a strict CSP (`default-src 'none'`,
  `frame-ancestors 'none'`), `X-Frame-Options: DENY`, CORP/COOP and a restrictive
  `Permissions-Policy`. Proxied dsh responses are passed through **byte for
  byte** (a test pins this).
- The public URL is not a credential; the relay forwards to one fixed upstream,
  so it cannot act as an open proxy.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the design and the dsh facts it is
built on, and [SECURITY.md](SECURITY.md) for reporting.

## Tests

```console
$ node --test
ℹ tests 73   ℹ pass 73   ℹ fail 0   ℹ skipped 0
```

The three browser tests need Chrome/Chromium (`CHROME_PATH` overrides the lookup) and
**skip explicitly** when it is missing, so `node --test` is green on a headless
Linux box too (69 pass + 3 skipped).

Layout and transfer measurements (8 width × theme configs with zero overflow, a
login page that fits 320 × 844 without scrolling, `mobile.css` 20,783 B → 5,808 B
gzip, `304` on reload, 5–10 ms of proxy overhead per request) are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md), with the commands to reproduce them.

Real listeners on every network path: gateway auth and proxying, security
headers, relay + tunnel end-to-end (HTTP, HTTPS and WebSocket), QR correctness against
an independent decoder, and the mobile layer driven against a live dsh instance
the suite starts itself.

## License

[MIT](LICENSE)






