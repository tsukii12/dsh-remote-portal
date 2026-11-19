# Testing

[Documentation index](README.md)

Use Node.js 20 or later. No runtime dependencies need to be installed.

```sh
node --test                       # all suites
node --test test/host.test.mjs    # gateway and host integration
node --test test/relay.test.mjs   # relay and tunnel integration
```

Gateway and tunnel tests use real listeners. The QR suite verifies codes with an
independent decoder. The mobile suite includes both unit tests and live browser
checks; only the latter skip when Chrome or a reachable dsh Web instance is missing.

## Run the live mobile checks

1. In another terminal, start a local dsh Web instance:

   ```sh
   dsh web --port 3080 --no-open
   ```

2. Set the base URL without query parameters, the token from the printed launch URL,
   and the path to an executable Chrome or Chromium. Keep the token local.
   Example for a POSIX shell:

   ```sh
   CHROME_PATH=/path/to/chrome \
   DSH_WEB_TEST_URL=http://127.0.0.1:3080 \
   DSH_WEB_TEST_TOKEN='<local launch token>' \
   node --test
   ```

   Use `node --test test/mobile.test.mjs` to run only the mobile suite. On Windows,
   the suite can also launch dsh automatically if it finds `dsh.cmd`; the explicit
   URL and token work on all platforms. Check that the live cases did not skip.
