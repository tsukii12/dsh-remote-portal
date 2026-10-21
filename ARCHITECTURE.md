# Architecture

How the plugin is put together, and **why** each piece exists. Everything below
was verified against dsh `0.2.1-rc.2`; the facts in [Host facts](#host-facts)
are the ones an implementer would otherwise have to rediscover.

```
┌──────────────────────────── browser (phone / laptop / desktop app) ────────────────────────────┐
│                                                                                                │
│   ① LAN:   http://192.168.1.5:3081/            ② Public:  https://dsh.example.com/__t/<id>/     │
│            └──────────────┬──────────────────────────────┘                                     │
└───────────────────────────┼────────────────────────────────────────────────────────────────────┘
                            │ TLS / HTTP + WebSocket
        ┌───────────────────▼────────────────────┐         ┌──────────────────────────────────┐
        │ ② your relay (tools/relay.mjs)         │◀────────│ tunnel agent (lib/tunnel.mjs)    │
        │   visitor :8080/:443 → mux frames      │  outbound│  one TLS socket, 1 stream per    │
        └────────────────────────────────────────┘   TLS    │  browser connection              │
                                                           └───────────────┬──────────────────┘
        ┌──────────────────────────────────────────────────────────────────▼──────────────────┐
        │ ① portal gateway (lib/gateway.mjs) — 0.0.0.0:3081, password/pairing/device lock      │
        │      ↓ reverse proxy, Host/Origin rewritten                                         │
        │ dsh web server — 127.0.0.1:19887 (the app, /api, WebSocket, static assets)           │
        └─────────────────────────────────────────────────────────────────────────────────────┘
```

Three transports, one policy: the gateway is the only thing that authenticates,
and it never learns whether the request arrived over LAN or through the relay.

---

## 1. Why a gateway instead of "just bind 0.0.0.0"

dsh's own defaults are deliberate: the web server rejects wildcard binds, and
browsers authenticate with a per-process launch token (`?token=…`) exchanged for
a signed, authority-bound cookie. Neither can be changed from inside a running
process, and neither is a *user* credential — there is no password anywhere.

So the plugin leaves that model untouched and adds a second listener in front:

| Concern | dsh web server | portal gateway |
|---|---|---|
| Bind | loopback (or one concrete interface) | `0.0.0.0:<port>`, configurable |
| Who may connect | a browser holding the launch cookie | anyone with the password / a one-time pairing code |
| Login page | none (the token URL *is* the login) | its own page, with lockout and device registry |
| Revocation | delete a credential record and restart | per-device, instant |

The gateway then needs a dsh cookie for the browser it is serving. It mints one
itself (`lib/mint.mjs`): `connection.authenticatedUrl(origin)` yields a URL with
the process launch token, the gateway performs that `GET /?token=…` on loopback,
and copies the `Set-Cookie` onto its own response. The token never leaves the
machine and is never logged.

## 2. Request path

```
socket
 ├─ /__portal/*          local: login page, login POST, pair, logout, manifest
 ├─ /dsh-remote-portal/* local: assets and the QR renderer (same files the
 │                        dsh-origin route serves)
 └─ everything else → proxy
        Host, Origin, Referer rewritten to the upstream authority
        X-Forwarded-For/Proto/Host appended
        Location headers pointing upstream rewritten back to the portal origin
        response streamed straight through (no buffering: SSE and 1 GB downloads)
        WebSocket upgrades tunnelled as raw bytes after the handshake
```

The **Host/Origin rewrite is not cosmetic**: dsh's browser-trust fence refuses a
request whose `Host` is not loopback, the listener's own bind literal, or a
declared `trustedHosts` entry — and refuses an `Origin` that disagrees with
`Host`. A proxy that forwards the visitor's `Host` unchanged gets 403 on every
request; the rewrite is what makes remote access work at all.

Cookie authority is the other half: dsh binds its cookie name and signature to
`host:port`. Cookies ignore ports, so a cookie minted for `127.0.0.1:19887` is
sent back to `192.168.1.5:3081` (or to a relay host) and validates, because the
gateway forwards it while claiming the upstream authority.

## 3. Authentication

* **Password** — `scrypt` (N=16384, r=8, p=1) with a 16-byte salt and a dummy
  record for the no-password case, so "is a password set?" cannot be answered by
  timing.
* **Session cookie** `dsh_portal` — `<id>.<issuedAt>.<expiresAt>.<hmac>` over
  `id|issuedAt|expiresAt|sha256(UA)`. The UA binding is inside the MAC: a stolen
  cookie replayed from another browser fails exactly like a tampered one.
* **Pairing** — 32 random bytes, stored as a SHA-256 hash, single use, 180 s by
  default. This is what the QR code encodes, so a phone never types a password.
* **Lockout** — 5 failures / 10 min per IP, 60 s doubling to 15 min, applied
  before the password is compared.
* **Bind safety** — a non-loopback bind without a password is refused
  (`needs-password`), and `open` mode is refused anywhere but loopback. The
  failure is a panel state, not an exception.

## 4. The public relay

`tools/relay.mjs` is a standalone server; `lib/tunnel.mjs` is the agent that the
gateway starts. The agent always dials **out**, so the machine running dsh needs
no inbound port, public address, or NAT mapping.

```
relay                                 agent (dsh host)
 visitor socket ──► stream id ──► REQ_HEAD/BODY/END ──► http.request → 127.0.0.1:3081
                   ◄────────────── RES_HEAD/BODY/END ◄── upstream response
 upgrade  ─────────────────────► WS_OPEN + WS_DATA ──► net.connect → raw bytes
```

* **One multiplexed socket.** A page load is ~75 requests; a TLS handshake per
  request over the public internet costs far more than the framing does.
* **Binary frames** (`type u8 | stream u32 | length u32 | payload`) — no base64
  on user traffic, no JSON on the hot path.
* **Routing** is a path prefix: `/__t/<id>/…`, where `<id>` is the token's hash,
  so a restart does not change the public URL. The relay strips the prefix before
  forwarding; dsh's shell resolves its assets relatively (`<base href="./">`), so
  the app works under a prefix — which is also why the plugin's own URLs are
  relative (`./dsh-remote-portal/…`, `__portal/login`).
* **Failure modes are explicit**: unknown id → 404 page, tunnel offline → 503
  page, request not answered within the deadline → 504 + stream released,
  unauthorized token → the agent never attaches and retries with backoff.
* **Keepalive**: the relay answers `PING` with `PONG`; a missing `PONG` for 10 s
  makes the agent reconnect, which is what recovers from a dead NAT mapping.

## 5. Browser halves

### Login page (`lib/login-page.mjs`)

A single self-contained document (≈22 KB, zero network requests) rendered by the
gateway for every unauthenticated request. It carries a strict CSP
(`default-src 'none'`, `frame-ancestors 'none'`, `form-action 'self'`), so the
form cannot be framed by another site. The form posts **relatively**
(`__portal/login`) so it works at the root and under a relay prefix.

### Settings panel (`client.js`)

A hand-written bundle (no build step) loaded by dsh's client module system.
It registers three surfaces, each independently guarded — a throwing client
plugin blanks the whole Web app, so every registration is in a `try/catch`:

1. `settings.section` — the panel inline in Settings;
2. `sidebar.footer.action` — the entry that opens the panel;
3. `shell.overlay` — a sheet the entry opens, so the panel is one click away
   from anywhere (no driving the host's own dialogs).

The panel talks only to the same-origin control API (`/dsh-remote-portal/*`) and
polls it every 3 s while visible, skipping the state update when the payload is
unchanged.

### Mobile layer (`assets/mobile.css`, `assets/mobile.js`)

The shipped UI has **one** `@media` rule in 77 KB of CSS — no responsive layout
at all. The layer is gated behind `@media (max-width: 900px)` + `html[data-drp-mobile]`
and keyed to stable hooks only (`[data-slot=…]`, `[role=dialog]`, `:has()`),
never CSS-module hashes. It turns the sidebar into a drawer, gives the session
title a readable minimum width, bounds dialogs, and respects safe-area insets.
Desktop is untouched: the whole layer is inert above 900 px.

## 6. Host facts

Verified against dsh `0.2.1-rc.2`; each one cost time to discover.

| Fact | Consequence |
|---|---|
| `ctx.webServer.register({kind, path, handler}) → disposer`; exact match wins over prefix | control routes are safe to compose |
| `ctx.webServer.host` rejects wildcard binds | a second listener is the only way to serve a LAN |
| Every request passes a Host/Origin trust fence | a proxy **must** rewrite both |
| Launch token → `303` + authority-bound signed cookie; secret persisted in `.credentials.yaml`, so cookies survive a dsh restart | the gateway can mint cookies, and phones stay logged in |
| `connection.authenticatedUrl(origin)` is the supported way to get the token | no log scraping |
| Client plugins are `window.__ModuleLoader__.load({id, factory})` bundles; only `react` may be required | the whole browser half ships as one JS file |
| Slots used: `settings.section`, `sidebar.footer.action`, `shell.overlay` | |
| The shell routes on `location.hash`; an unknown value stops the client tree from mounting | deep links use `?panel=1`, never a hash |
| `dsh --dump-config` refuses the `desktop` profile ("managed exclusively by the Electron application") | install verification skips that check there |

## 7. Testing strategy

| Suite | What it proves |
|---|---|
| `test/host.test.mjs` | real listeners: bind/stop/rebind, login, lockout, pairing single-use, header rewriting, upgrade tunnelling, no-buffering streaming, cookie minting, state durability, secrets never exposed |
| `test/security.test.mjs` | every portal response carries the hardening set, and **proxied responses keep the app's own headers** |
| `test/relay.test.mjs` | real relay + real agent + dummy upstream: prefix stripping, header forwarding, WS byte-piping, unknown/offline tunnel, wrong token, reconnect, timeout release, framing |
| `test/qr.test.mjs` | QR correctness against an *independent* decoder (not a round-trip through the same tables) |
| `test/mobile.test.mjs` | the mobile layer against a **live** dsh instance the suite starts itself: drawer API, hit sizes, and a 12-configuration overflow audit |

`node --test` → 73 tests, ~56 s, no mocks on the network paths.




