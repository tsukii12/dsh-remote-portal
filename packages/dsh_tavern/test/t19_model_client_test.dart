import 'dart:async';
import 'dart:convert';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  for (final c in [
    (400, 'invalid format', TavernFailure.invalidParameters),
    (422, 'invalid parameters', TavernFailure.invalidParameters),
    (402, 'insufficient balance', TavernFailure.insufficientBalance),
    (400, 'context_length_exceeded', TavernFailure.contextTooLong),
    (403, 'forbidden', TavernFailure.badKey),
    (429, 'rate limit', TavernFailure.busy),
  ]) {
    test('HTTP ${c.$1} ${c.$2} has a distinct failure and no retry', () async {
      final clients = <_Client>[];
      final model = TavernModelClient(
        clientFactory: () {
          final client = _Client((_) async => _response(c.$1, '${c.$2} secret-key Bearer private-token'));
          clients.add(client);
          return client;
        },
      );
      await expectLater(
        _generate(model),
        throwsA(
          isA<TavernModelException>()
              .having((e) => e.kind, 'kind', c.$3)
              .having(
                (e) => e.detail,
                'detail',
                allOf(isNot(contains('secret-key')), isNot(contains('private-token'))),
              ),
        ),
      );
      expect(clients, hasLength(1));
      expect(clients.single.closed, isTrue);
    });
  }
  test('cancellation before send closes the allocated client without a POST', () async {
    final cancellation = ModelCancellation();
    var sent = false;
    late _Client client;
    final model = TavernModelClient(
      clientFactory: () {
        cancellation.cancel();
        client = _Client((_) async {
          sent = true;
          return _success(true);
        });
        return client;
      },
    );
    await expectLater(
      _generate(model, cancellation: cancellation),
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.cancelled)),
    );
    expect(sent, isFalse);
    expect(client.closed, isTrue);
  });
  test('timeout awaiting headers is not a safe connection retry', () async {
    final pending = Completer<http.StreamedResponse>();
    var attempts = 0;
    final model = TavernModelClient(
      idleTimeout: const Duration(milliseconds: 10),
      clientFactory: () {
        attempts++;
        return _Client((_) => pending.future);
      },
    );
    await expectLater(
      _generate(model),
      throwsA(
        isA<TavernModelException>()
            .having((e) => e.kind, 'kind', TavernFailure.network)
            .having((e) => e.detail, 'detail', 'request_timeout'),
      ),
    );
    expect(attempts, 1);
    pending.complete(_success(true));
  });

  test('an interrupted non-streaming accepted body is not retried', () async {
    var attempts = 0;
    Stream<List<int>> body() async* {
      yield utf8.encode('{"choices":[');
      throw http.ClientException('partial JSON');
    }

    final model = TavernModelClient(
      clientFactory: () {
        attempts++;
        return _Client((_) async => http.StreamedResponse(body(), 200));
      },
    );
    await expectLater(
      _generate(model, stream: false),
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.network)),
    );
    expect(attempts, 1);
  });

  for (final body in [
    'not JSON',
    'data: {"error":{"message":"failed"}}\n\n',
    'data: {"choices":[{"delta":{},"finish_reason":"aborted"}]}\n\ndata: [DONE]\n\n',
  ]) {
    test('accepted protocol failure is not retried: $body', () async {
      var attempts = 0;
      final model = TavernModelClient(
        clientFactory: () {
          attempts++;
          return _Client((_) async => _response(200, body));
        },
      );
      await expectLater(
        _generate(model, stream: body != 'not JSON'),
        throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.server)),
      );
      expect(attempts, 1);
    });
  }
  for (final c in <(String, Map<String, Object?>)>[
    ('empty', {}),
    (
      'role',
      {
        'choices': [
          {
            'delta': {'role': 'assistant'},
          },
        ],
      },
    ),
    (
      'reasoning',
      {
        'choices': [
          {
            'delta': {'reasoning_content': '思考'},
          },
        ],
      },
    ),
    (
      'text',
      {
        'choices': [
          {
            'delta': {'content': '半句'},
          },
        ],
      },
    ),
    (
      'usage',
      {
        'choices': [],
        'usage': {'prompt_tokens': 1, 'completion_tokens': 0},
      },
    ),
  ]) {
    test('accepted ${c.$1} stream never retries after a connection loss', () async {
      var attempts = 0;
      Stream<List<int>> body() async* {
        yield utf8.encode('data: ${jsonEncode(c.$2)}\n\n');
        throw http.ClientException('lost accepted stream');
      }

      final model = TavernModelClient(
        clientFactory: () {
          attempts++;
          return _Client((_) async => http.StreamedResponse(body(), 200));
        },
      );
      final seen = <ModelDelta>[];
      await expectLater(
        model
            .generate(
              config: TavernModelConfig(apiKey: () async => 'secret-key'),
              body: {},
              cancellation: ModelCancellation(),
            )
            .forEach(seen.add),
        throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.network)),
      );
      expect(attempts, 1);
      expect(seen.whereType<ModelFinished>(), isEmpty);
      if (c.$1 == 'text') expect(seen.whereType<ModelText>().single.text, '半句');
      if (c.$1 == 'reasoning') expect(seen.whereType<ModelReasoning>().single.text, '思考');
      if (c.$1 == 'usage') expect(seen.whereType<ModelUsage>().single.usage.promptTokens, 1);
    });
  }
  test('5xx exhausts exactly two retries and stays server despite context text', () async {
    final clients = <_Client>[];
    final model = TavernModelClient(
      clientFactory: () {
        final client = _Client((_) async => _response(500, 'context_length_exceeded secret-key'));
        clients.add(client);
        return client;
      },
    );
    await expectLater(
      _generate(model),
      throwsA(
        isA<TavernModelException>()
            .having((e) => e.kind, 'kind', TavernFailure.server)
            .having((e) => e.detail, 'detail', isNot(contains('secret-key'))),
      ),
    );
    expect(clients, hasLength(3));
    expect(clients.every((c) => c.closed), isTrue);
  });

  test('503 with an unreadable error body still retries its known status', () async {
    var attempts = 0;
    final model = TavernModelClient(
      clientFactory: () => _Client((_) async {
        attempts++;
        if (attempts == 1) return http.StreamedResponse(Stream.error(http.ClientException('lost error body')), 503);
        return _success(true);
      }),
    );
    expect((await _generate(model)).whereType<ModelText>().single.text, '成功');
    expect(attempts, 2);
  });

  test('cancellation during backoff prevents the next request', () async {
    final closed = Completer<void>();
    final cancellation = ModelCancellation();
    var attempts = 0;
    final model = TavernModelClient(
      clientFactory: () {
        attempts++;
        return _Client(
          (_) async => _response(503, 'retry later'),
          onClose: () {
            if (!closed.isCompleted) closed.complete();
          },
        );
      },
    );
    final result = expectLater(
      _generate(model, cancellation: cancellation),
      throwsA(isA<TavernModelException>().having((e) => e.kind, 'kind', TavernFailure.cancelled)),
    );
    await closed.future;
    cancellation.cancel();
    await result;
    expect(attempts, 1);
  });
  for (final streaming in [true, false]) {
    test('connection then 503 retries one prepared payload (stream=$streaming)', () async {
      final clients = <_Client>[];
      final bodies = <String>[];
      var keys = 0;
      final body = <String, Object?>{
        'stream': streaming,
        'messages': [
          {'role': 'user', 'content': '你好'},
        ],
      };
      final original = jsonEncode(body);
      final model = TavernModelClient(
        clientFactory: () {
          final attempt = clients.length;
          final client = _Client((request) async {
            bodies.add(utf8.decode(await request.finalize().toBytes()));
            if (attempt == 0) throw http.ClientException('connection failed secret-key');
            if (attempt == 1) return _response(503, 'temporarily overloaded');
            return _success(streaming);
          });
          clients.add(client);
          return client;
        },
      );
      final deltas = await model
          .generate(
            config: TavernModelConfig(
              apiKey: () async {
                keys++;
                return 'secret-key';
              },
            ),
            body: body,
            cancellation: ModelCancellation(),
          )
          .toList();
      expect(keys, 1);
      expect(clients, hasLength(3));
      expect(clients.every((c) => c.closed), isTrue);
      expect(bodies.toSet(), hasLength(1));
      expect(jsonEncode(body), original);
      expect(deltas.whereType<ModelText>().single.text, '成功');
      expect(deltas.whereType<ModelFinished>().single.reason, 'length');
    });
  }
}

Future<List<ModelDelta>> _generate(TavernModelClient model, {ModelCancellation? cancellation, bool stream = true}) =>
    model
        .generate(
          config: TavernModelConfig(apiKey: () async => 'secret-key'),
          body: {'stream': stream},
          cancellation: cancellation ?? ModelCancellation(),
        )
        .toList();

http.StreamedResponse _response(int status, String text) =>
    http.StreamedResponse(Stream.value(utf8.encode(text)), status);

http.StreamedResponse _success(bool streaming) {
  final body = {
    'choices': [
      {
        streaming ? 'delta' : 'message': {'content': '成功'},
        'finish_reason': 'length',
      },
    ],
  };
  return _response(200, streaming ? 'data: ${jsonEncode(body)}\n\ndata: [DONE]\n\n' : jsonEncode(body));
}

class _Client extends http.BaseClient {
  _Client(this.handler, {this.onClose});
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  final void Function()? onClose;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}
