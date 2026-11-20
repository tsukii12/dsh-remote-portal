import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/llm/tool_calls.dart';
import 'package:test/test.dart';

// Actual loopback HTTP and the production SSE/UTF-8 decoder. No API account,
// mock ModelDelta producer, model execution or additional tool round trip.
void main() {
  test('loopback SSE keeps text reasoning and usage separate from interleaved Unicode tools', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'index': 1,
              'delta': {
                'tool_calls': [_wire(0, id: 'ignored', arguments: '{}')],
              },
            },
            {
              'index': 0,
              'delta': {
                'reasoning_content': '想一想',
                'content': '正文',
                'tool_calls': [_wire(7, arguments: '{"ops":['), _wire(2, arguments: '{"text":"海')],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'index': 0,
              'delta': {
                'tool_calls': [
                  {
                    'index': 2,
                    'function': {'arguments': '🐋"}'},
                  },
                  {
                    'index': 7,
                    'function': {'arguments': '1,2]}'},
                  },
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {'index': 0, 'delta': {}, 'finish_reason': 'tool_calls'},
          ],
        },
        {
          'choices': [],
          'usage': {'prompt_tokens': 8, 'completion_tokens': 3},
        },
      ], splitBytes: true),
      (h) async {
        final body = <String, Object?>{
          'stream': true,
          'messages': [
            {'role': 'user', 'content': 'go'},
          ],
          'tools': [
            {
              'type': 'function',
              'function': {'name': 'update_state'},
            },
          ],
        };
        final before = jsonEncode(body);
        final events = await h.model.generate(config: h.config, body: body, cancellation: ModelCancellation()).toList();
        final batch = _collect(events);
        expect(events.whereType<ModelReasoning>().single.text, '想一想');
        expect(events.whereType<ModelText>().single.text, '正文');
        expect(events.whereType<ModelUsage>().single.usage.promptTokens, 8);
        expect(events.last, isA<ModelFinished>());
        expect(events.whereType<ModelFinished>().single.reason, 'tool_calls');
        expect(batch.calls.map((call) => call.index), [2, 7]);
        expect(batch.calls.every((call) => call.valid), isTrue);
        expect(batch.calls.first.parameters, {'text': '海🐋'});
        expect(batch.calls.last.parameters, {
          'ops': [1, 2],
        });
        expect(h.requestCount, 1);
        expect(h.requests.single['tools'], body['tools']);
        expect(h.requests.single.containsKey('thinking'), isFalse);
        expect(jsonEncode(body), before);
      },
    );
  });

  test('nonstream calls use original array ordinals and retain a malformed member at its own index', () async {
    await _withLoopback(
      (request, _) => _json(request, {
        'choices': [
          {
            'message': {
              'reasoning_content': '思',
              'content': '答',
              'tool_calls': [
                _wire(99, id: 'first', arguments: '{"ops":[]}'),
                {
                  'id': 'second',
                  'type': 'function',
                  'function': {'name': 'future_tool', 'arguments': '{}'},
                },
                9,
              ],
            },
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 4, 'completion_tokens': 2},
      }),
      (h) async {
        final events = await h.generate(stream: false);
        final batch = _collect(events);
        expect(batch.calls.map((call) => call.index), [0, 1, 2]);
        expect(batch.calls.map((call) => call.valid), [true, true, false]);
        expect(batch.calls[1].name, 'future_tool');
        expect(_codes(batch.calls[2].issues), contains('invalid_tool_call'));
        expect(events.whereType<ModelText>().single.text, '答');
        expect(events.whereType<ModelReasoning>().single.text, '思');
        expect(events.whereType<ModelUsage>().single.usage.completionTokens, 2);
        expect(events.whereType<ModelFinished>().single.reason, 'stop');
        expect(h.requestCount, 1);
      },
    );
  });

  test('bad streaming containers indexes and field types remain diagnosed without poisoning valid calls', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {
                'tool_calls': {'not': 'a list'},
              },
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  false,
                  {
                    'id': 'no-index',
                    'type': 'function',
                    'function': {'name': 'update_state', 'arguments': '{}'},
                  },
                  {'index': 1.0, 'id': 'float-index'},
                  {'index': '1', 'id': 'string-index'},
                  {
                    'index': 1,
                    'id': null,
                    'type': true,
                    'function': {'name': 7, 'arguments': []},
                  },
                  {'index': 2, 'id': 'bad-function', 'type': 'function', 'function': null},
                  _wire(3, arguments: '{}'),
                ],
              },
              'finish_reason': 'stop',
            },
          ],
        },
      ]),
      (h) async {
        final events = await h.generate();
        final batch = _collect(events);
        expect(_codes(batch.issues), containsAll(['invalid_tool_calls', 'invalid_tool_call', 'invalid_index']));
        expect(batch.calls.map((call) => call.index), [1, 2, 3]);
        expect(batch.calls.map((call) => call.valid), [false, false, true]);
        expect(
          batch.calls.first.issues
              .where((issue) => issue['code'] == 'invalid_field_type')
              .map((issue) => issue['field']),
          ['id', 'type', 'function.name', 'function.arguments'],
        );
        expect(batch.calls[1].issues.any((issue) => issue['field'] == 'function'), isTrue);
        expect(batch.eligibleStructure, isTrue);
        expect(events.whereType<ModelFinished>().single.reason, 'stop');
        expect(h.requestCount, 1);
      },
    );
  });

  test('wire metadata conflicts and duplicate ids are visible before execution candidates are returned', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  _wire(0, arguments: '{}'),
                  _wire(2, id: 'duplicate', arguments: '{}'),
                  _wire(1, id: 'duplicate', arguments: '{}'),
                ],
              },
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [
                  {
                    'index': 0,
                    'id': 'changed',
                    'type': 'other',
                    'function': {'name': 'other'},
                  },
                ],
              },
              'finish_reason': 'tool_calls',
            },
          ],
        },
      ]),
      (h) async {
        final batch = _collect(await h.generate());
        expect(batch.calls.every((call) => !call.valid), isTrue);
        expect(_codes(batch.calls.first.issues), contains('conflicting_metadata'));
        expect(_codes(batch.calls[1].issues), contains('duplicate_id'));
        expect(_codes(batch.calls[2].issues), contains('duplicate_id'));
        expect(h.requestCount, 1);
      },
    );
  });

  test('absent and null tool fields leave the old text-only event and request contract intact', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {'content': '旧'},
            },
          ],
        },
        {
          'choices': [
            {
              'delta': {'content': '卡', 'tool_calls': null},
              'finish_reason': 'stop',
            },
          ],
        },
      ]),
      (h) async {
        final events = await h.generate();
        expect(events.whereType<ModelToolFragment>(), isEmpty);
        expect(events.whereType<ModelText>().map((event) => event.text).join(), '旧卡');
        expect(events.whereType<ModelFinished>().single.reason, 'stop');
        expect(h.requests.single.containsKey('tools'), isFalse);
        expect(h.requests.single.containsKey('tool_choice'), isFalse);
        expect(h.requests.single.containsKey('thinking'), isFalse);
        expect(h.requestCount, 1);
      },
    );
  });

  test('cancel after the first tool fragment stops later fragments usage and finish from that frame', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [_wire(0, arguments: '{"ops":['), _wire(1, arguments: '{}')],
              },
              'finish_reason': 'tool_calls',
            },
          ],
          'usage': {'prompt_tokens': 8, 'completion_tokens': 2},
        },
      ]),
      (h) async {
        h.allowDisconnect = true;
        final cancellation = ModelCancellation();
        final events = <ModelDelta>[];
        final future = h.model.generate(config: h.config, body: {'stream': true}, cancellation: cancellation).forEach((
          event,
        ) {
          events.add(event);
          cancellation.cancel();
        });
        await expectLater(
          future,
          throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.cancelled)),
        );
        expect(events, hasLength(1));
        expect(events.single, isA<ModelToolFragment>());
        final batch = _collect(events);
        expect(batch.calls.single.valid, isFalse);
        expect(_codes(batch.calls.single.issues), contains('invalid_arguments_json'));
        expect(h.requestCount, 1);
      },
    );
  });

  test('accepted SSE EOF before finish preserves a half-call for diagnosis and never retries', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {
                'tool_calls': [_wire(0, arguments: '{"ops":[')],
              },
            },
          ],
        },
      ], done: false),
      (h) async {
        final events = <ModelDelta>[];
        await expectLater(
          h.model
              .generate(config: h.config, body: {'stream': true}, cancellation: ModelCancellation())
              .forEach(events.add),
          throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.network)),
        );
        expect(events.whereType<ModelFinished>(), isEmpty);
        expect(_collect(events).calls.single.valid, isFalse);
        expect(h.requestCount, 1);
      },
    );
  });

  test('a normal response with malformed argument JSON retains text usage and one finish without a retry', () async {
    await _withLoopback(
      (request, _) => _sse(request, [
        {
          'choices': [
            {
              'delta': {
                'content': 'still visible',
                'tool_calls': [_wire(0, arguments: '{"ops":[}')],
              },
              'finish_reason': 'stop',
            },
          ],
          'usage': {'prompt_tokens': 2, 'completion_tokens': 1},
        },
      ]),
      (h) async {
        final events = await h.generate();
        expect(events.whereType<ModelText>().single.text, 'still visible');
        expect(events.whereType<ModelUsage>(), hasLength(1));
        expect(events.whereType<ModelFinished>(), hasLength(1));
        final batch = _collect(events);
        expect(batch.calls.single.arguments, '{"ops":[}');
        expect(_codes(batch.calls.single.issues), contains('invalid_arguments_json'));
        expect(batch.calls.single.valid, isFalse);
        expect(h.requestCount, 1);
      },
    );
  });

  for (final reason in <String?>[null, 'length', 'content_filter']) {
    test('complete tool structure does not rewrite the terminal reason $reason into authorization', () async {
      await _withLoopback(
        (request, _) => _sse(request, [
          {
            'choices': [
              {
                'delta': {
                  'tool_calls': [_wire(0, arguments: '{}')],
                },
                'finish_reason': reason,
              },
            ],
          },
        ]),
        (h) async {
          final events = await h.generate();
          expect(events.whereType<ModelFinished>().single.reason, reason);
          expect(_collect(events).calls.single.valid, isTrue);
          // The engine must use this reason and the actual sent tools to decide
          // eligibility; the transport never executes a structurally valid call.
          expect(h.requestCount, 1);
        },
      );
    });
  }
}

Map<String, Object?> _wire(int index, {String? id, required String arguments}) => {
  'index': index,
  'id': id ?? 'call-$index',
  'type': 'function',
  'function': {'name': 'update_state', 'arguments': arguments},
};

ModelToolBatch _collect(Iterable<ModelDelta> events) {
  final accumulator = ModelToolAccumulator();
  for (final event in events.whereType<ModelToolFragment>()) {
    accumulator.add(event);
  }
  return accumulator.finish();
}

List<Object?> _codes(List<Map<String, Object?>> issues) => [for (final issue in issues) issue['code']];

Future<void> _sse(
  HttpRequest request,
  List<Map<String, Object?>> events, {
  bool done = true,
  bool splitBytes = false,
}) async {
  request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
  request.response.bufferOutput = false;
  final frames = events.map((event) => 'data: ${jsonEncode(event)}\n\n').join();
  final text = done ? '${frames}data: [DONE]\n\n' : frames;
  if (splitBytes) {
    final bytes = utf8.encode(text);
    for (var index = 0; index < bytes.length; index++) {
      request.response.add([bytes[index]]);
      if (index + 1 < bytes.length) {
        await request.response.flush();
      }
    }
  } else {
    request.response.write(text);
  }
  try {
    await request.response.close();
  } on SocketException {
    // The client legitimately stops reading on [DONE], before HTTP EOF.
  } on HttpException {
    // All intended bytes were supplied; response assertions still verify
    // their delivery. Closing the peer here must not fail fixture cleanup.
  }
}

Future<void> _json(HttpRequest request, Map<String, Object?> body) async {
  request.response.headers.contentType = ContentType.json;
  request.response.write(jsonEncode(body));
  await request.response.close();
}

Future<void> _withLoopback(
  Future<void> Function(HttpRequest, _Loopback) respond,
  Future<void> Function(_Loopback) body,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final h = _Loopback(server, respond);
  try {
    await body(h);
  } finally {
    await h.close();
  }
  expect(h.errors, isEmpty);
}

class _Loopback {
  _Loopback(this.server, this.respond) {
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
  final HttpServer server;
  final Future<void> Function(HttpRequest, _Loopback) respond;
  late final StreamSubscription<HttpRequest> subscription;
  final model = TavernModelClient(idleTimeout: const Duration(seconds: 10));
  final requests = <Map<String, Object?>>[];
  final errors = <Object>[];
  final pending = <Future<void>>[];
  var requestCount = 0;
  var allowDisconnect = false;
  var closing = false;

  TavernModelConfig get config => TavernModelConfig(
    apiKey: () async => 'loopback-only',
    model: 'fixture',
    deepseek: false,
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
  );

  Future<List<ModelDelta>> generate({bool stream = true}) =>
      model.generate(config: config, body: {'stream': stream}, cancellation: ModelCancellation()).toList();

  Future<void> _handle(HttpRequest request) async {
    try {
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>);
      await respond(request, this);
    } catch (error) {
      if (!closing && !(allowDisconnect && (error is SocketException || error is HttpException))) {
        errors.add(error);
      }
      try {
        await request.response.close();
      } catch (_) {
        // The deliberately canceled request may already have closed its peer.
      }
    }
  }

  Future<void> close() async {
    closing = true;
    await server.close(force: true);
    await subscription.cancel();
    await Future.wait(pending);
  }
}
