// Title reads (sessionsProvider) across a WebSocket reconnect of the same
// client (CR-fef154a). On an SSH host the app keeps its DshClient when the
// tunnel comes back on the same port and token, and only the mux reconnects:
// readListLiveConnectionProvider goes null while it does, which retires the
// title queue — but the queue's `session/projections` calls are plain HTTP
// POSTs the mux loss doesn't end. They still fold a log each on the Host, and
// what they answer belongs to a queue that's gone.
//
// Real DshClient HTTP and WebSocket transport against an owned loopback
// imitation of the wire (not a DSH Host): plain test(), so no test binding
// fakes the sockets (flutter_test_config.dart installs none).
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Selected extends ActiveHostController {
  @override
  HostRef build() => HostRef.portal('loopback');
}

class _Workspaces extends WorkspacesController {
  @override
  WorkspacesState build() => const WorkspacesState(status: WorkspacesStatus.ready);
}

class _WorkspacePrefs extends WorkspacePrefsController {
  @override
  WorkspacePrefs build() => const WorkspacePrefs(loaded: true);
}

Map<String, Object?> _folded(String id) => {
  'kind': 'sequenced',
  'asOfSeq': 12,
  'values': {
    'title': 'Title $id',
    'sessionListMetadata': {'blank': false},
  },
};

/// One `session/projections` POST the wire holds until it's answered.
class _Read {
  _Read(this.request, this.envelope, this.id);
  final HttpRequest request;
  final Map<String, Object?> envelope;
  final String id;
  bool answered = false;
}

class _Socket {
  _Socket(this.ws);
  final WebSocket ws;
  String? events;
  bool ready = false;
}

/// The Host's wire: a login, the mux WebSocket, `session/list` with eight
/// cold rows (no title), and `session/projections` held while [hold].
class _Wire {
  _Wire(this.server);

  static Future<_Wire> start() async {
    final wire = _Wire(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    wire.server.listen(wire._handle);
    return wire;
  }

  final HttpServer server;
  final reads = <_Read>[];
  final sockets = <_Socket>[];
  int lists = 0;

  /// The most title reads the Host held at once.
  int maxOutstanding = 0;
  bool allowReady = true;
  bool hold = true;

  Uri get base => Uri.parse('http://127.0.0.1:${server.port}');
  int get outstanding => reads.where((r) => !r.answered).length;

  void ready(_Socket socket) {
    if (socket.ready || socket.events == null || !allowReady) return;
    socket.ready = true;
    socket.ws.add(
      jsonEncode({
        'type': 'item',
        'streamId': socket.events,
        'value': {
          'type': 'ready',
          'clientId': 'loopback-${sockets.indexOf(socket)}',
          'host': {'home': '/loopback-home'},
        },
      }),
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    if (request.uri.path == '/') {
      // A synthetic login: the cookie the client carries from here on.
      response.statusCode = 303;
      response.headers.set('location', './');
      response.headers.add('set-cookie', 'dsh-auth-loopback=v1.fixture; Path=/; HttpOnly; SameSite=Strict');
      await response.close();
      return;
    }
    if (request.uri.path == '/api/remote.mux') {
      final socket = _Socket(await WebSocketTransformer.upgrade(request));
      sockets.add(socket);
      socket.ws.listen((raw) {
        final frame = jsonDecode(raw as String) as Map<String, Object?>;
        if (frame['type'] != 'open') return;
        final id = frame['streamId'];
        if (frame['endpoint'] == r'$events') {
          socket.events = id as String;
          ready(socket);
        } else if (frame['endpoint'] == 'workspace/follow') {
          socket.ws.add(
            jsonEncode({
              'type': 'item',
              'streamId': id,
              'value': {
                'type': 'baseline',
                'items': <Object?>[],
                'archivedSessionIds': <Object?>[],
                'pinnedSessionIds': <Object?>[],
              },
            }),
          );
        }
      });
      return;
    }
    final envelope = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
    final endpoint = request.uri.path.substring('/api/'.length);
    final args = ((envelope['payload'] as Map)['args'] as Map).cast<String, Object?>();
    if (endpoint == 'session/list') {
      lists++;
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'type': 'server-response',
          'rpcId': envelope['rpcId'],
          'result': {
            'ok': true,
            'value': {
              'items': [
                for (var i = 0; i < 8; i++)
                  {
                    'sessionId': 's$i',
                    'updatedAt': 1793000000000 - i * 1000,
                    'running': false,
                    'blank': false,
                    'agentAvailable': false,
                  },
              ],
            },
          },
        }),
      );
      await response.close();
    } else if (endpoint == 'session/projections') {
      final read = _Read(request, envelope, (args['request'] as Map)['sessionId'] as String);
      reads.add(read);
      if (outstanding > maxOutstanding) maxOutstanding = outstanding;
      if (!hold) await answer(read);
    } else {
      response.statusCode = 404;
      await response.close();
    }
  }

  Future<void> answer(_Read read, {int status = 200}) async {
    if (read.answered) return;
    read.answered = true;
    final response = read.request.response;
    response.statusCode = status;
    if (status == 200) {
      response.headers.contentType = ContentType.json;
      response.write(
        jsonEncode({
          'type': 'server-response',
          'rpcId': read.envelope['rpcId'],
          'result': {'ok': true, 'value': _folded(read.id)},
        }),
      );
    }
    await response.close().catchError((Object _) {});
  }

  Future<void> close() async {
    for (final read in reads.toList()) {
      await answer(read);
    }
    for (final socket in sockets) {
      await socket.ws.close().catchError((Object _) {});
    }
    await server.close(force: true);
  }
}

Future<void> _until(bool Function() condition, String reason) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 5)) throw StateError('timeout: $reason');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Lets loopback round trips land.
Future<void> _settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Polls [condition] for a while; whether it came true.
Future<bool> _eventually(bool Function() condition) async {
  final timer = Stopwatch()..start();
  while (!condition()) {
    if (timer.elapsed > const Duration(seconds: 3)) return false;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return true;
}

void main() {
  late _Wire wire;
  late DshClient client;
  late ProviderContainer c;
  late ProviderSubscription<AsyncValue<List<SessionSummary>>> watched;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    wire = await _Wire.start();
    client = await DshClient.connect(
      baseUri: wire.base,
      token: 'loopback-token',
      muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 100)]),
    );
    c = ProviderContainer(
      overrides: [
        activeHostProvider.overrideWith(_Selected.new),
        activeConnectionProvider.overrideWithValue(
          AsyncData(HostConnection(client: client, isLocal: false, kind: HostKind.portal, hostId: 'loopback')),
        ),
        readListIdentityProvider.overrideWithValue(ReadListIdentity.of(['ssh-loopback'])),
        workspacesProvider.overrideWith(_Workspaces.new),
        workspacePrefsProvider.overrideWith(_WorkspacePrefs.new),
        dsBotOwnedSessionsProvider.overrideWithValue(const {}),
      ],
    );
    watched = c.listen(sessionsProvider, (_, _) {}, fireImmediately: true);
  });

  tearDown(() async {
    watched.close();
    c.dispose();
    for (final read in wire.reads.toList()) {
      await wire.answer(read);
    }
    await client.close();
    await wire.close();
  });

  Map<String, String?> titles() => {for (final row in c.read(sessionsProvider).value!) row.sessionId: row.title};

  /// The first list's two reads out and held; then only the WebSocket drops
  /// (the HTTP reads stay out), and the same client's mux comes back ready
  /// with the next list read.
  Future<void> reconnectWithReadsOut() async {
    await c.read(sessionsProvider.future);
    await _until(() => wire.reads.length == 2, 'the first two title reads go out');
    // Lists landing on a steady connection share the two readers.
    await c.read(sessionsProvider.notifier).refresh();
    await c.read(sessionsProvider.notifier).refresh();
    await _settle();
    expect(wire.outstanding, 2);
    final generation = client.mux.generation!.number;
    final listsBefore = wire.lists;
    wire.allowReady = false;
    await wire.sockets.first.ws.close(1001, 'only the WebSocket drops');
    await _until(() => c.read(readListLiveConnectionProvider) == null, 'the live connection is revoked');
    await c.read(sessionsProvider.future);
    expect(c.read(sessionsProvider).value, isEmpty);
    expect(wire.reads.take(2).every((r) => !r.answered), isTrue, reason: 'the HTTP reads are still out');
    await _until(() => wire.sockets.length == 2 && wire.sockets.last.events != null, 'a second WebSocket opens');
    wire.allowReady = true;
    wire.ready(wire.sockets.last);
    await _until(() => client.mux.generation?.number == generation + 1, 'the same client is ready again');
    expect(identical(c.read(activeConnectionProvider).value!.client, client), isTrue);
    await _until(() => wire.lists > listsBefore, 'the reconnected list is read');
    await c.read(sessionsProvider.future);
    await _settle();
  }

  test('reads still out on the client when its WebSocket reconnects count against the two readers', () async {
    await reconnectWithReadsOut();
    expect(wire.outstanding, lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
    expect(wire.reads, hasLength(2), reason: 'the reconnected queue waits for the reads still out');
    // Each read still out that ends hands its slot to the reconnected queue,
    // which reads every row (what the retired reads answered lands nowhere).
    wire.hold = false;
    for (final read in wire.reads.toList()) {
      await wire.answer(read);
    }
    expect(await _eventually(() => titles().values.every((t) => t != null)), isTrue, reason: '${titles()}');
    expect(wire.maxOutstanding, lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
    expect(wire.reads.skip(2).map((r) => r.id), unorderedEquals(['s0', 's1', 's2', 's3', 's4', 's5', 's6', 's7']));
  });

  test('a retired read answering 404 late doesn\'t stop the reconnected queue reading titles', () async {
    await reconnectWithReadsOut();
    // The reads out of the retired queue answer now: one "not supported",
    // one with its title. Neither lands; the queue reading now goes on.
    await wire.answer(wire.reads[0], status: 404);
    await _settle();
    await wire.answer(wire.reads[1]);
    await _settle();
    wire.hold = false;
    for (final read in wire.reads.skip(2).toList()) {
      await wire.answer(read);
    }
    await _settle();
    await c.read(sessionsProvider.notifier).refresh();
    expect(await _eventually(() => titles().values.every((t) => t != null)), isTrue, reason: '${titles()}');
    expect(wire.maxOutstanding, lessThanOrEqualTo(SessionsController.titleReadsAtOnce));
  });
}
