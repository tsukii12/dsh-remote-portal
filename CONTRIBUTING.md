# Contributing

Thanks for taking a look. This is a small, dependency-free plugin; the bar for a
change is “does it keep the guarantees below intact?”.

## Ground rules

1. **No runtime dependencies and no build step.** The host half is plain ESM on
   Node ≥ 20; the browser half is one hand-written bundle. A PR that adds a
   bundler or an npm dependency needs a very good reason.
2. **Never widen the host's trust.** The portal adds a gate in front of dsh; it
   must not touch dsh's own authentication, its Host/Origin fence, or the
   proxied responses. `test/security.test.mjs` pins the last one.
3. **Every network behaviour gets a test.** The suites start real listeners; a
   mock-based test for a proxy path is considered untested.
4. **Client code is defensive by construction.** A throwing client plugin blanks
   the whole Harness UI, so every registration in `client.js` lives in its own
   `try/catch`, and the factory body stays side-effect free.

## Getting set up

```bash
git clone <repo> dsh-remote-portal && cd dsh-remote-portal
node --test                                  # 72 tests, ~47 s, no network needed
node --test test/host.test.mjs               # one suite
```

To try it in a live Harness, install it into a profile and restart dsh:

```powershell
.\install.ps1 -Profile web
dsh web --port 3080          # then open http://127.0.0.1:3080/?token=…
```

The panel lives at **Settings → 远程访问** (or append `?panel=1`).

## What to change where

| You want to… | Touch |
|---|---|
| change the auth model, cookies, lockout | `lib/auth.mjs`, then `test/host.test.mjs` |
| change proxying (headers, streaming, upgrades) | `lib/proxy.mjs` + `test/host.test.mjs` |
| change the public relay protocol | `tools/relay.mjs` **and** `lib/tunnel.mjs` together + `test/relay.test.mjs` |
| change the login page | `lib/login-page.mjs` (keep it self-contained: no external requests, strict CSP) |
| change the panel or the mobile layer | `client.js`, `assets/mobile.css`, `assets/mobile.js`; `test/mobile.test.mjs` runs them against a live page |
| change the QR encoder | `lib/qr.mjs`; `test/qr.test.mjs` decodes with an independent implementation |

## Style

* Comments explain **why**, especially where a line exists because of a dsh
  behaviour (see `ARCHITECTURE.md` §6 — those facts cost real time to discover).
* Keep user-facing strings bilingual (`zh` + `en`) and go through the existing
  `t()` dictionaries.
* No `console.log` in the host half; use the injected `logger`.
* Prefer small, boring functions and explicit error values over exceptions in
  request paths.

## Pull requests

* One logical change per PR, with the test that proves it.
* Update `CHANGELOG.md` under *Unreleased*.
* Say which environment you verified on (OS, dsh version, profile).
* If user-visible, add or update a screenshot under `docs/screenshots/`.



