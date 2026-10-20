# Performance & layout measurements

Every number here was measured on a live page, not estimated. The harness is
`tools/cdp.mjs` (a small Chrome DevTools Protocol driver) plus `curl`; the
commands are reproducible on any machine that has Chrome and the plugin
installed.

Reproduce the whole set:

```bash
dsh web --port 19920 --no-open          # note the ?token=… URL it prints
# open http://127.0.0.1:3081/?token=… once? no — set a password in the panel instead
node tools/cdp.mjs audit http://127.0.0.1:3081/ out.json --widths 320,390,430,768 --themes dark,light
```

The panel's control API (`/dsh-remote-portal/*`) needs the portal session, so an
audit of the *app* page is run with a login step:

```bash
PRE='(async()=>{const b=new URLSearchParams({password:"…"});
  await fetch("/__portal/login",{method:"POST",
    headers:{"content-type":"application/x-www-form-urlencoded"},body:b,
    credentials:"same-origin"});location.replace("/")})()'
node tools/cdp.mjs audit http://127.0.0.1:3081/ out.json \
  --widths 320,390,430,768 --themes dark,light --pre "$PRE" --settle 8000
```

---

## 1. Layout: nothing overflows, at any size

`tools/cdp.mjs audit` reports `docScrollWidth`, `bodyScrollWidth`, whether the
mobile layer is active (`html[data-drp-mobile]`) and the elements that stick out
of the viewport.

| Viewports | Themes | Configs | Overflowing configs | Offenders | Layer active |
|---|---|---|---|---|---|
| 320 / 390 / 430 / 768 px | dark + light | 8 | **0** | **0** | yes (`data-drp-mobile`) |

Raw output (trimmed):

```json
[{ "requested": {"w":320,"h":844,"theme":"dark"},
   "innerWidth":320, "docScrollWidth":320, "bodyScrollWidth":320,
   "offenderCount":0, "htmlAttrs":"lang,data-ds-theme-source,style,data-drp-mobile", "ok":true },
 …
 { "requested": {"w":768,"h":844,"theme":"light"}, "ok":true }]
```

### The two fixes behind it

Both were found by measuring, not by looking:

| Symptom | Measured before | After | How |
|---|---|---|---|
| Session title crushed in the mobile header | **14 px** wide at 390 px viewport (the "N subagents" badge held 92 of the title cluster's 116 px) | **134 px** at 390, 110 px at 320, 174 px at 430; the badge yields first and hides ≤430 px | `getBoundingClientRect()` on the title element at 3 widths |
| A tall dialog's primary action unreachable | button at **y = 1836** in an 844 px viewport | inside the viewport, dialog scrolls internally | rect of the dialog's action row |

The header fix is three rules, not a redesign:

```css
header nav { min-width: 84px; }              /* the hamburger never shrinks */
div:has(> nav) { flex: 1 1 auto; min-width: 0; }  /* the title cluster may use the space */
@media (max-width: 430px) { /* the badge is hidden, the title keeps its minimum */ }
```

## 2. Long code, wide tables, big images

The three things that break a phone layout. Measured by injecting one of each
into the live conversation column at 390 px and reading the geometry
(`test/mobile.test.mjs` → "long code, wide tables and big images stay inside the
phone column"):

| Probe | Element box | Inner scroll width | Page overflow |
|---|---|---|---|
| `<pre>` with a 250-character unbroken URL | 390 px | **1,764 px** (scrolls inside) | **0** |
| table with 12 wide cells, in a `_tableScroll` wrapper | 390 px | **755 px** (pans) | **0** |
| `<img>` with an intrinsic size of 1600 × 900 | **390 px**, aspect ratio kept | — | **0** |

Before the rules, the same probe pushed the document to 602 px wide (212 px of
sideways scroll on every message that contained a wide table). The rules are:

```css
html[data-drp-mobile] img, video, canvas      { max-width: 100%; height: auto; }
html[data-drp-mobile] pre                     { max-width: 100%; overflow-x: auto; }
html[data-drp-mobile] [class*="_tableScroll"] { max-width: 100%; overflow-x: auto; }
html[data-drp-mobile] table                   { max-width: 100%; display: block; overflow-x: auto; }
```

The table rule matters more than it looks: dsh only adds `md-table-wide` (its own
horizontal scroller) when the table looked wide **at desktop width**, which says
nothing about a 390 px column — so the scroller is enabled unconditionally on
mobile instead of re-measuring every table after each render.

## 3. Login page: it fits a small phone

Measured on `GET /` (the login page) at 844 px viewport height:

| Viewport | Password input | Submit button | Horizontal overflow | Needs scrolling |
|---|---|---|---|---|
| 320 × 844 | 276 × **48** | 276 × **48** | no | **no** (`scrollHeight` 844) |
| 390 × 844 | 346 × 48 | 346 × 48 | no | no |
| 768 × 844 | 334 × 48 | 334 × 48 (card 400 × 477, centred) | no | no |

48 px controls clear the 44 px touch-target guideline, and the whole page fits a
320 × 844 screen without scrolling — the "continue" button is never below the
fold on a small phone.

## 4. Asset transfer: 3.6× smaller, and free on reload

Both asset routes (the portal's own `/dsh-remote-portal/assets/*` and the
dsh-origin route injected into the app) send `ETag`, honour `If-None-Match` and
gzip when the client asks.

```console
$ curl -s -o /dev/null -w '%{size_download} %{time_total}\n' \
       -H 'Accept-Encoding: gzip' http://127.0.0.1:3081/dsh-remote-portal/assets/mobile.css
5808 0.0186

$ curl -s -o /dev/null -w '%{http_code} %{size_download}\n' \
       -H 'If-None-Match: W/"512f-1a15aab728d"' http://127.0.0.1:3081/dsh-remote-portal/assets/mobile.css
304 0
```

| Asset | Raw | gzip | Ratio | Revalidate |
|---|---|---|---|---|
| `mobile.css` | 20,783 B | **5,808 B** | 27.9 % | `304`, 0 B, 13.8 ms |
| `mobile.js` | 16,078 B | **5,200 B** | 32.3 % | `304`, 0 B |

## 5. The gateway's own overhead

Measured with `curl` against the same upstream, alternating direct
(`127.0.0.1:19920`) and through the gateway (`127.0.0.1:3081`) 20 times each:

| Path | p50 latency | Compressed bytes |
|---|---|---|
| direct to dsh | 2–4 ms | 319,590 |
| through the gateway | 5–10 ms more per request | 319,590 (identical) |

So a remote page pays single-digit milliseconds per request on loopback, and the
proxy does not re-compress or alter the body.

## 6. Panel re-renders

The panel polls `GET /dsh-remote-portal/status` every 3 s while it is visible.
The response is compared against the previous one and the React state update is
skipped when nothing changed — an idle panel therefore re-renders once, not 20
times a minute. (Verified by counting renders in the dev build; the comparison
is a plain JSON-equality check on the payload.)

## 7. What is *not* fast, and why

A warm reload of the app page still transfers ~6.7 MB. That is dsh's own bundle,
served with `Cache-Control: no-store`; the plugin deliberately does not rewrite
those headers (the app owns its caching policy, and a stale bundle after an
upgrade is worse than a re-download). The only assets the plugin controls are its
two, and they are cached as shown above.

---

### Reference: the audit tool

```console
$ node tools/cdp.mjs
  shot  <url> <out.png>            screenshot (flags: --w --h --mobile --pre --post --settle)
  dom   <url>                      serialized DOM
  eval  <url> <expression>         evaluate JS in the page
  audit <url> <out.json>           overflow audit (--widths --themes --pre)
```

Other flags: `--ignore-cert` (self-signed TLS), `--host-map host=ip` (verify a
deployment before DNS exists), `--pre-file` (load the pre script from a file).

