import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _plainError = '{"error":{"code":"context_length_exceeded"}}';
const _escapedError = r'{"error":{"code":"context_length_exceede\u0064"}}';
const _key = 'http-json-fixture-key';
final _url = Uri.parse('https://http-json.invalid/v1/chat/completions');

// The HTTP peer is synthetic; request encoding, error-body reading, failure
// mapping, Tavern.send, files and SQLite are production paths.
void main() {
  test('HTTP errors decode context strings while preserving raw and status precedence', () async {
    for (final row in <(int, String, TavernFailure)>[
      (400, _plainError, TavernFailure.contextTooLong),
      (400, _escapedError, TavernFailure.contextTooLong),
      (400, r'{"error":{"message":"maximum\u0020context length"}}', TavernFailure.contextTooLong),
      (400, r'{"error":{"message":"CONTEXT\u0020WINDOW"}}', TavernFailure.contextTooLong),
      (400, r'{"error":{"message":"context\u0020too long"}}', TavernFailure.contextTooLong),
      (400, r'{"error":{"code":"context_length_exceede\u0064"},"unrelated":1e400}', TavernFailure.contextTooLong),
      (400, 'context_length_exceeded', TavernFailure.contextTooLong),
      (400, '{"error":"context_length_exceeded"}', TavernFailure.contextTooLong),
      (400, '{"error":', TavernFailure.invalidParameters),
      (400, r'{"error":{"code":"context_length_exceede\u0064"},"other":TRUE}', TavernFailure.invalidParameters),
      (422, 'invalid parameters', TavernFailure.invalidParameters),
      (400, r'{"error":{"code":7,"message":["context_length_exceede\u0064"]}}', TavernFailure.invalidParameters),
      (400, r'{"provider_code":"context_length_exceede\u0064"}', TavernFailure.invalidParameters),
      (401, _escapedError, TavernFailure.badKey),
      (403, _escapedError, TavernFailure.badKey),
      (402, _escapedError, TavernFailure.insufficientBalance),
      (429, _escapedError, TavernFailure.busy),
      (503, _escapedError, TavernFailure.server),
    ]) {
      final peers = <_ErrorPeer>[];
      var keyReads = 0;
      final config = TavernModelConfig(
        apiKey: () async {
          keyReads++;
          return _key;
        },
        baseUrl: 'https://http-json.invalid/v1',
        model: 'fixture',
        deepseek: false,
      );
      final model = TavernModelClient(
        clientFactory: () {
          final peer = _ErrorPeer(row.$1, row.$2);
          peers.add(peer);
          return peer;
        },
      );
      final seen = <ModelDelta>[];
      TavernModelException? failure;
      try {
        await model
            .generate(config: config, body: {'stream': false}, cancellation: ModelCancellation())
            .forEach(seen.add);
      } on TavernModelException catch (error) {
        failure = error;
      }
      expect(
        failure,
        isA<TavernModelException>()
            .having((error) => error.kind, 'kind', row.$3)
            .having((error) => error.detail, 'raw detail', 'HTTP ${row.$1}: ${row.$2}'),
        reason: row.$2,
      );
      expect(seen, isEmpty);
      expect(keyReads, 1);
      expect(peers, hasLength(row.$1 == 503 ? 3 : 1));
      for (final peer in peers) {
        expect(peer.closed, isTrue);
        expect(peer.requests, hasLength(1));
        expect(peer.requests.single.method, 'POST');
        expect(peer.requests.single.url, _url);
        expect(peer.requests.single.body, {'stream': false, 'model': 'fixture'});
      }
    }
  });

  test('public send preserves an escaped JSON context error through reopen', () async {
    final root = await Directory.systemTemp.createTemp('dsh-t12-http-error-json-');
    TavernEngine? ownedEngine;
    final peers = <_ErrorPeer>[];
    addTearDown(() async {
      try {
        await ownedEngine?.close();
      } finally {
        if (await root.exists()) await root.delete(recursive: true);
      }
      expect(await root.exists(), isFalse);
      expect(peers.every((peer) => peer.closed), isTrue);
      stdout.writeln('HTTP_JSON_CONTEXT_CLEANUP');
    });
    final pending = [_plainError, _escapedError];
    var keyReads = 0;
    final config = TavernModelConfig(
      apiKey: () async {
        keyReads++;
        return _key;
      },
      baseUrl: 'https://http-json.invalid/v1',
      model: 'fixture',
      deepseek: false,
    );
    final model = TavernModelClient(
      clientFactory: () {
        if (pending.isEmpty) throw StateError('Unexpected additional HTTP request.');
        final peer = _ErrorPeer(400, pending.removeAt(0));
        peers.add(peer);
        return peer;
      },
    );
    Future<TavernEngine> open() => TavernEngine.openDirectory(root, config: config, modelClient: model);
    var engine = await open();
    ownedEngine = engine;
    Tavern facade = engine;
    final preset = t24Preset().raw..['stream_openai'] = false;
    await engine.setPreset(ChatPreset(preset));
    final character = await facade.importCard(t24Card());
    final chatId = await facade.createChat(character.id);
    final greeting = (await facade.path(chatId)).single;
    expect(greeting.text, 'G');

    Future<void> checkSaved(String wire) async {
      expect((await facade.path(chatId)).map((message) => (message.nodeId, message.text)), [(greeting.nodeId, 'G')]);
      final inspection = (await facade.inspectTurn(chatId))!;
      expect(inspection.status, TavernInspectionStatus.failed);
      expect(inspection.failure, TavernFailure.contextTooLong);
      expect(inspection.detail, 'HTTP 400: $wire');
      expect(inspection.contextNodeId, greeting.nodeId);
      expect(inspection.nodeId, isNull);
      expect(inspection.reportedUsage, isNull);
    }

    final ordinary = await facade.send(chatId, 'ordinary context control').toList();
    expect(ordinary.whereType<TavernTurnFailed>().map((event) => event.kind).toList(), [TavernFailure.contextTooLong]);
    expect(ordinary.whereType<TavernTurnDone>(), isEmpty);
    expect(ordinary.whereType<TavernTurnFailed>().single.partial, isNull);
    expect(ordinary.whereType<TavernTurnStarted>(), hasLength(1));
    expect(peers, hasLength(1));
    expect(peers.single.closed, isTrue);
    expect(peers.single.requests, hasLength(1));
    expect(peers.single.requests.single.method, 'POST');
    expect(peers.single.requests.single.url, _url);
    expect(peers.single.requests.single.body['stream'], isFalse);
    expect(peers.single.requests.single.body['model'], 'fixture');
    final ordinaryMessages = peers.single.requests.single.body['messages']! as List<Object?>;
    expect((ordinaryMessages.last as Map<String, Object?>)['content'], 'ordinary context control');
    expect(keyReads, 1);
    await checkSaved(_plainError);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(_plainError);
    expect(peers, hasLength(1));
    expect(keyReads, 1);
    stdout.writeln('HTTP_JSON_CONTEXT_READY');

    final target = await facade.send(chatId, 'escaped context error').toList();
    // First target assertion is the full public failure-kind list. The old
    // raw substring classifier produces [TavernFailure.invalidParameters].
    expect(target.whereType<TavernTurnFailed>().map((event) => event.kind).toList(), [TavernFailure.contextTooLong]);
    expect(target.whereType<TavernTurnDone>(), isEmpty);
    expect(target.whereType<TavernTurnStarted>(), hasLength(1));
    final failed = target.whereType<TavernTurnFailed>().single;
    expect(target.last, same(failed));
    expect(failed.partial, isNull);
    expect(failed.detail, 'HTTP 400: $_escapedError');
    expect(peers, hasLength(2));
    expect(peers.last.requests, hasLength(1));
    expect(peers.last.requests.single.method, 'POST');
    expect(peers.last.requests.single.url, _url);
    expect(peers.last.requests.single.body['stream'], isFalse);
    expect(peers.last.requests.single.body['model'], 'fixture');
    final targetMessages = peers.last.requests.single.body['messages']! as List<Object?>;
    expect((targetMessages.last as Map<String, Object?>)['content'], 'escaped context error');
    expect(peers.every((peer) => peer.closed), isTrue);
    expect(pending, isEmpty);
    expect(keyReads, 2);
    await checkSaved(_escapedError);
    await facade.close();
    ownedEngine = null;
    engine = await open();
    ownedEngine = engine;
    facade = engine;
    await checkSaved(_escapedError);
    expect(peers, hasLength(2));
    expect(keyReads, 2);
  });
}

typedef _Request = ({String method, Uri url, Map<String, Object?> body});

class _ErrorPeer extends http.BaseClient {
  _ErrorPeer(this.status, this.wire);
  final int status;
  final String wire;
  final requests = <_Request>[];
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(utf8.decode(await request.finalize().toBytes())) as Map<String, Object?>;
    requests.add((method: request.method, url: request.url, body: body));
    return http.StreamedResponse(
      Stream.value(utf8.encode(wire)),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  }

  @override
  void close() {
    closed = true;
  }
}
