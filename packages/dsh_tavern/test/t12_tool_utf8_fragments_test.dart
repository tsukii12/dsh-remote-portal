import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/llm/tool_calls.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

const _limit = ModelToolAccumulator.maxArgumentBytes;
const _whale = '🐋';
final _lead = String.fromCharCode(0xd83d);
final _tail = String.fromCharCode(0xdc0b);
final _at = DateTime.utc(2026, 11, 11, 4);

void main() {
  test('loopback split surrogate arguments at the UTF-8 limit commit and survive reopening', () async {
    final arguments = _argumentsAt(_limit);
    final parts = _splitPair(arguments);
    expect(utf8.encode(arguments), hasLength(_limit));
    expect(parts.map((part) => utf8.encode(part).length).reduce((a, b) => a + b), _limit + 2);
    final bytes = _wire(parts);
    expect(bytes.every((byte) => byte < 128), isTrue);
    final wire = ascii.decode(bytes);
    expect(wire, contains(r'\ud83d'));
    expect(wire, contains(r'\udc0b'));
    await _exerciseFacade(bytes);
  });

  test('loopback unsplit arguments at the same UTF-8 limit remain executable', () async {
    await _exerciseFacade(_wire([_argumentsAt(_limit)]));
  });

  test('same-index pairing survives interleaved calls and empty or metadata-only fragments', () {
    final parts = _splitPair(_argumentsAt(_limit - 2));
    final accumulator = ModelToolAccumulator()
      ..add(_fragment(0, parts.first))
      ..add(_fragment(19, '{}'))
      ..add(ModelToolFragment(index: 0))
      ..add(ModelToolFragment(index: 0, arguments: ''))
      ..add(ModelToolFragment(index: 0, id: 'call-0'))
      ..add(ModelToolFragment(index: 0, arguments: parts.last));
    final batch = accumulator.finish();
    expect(batch.eligibleStructure, isTrue);
    expect(batch.calls.map((call) => call.index), [0, 19]);
    expect(batch.calls.every((call) => call.valid), isTrue);
    expect(batch.calls.first.arguments, parts.join());
    expect(batch.calls.first.parameters, {
      'ops': [
        {'op': 'set', 'path': '/n', 'value': 7, 'why': _whale},
      ],
    });
    expect(batch.calls.last.parameters, isEmpty);
    expect(batch.issues, isEmpty);
  });

  test('surrogates from different indexes cannot discount the aggregate budget', () {
    const prefix = '{"value":"';
    const suffix = '"}';
    final other = '$prefix$_tail$suffix';
    final firstBytes = _limit + 2 - utf8.encode(other).length;
    final padding = firstBytes - utf8.encode('$prefix$_lead$suffix').length;
    final fill = 'a' * padding;
    final first = '$prefix$fill$_lead$suffix';
    expect(utf8.encode(first).length + utf8.encode(other).length, _limit + 2);
    final accumulator = ModelToolAccumulator()
      ..add(_fragment(19, prefix))
      ..add(_fragment(0, first.substring(0, first.length - suffix.length)))
      ..add(ModelToolFragment(index: 19, arguments: '$_tail$suffix'))
      ..add(ModelToolFragment(index: 0, arguments: suffix));
    _expectResourceRefusal(accumulator.finish());
  });

  test('unassigned bytes and genuine split-call overflow keep the entire batch blocked', () {
    for (final index in <int?>[null, -1]) {
      final arguments = ' ' * (_limit - 6) + '{}';
      expect(utf8.encode(arguments), hasLength(_limit - 4));
      final accumulator = ModelToolAccumulator()
        ..add(_fragment(0, arguments))
        ..add(ModelToolFragment(index: index, arguments: _lead))
        ..add(ModelToolFragment(index: index, arguments: _tail));
      _expectResourceRefusal(accumulator.finish());
    }

    final parts = _splitPair(_argumentsAt(_limit + 1));
    final accumulator = ModelToolAccumulator()
      ..add(_fragment(0, parts.first))
      ..add(ModelToolFragment(index: 0, arguments: parts.last))
      ..add(_fragment(1, '{}'));
    final batch = accumulator.finish();
    _expectResourceRefusal(batch);
    expect(batch.calls.map((call) => call.index), [0, 1]);
    expect(batch.calls.last.parameters, isNull);
  });
}

ModelToolFragment _fragment(int index, String arguments) =>
    ModelToolFragment(index: index, id: 'call-$index', type: 'function', name: 'update_state', arguments: arguments);

void _expectResourceRefusal(ModelToolBatch batch) {
  expect(batch.eligibleStructure, isFalse);
  expect(batch.issues.map((issue) => issue['code']), contains('tool_arguments_limit'));
  expect(batch.calls.every((call) => !call.valid && call.parameters == null), isTrue);
  expect(batch.calls.every((call) => call.issues.any((issue) => issue['code'] == 'batch_resource_limit')), isTrue);
}

String _argumentsAt(int bytes) {
  final body = jsonEncode({
    'ops': [
      {'op': 'set', 'path': '/n', 'value': 7, 'why': _whale},
    ],
  });
  final padding = ' ' * (bytes - utf8.encode(body).length);
  return '$padding$body';
}

List<String> _splitPair(String arguments) {
  final position = arguments.indexOf(_whale);
  expect(position, greaterThanOrEqualTo(0));
  return [arguments.substring(0, position + 1), arguments.substring(position + 1)];
}

List<int> _wire(List<String> parts) {
  final frames = <Map<String, Object?>>[
    for (var index = 0; index < parts.length; index++)
      {
        'id': 'utf8-tools',
        'object': 'chat.completion.chunk',
        'created': 1,
        'model': 'fixture',
        'choices': [
          {
            'index': 0,
            'delta': {
              'tool_calls': [
                {
                  'index': 0,
                  if (index == 0) 'id': 'call-0',
                  if (index == 0) 'type': 'function',
                  'function': {if (index == 0) 'name': 'update_state', 'arguments': parts[index]},
                },
              ],
            },
            'finish_reason': null,
          },
        ],
      },
    {
      'choices': [
        {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'tool_calls'},
      ],
    },
    {
      'choices': <Object?>[],
      'usage': {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10},
    },
  ];
  final text = frames.map((frame) => 'data: ${jsonEncode(frame)}\n\n').join();
  return utf8.encode('${text}data: [DONE]\n\n');
}

Future<void> _exerciseFacade(List<int> bytes) async {
  final endpoint = await _Endpoint.open(bytes);
  Directory? directory;
  TavernEngine? engine;
  try {
    directory = await Directory.systemTemp.createTemp('dsh-t12-tool-utf8-');
    engine = await _openEngine(directory, endpoint);
    await engine.setPreset(t24Preset());
    final card = jsonDecode(utf8.decode(t24Card())) as Map<String, Object?>;
    final data = card['data']! as Map<String, Object?>;
    data['extensions'] = {
      'dshgo': {
        'v': 1,
        'state': {
          'schema': {
            'type': 'object',
            'additionalProperties': false,
            'required': ['n'],
            'properties': {
              'n': {'type': 'integer', 'default': 0},
            },
          },
        },
      },
    };
    final character = await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
    final chat = await engine.createChat(character.id);
    expect((await engine.readState(chat)).values, {'n': 0});
    final events = await engine.send(chat, 'set n').toList();
    await endpoint.verifyRequest();
    expect(events.whereType<TavernTurnFailed>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), hasLength(1));
    final done = events.whereType<TavernTurnDone>().single;
    expect(events.last, same(done));
    expect(done.finishReason, 'tool_calls');
    expect(done.message.usage?.promptTokens, 7);
    expect(done.message.usage?.completionTokens, 3);

    // First defect-specific oracle after real HTTP, tool-offer and terminal
    // preconditions. The old product finishes normally but leaves n at zero.
    final values = (await engine.readState(chat)).values as Map<String, Object?>;
    expect(values['n'], 7);
    expect(done.message.text, isEmpty);
    final path = await engine.path(chat);
    expect(path.map((message) => message.text), ['G', 'set n', '']);
    expect(path.last.nodeId, done.message.nodeId);
    final tool = (await engine.readAgentRuns(chat)).where((run) => run.kind == 'state.tool').single;
    expect(tool.result['committed'], isTrue);
    expect(tool.nodeId, done.message.nodeId);
    final parameters = tool.result['parameters']! as Map<String, Object?>;
    expect(parameters['ops'], [
      {'op': 'set', 'path': '/n', 'value': 7, 'why': _whale},
    ]);

    await engine.close();
    engine = await _openEngine(directory, endpoint);
    expect((await engine.readState(chat)).values, {'n': 7});
    expect((await engine.path(chat)).map((message) => message.nodeId), path.map((message) => message.nodeId));
    final reopened = (await engine.readAgentRuns(chat)).where((run) => run.kind == 'state.tool').single;
    expect(reopened.id, tool.id);
    expect(reopened.result['committed'], isTrue);
    expect(endpoint.requestCount, 1);
  } finally {
    try {
      await engine?.close();
      if (directory != null) {
        await directory.delete(recursive: true);
      }
    } finally {
      await endpoint.close();
    }
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
  final requests = <Map<String, Object?>>[];
  final methods = <String>[];
  final paths = <String>[];
  var requestCount = 0;

  TavernModelConfig get config => TavernModelConfig(
    apiKey: () async => 'loopback-only',
    model: 'fixture',
    thinking: false,
    deepseek: false,
    baseUrl: 'http://${server.address.address}:${server.port}/v1',
  );

  Future<void> _handle(HttpRequest request) async {
    try {
      methods.add(request.method);
      paths.add(request.uri.path);
      requests.add(jsonDecode(await utf8.decoder.bind(request).join()) as Map<String, Object?>);
      request.response.headers.contentType = ContentType('text', 'event-stream', charset: 'utf-8');
      request.response.contentLength = bytes.length;
      request.response.persistentConnection = false;
      request.response.add(bytes);
      try {
        await request.response.close();
      } on SocketException {
        // The client can finish on DONE before the server's close completes.
      } on HttpException {
        // Only the final close may race the completed response.
      }
    } catch (error) {
      errors.add(error);
      try {
        await request.response.close();
      } catch (_) {
        /* Keep the original error. */
      }
    }
  }

  Future<void> verifyRequest() async {
    await Future.wait(pending);
    expect(errors, isEmpty);
    expect(requestCount, 1);
    expect(methods, ['POST']);
    expect(paths, ['/v1/chat/completions']);
    expect(requests, hasLength(1));
    final body = requests.single;
    expect(body['stream'], isTrue);
    final tools = body['tools']! as List<Object?>;
    expect(
      tools.whereType<Map<String, Object?>>().any(
        (tool) => tool['type'] == 'function' && (tool['function'] as Map<String, Object?>)['name'] == 'update_state',
      ),
      isTrue,
    );
    expect(body['tool_choice'], anyOf(isNull, 'auto', 'required'));
    final messages = body['messages']! as List<Object?>;
    expect(messages.whereType<Map<String, Object?>>().any((message) => message['prefix'] == true), isFalse);
  }

  Future<void> close() async {
    await server.close(force: true);
    await subscription.cancel();
    await Future.wait(pending);
  }
}
