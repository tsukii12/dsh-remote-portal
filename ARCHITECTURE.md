# YuRemote architecture and security model

[简体中文](docs/ARCHITECTURE.zh-CN.md) · [Documentation](docs/README.md#english)

## 1. Gateway and upstream

A browser or app talks directly to the YuRemote gateway on the host, or sends HTTPS via a relay. In either case the gateway authenticates the visitor and proxies to dsh. Leave the dsh Web listener private. It has a launch token and checks incoming Host and Origin; it is not a substitute for the portal.

The gateway rewrites upstream authority headers to match dsh, streams HTTP responses and forwards WebSocket upgrades. It uses the dsh launch credential locally to mint an upstream cookie; that credential is not sent to the client. The browser can receive the minted cookie alongside the gateway's own cookie. Device authorization is enforced by the gateway.

## 2. Relay and app

The tunnel agent dials out from the host and multiplexes visitor traffic over its connection to the relay. The relay routes by tunnel ID; the gateway still handles sign-in. A relay operator terminating TLS can see visitor traffic, so run the service on infrastructure you trust.

The web remote uses dsh's interface with YuRemote layout and navigation enhancements. The Flutter app connects through the gateway with a cookie session and uses dsh RPCs and the `remote.mux` WebSocket. The workspaces and engine stay on the host.

## 3. Authentication

- Passwords are hashed with scrypt. The default lockout begins after five failures, with a 60-second initial delay. Successful logins register a device session.
- The signed `dsh_portal` cookie is HttpOnly, SameSite=Lax, bound to the User-Agent, and Secure when the gateway sees a secure connection. This does not protect plaintext HTTP from interception.
- Pairing codes are single use, stored as hashes and expire after 180 seconds by default. The relay token is separate: it lets the agent attach to the relay, not sign in to dsh.
- In password mode, a non-loopback listener requires a configured password. Pair-only mode requires a pairing code instead. Open mode is loopback-only; never expose an open-mode gateway with a tunnel.

## 4. Repository map

| Path | Responsibility |
| --- | --- |
| `index.js`, `cordis.patch.yml`, `install.*`, `tools/install-profile.mjs` | Plugin registration, control routes and installation |
| `lib/` | Gateway, login page, proxy, authentication, state, QR and tunnel agent |
| `client.js`, `assets/`, `locale/` | Browser settings, workspace picker, mobile layout and localization |
| `tools/relay.mjs`, `tools/deploy-relay.sh` | Relay server and systemd deployment |
| `app/`, `packages/` | Flutter app and shared Dart packages, including the portal and dsh clients |
| `test/`, `tools/cdp.mjs` | Node coverage and Chrome DevTools tools |

## 5. Host configuration

The entry in `cordis.patch.yml` provides initial settings. Values saved in the portal panel take precedence on restart. State lives under `$DSH_HOME/yuremote/` (or `~/.dsh/yuremote/` by default); keep `state.json` private (mode `0600`).

| Key | Default or purpose |
| --- | --- |
| `enabled`, `host`, `port` | `true`, `0.0.0.0`, `3081`; see [panel settings](docs/GETTING-STARTED.md#remote-access-settings) |
| `mobile` | `true`; enables the mobile browser layer |
| `auth.mode` | `password`; also accepts `pair-only` and loopback-only `open` |
| `auth.sessionDays`, `auth.maxFailures`, `auth.lockSeconds` | `30`, `5`, `60` |
| `tls` | Off; set both `certFile` and `keyFile` (PEM) for direct HTTPS |
| `tunnel` | Off; set `url` and `token` to connect, optionally `caFile` or `insecure` |
| `stateDir`, `brand` | Optional state directory and login page label |
| `rateLimit` | `1200` requests per 10-second window per address; `0` disables it |

See [Security policy](SECURITY.md) to report a vulnerability.
