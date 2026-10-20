# Security policy

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Open a private security advisory on the repository (GitHub → *Security* →
*Advisories* → *Report a vulnerability*), or contact the maintainer directly if
the advisory flow is unavailable. Include:

* what you can do that you should not be able to do,
* the version (`status()` in the panel shows it) and the platform,
* whether the portal was reachable over LAN, through a relay, or both,
* a minimal reproduction (curl transcript is ideal).

You can expect an acknowledgement within a few days. Please give a reasonable
window before public disclosure; credit is given in the changelog if you want it.

## Scope

In scope:

* the portal gateway (`lib/gateway.mjs`, `lib/proxy.mjs`, `lib/auth.mjs`,
  `lib/mint.mjs`) — authentication bypass, cookie forgery, request smuggling,
  open-proxy behaviour, header-injection, information disclosure;
* the login page (`lib/login-page.mjs`) — XSS, clickjacking, form-action abuse;
* the relay and tunnel (`tools/relay.mjs`, `lib/tunnel.mjs`) — stream
  confusion, token bypass, cross-tunnel data leakage;
* the browser half (`client.js`, `assets/`) — XSS against the Harness origin,
  slot-registration tricks that survive a host update.

Out of scope:

* anything that requires an attacker who can already read `state.json` or
  `.credentials.yaml` (that is game over by definition);
* the fact that plain-HTTP LAN mode is sniffable — documented, and TLS is
  supported;
* `dsh` itself and third-party plugins; report those upstream.

## Design notes that are *not* bugs

* **The public URL is not a credential.** `/__t/<id>/` is a stable address
  derived from the tunnel token; anyone who has it still needs the portal
  password or a one-time pairing code.
* **Devices share one dsh identity.** Revoking a device rejects its portal
  cookie; it cannot revoke the underlying dsh browser cookie, which never leaves
  the host.
* **Sessions are bound to the browser's User-Agent hash.** Copying a cookie to a
  different browser invalidates it on purpose.
* **A non-loopback bind without a password is refused** rather than warned
  about; that is the intended failure mode (`needs-password`).

## Hardening checklist for operators

1. Set a password before enabling the portal (the panel enforces this).
2. Use `tls:` when the portal is reachable from an untrusted network, or route
   it through the relay so the public hop is HTTPS.
3. Rotate the tunnel token if it was ever pasted somewhere you do not control
   (panel → 公网访问 → 断开, change the token on the server, reconnect).
4. Keep `~/.dsh/dsh-remote-portal/state.json` at `0600`; it holds the password
   hash, session signing secret and the tunnel token.
5. Watch the panel's 最近访问 card and 已授权设备 list; remove what you do not
   recognise.
