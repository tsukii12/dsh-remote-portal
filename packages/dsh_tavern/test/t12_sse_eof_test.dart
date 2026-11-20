import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _partial = '前半句🐋';
const _question = 'QUESTION';
final _at = DateTime.utc(2026, 11, 10, 22);
final _prefix = 'data: ${jsonEncode(_chunk(content: _partial))}\n\n';
final _openFinish = '${_prefix}data: ${jsonEncode(_chunk(finishReason: 'stop', usage: true))}\n';
final _closedFinish = '$_openFinish\n';
final _openDone = '${_prefix}data: [DONE]\n';
final _closedDone = '$_openDone\n';

// Production HTTP/SSE, engine, files and SQLite. No synthetic ModelDelta
// producer, private hooks, external provider or account is involved.
void main() {
  for (final line in <(String, String)>[('LF', '\n'), ('CRLF', '\r\n'), ('CR', '\r')]) {
    for (final bytewise in [false, true]) {
      test('parser EOF ${line.$1} ${bytewise ? 'bytewise' : 'whole'} requires an event blank line', () async {
        final end = line.$2;
        final prefix =
            '\uFEFF: keepalive$end'
            'data: {"text":$end'
            'data: "前半句🐋"}$end$end';
        const first = '{"text":\n"前半句🐋"}';
        for (final payload in ['{"finish_reason":"stop"}', '[DONE]']) {
          final pending = 'data: $payload';
          // A complete JSON value (or DONE marker) is still an incomplete
          // SSE event, both without a line ending and with only one.
          for (final suffix in ['', end]) {
            expect(await _decode('$prefix$pending$suffix', bytewise: bytewise), [first]);
          }
          expect(await _decode('$prefix$pending$end$end', bytewise: bytewise), [first, payload]);
        }
      });
    }
  }

  for (final sample in <(String, String)>[('finish frame', _openFinish), ('DONE marker', _openDone)]) {
    test('loopback normal HTTP EOF rejects an unfinished ${sample.$1} without retry', () async {
      await _withEndpoint(sample.$2, (endpoint) async {
        final seen = <ModelDelta>[];
        TavernModelException? failure;
        try {
          await endpoint.generate().forEach(seen.add);
        } on TavernModelException catch (error) {
          failure = error;
        }
        await endpoint.verifyOneRequest();
        expect(seen.whereType<ModelText>().single.text, _partial);
        expect(seen.whereType<ModelFinished>(), isEmpty);
        expect(
          failure,
          isA<TavernModelException>()
              .having((error) => error.kind, 'kind', TavernFailure.network)
              .having((error) => error.detail, 'detail', 'stream_ended_before_finish'),
        );
        expect(seen.whereType<ModelUsage>(), isEmpty);
      });
    });
  }

  test('loopback one extra LF completes the finish frame without requiring DONE', () async {
    expect(_closedFinish, '$_openFinish\n');
    await _withEndpoint(_closedFinish, (endpoint) async {
      final seen = await endpoint.generate().toList();
      await endpoint.verifyOneRequest();
      expect(seen.whereType<ModelText>().single.text, _partial);
      expect(seen.whereType<ModelFinished>().single.reason, 'stop');
      expect(seen.whereType<ModelUsage>().single.usage.promptTokens, 7);
      expect(seen.last, isA<ModelFinished>());
    });
  });

  test('loopback a complete DONE event still succeeds with a null finish reason', () async {
    expect(_closedDone, '$_openDone\n');
    await _withEndpoint(_closedDone, (endpoint) async {
      final seen = await endpoint.generate().toList();
      await endpoint.verifyOneRequest();
      expect(seen.whereType<ModelText>().single.text, _partial);
      expect(seen.whereType<ModelFinished>().single.reason, isNull);
      expect(seen.whereType<ModelUsage>(), isEmpty);
      expect(seen.last, isA<ModelFinished>());
    });
  });

  test('facade normal HTTP EOF rejects an unfinished finish frame and retains partial', () async {
    await _withFacade(_openFinish, (h) async {
      final events = await h.engine.send(h.chatId, _question).toList();
      await h.endpoint.verifyOneRequest();
      expect(events.whereType<TavernTurnStarted>(), hasLength(1));
      expect(events.whereType<TavernTextDelta>().single.text, _partial);

      // This is the old-product semantic oracle: the original parser emits
      // a real successful Done here. A timeout or a fixture error is not it.
      expect(
        events.whereType<TavernTurnDone>(),
        isEmpty,
        reason: 'An unfinished SSE finish frame must not authorize a successful terminal.',
      );
      final failed = events.whereType<TavernTurnFailed>().single;
      expect(events.last, same(failed));
      expect(failed.kind, TavernFailure.network);
      expect(failed.detail, 'stream_ended_before_finish');
      final partial = failed.partial!;
      expect(partial.text, _partial);
      expect(partial.usage, isNull, reason: 'Usage in the discarded final frame is not accepted.');
      expect(partial.nodeId, events.whereType<TavernTurnStarted>().single.message.nodeId);
      final path = await h.engine.path(h.chatId);
      expect(path.map((message) => message.text), ['G', _question, _partial]);
      expect(path.last.nodeId, partial.nodeId);
      final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: partial.nodeId))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(inspection.failure, TavernFailure.network);
      expect(inspection.detail, 'stream_ended_before_finish');
      expect(inspection.reportedUsage, isNull);

      await h.reopen();
      final reopened = await h.engine.path(h.chatId);
      expect(reopened.map((message) => message.nodeId), path.map((message) => message.nodeId));
      expect(reopened.map((message) => message.text), ['G', _question, _partial]);
      expect(reopened.last.usage, isNull);
      final persisted = (await h.engine.inspectTurn(h.chatId, nodeId: partial.nodeId))!;
      expect(persisted.status, TavernInspectionStatus.failed);
      expect(persisted.failure, TavernFailure.network);
      expect(persisted.detail, 'stream_ended_before_finish');
      expect(persisted.reportedUsage, isNull);
      expect(h.endpoint.requestCount, 1);
    });
  });

  for (final sample in <(String, String, String?, bool)>[
    ('one extra LF and no DONE', _closedFinish, 'stop', true),
    ('complete DONE with no finish reason', _closedDone, null, false),
  ]) {
    test('facade ${sample.$1} keeps the successful terminal contract', () async {
      await _withFacade(sample.$2, (h) async {
        final events = await h.engine.send(h.chatId, _question).toList();
        await h.endpoint.verifyOneRequest();
        expect(events.whereType<TavernTurnFailed>(), isEmpty);
        expect(events.whereType<TavernTextDelta>().single.text, _partial);
        final done = events.whereType<TavernTurnDone>().single;
        expect(events.last, same(done));
        expect(done.finishReason, sample.$3);
        expect(done.message.text, _partial);
        expect(done.message.usage?.promptTokens, sample.$4 ? 7 : null);
        expect(
          (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!.status,
          TavernInspectionStatus.completed,
        );
        await h.reopen();
        final path = await h.engine.path(h.chatId);
        expect(path.map((message) => message.text), ['G', _question, _partial]);
        expect(path.last.nodeId, done.message.nodeId);
        expect(path.last.usage?.promptTokens, sample.$4 ? 7 : null);
        expect(
          (await h.engine.inspectTurn(h.chatId, nodeId: done.message.nodeId))!.status,
          TavernInspectionStatus.completed,
        );
        expect(h.endpoint.requestCount, 1);
      });
    });
  }
}

Map<String, Object?> _chunk({String? content, String? finishReason, bool usage = false}) => {
  'id': 'eof-fixture',
  'object': 'chat.completion.chunk',
  'created': 1,
  'model': 'fixture',
  'system_fingerprint': 'fixture',
  'choices': [
    {
      'index': 0,
      'delta': {'content': content ?? ''},
      'logprobs': null,
      'finish_reason': finishReason,
    },
  ],
  'usage': usage
      ? {
          'prompt_tokens': 7,
          'completion_tokens': 3,
          'total_tokens': 10,
          'prompt_tokens_details': {'cached_tokens': 0},
          'prompt_cache_hit_tokens': 0,
          'prompt_cache_miss_tokens': 7,
        }
      : null,
};

Future<List<String>> _decode(String text, {required bool bytewise}) {
  final bytes = utf8.encode(text);
  final source = bytewise
      ? Stream<List<int>>.fromIterable(bytes.map((byte) => <int>[byte]))
      : Stream<List<int>>.value(bytes);
  return decodeServerSentEvents(source).toList();
}

Future<void> _withEndpoint(String wire, Future<void> Function(_Endpoint) body) async {
  final endpoint = await _Endpoint.open(wire);
  try {
    await body(endpoint);
  } finally {
    await endpoint.close();
  }
  expect(endpoint.errors, isEmpty);
}

class _Endpoint {
  _Endpoint(this.server, this.wire) {
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

  static Future<_Endpoint> open(String wire) async =>
      _Endpoint(await HttpServer.bind(InternetAddress.loopbackIPv4, 0), wire);

  final HttpServer server;
  final String wire;
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
      final bytes = utf8.encode(wire);
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      // The HTTP message is complete even when its final SSE event is not.
      // A deliberately short Content-Length body would test a different
      // transport exception and would not prove the pending-frame bug.
      request.response.contentLength = bytes.length;
      request.response.persistentConnection = false;
      request.response.add(bytes);
      try {
        await request.response.close();
      } on SocketException {
        // All bytes were supplied. A client can close its peer on DONE.
        // The exact client outcome and body assertions remain mandatory.
      } on HttpException {
        // Only this final close may race the client's completed response.
      }
    } catch (error) {
      errors.add(error);
      try {
        await request.response.close();
      } catch (_) {
        // Preserve the original handler failure for verifyOneRequest.
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

Future<void> _withFacade(String wire, Future<void> Function(_Facade) body) async {
  await _withEndpoint(wire, (endpoint) async {
    final directory = await Directory.systemTemp.createTemp('dsh-t12-sse-eof-');
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
