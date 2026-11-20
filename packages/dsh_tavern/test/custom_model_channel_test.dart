import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'support/t24_engine_harness.dart' show t24Card, t24Preset;

typedef _Json = Map<String, Object?>;

// The production transport, prompt assembly, engine and stores run here. Only
// the HTTP peer, clock and dice are supplied; no external service is contacted.
void main() {
  test('generic local channels keep supplied Authorization with null and empty keys', () async {
    final wire = _Wire((_, _) => _completion({'role': 'assistant', 'content': 'local answer'}));
    final body = <String, Object?>{
      'messages': [
        {'role': 'user', 'content': 'Q'},
        {
          'role': 'assistant',
          'content': 'existing answer',
          'prefix': true,
          'reasoning_content': 'native thought',
          'reasoning': 'alias thought',
        },
      ],
      'stream': false,
      'thinking': {'type': 'enabled'},
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'channel_tool',
            'strict': true,
            'parameters': {'type': 'object', 'properties': <String, Object?>{}},
          },
        },
      ],
    };
    final original = jsonEncode(body);
    for (final key in <String?>[null, '']) {
      final events = await wire.model
          .generate(
            config: _config(
              key: key,
              baseUrl: 'http://127.0.0.1:11434/v1',
              thinking: true,
              headers: {'X-Route': 'local-route', 'aUtHoRiZaTiOn': 'Basic local-credential'},
            ),
            body: body,
            cancellation: ModelCancellation(),
          )
          .toList();
      expect(events.whereType<ModelText>().single.text, 'local answer');
      final request = wire.requests.last;
      expect(request.url, Uri.parse('http://127.0.0.1:11434/v1/chat/completions'));
      expect(request.headers['authorization'], 'Basic local-credential');
      expect(request.headers['x-route'], 'local-route');
      final sent = _body(request);
      _expectGeneric(sent);
      expect(sent['messages'], [
        {'role': 'user', 'content': 'Q'},
        {'role': 'assistant', 'content': 'existing answer'},
      ]);
      expect(_toolNames(sent), ['channel_tool']);
      expect(jsonEncode(body), original);
    }
    expect(wire.requests, hasLength(2));
  });

  test('DeepSeek still rejects null and empty keys before creating an HTTP client', () async {
    var created = 0;
    final model = TavernModelClient(
      clientFactory: () {
        created++;
        return MockClient((_) async => _completion({'role': 'assistant', 'content': 'unexpected'}));
      },
    );
    for (final key in <String?>[null, '']) {
      await expectLater(
        model
            .generate(
              config: _config(key: key, deepseek: true),
              body: {},
              cancellation: ModelCancellation(),
            )
            .toList(),
        throwsA(isA<TavernModelException>().having((error) => error.kind, 'kind', TavernFailure.noKey)),
      );
    }
    expect(created, 0);
  });

  test('every HTTP retry carries custom headers and provider errors redact their values', () async {
    const key = 'api-private-7201';
    const secret = r'header-"private-6438"\route';
    final wire = _Wire(
      (_, index) => http.Response(
        jsonEncode({
          'error': {'message': 'Rejected $key with $secret'},
        }),
        index == 0 ? 503 : 400,
      ),
    );
    await expectLater(
      wire.model
          .generate(
            config: _config(
              key: key,
              headers: {
                'X-Route': 'retry-route',
                'X-Secret': secret,
                'Authorization': 'Basic original-auth',
                'aUtHoRiZaTiOn': 'Basic alternate-auth',
              },
            ),
            body: {'stream': false},
            cancellation: ModelCancellation(),
          )
          .toList(),
      throwsA(
        isA<TavernModelException>()
            .having((error) => error.kind, 'kind', TavernFailure.invalidParameters)
            .having((error) => error.detail, 'API key redacted', isNot(contains(key)))
            .having((error) => error.detail, 'encoded header value redacted', isNot(contains('private-6438'))),
      ),
    );
    expect(wire.requests, hasLength(2));
    for (final request in wire.requests) {
      expect(request.headers['authorization'], 'Bearer $key');
      expect(request.headers.keys.where((name) => name.toLowerCase() == 'authorization'), hasLength(1));
      expect(request.headers['x-route'], 'retry-route');
      expect(request.headers['x-secret'], secret);
      expect(request.headers['content-type'], contains('application/json'));
    }
  });

  test('keyless Authorization credentials are redacted when the provider echoes only the token', () async {
    for (final credential in ['abc123', r'abc123"quoted\suffix']) {
      final wire = _Wire(
        (_, _) => http.Response(
          jsonEncode({
            'error': {'message': 'invalid token $credential'},
          }),
          401,
        ),
      );
      await expectLater(
        wire.model
            .generate(
              config: _config(key: null, headers: {'Authorization': 'Bearer $credential'}),
              body: {'stream': false},
              cancellation: ModelCancellation(),
            )
            .toList(),
        throwsA(
          isA<TavernModelException>()
              .having((error) => error.kind, 'kind', TavernFailure.badKey)
              .having((error) => error.detail, 'credential redacted', isNot(contains('abc123')))
              .having((error) => error.detail, 'provider message retained', contains('invalid token [redacted]')),
        ),
      );
      expect(wire.requests.single.headers['authorization'], 'Bearer $credential');
    }
  });

  test('streaming reasoning accepts both names without duplicating the preferred native field', () async {
    final wire = _Wire(
      (_, _) => _sse([
        {'role': 'assistant', 'reasoning': 'alias '},
        {'reasoning_content': 'native ', 'reasoning': 'duplicate '},
        {'reasoning_content': '', 'reasoning': 'fallback'},
        {'content': 'answer'},
      ]),
    );
    final events = await wire.model
        .generate(config: _config(), body: {'stream': true}, cancellation: ModelCancellation())
        .toList();
    expect(events.whereType<ModelReasoning>().map((event) => event.text), ['alias ', 'native ', 'fallback']);
    expect(events.whereType<ModelText>().single.text, 'answer');
    final snapshot = events.whereType<ModelFinished>().single.assistantSnapshot!;
    expect(snapshot.completeForReplay, isTrue);
    expect(snapshot.wireMessage['reasoning'], 'alias duplicate fallback');
    expect(snapshot.wireMessage['reasoning_content'], 'native ');
  });

  test('nonstreaming reasoning uses the alias when the native field is absent or empty', () async {
    final messages = <_Json>[
      {'reasoning': 'alias'},
      {'reasoning_content': 'native', 'reasoning': 'duplicate'},
      {'reasoning_content': '', 'reasoning': 'fallback'},
    ];
    final wire = _Wire((_, index) => _completion({'role': 'assistant', 'content': 'answer', ...messages[index]}));
    for (final expected in ['alias', 'native', 'fallback']) {
      final events = await wire.model
          .generate(config: _config(), body: {'stream': false}, cancellation: ModelCancellation())
          .toList();
      expect(events.whereType<ModelReasoning>().map((event) => event.text), [expected]);
      expect(events.whereType<ModelText>().single.text, 'answer');
    }
  });

  test('generic send and continue carry headers and keep DeepSeek fields out of requests and inspections', () async {
    const secret = 'main-header-private-8297';
    final wire = _Wire(
      (_, index) => _completion({
        'role': 'assistant',
        'content': index == 0 ? 'answer' : ' tail',
        'reasoning': 'private thought',
      }),
    );
    final h = await _Fixture.open(
      _config(key: null, headers: {'X-Route': 'main-route', 'X-Secret': secret}),
      wire,
      state: true,
    );
    final first = _done(await h.engine.send(h.chatId, 'Q').toList());
    expect(first.reasoning, 'private thought');
    final continued = _done(await h.engine.continueReply(h.chatId, first.nodeId).toList());
    expect(continued.nodeId, first.nodeId);
    expect(continued.text, 'answer tail');
    expect(wire.requests, hasLength(2));
    expect(_toolNames(_body(wire.requests.first)), contains('update_state'));
    for (final request in wire.requests) {
      expect(request.url, Uri.parse('https://channel.invalid/v1/chat/completions'));
      expect(request.headers['x-route'], 'main-route');
      expect(request.headers['x-secret'], secret);
      expect(request.headers['authorization'], isNull);
      _expectGeneric(_body(request));
    }
    final inspection = (await h.engine.inspectTurn(h.chatId, nodeId: continued.nodeId))!;
    _expectGeneric(inspection.prompt!.body);
    final saved = jsonEncode(inspection.toJson());
    expect(saved, isNot(contains(secret)));
    expect(saved, isNot(contains('main-route')));
    expect(saved, isNot(contains('X-Secret')));
  });

  test('tool continuation sends the same channel headers on each real request', () async {
    const secret = 'tool-header-private-5420';
    final wire = _Wire(
      (_, index) => index == 0
          ? _completion({
              'role': 'assistant',
              'content': 'before ',
              'tool_calls': [
                _tool('route-roll', 'roll', {'dice': 'd6'}),
              ],
            }, finish: 'tool_calls')
          : _completion({'role': 'assistant', 'content': 'after'}),
    );
    final h = await _Fixture.open(
      _config(deepseek: true, headers: {'X-Route': 'tool-route', 'X-Secret': secret}),
      wire,
    );
    await h.engine.setToolPolicy({
      'roll': {'allow': true},
    });
    final events = await h.engine.send(h.chatId, 'roll once').toList();
    expect(_done(events).text, 'before after');
    expect(wire.requests, hasLength(2));
    final continuation = _rows(_body(wire.requests.last)['messages']);
    expect(continuation.where((message) => message['role'] == 'tool').single['tool_call_id'], 'route-roll');
    for (final request in wire.requests) {
      expect(request.headers['x-route'], 'tool-route');
      expect(request.headers['x-secret'], secret);
      expect(request.headers['authorization'], 'Bearer channel-key');
    }
    final turnId = events.whereType<TavernTurnStarted>().single.logicalTurnId!;
    final turn = (await h.engine.readToolTurn(turnId))!;
    expect(turn.requests, hasLength(2));
    expect(jsonEncode(turn.toJson()), isNot(contains(secret)));
  });

  test('automatic director and secret jobs use explicit auxiliary headers model and thinking', () async {
    const secret = 'aux-header-private-1369';
    final auxiliary = _config(
      key: 'aux-key',
      baseUrl: 'https://aux.invalid/v1',
      model: 'aux-reasoner',
      deepseek: true,
      thinking: true,
      headers: {'X-Route': 'aux-route', 'X-Secret': secret},
    );
    final wire = _Wire((request, _) {
      final names = _toolNames(_body(request));
      if (names.contains('direct')) {
        return _completion({
          'role': 'assistant',
          'content': null,
          'tool_calls': [_tool('direct-result', 'direct', _directOutput())],
        }, finish: 'tool_calls');
      }
      if (names.contains('propose_secrets')) {
        return _completion({
          'role': 'assistant',
          'content': null,
          'tool_calls': [
            _tool('secret-result', 'propose_secrets', {'notes': '', 'facts': <Object?>[]}),
          ],
        }, finish: 'tool_calls');
      }
      return _completion({'role': 'assistant', 'content': 'source reply'});
    });
    final h = await _Fixture.open(
      _config(key: null, headers: {'X-Route': 'main-only-route'}, auxiliary: auxiliary),
      wire,
      secrets: true,
    );
    await h.engine.setSettings({
      'director': {'enabled': true, 'secretsEnabled': true, 'every': 1},
    });
    _done(await h.engine.send(h.chatId, 'Q').toList());
    final idle = await h.engine
        .watchDirector(h.chatId)
        .firstWhere((snapshot) => snapshot.pendingJobs == 0 && snapshot.latestSuccess != null);
    expect(idle.latestSuccess!.success, isTrue);
    final proposals = (await h.engine.readAgentRuns(h.chatId)).where((run) => run.kind == 'director.secret_proposal');
    expect(proposals.single.result['success'], isTrue);
    expect(wire.requests, hasLength(3));
    expect(wire.requests.first.headers['x-route'], 'main-only-route');
    expect(wire.requests.first.headers['x-secret'], isNull);
    for (final request in wire.requests.skip(1)) {
      expect(request.url, Uri.parse('https://aux.invalid/beta/chat/completions'));
      expect(request.headers['authorization'], 'Bearer aux-key');
      expect(request.headers['x-route'], 'aux-route');
      expect(request.headers['x-secret'], secret);
      expect(_body(request)['model'], 'aux-reasoner');
      expect(_body(request)['thinking'], {'type': 'enabled'});
      expect(_body(request)['tool_choice'], 'auto');
    }
  });

  test('group helpers retain legacy fallback headers and can switch to a keyless generic auxiliary', () async {
    final wire = _Wire((_, _) => _completion({'role': 'assistant', 'content': 'group answer'}));
    final h = await _Fixture.open(
      _config(deepseek: true, thinking: true, model: 'main-reasoner', headers: {'X-Route': 'group-fallback'}),
      wire,
    );
    final group = await h.engine.createGroupChat(
      [h.characterId],
      activation: TavernGroupActivation.listOrder,
      addGreetings: false,
    );
    await h.engine.updateGroupMember(group, h.characterId, modelRole: TavernGroupModelRole.helper);
    final first = await h.engine.sendGroup(group, 'first').toList();
    expect(first.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    expect(wire.requests, hasLength(1));
    expect(wire.requests.first.headers['x-route'], 'group-fallback');
    expect(_body(wire.requests.first)['model'], 'deepseek-flash');
    expect(_body(wire.requests.first)['thinking'], {'type': 'disabled'});

    h.engine.configure(
      _config(
        deepseek: true,
        thinking: true,
        model: 'main-reasoner',
        headers: {'X-Route': 'group-fallback'},
        auxiliary: _config(
          key: null,
          baseUrl: 'http://127.0.0.1:1234/v1',
          model: 'local-helper',
          thinking: true,
          headers: {'X-Route': 'group-aux'},
        ),
      ),
    );
    final second = await h.engine.sendGroup(group, 'second').toList();
    expect(second.whereType<TavernGroupFinished>().single.reason, TavernGroupEndReason.completed);
    expect(wire.requests, hasLength(2));
    final request = wire.requests.last;
    expect(request.url, Uri.parse('http://127.0.0.1:1234/v1/chat/completions'));
    expect(request.headers['authorization'], isNull);
    expect(request.headers['x-route'], 'group-aux');
    expect(_body(request)['model'], 'local-helper');
    _expectGeneric(_body(request));
  });

  test('script generate and raw preserve the main channel headers across configuration copies', () async {
    const secret = 'script-header-private-8502';
    final wire = _Wire(
      (_, index) => _completion({'role': 'assistant', 'content': 'script-$index', 'reasoning': 'script thought'}),
    );
    final h = await _Fixture.open(
      _config(
        key: null,
        thinking: true,
        headers: {'X-Route': 'script-route', 'X-Secret': secret},
        auxiliary: _config(model: 'unused-auxiliary'),
      ),
      wire,
    );
    final context = await h.engine.scripts.openContext(
      TavernScriptContextSpec(instanceId: 'channel-script', chatId: h.chatId, characterId: h.characterId),
    );
    final generated = await h.engine.scripts.generate(
      context.id,
      TavernScriptGenerateRequest(userInput: 'assembled question', includeReasoning: true),
    );
    final first = await generated.result;
    final raw = await h.engine.scripts.generateRaw(
      context.id,
      TavernScriptRawRequest(
        includeReasoning: true,
        orderedPrompts: const [
          TavernScriptPromptPart.literal(role: TavernScriptPromptRole.user, content: 'raw question'),
        ],
      ),
    );
    final second = await raw.result;
    expect([first.text, second.text], ['script-0', 'script-1']);
    expect([first.reasoning, second.reasoning], ['script thought', 'script thought']);
    expect(wire.requests, hasLength(2));
    for (final request in wire.requests) {
      expect(request.url, Uri.parse('https://channel.invalid/v1/chat/completions'));
      expect(request.headers['authorization'], isNull);
      expect(request.headers['x-route'], 'script-route');
      expect(request.headers['x-secret'], secret);
      expect(_body(request)['model'], 'channel-model');
      _expectGeneric(_body(request));
    }
    expect(_body(wire.requests.last)['messages'], [
      {'role': 'user', 'content': 'raw question'},
    ]);
  });
}

TavernModelConfig _config({
  String? key = 'channel-key',
  String baseUrl = 'https://channel.invalid/v1',
  String model = 'channel-model',
  bool deepseek = false,
  bool thinking = false,
  Map<String, String> headers = const {},
  TavernModelConfig? auxiliary,
}) => TavernModelConfig(
  apiKey: () async => key,
  baseUrl: baseUrl,
  model: model,
  deepseek: deepseek,
  thinking: thinking,
  headers: headers,
  auxiliary: auxiliary,
);

_Json _map(Object? value) => value! as _Json;
List<_Json> _rows(Object? value) => (value! as List<Object?>).cast<_Json>();
_Json _body(http.Request request) => _map(jsonDecode(request.body));
List<String> _toolNames(_Json body) => [
  for (final tool in _rows(body['tools'] ?? const <Object?>[])) _map(tool['function'])['name']! as String,
];

void _expectGeneric(_Json body) {
  expect(body.containsKey('thinking'), isFalse);
  for (final message in _rows(body['messages'] ?? const <Object?>[])) {
    expect(message.containsKey('prefix'), isFalse);
    expect(message.containsKey('reasoning_content'), isFalse);
    expect(message.containsKey('reasoning'), isFalse);
  }
  for (final tool in _rows(body['tools'] ?? const <Object?>[])) {
    expect(_map(tool['function']).containsKey('strict'), isFalse);
  }
}

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

http.Response _completion(_Json message, {String finish = 'stop'}) => http.Response(
  jsonEncode({
    'choices': [
      {'index': 0, 'message': message, 'finish_reason': finish},
    ],
  }),
  200,
  headers: {'content-type': 'application/json'},
);

http.Response _sse(List<_Json> deltas) {
  final chunks = [
    for (final delta in deltas)
      {
        'choices': [
          {'index': 0, 'delta': delta, 'finish_reason': null},
        ],
      },
    {
      'choices': [
        {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
      ],
    },
  ];
  return http.Response(
    '${chunks.map((chunk) => 'data: ${jsonEncode(chunk)}\n\n').join()}data: [DONE]\n\n',
    200,
    headers: {'content-type': 'text/event-stream'},
  );
}

_Json _tool(String id, String name, _Json arguments) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': jsonEncode(arguments)},
};

_Json _directOutput() => {
  'notes': '',
  'beat': '',
  'prefetch': <Object?>[],
  'suggestions': [
    for (var i = 0; i < 3; i++) {'text': 'option $i', 'risk': ''},
  ],
  'events': <Object?>[],
};

class _Wire {
  _Wire(this.respond);
  final http.Response Function(http.Request request, int index) respond;
  final requests = <http.Request>[];
  late final TavernModelClient model = TavernModelClient(
    clientFactory: () => MockClient((request) async {
      requests.add(request);
      return respond(request, requests.length - 1);
    }),
  );
}

class _Fixture {
  _Fixture(this.engine, this.characterId, this.chatId);
  final TavernEngine engine;
  final String characterId, chatId;

  static Future<_Fixture> open(TavernModelConfig config, _Wire wire, {bool state = false, bool secrets = false}) async {
    final root = await Directory.systemTemp.createTemp('dsh-custom-channel-');
    final engine = await TavernEngine.openDirectory(
      root,
      config: config,
      modelClient: wire.model,
      clock: () => DateTime.utc(2026, 11, 13),
      random: () => 0.25,
      rollRandom: (_) => 0,
    );
    addTearDown(() async {
      await engine.close();
      await root.delete(recursive: true);
    });
    await engine.setPreset(ChatPreset({...t24Preset().raw, 'stream_openai': false, 'openai_max_context': 16384}));
    final card = _map(jsonDecode(utf8.decode(t24Card())));
    if (state || secrets) _map(card['data'])['extensions'] = _stateExtensions(secrets: secrets);
    final character = await engine.importCard(Uint8List.fromList(utf8.encode(jsonEncode(card))));
    return _Fixture(engine, character.id, await engine.createChat(character.id));
  }
}

_Json _stateExtensions({required bool secrets}) => {
  'dshgo': {
    'v': 1,
    'state': {
      'schema': {
        'type': 'object',
        'additionalProperties': false,
        'required': [
          'count',
          if (secrets) ...['entity', 'private'],
        ],
        'properties': {
          'count': {'type': 'integer', 'minimum': 0, 'maximum': 100, 'default': 0},
          if (secrets) 'entity': {'type': 'string'},
          if (secrets)
            'private': {
              'type': 'object',
              'additionalProperties': false,
              'required': ['fact'],
              'x-dsh-hidden': true,
              'x-dsh-by': ['rules', 'user'],
              'properties': {
                'fact': {
                  'type': ['string', 'null'],
                },
              },
            },
        },
      },
      'init': {
        'count': 0,
        if (secrets) 'entity': 'entity-one',
        if (secrets) 'private': {'fact': null},
      },
      'rules': <Object?>[],
    },
    if (secrets)
      'director': {
        'secretSlots': {
          'v': 1,
          'slots': [
            {
              'id': 'alibi',
              'path': '/private/fact',
              'entityPath': '/entity',
              'unbound': {'exists': true, 'value': null},
              'bindWhen': true,
              'release': {
                'id': 'alibi-release',
                'audience': 'currentCharacter',
                'when': false,
                'template': 'Fact: {{fact}}',
              },
            },
          ],
        },
      },
  },
};
