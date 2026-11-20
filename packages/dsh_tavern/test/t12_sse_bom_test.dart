import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _bom = <int>[0xef, 0xbb, 0xbf];
const _text = '海🌊';
const _question = 'BOM QUESTION';
final _at = DateTime.utc(2026, 11, 11);
final _first = jsonEncode(_chunk(content: 'FIRST'));
final _content = jsonEncode(_chunk(content: _text));
final _quotedContent = jsonEncode(_chunk(content: '\uFEFF$_text'));
final _finish = jsonEncode(_chunk(reason: 'stop', usage: true));
final _tail = <int>[..._frame(_content), ..._frame(_finish), ..._frame('[DONE]')];
final _double = <int>[..._bom, ..._bom, ..._frame(_first), ..._tail];
final _quoted = <int>[..._bom, ..._frame(_quotedContent), ..._frame(_finish), ..._frame('[DONE]')];

// A UTF-8 decoder consumes exactly one initial BOM. Further BOMs belong to
// the field or quoted value. These expectations follow the fixed ST parser
// and the SSE/Encoding contracts; no ModelDelta producer is substituted.
void main() {
  test('parser consumes one initial BOM and preserves later BOM field and content boundaries', () async {
    final normalEvents = [_content, _finish, '[DONE]'];
    final cases = <(String, List<int>, List<String>)>[
      ('zero leading BOM', [..._frame(_first), ..._tail], [_first, ...normalEvents]),
      ('one leading BOM', [..._bom, ..._frame(_first), ..._tail], [_first, ...normalEvents]),
      ('two leading BOMs', _double, normalEvents),
      ('three leading BOMs', [..._bom, ..._double], normalEvents),
      ('late field BOM', [...utf8.encode(': keepalive\n\n'), ..._bom, ..._frame(_first), ..._tail], normalEvents),
      ('quoted content BOM', _quoted, [_quotedContent, _finish, '[DONE]']),
      ('double BOM before only finish', [..._bom, ..._bom, ..._frame(_finish)], []),
    ];
    expect(_quotedContent, contains('\uFEFF'), reason: 'The quoted fixture includes actual UTF-8 BOM bytes.');
    for (final sample in cases) {
      for (final mode in ['whole', 'every_byte', 'prefix_and_multibyte']) {
        final chunks = _chunks(sample.$2, mode).toList();
        expect(chunks.expand((chunk) => chunk), orderedEquals(sample.$2));
        final actual = await decodeServerSentEvents(Stream<List<int>>.fromIterable(chunks)).toList();
        expect(actual, sample.$3, reason: '${sample.$1} / $mode');
      }
    }
  });

  test('facade double initial BOM ignores FIRST and persists the later completed content', () async {
    await _withFacade(_double, (h) async {
      final events = await h.engine.send(h.chatId, _question).toList();
      await h.endpoint.verifyOneRequest();
      final done = _expectCompleted(events);

      // First defect-specific oracle, after common successful completion.
      // The parent produces FIRST海🌊 with the same one POST and stop Done.
      // A missing terminal, HTTP error or timeout does not reproduce this.
      expect(events.whereType<TavernTextDelta>().map((delta) => delta.text).join(), _text);
      await _expectStoredSuccess(h, done, _text);
    });
  });

  test('facade single initial BOM preserves a quoted BOM through close and reopen', () async {
    expect(_quotedContent, contains('\uFEFF'));
    await _withFacade(_quoted, (h) async {
      final events = await h.engine.send(h.chatId, _question).toList();
      await h.endpoint.verifyOneRequest();
      final done = _expectCompleted(events);
      expect(events.whereType<TavernTextDelta>().map((delta) => delta.text).join(), '\uFEFF$_text');
      await _expectStoredSuccess(h, done, '\uFEFF$_text');
    });
  });
}

TavernTurnDone _expectCompleted(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  expect(events.whereType<TavernTurnStarted>(), hasLength(1));
  expect(events.whereType<TavernTurnDone>(), hasLength(1));
  final done = events.whereType<TavernTurnDone>().single;
  expect(events.last, same(done));
  expect(done.finishReason, 'stop');
  expect(done.message.usage?.promptTokens, 7);
  expect(done.message.usage?.cacheHitTokens, 2);
  expect(done.message.usage?.completionTokens, 3);
  expect(done.message.nodeId, events.whereType<TavernTurnStarted>().single.message.nodeId);
  return done;
}

Future<void> _expectStoredSuccess(_Facade h, TavernTurnDone done, String text) async {
  expect(done.message.text, text);
  final path = await h.engine.path(h.chatId);
  expect(path.map((message) => message.text), ['G', _question, text]);
  expect(path.last.nodeId, done.message.nodeId);
  final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!;
  expect(inspection.nodeId, done.message.nodeId);
  expect(inspection.status, TavernInspectionStatus.completed);
  expect(inspection.failure, isNull);
  expect(inspection.detail, isNull);
  expect(inspection.reportedUsage?.promptTokens, 7);
  expect(inspection.reportedUsage?.cacheHitTokens, 2);
  expect(inspection.reportedUsage?.completionTokens, 3);

  await h.reopen();
  final reopened = await h.engine.path(h.chatId);
  expect(reopened.map((message) => message.nodeId), path.map((message) => message.nodeId));
  expect(reopened.map((message) => message.text), ['G', _question, text]);
  expect(reopened.last.usage?.promptTokens, 7);
  expect(reopened.last.usage?.cacheHitTokens, 2);
  expect(reopened.last.usage?.completionTokens, 3);
  final persisted = (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!;
  expect(persisted.toJson(), inspection.toJson());
  expect(h.endpoint.requestCount, 1);
}

Map<String, Object?> _chunk({String? content, String? reason, bool usage = false}) => {
  'id': 'bom-fixture',
  'object': 'chat.completion.chunk',
  'created': 1,
  'model': 'fixture',
  'choices': [
    {
      'index': 0,
      'delta': {'content': content ?? ''},
      'finish_reason': reason,
    },
  ],
  if (usage)
    'usage': {
      'prompt_tokens': 7,
      'completion_tokens': 3,
      'total_tokens': 10,
      'prompt_tokens_details': {'cached_tokens': 2},
    },
};

List<int> _frame(String payload) => utf8.encode('data: $payload\n\n');

Iterable<List<int>> _chunks(List<int> bytes, String mode) sync* {
  if (mode == 'whole') {
    yield bytes;
    return;
  }
  if (mode == 'every_byte') {
    for (final byte in bytes) {
      yield [byte];
    }
    return;
  }
  // All three possible leading BOMs are split. The CJK/emoji cuts are used
  // when present; the finish-only case intentionally has no content marker.
  final cuts = <int>{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, bytes.length};
  final marker = utf8.encode(_text);
  for (var index = 0; index <= bytes.length - marker.length; index++) {
    var matches = true;
    for (var offset = 0; offset < marker.length; offset++) {
      if (bytes[index + offset] != marker[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) {
      cuts.addAll([index + 1, index + 2, index + 4, index + 5, index + 6]);
      break;
    }
  }
  final ordered = cuts.where((cut) => cut >= 0 && cut <= bytes.length).toList()..sort();
  for (var index = 1; index < ordered.length; index++) {
    yield bytes.sublist(ordered[index - 1], ordered[index]);
  }
}

class _Endpoint {
  _Endpoint(this.server, List<int> bytes) : bytes = List<int>.unmodifiable(bytes) {
    subscription = server.listen(
      (request) {
        requestCount++;
        pending.add(_handle(request));
      },
      onError: (Object error) {
        errors.add(error);
      },
    );
  }

  static Future<_Endpoint> open(List<int> bytes) async =>
      _Endpoint(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), bytes);

  final HttpServer server;
  final List<int> bytes;
  late final StreamSubscription<HttpRequest> subscription;
  final model = TavernModelClient(idleTimeout: const Duration(seconds: 10));
  final pending = <Future<void>>[];
  final errors = <Object>[];
  final methods = <String>[];
  final paths = <String>[];
  final requests = <Map<String, Object?>>[];
  var requestCount = 0;

  TavernModelConfig get config => TavernModelConfig(
    apiKey: () async => 'loopback-fixture',
    model: 'fixture',
    deepseek: false,
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
  );

  Future<void> _handle(HttpRequest request) async {
    try {
      methods.add(request.method);
      paths.add(request.uri.path);
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>);
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      // These are exact original bytes and their real HTTP content length.
      // Do not decode/re-encode them, reset the socket or assume chunk cuts.
      request.response.contentLength = bytes.length;
      request.response.persistentConnection = false;
      request.response.add(bytes);
      try {
        await request.response.close();
      } on SocketException {
        // The client can stop at DONE before this final close completes.
        // Exact successful terminal and body checks remain mandatory.
      } on HttpException {
        // Only final response close is allowed to race client completion.
      }
    } catch (error) {
      errors.add(error);
      try {
        await request.response.close();
      } catch (_) {
        /* Keep the handler error. */
      }
    }
  }

  Future<void> verifyOneRequest() async {
    await Future.wait(pending);
    expect(errors, isEmpty);
    expect(requestCount, 1);
    expect(methods, ['POST']);
    expect(paths, ['/v1/chat/completions']);
    expect(requests, hasLength(1));
    expect(requests.single['stream'], isTrue);
  }

  Future<void> close() async {
    await server.close(force: true);
    await subscription.cancel();
    await Future.wait(pending);
  }
}

Future<void> _withFacade(List<int> bytes, Future<void> Function(_Facade) body) async {
  final endpoint = await _Endpoint.open(bytes);
  try {
    final directory = await Directory.systemTemp.createTemp('dsh-t12-sse-bom-');
    TavernEngine? engine;
    _Facade? facade;
    try {
      engine = await _openEngine(directory, endpoint);
      await engine.setPreset(t24Preset());
      final character = await engine.importCard(t24Card());
      final chatId = await engine.createChat(character.id);
      facade = _Facade(directory, endpoint, engine, chatId);
      await body(facade);
    } finally {
      try {
        await (facade?.engine ?? engine)?.close();
      } finally {
        await directory.delete(recursive: true);
      }
    }
  } finally {
    await endpoint.close();
  }
  expect(endpoint.errors, isEmpty);
}

Future<TavernEngine> _openEngine(Directory directory, _Endpoint endpoint) => TavernEngine.openDirectory(
  directory,
  config: endpoint.config,
  modelClient: endpoint.model,
  clock: () => _at,
  random: () => 0.25,
);

class _Facade {
  _Facade(this.directory, this.endpoint, this.engine, this.chatId);
  final Directory directory;
  final _Endpoint endpoint;
  TavernEngine engine;
  final String chatId;

  Future<void> reopen() async {
    await engine.close();
    engine = await _openEngine(directory, endpoint);
  }
}
