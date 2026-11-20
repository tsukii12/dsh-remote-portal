// Dev-only copies of existing pure-Dart test fixtures. Kept here because package:
// imports cannot escape lib/ in an Android entry point. Sources (same APIs):
// packages/dsh_client/test/support/fake_dsh.dart: FakeDsh/FakeMuxSocket
// app/test/notify/support.dart: session/alert/notification fixtures
// app/test/chat/support/composer_fakes.dart: silentWav/readySpeechCatalog
// No Flutter test binding, platform mocking or production entry references.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_client/dsh_client.dart';

import '../state/notify_state.dart';

/// Minimal in-process imitation of `dsh web` 0.2.0-rc.2's carrier: launch
/// token login, cookie check, Host/Origin fence, `POST /api/<endpoint>`
/// envelopes and the `/api/remote.mux` WebSocket with `$events`.
class FakeDsh {
  FakeDsh._(this._server);

  static const token = 'launch-token';
  static const cookieName = 'dsh-auth-test';
  static const cookieValue = 'v1.payload.sig';

  static Future<FakeDsh> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeDsh._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;
  int get port => _server.port;
  Uri get baseUri => Uri.parse('http://127.0.0.1:$port');

  /// Every HTTP request's method, path, and headers of interest.
  final List<Map<String, Object?>> requests = [];

  /// Decoded RPC envelopes in arrival order.
  final List<Map<String, Object?>> rpcCalls = [];

  /// Business handlers: endpoint -> args -> result (`{ok, value|error}`).
  final Map<String, Map<String, Object?> Function(Map<String, Object?> args)> handlers = {};

  /// Called for each logical stream the client opens (not `$events`).
  void Function(FakeMuxSocket socket, String streamId, String endpoint, Map<String, Object?> payload)? onOpen;

  /// Pending waterfalls redelivered to every new `$events` stream.
  final List<Map<String, Object?>> pendingWaterfalls = [];
  final List<FakeMuxSocket> sockets = [];
  int _generation = 0;
  bool rejectWebSocket = false;

  String? acceptedAuthority;
  String indexHtml = '';
  bool gzipIndex = false;
  Future<void> Function()? beforeIndex;

  Future<void> close() async {
    for (final socket in sockets) {
      await socket.ws.close();
    }
    await _server.close(force: true);
  }

  bool _cookieOk(HttpRequest request) {
    final raw = request.headers.value(HttpHeaders.cookieHeader) ?? '';
    return raw.split(';').map((s) => s.trim()).contains('$cookieName=$cookieValue') &&
        request.headers.value('host') == (acceptedAuthority ?? '127.0.0.1:$port');
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add({
      'method': request.method,
      'path': request.uri.path,
      'rawPath': request.requestedUri.path,
      'host': request.headers.value('host'),
      'origin': request.headers.value('origin'),
      'cookie': request.headers.value(HttpHeaders.cookieHeader),
    });
    final response = request.response;
    final origin = request.headers.value('origin');
    if (origin != null && origin != 'http://${request.headers.value('host')}') {
      response.statusCode = 403;
      await response.close();
      return;
    }
    if (request.uri.path == '/' && request.method == 'GET') {
      final tokens = request.uri.queryParametersAll['token'] ?? const [];
      if (tokens.length == 1 && tokens.single == token) {
        acceptedAuthority = request.headers.value('host');
        response.statusCode = 303;
        response.headers
          ..set('location', './')
          ..add(
            'set-cookie',
            '$cookieName=$cookieValue; Max-Age=2592000; Path=/; '
                'Expires=Sat, 21 Nov 2099 19:10:16 GMT; HttpOnly; SameSite=Strict',
          );
        await response.close();
        return;
      }
      final html = indexHtml;
      final compressed = gzipIndex;
      if (beforeIndex != null) await beforeIndex!();
      response.statusCode = _cookieOk(request) && tokens.isEmpty ? 200 : 401;
      if (response.statusCode == 200) {
        if (compressed) {
          response.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          response.add(gzip.encode(utf8.encode(html)));
        } else {
          response.write(html);
        }
      }
      await response.close();
      return;
    }
    if (request.uri.path == '/api/remote.mux') {
      if (rejectWebSocket || !_cookieOk(request)) {
        response.statusCode = 401;
        await response.close();
        return;
      }
      final ws = await WebSocketTransformer.upgrade(request);
      final socket = FakeMuxSocket(this, ws, ++_generation);
      sockets.add(socket);
      return;
    }
    if (!request.uri.path.startsWith('/api/')) {
      response.statusCode = 404;
      await response.close();
      return;
    }
    if (!_cookieOk(request)) {
      response.statusCode = 401;
      response.write('unauthorized');
      await response.close();
      return;
    }
    if (request.headers.contentType?.mimeType != 'application/json') {
      response.statusCode = 415;
      await response.close();
      return;
    }
    final envelope = jsonDecode(await utf8.decodeStream(request)) as Map<String, Object?>;
    rpcCalls.add(envelope);
    final endpoint = request.requestedUri.path.substring('/api/'.length);
    final Map<String, Object?> result;
    if (envelope['method'] != endpoint) {
      result = {
        'ok': false,
        'error': {'code': 'gateway/bad-request', 'message': 'method mismatch', 'details': {}},
      };
    } else {
      final handler = handlers[endpoint];
      if (handler == null) {
        response.statusCode = 404;
        await response.close();
        return;
      }
      final args = ((envelope['payload'] as Map)['args'] as Map).cast<String, Object?>();
      result = handler(args);
    }
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode({'type': 'server-response', 'rpcId': envelope['rpcId'], 'result': result}));
    await response.close();
  }
}

class FakeMuxSocket {
  FakeMuxSocket(this.host, this.ws, this.generation) {
    ws.listen(_onMessage);
  }

  final FakeDsh host;
  final WebSocket ws;
  final int generation;
  String? eventsStreamId;
  final List<Map<String, Object?>> received = [];
  String get clientId => 'client-$generation';

  void send(Map<String, Object?> frame) => ws.add(jsonEncode(frame));
  void item(String streamId, Object? value) => send({'type': 'item', 'streamId': streamId, 'value': value});
  void event(Map<String, Object?> value) => item(eventsStreamId!, value);

  void _onMessage(Object? data) {
    final frame = (jsonDecode(data! as String) as Map).cast<String, Object?>();
    received.add(frame);
    if (frame['type'] != 'open') return;
    final streamId = frame['streamId']! as String;
    final endpoint = frame['endpoint']! as String;
    if (endpoint == r'$events') {
      eventsStreamId = streamId;
      event({
        'type': 'ready',
        'clientId': clientId,
        'host': {'home': '/home/user'},
      });
      for (final waterfall in host.pendingWaterfalls) {
        event(waterfall);
      }
      return;
    }
    host.onOpen?.call(this, streamId, endpoint, (frame['payload']! as Map).cast<String, Object?>());
  }
}

/// Lets queued microtasks and zero-length timers run.
Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

SessionSummary session(String id, {String? title, bool running = false, String? parent}) => SessionSummary(
  sessionId: id,
  updatedAt: DateTime(2026, 10, 24),
  running: running,
  blank: false,
  agentAvailable: true,
  parentSessionId: parent,
  origin: parent == null ? null : 'subagent',
  projections: SessionProjections(1, {'title': title}),
);

ApprovalRequestedEvent approval(String eventId, String sessionId, {String tool = 'bash', String? reason}) =>
    ApprovalRequestedEvent(ApprovalRequest(eventId: eventId, sessionId: sessionId, toolName: tool, reason: reason));

UserQuestionRequestedEvent question(String eventId, String sessionId, List<String> questions) =>
    UserQuestionRequestedEvent(
      UserQuestionRequest(
        eventId: eventId,
        sessionId: sessionId,
        questions: [for (final (i, q) in questions.indexed) UserQuestion(id: 'q$i', question: q)],
      ),
    );

TurnOutcome outcome(int seq, String kind, {String? reply, String? title, LlmFailure? error, String? cause}) =>
    TurnOutcome(
      seq: seq,
      reason: TurnEndReason(kind, error: error, cancelCause: cause),
      reply: reply,
      title: title,
    );

/// A connected host whose `$events` the test drives by hand.
class FakeAlertSource implements AlertSource {
  final _events = StreamController<HostEvent>.broadcast(sync: true);
  List<HostEvent> pending = [];
  bool isConnected = true;
  List<SessionSummary> sessions = [];

  /// Next answer of [lastTurn] per session (null: unreadable).
  final Map<String, TurnOutcome?> outcomes = {};
  final Map<String, ToolCallPart> approvalCalls = {};
  int listCalls = 0;
  final List<String> lastTurnCalls = [];

  void emit(HostEvent event) => _events.add(event);

  @override
  Stream<HostEvent> get events => _events.stream;

  @override
  List<HostEvent> get pendingRequests => pending;

  @override
  bool get connected => isConnected;

  @override
  Future<List<SessionSummary>> listSessions() async {
    listCalls++;
    return sessions;
  }

  @override
  Future<ToolCallPart?> approvalCall(ApprovalRequest request) async => approvalCalls[request.callId];

  @override
  Future<TurnOutcome?> lastTurn(String sessionId) async {
    lastTurnCalls.add(sessionId);
    return outcomes[sessionId];
  }
}

/// Records what would reach the native side.
class FakeNotifyChannel extends NotifyChannel {
  FakeNotifyChannel({this.system = const NotifySystemStatus()});

  NotifySystemStatus system;
  final List<NotifyPost> shown = [];
  final List<(String, String)> cancelled = [];
  final List<String> cancelledGroups = [];
  int cancelledAll = 0;
  final List<String?> openedSettings = [];
  final actionController = StreamController<NotifyAction>.broadcast(sync: true);
  final actionResults = <(NotifyAction, NotifyActionResult)>[];
  final tapController = StreamController<NotifyTap>.broadcast(sync: true);

  @override
  Future<NotifySystemStatus> status() async => system;

  @override
  Future<void> show(NotifyPost post) async => shown.add(post);

  @override
  Future<bool> tryShow(NotifyPost post, {bool Function()? stillCurrent}) async {
    if (stillCurrent?.call() == false) return false;
    if (!system.native || !system.enabled || !(post.attention ? system.attention : system.done)) return false;
    await show(post);
    return true;
  }

  @override
  Future<void> cancel(String group, String key) async => cancelled.add((group, key));

  @override
  Future<void> cancelGroup(String group) async => cancelledGroups.add(group);

  @override
  Future<void> cancelAll() async => cancelledAll++;

  @override
  Future<bool> openSettings({String? channel}) async {
    openedSettings.add(channel);
    return true;
  }

  @override
  Stream<NotifyTap> get taps => tapController.stream;

  @override
  Stream<NotifyAction> get actions => actionController.stream;

  @override
  Future<void> completeAction(NotifyAction action, NotifyActionResult result) async =>
      actionResults.add((action, result));
}

/// A canonical 16 kHz mono PCM16 WAV of [seconds] of silence.
Uint8List silentWav(double seconds) {
  final samples = (seconds * 16000).round();
  final data = samples * 2;
  final bytes = ByteData(44 + data);
  void ascii(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  bytes.setUint32(4, 36 + data, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 1, Endian.little);
  bytes.setUint32(24, 16000, Endian.little);
  bytes.setUint32(28, 32000, Endian.little);
  bytes.setUint16(32, 2, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bytes.setUint32(40, data, Endian.little);
  return bytes.buffer.asUint8List();
}

/// `speech/catalog` with SenseVoice ready, as the voice-input bundle serves it.
Map<String, Object?> readySpeechCatalog({String phase = 'standby'}) => {
  'providers': [
    {
      'id': 'sensevoice-local',
      'name': 'SenseVoice',
      'location': 'host-local',
      'languages': ['auto', 'zh', 'en'],
      'preparation': {'phase': phase},
    },
  ],
  'selection': {'providerId': 'sensevoice-local', 'language': 'auto'},
  'maxAudioBytes': 4 * 1024 * 1024,
  'maxDurationSeconds': 120,
};
