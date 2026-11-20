# dsh_client

Pure-Dart client for the DeepSeek Harness `dsh web` API. It is verified against DSH 0.2.0-rc.2 and 0.2.1-rc.2.

## Layers

| Layer | Role |
|---|---|
| `DshCarrier` | Pluggable transport: unary calls plus links that multiplex logical streams |
| `DshHttpCarrier` (default) | `DshConnection` (launch-token login, cookie, `Host` override, no `Origin`), `POST /api/<endpoint>`, `/api/remote.mux` WebSocket |
| `DshRpc` | `call(endpoint, args)` → `{ok, value \| error}` |
| `DshMux` | `$events` ready handshake, generations, reconnect backoff, stream reopen/resync, pending approvals |
| `DshClient` | App API: `connect`, `listSessions`, `createSession`, `watch`, `prompt`, `cancel`, `history`, `respondApproval`, `answerQuestion`, `listModels`, `setModel`, `setProviderKey`, `archiveSession`, `watchWorkspaces`, `hostEvents`, `renameSession`, `setPermissionPreset`, `executeCommand`, `close`, ... |
| `ChatTranscript` | Optional reducer from events to chat items |

## Carriers

```dart
// Local engine (unchanged):
final local = await DshClient.connect(launchUrl: 'dsh web: http://127.0.0.1:3080/?token=…');

// Any other carrier, e.g. the encrypted remote tunnel from package:dsh_remote:
final client = await DshClient.connectCarrier(myCarrier);   // or DshClient.withCarrier(myCarrier)
```

A carrier implements:

- `call(endpoint, args)`: returns `RpcOk` / `RpcError` for Host outcomes and throws for carrier failures.
- `openLink(options)`: returns a `DshMuxLink`. The link delivers `{type: item|end|error, streamId, ...}` frames for streams opened with `open(streamId, endpoint, {args})`, implements `cancel(streamId)`, and reports its own death once through `onLost`.

`DshMux` does everything above a single link, so a new carrier gets reconnects, generations and `watch()` resync for free.

Carriers can also narrow the surface:

- `supportsUplink`: when false, `MuxStream.send` throws `UnsupportedError`.
- `allowsEndpoint`: refused endpoints resolve to `METHOD_NOT_ALLOWED`, which `DshClient.supportsEndpoint` exposes.
- `DshCarrierRefusedException(code)`: a carrier throws it from `openLink` when only user action can help. The mux stops in `DshConnectionState.unauthorized` (like HTTP 401/403) until `mux.reconnect()`.

`DshClient.connection` is only available on the HTTP carrier; it throws `StateError` otherwise.

## Tests

```bash
dart test -x live                                   # fixtures, transcript, fake HTTP Host, in-memory carrier
DSH_LIVE_URL='<dsh web launch URL>' dart test test/live_test.dart   # real dsh web, no prompts
dart run bin/probe.dart --url '<launch url>' --list-only
```
