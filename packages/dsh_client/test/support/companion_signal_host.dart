// Controlled loopback Host for actual DshClient HTTP, WebSocket mux and SSE.
// It does not emulate engine execution; the Node engine suite owns that proof.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';

const signalTestGeneration = '11111111-1111-4111-8111-111111111111';
const signalTestBinding = '22222222-2222-4222-8222-222222222222';
const signalTestStore = '33333333-3333-4333-8333-333333333333';
const signalTestBridge = '44444444-4444-4444-8444-444444444444';
Map<String, Object?> signalTestCapabilities() => {
  'v': 1,
  'generation': signalTestGeneration,
  'available': true,
  'reason': null,
  'kinds': ['run.result'],
  'maxEventBytes': 1024,
  'replay': false,
  'counts': false,
  'devicePower': {'available': false},
  'notifications': {'available': false},
};
Map<String, Object?> signalTestRecallBinding({
  int memoryRevision = 7,
  String sessionId = 'companion',
  String status = 'ready',
}) => {
  'v': 1,
  'bindingId': signalTestBinding,
  'bridgeEpoch': signalTestBridge,
  'recallEpoch': 1,
  'storeId': signalTestStore,
  'memoryRevision': memoryRevision,
  'sessionId': sessionId,
  'status': status,
  'reason': status == 'ready' ? null : 'user-off',
  'selectorVersion': companionRecallSelector,
  'serverNow': 1794090000000,
};
Map<String, Object?> signalTestEnvelope({
  String session = 'task',
  String callId = 'call-1',
  int seq = 5,
  int turn = 1,
  String kind = 'test',
  String result = 'succeeded',
  int? exitCode = 0,
}) => {
  'v': 1,
  'id': companionRunEventId(session, callId, seq),
  'generation': signalTestGeneration,
  'source': {'sessionId': session, 'turn': turn, 'step': 1, 'callId': callId, 'seq': seq},
  'payload': {
    'runId': callId,
    'runKind': kind,
    'result': result,
    'exitCode': exitCode,
    'durationMs': 10,
    'passed': null,
    'failed': null,
    'skipped': null,
  },
};

class CompanionSignalTestHost {
  CompanionSignalTestHost._(this.server) {
    server.listen(_handle);
  }
  static Future<CompanionSignalTestHost> start() async =>
      CompanionSignalTestHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
  final HttpServer server;
  Uri get baseUri => Uri.parse('http://127.0.0.1:${server.port}');
  final paths = <String>[];
  final cookies = <String?>[];
  final sockets = <WebSocket>[];
  final streams = <HttpResponse>[];
  final _eventIds = <WebSocket, String>{};
  final clients = <DshClient>[];
  Object capability = signalTestCapabilities();
  int capabilityStatus = 200;
  bool sendReady = true;
  Object binding = signalTestRecallBinding();
  Future<void> Function()? beforeBinding;
  Future<void> Function(HttpRequest)? customCapability;
  Future<void> Function(HttpResponse)? onStream;
  Completer<void> streamOpened = Completer<void>();
  int generation = 0, streamOpens = 0;

  Future<DshClient> connect({bool startMux = true}) async {
    final client = await DshClient.connect(
      baseUri: baseUri,
      token: 'test',
      startMux: startMux,
      muxOptions: const MuxOptions(autoReconnect: false),
    );
    clients.add(client);
    return client;
  }

  Future<void> _handle(HttpRequest req) async {
    if (req.uri.path == '/' && req.uri.queryParameters['token'] == 'test') {
      req.response
        ..statusCode = 303
        ..headers.set('location', './')
        ..headers.add('set-cookie', 'dsh-auth-signal=v1.test; Path=/; HttpOnly');
      await req.response.close();
      return;
    }
    paths.add(req.uri.path);
    cookies.add(req.headers.value('cookie'));
    if (req.headers.value('cookie') != 'dsh-auth-signal=v1.test') {
      req.response.statusCode = 401;
      await req.response.close();
      return;
    }
    if (req.uri.path == '/api/remote.mux') {
      final ws = await WebSocketTransformer.upgrade(req);
      sockets.add(ws);
      generation++;
      ws.listen((raw) {
        final f = jsonDecode(raw as String) as Map;
        if (f['type'] == 'open' && f['endpoint'] == r'$events') {
          _eventIds[ws] = f['streamId'] as String;
          _event(ws, {
            'type': 'ready',
            'clientId': 'client-$generation',
            'host': {'home': '/test'},
          });
        }
      });
      return;
    }
    if (req.uri.path == '/dsh-go/v1/companion/signals') {
      if (customCapability != null) {
        await customCapability!(req);
        return;
      }
      await reply(req, capability, status: capabilityStatus);
      return;
    }
    if (req.uri.path == '/dsh-go/v1/companion/signals/stream') {
      streamOpens++;
      req.response
        ..statusCode = 200
        ..bufferOutput = false
        ..headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      streams.add(req.response);
      if (sendReady) frame(req.response, 'companion/ready', {'v': 1, 'generation': signalTestGeneration});
      if (!streamOpened.isCompleted) streamOpened.complete();
      await onStream?.call(req.response);
      return;
    }
    if (req.uri.path == '/dsh-go/v1/companion/recall') {
      await reply(req, {
        'v': 1,
        'supported': true,
        'reason': null,
        'busy': true,
        'activeBindingId': signalTestBinding,
        'selectorVersion': companionRecallSelector,
        'maxItems': 12,
        'textUtf16Budget': 1200,
      });
      return;
    }
    if (req.uri.path == '/dsh-go/v1/companion/recall/bindings/$signalTestBinding') {
      await beforeBinding?.call();
      await reply(req, binding);
      return;
    }
    await reply(req, {
      'error': {'code': 'companion/not-found'},
    }, status: 404);
  }

  static Future<void> reply(HttpRequest req, Object value, {int status = 200}) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(value));
    await req.response.close();
  }

  void _event(WebSocket socket, Map<String, Object?> value) =>
      socket.add(jsonEncode({'type': 'item', 'streamId': _eventIds[socket], 'value': value}));
  void event(Map<String, Object?> value) => _event(sockets.last, value);
  Future<MuxEventProvenance> proof(DshClient client, {String session = 'task', bool running = false}) async {
    final receipt = client.mux.hostEventReceipts.firstWhere((r) => r.event is SessionStatusEvent);
    event({
      'type': 'emit',
      'event': 'api-session/status',
      'args': [session, running],
    });
    return (await receipt).provenance;
  }

  void frame(HttpResponse response, String eventName, Object data, {String? id}) {
    response.write('${id == null ? '' : 'id: $id\n'}event: $eventName\ndata: ${jsonEncode(data)}\n\n');
  }

  void run(Map<String, Object?> value) {
    for (final response in streams.toList()) {
      frame(response, 'companion/run-result', value, id: value['id'] as String);
    }
  }

  Future<void> close() async {
    for (final client in clients) {
      await client.close();
    }
    for (final socket in sockets) {
      await socket.close();
    }
    for (final response in streams) {
      unawaited(response.close().catchError((_) {}));
    }
    await server.close(force: true);
  }
}
