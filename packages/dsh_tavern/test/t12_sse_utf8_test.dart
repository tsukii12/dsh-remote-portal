import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _text = '海🌊';
const _question = 'UTF8 QUESTION';
final _at = DateTime.utc(2026, 11, 10, 23);
final _content = jsonEncode(_chunk(content: _text));
final _finish = jsonEncode(_chunk(reason: 'stop', usage: true));
final _normal = <int>[..._frame(_content), ..._frame(_finish), ..._frame('[DONE]')];
final _commentFf = <int>[0xef, 0xbb, 0xbf, ...utf8.encode(': keepalive '), 0xff, 10, 10, ..._normal];
final _quotedFf = <int>[
  ..._replaceMarker(_frame(jsonEncode(_chunk(content: '${_text}A~B')))),
  ..._frame(_finish),
  ..._frame('[DONE]'),
];
final _invalidJson = <int>[...utf8.encode('data: '), 0xff, 10, 10, ..._normal];

// Raw bytes reach the production decoder and real loopback HTTP transport.
// Encoding the character U+00FF would not produce the malformed byte 0xFF.
void main() {
  test('parser replacement preserves SSE framing across malformed and valid UTF-8 chunks', () async {
    final normalEvents = [_content, _finish, '[DONE]'];
    final cases = <(String, List<int>, List<String>)>[
      ('valid BOM and comment', [0xef, 0xbb, 0xbf, ...utf8.encode(': ok\n\n'), ..._normal], normalEvents),
      ('FF in initial comment', _commentFf, normalEvents),
      (
        'FF after content',
        [..._frame(_content), 58, 32, 0xff, 10, 10, ..._frame(_finish), ..._frame('[DONE]')],
        normalEvents,
      ),
      ('unfinished prefix before LF', [58, 32, 0xe2, 10, 10, ..._normal], normalEvents),
      ('FF inside JSON string', _quotedFf, [jsonEncode(_chunk(content: '${_text}A�B')), _finish, '[DONE]']),
      ('FF is still invalid JSON data', _invalidJson, ['�', ...normalEvents]),
      (
        'damaged field stays unknown',
        [...utf8.encode('da'), 0xff, ...utf8.encode('ta: discard\n\n'), ..._normal],
        normalEvents,
      ),
      (
        'unfinished malformed finish stays pending',
        [
          ..._frame(_content),
          ..._replaceMarker(utf8.encode('data: ${jsonEncode(_chunk(content: '~', reason: 'stop'))}\n')),
        ],
        [_content],
      ),
      (
        'unfinished UTF-8 in trailing comment',
        [..._frame(_content), ..._frame(_finish), 58, 32, 0xf0, 0x9f],
        [_content, _finish],
      ),
    ];
    for (final sample in cases) {
      for (final mode in ['whole', 'every_byte', 'split_valid_multibyte']) {
        final chunks = _chunks(sample.$2, mode).toList();
        expect(chunks.expand((chunk) => chunk), orderedEquals(sample.$2));
        final actual = await decodeServerSentEvents(Stream<List<int>>.fromIterable(chunks)).toList();
        expect(actual, sample.$3, reason: '${sample.$1} / $mode');
      }
    }
  });

  test('facade ignores malformed UTF-8 in a completed SSE comment', () async {
    await _withFacade(_commentFf, (h) async {
      final events = await h.engine.send(h.chatId, _question).toList();
      await h.endpoint.verifyOneRequest();
      final completed = events.whereType<TavernTurnDone>().toList();
      final failed = events.whereType<TavernTurnFailed>().toList();

      // First defect-specific oracle. Old strict decoding reports the actual
      // invalid_response_format terminal before receiving the valid content.
      expect(
        <String, Object?>{
          'completed': completed.length == 1,
          'failureDetail': failed.isEmpty ? null : failed.first.detail,
          'requestCount': h.endpoint.requestCount,
        },
        {'completed': true, 'failureDetail': null, 'requestCount': 1},
      );
      await _expectStoredSuccess(h, events, _text);
    });
  });

  test('facade persists replacement characters from quoted SSE content', () async {
    await _withFacade(_quotedFf, (h) async {
      final events = await h.engine.send(h.chatId, _question).toList();
      await h.endpoint.verifyOneRequest();
      await _expectStoredSuccess(h, events, '${_text}A�B');
    });
  });

  test('replacement decoding does not accept malformed JSON or retry an accepted response', () async {
    await _withEndpoint(_invalidJson, (endpoint) async {
      final seen = <ModelDelta>[];
      TavernModelException? failure;
      try {
        await endpoint.generate().forEach(seen.add);
      } on TavernModelException catch (error) {
        failure = error;
      }
      await endpoint.verifyOneRequest();
      expect(
        failure,
        isA<TavernModelException>()
            .having((error) => error.kind, 'kind', TavernFailure.server)
            .having((error) => error.detail, 'detail', 'invalid_response_format'),
      );
      expect(seen.whereType<ModelText>(), isEmpty);
      expect(seen.whereType<ModelFinished>(), isEmpty);
      expect(seen.whereType<ModelUsage>(), isEmpty);
    });
  });
}

Future<void> _expectStoredSuccess(_Facade h, List<TavernEvent> events, String text) async {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  expect(events.whereType<TavernTurnStarted>(), hasLength(1));
  expect(events.whereType<TavernTextDelta>().map((delta) => delta.text).join(), text);
  final done = events.whereType<TavernTurnDone>().single;
  expect(events.last, same(done));
  expect(done.finishReason, 'stop');
  expect(done.message.text, text);
  expect(done.message.usage?.promptTokens, 7);
  expect(done.message.usage?.completionTokens, 3);
  expect(done.message.nodeId, events.whereType<TavernTurnStarted>().single.message.nodeId);
  final path = await h.engine.path(h.chatId);
  expect(path.map((message) => message.text), ['G', _question, text]);
  expect(path.last.nodeId, done.message.nodeId);
  final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!;
  expect(inspection.status, TavernInspectionStatus.completed);
  expect(inspection.failure, isNull);
  expect(inspection.reportedUsage?.promptTokens, 7);

  await h.reopen();
  final reopened = await h.engine.path(h.chatId);
  expect(reopened.map((message) => message.nodeId), path.map((message) => message.nodeId));
  expect(reopened.map((message) => message.text), ['G', _question, text]);
  expect(reopened.last.usage?.promptTokens, 7);
  expect(reopened.last.usage?.completionTokens, 3);
  final persisted = (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!;
  expect(persisted.status, TavernInspectionStatus.completed);
  expect(persisted.failure, isNull);
  expect(persisted.reportedUsage?.promptTokens, 7);
  expect(h.endpoint.requestCount, 1);
}

Map<String, Object?> _chunk({String? content, String? reason, bool usage = false}) => {
  'id': 'utf8-fixture',
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
  if (usage) 'usage': {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10},
};

List<int> _frame(String payload) => utf8.encode('data: $payload\n\n');

List<int> _replaceMarker(List<int> input) {
  final bytes = List<int>.of(input);
  final marker = bytes.indexOf(126);
  if (marker < 0 || bytes.lastIndexOf(126) != marker) throw StateError('Expected one fixture marker.');
  bytes[marker] = 0xff;
  return bytes;
}

Iterable<List<int>> _chunks(List<int> bytes, String mode) sync* {
  if (mode == 'whole') {
    yield bytes;
  } else if (mode == 'every_byte') {
    for (final byte in bytes) {
      yield [byte];
    }
  } else {
    final marker = utf8.encode(_text);
    var found = -1;
    for (var index = 0; index <= bytes.length - marker.length; index++) {
      var matches = true;
      for (var offset = 0; offset < marker.length; offset++) {
        if (bytes[index + offset] != marker[offset]) {
          matches = false;
          break;
        }
      }
      if (matches) {
        found = index;
        break;
      }
    }
    if (found < 0) throw StateError('Expected the valid multibyte fixture text.');
    // Split inside both the three-byte CJK character and the four-byte emoji.
    final cuts = [0, found + 1, found + 2, found + 4, found + 5, found + 6, bytes.length];
    for (var index = 1; index < cuts.length; index++) {
      yield bytes.sublist(cuts[index - 1], cuts[index]);
    }
  }
}

Future<void> _withEndpoint(List<int> bytes, Future<void> Function(_Endpoint) body) async {
  final endpoint = await _Endpoint.open(bytes);
  try {
    await body(endpoint);
  } finally {
    await endpoint.close();
  }
  expect(endpoint.errors, isEmpty);
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

  Stream<ModelDelta> generate() => model.generate(
    config: config,
    body: {
      'stream': true,
      'messages': [
        {'role': 'user', 'content': _question},
      ],
    },
    cancellation: ModelCancellation(),
  );

  Future<void> _handle(HttpRequest request) async {
    try {
      methods.add(request.method);
      paths.add(request.uri.path);
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>);
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      // Send the exact original bytes, including FF, with their real length.
      // There is no String conversion, socket reset or deliberately short body.
      request.response.contentLength = bytes.length;
      request.response.persistentConnection = false;
      request.response.add(bytes);
      try {
        await request.response.close();
      } on SocketException {
        // DONE or the JSON error can close the client before this completes.
        // Exact client outcome and body checks remain mandatory.
      } on HttpException {
        // Only this final close may race the client's response termination.
      }
    } catch (error) {
      errors.add(error);
      try {
        await request.response.close();
      } catch (_) {
        /* Preserve the original handler error. */
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
  await _withEndpoint(bytes, (endpoint) async {
    final directory = await Directory.systemTemp.createTemp('dsh-t12-sse-utf8-');
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
      await (facade?.engine ?? engine)?.close();
      await directory.delete(recursive: true);
    }
  });
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
