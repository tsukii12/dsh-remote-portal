# Development and testing

[简体中文](TESTING.zh-CN.md) · [Documentation](README.md#english)

Use Node.js 20+ for the plugin and relay. See the [repository map](../ARCHITECTURE.md#4-repository-map) before editing. Keep changes focused; add coverage to the suite for the component you change.

```sh
npm test                          # YuRemote Node suites (same command as CI)
node --test test/host.test.mjs     # Gateway and host integration
node --test test/relay.test.mjs    # Relay and tunnel integration
```

The mobile suite includes live Chrome checks. Start `dsh web --port 3080 --no-open` with YuRemote installed in a separate terminal. Use the loopback base URL without a query string and the token from the launch URL. Do not share it.

```sh
CHROME_PATH=/path/to/chrome \
DSH_WEB_TEST_URL=http://127.0.0.1:3080 \
DSH_WEB_TEST_TOKEN='<local launch token>' \
npm test
```

On Windows, the suite can auto-start dsh if it finds `dsh.cmd`. If Chrome or a live instance is unavailable, the live cases skip. Check the skip count before reporting browser coverage.

A bare `node --test` also discovers the vendored Tavern differential tests. The Tavern browser adapter tests require Node's `--experimental-vm-modules` flag; they are not part of the YuRemote gateway workflow.

For Flutter, see [build from source](APP.md#build-from-source). The app workflow uses the following active checks; the inherited legacy suite is not the app's CI gate.

```sh
cd app
flutter pub get
flutter analyze lib
flutter test test/portal
```

On Linux, CI installs Noto CJK fonts and sets `DSH_TEST_FONT_DIR=/usr/share/fonts/opentype/noto`. The same workflow runs `dart pub get`, `dart analyze` and `dart test` in each of `packages/dsh_client` and `packages/dsh_portal`.
