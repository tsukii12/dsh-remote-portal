import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

// Offline recovery draft: not compiled, formatted, or run. The proposed gate
// belongs to the facade; every fixture below goes through the real T4 HTTP
// client, JSON/SSE decoder, generation lifecycle, and SQLite store.
void main() {
  for (final thinking in [false, true]) {
    for (final stream in [true, false]) {
      test('DeepSeek thinking=$thinking stream=$stream gates fresh reasoning without dropping body or usage', () async {
        final h = await _open(deepseek: true, thinking: thinking, stream: stream);
        addTearDown(h.close);
        final chatId = await _freshChat(h.engine);
        await h.engine.setSettings({
          'globalRegexScripts': [_reasoningScript()],
        });
        h.wire.success(stream: stream, text: 'BODY', reasoning: 'NEW');
        final events = await h.engine.send(chatId, 'QUESTION').toList();
        final done = _done(events);

        expect(h.wire.requests, hasLength(1));
        expect(h.wire.requests.single['stream'], stream);
        expect(_map(h.wire.requests.single['thinking'])['type'], thinking ? 'enabled' : 'disabled');
        expect(events.whereType<TavernTextDelta>().map((event) => event.text).join(), 'BODY');
        expect(events.whereType<TavernReasoningDelta>().map((event) => event.text).join(), thinking ? 'NEW' : '');
        expect(events.whereType<TavernReasoningDelta>(), hasLength(thinking ? 1 : 0));
        expect(done.text, 'BODY');
        expect(done.reasoning ?? '', thinking ? '1|NEW' : '');
        _expectUsage(done.usage);
        if (thinking) {
          expect(h.engine.variables(chatId)['reasoningWrites'], 1);
        } else {
          expect(h.engine.variables(chatId).containsKey('reasoningWrites'), isFalse);
        }
        final path = await h.engine.path(chatId);
        expect(path.map((message) => message.text), ['G', 'QUESTION', 'BODY']);
        expect(path.last.reasoning ?? '', thinking ? '1|NEW' : '');
        _expectUsage(path.last.usage);

        await h.reopen();
        final stored = (await h.engine.path(chatId)).last;
        expect(stored.text, 'BODY');
        expect(stored.reasoning ?? '', thinking ? '1|NEW' : '');
        _expectUsage(stored.usage);
        expect(h.engine.variables(chatId).containsKey('reasoningWrites'), thinking);
        if (thinking) {
          expect(h.engine.variables(chatId)['reasoningWrites'], 1);
        }
      });
    }
  }

  test('disabled fresh reasoning followed by a socket failure is not partial output and rolls back the user', () async {
    final h = await _open(deepseek: true, thinking: false, stream: true);
    addTearDown(h.close);
    final chatId = await _freshChat(h.engine);
    await h.engine.setSettings({
      'globalRegexScripts': [_reasoningScript()],
    });
    final before = await h.engine.path(chatId);
    final beforeIds = before.map((message) => message.nodeId).toList();
    final beforeVariables = h.engine.variables(chatId);
    h.wire.reasoningThenSocketFailure();
    final events = await h.engine.send(chatId, 'QUESTION_TO_ROLL_BACK').toList();

    expect(events.whereType<TavernTextDelta>(), isEmpty);
    expect(events.whereType<TavernReasoningDelta>(), isEmpty);
    expect(events.whereType<TavernTurnDone>(), isEmpty);
    final failure = events.whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.network);
    expect(failure.partial, isNull);
    final after = await h.engine.path(chatId);
    expect(after.map((message) => message.nodeId), beforeIds);
    expect(after.map((message) => message.text), before.map((message) => message.text));
    expect(h.engine.variables(chatId), beforeVariables);
    expect(h.engine.variables(chatId).containsKey('reasoningWrites'), isFalse);
    expect(h.wire.requests, hasLength(1));
    expect(_map(h.wire.requests.single['thinking'])['type'], 'disabled');

    // The server fixture contains one reasoning SSE event and then throws:
    // there are no content, usage, finish_reason, or [DONE] packets.
    final files = await h.engine.exportChat(chatId);
    final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
    expect(document.messages.map((row) => row['mes']), ['G']);
    await h.reopen();
    expect((await h.engine.path(chatId)).map((message) => message.nodeId), beforeIds);
    expect(h.engine.variables(chatId), beforeVariables);
  });

  for (final oldBody in ['PREVIOUS', '']) {
    test('disabled continue preserves OLD reasoning and prefix with old body "$oldBody"', () async {
      final h = await _open(deepseek: true, thinking: false, stream: true);
      addTearDown(h.close);
      // Deliberately no reasoning regex in these cases: this verifies history
      // preservation, independently of the fresh-reply placement-6 tests.
      await h.engine.setSettings({
        'reasoning': {'add_to_prompts': false},
      });
      final chatId = await _continuationChat(h.engine, oldBody);
      final before = await h.engine.path(chatId);
      final target = before.last;
      expect(target.reasoning, 'OLD');
      h.wire.success(stream: true, text: 'TAIL', reasoning: 'NEW');
      final events = await h.engine.continueReply(chatId, target.nodeId).toList();
      final done = _done(events);

      final request = h.wire.requests.single;
      expect(_map(request['thinking'])['type'], 'disabled');
      final prefix = _messages(request).last;
      expect(prefix['role'], 'assistant');
      expect(prefix['prefix'], isTrue);
      expect(prefix['content'], isA<String>());
      expect(prefix['content']! as String, contains('OLD'));
      if (oldBody.isNotEmpty) {
        expect(prefix['content']! as String, contains(oldBody));
      }
      expect(events.whereType<TavernReasoningDelta>(), isEmpty);
      expect(events.whereType<TavernTextDelta>().map((event) => event.text).join(), 'TAIL');
      expect(done.nodeId, target.nodeId);
      // The fixture explicitly configures an empty continue_postfix so this
      // assertion does not depend on ordinary-space/newline postfix rules.
      expect(done.text, '${oldBody}TAIL');
      expect(done.reasoning, 'OLD');
      _expectUsage(done.usage);
      final after = await h.engine.path(chatId);
      expect(after.map((message) => message.nodeId), before.map((message) => message.nodeId));
      expect(after.last.reasoning, 'OLD');
      expect(h.engine.variables(chatId)['prior'], 7);
      await h.reopen();
      final stored = (await h.engine.path(chatId)).last;
      expect(stored.nodeId, target.nodeId);
      expect(stored.text, '${oldBody}TAIL');
      expect(stored.reasoning, 'OLD');
    });
  }

  test('generic thinking=false still accepts new provider reasoning and its placement-6 write-back', () async {
    final h = await _open(deepseek: false, thinking: false, stream: true);
    addTearDown(h.close);
    final chatId = await _freshChat(h.engine);
    await h.engine.setSettings({
      'globalRegexScripts': [_reasoningScript()],
    });
    h.wire.success(stream: true, text: 'BODY', reasoning: 'NEW');
    final events = await h.engine.send(chatId, 'QUESTION').toList();
    final done = _done(events);
    expect(h.wire.requests.single.containsKey('thinking'), isFalse);
    expect(events.whereType<TavernReasoningDelta>().map((event) => event.text).join(), 'NEW');
    expect(events.whereType<TavernReasoningDelta>(), hasLength(1));
    expect(done.text, 'BODY');
    expect(done.reasoning, '1|NEW');
    expect(h.engine.variables(chatId)['reasoningWrites'], 1);
    _expectUsage(done.usage);
    await h.reopen();
    expect((await h.engine.path(chatId)).last.reasoning, '1|NEW');
    expect(h.engine.variables(chatId)['reasoningWrites'], 1);
  });
}

const _model = 'fixture-model';
final _at = DateTime.utc(2026, 11, 10, 12);
const _reportedUsage = <String, Object?>{
  'prompt_tokens': 7,
  'completion_tokens': 3,
  'total_tokens': 10,
  'prompt_cache_hit_tokens': 2,
};

Future<_Harness> _open({required bool deepseek, required bool thinking, required bool stream}) async {
  final directory = await Directory.systemTemp.createTemp('dsh-t11-reasoning-gate-');
  final wire = _Wire();
  final config = TavernModelConfig(
    apiKey: () async => 'fixture-key',
    model: _model,
    deepseek: deepseek,
    thinking: thinking,
  );
  final engine = await TavernEngine.openDirectory(
    directory,
    config: config,
    modelClient: TavernModelClient(clientFactory: wire.client),
    clock: () => _at,
    random: () => 0.25,
  );
  final h = _Harness(directory, config, wire, engine);
  await engine.setPreset(_preset(stream));
  return h;
}

class _Harness {
  _Harness(this.directory, this.config, this.wire, this.engine);
  final Directory directory;
  final TavernModelConfig config;
  final _Wire wire;
  TavernEngine engine;

  Future<void> reopen() async {
    await engine.close();
    engine = await TavernEngine.openDirectory(
      directory,
      config: config,
      modelClient: TavernModelClient(clientFactory: wire.client),
      clock: () => _at,
      random: () => 0.25,
    );
  }

  Future<void> close() async {
    await engine.close();
    await directory.delete(recursive: true);
  }
}

Future<String> _freshChat(TavernEngine engine) async {
  final card = await engine.importCard(_card());
  return engine.createChat(card.id);
}

Future<String> _continuationChat(TavernEngine engine, String oldBody) async {
  final card = await engine.importCard(_card());
  final document = StChatDocument(
    fileName: 'continue.jsonl',
    header: {
      'user_name': 'unused',
      'character_name': 'unused',
      'chat_metadata': {
        'variables': {'prior': 7},
      },
    },
    messages: [
      _row('ASK', user: true),
      _row(oldBody, reasoning: 'OLD'),
    ],
  );
  return (await engine.importChats(card.id, [
    TavernChatFile(fileName: document.fileName, bytes: document.encode()),
  ])).chatIds.single;
}

Map<String, Object?> _row(String text, {bool user = false, String? reasoning}) => {
  'name': user ? 'User' : 'Guide',
  'is_user': user,
  'is_system': false,
  'send_date': _at.toIso8601String(),
  'mes': text,
  'extra': {'reasoning': ?reasoning},
};

Map<String, Object?> _reasoningScript() => {
  'id': 'reasoning-write',
  'scriptName': 'reasoning-write',
  'findRegex': r'^([\s\S]+)$',
  'replaceString': r'{{incvar::reasoningWrites}}|$1',
  'placement': [6],
  'trimStrings': <String>[],
  'disabled': false,
  'markdownOnly': false,
  'promptOnly': false,
  'runOnEdit': false,
  'substituteRegex': 0,
  'minDepth': null,
  'maxDepth': null,
};

ChatPreset _preset(bool stream) {
  const identifiers = [
    'worldInfoBefore',
    'main',
    'worldInfoAfter',
    'charDescription',
    'charPersonality',
    'scenario',
    'personaDescription',
    'dialogueExamples',
    'chatHistory',
    'jailbreak',
  ];
  return ChatPreset({
    'openai_max_context': 4096,
    'openai_max_tokens': 256,
    'stream_openai': stream,
    'names_behavior': 0,
    'continue_prefill': true,
    'continue_postfix': '',
    'new_chat_prompt': '',
    'new_group_chat_prompt': '',
    'new_example_chat_prompt': '',
    'continue_nudge_prompt': '',
    'group_nudge_prompt': '',
    'send_if_empty': '',
    'wi_format': '{0}',
    'personality_format': '{0}',
    'scenario_format': '{0}',
    'prompts': [
      for (final id in identifiers)
        {
          'identifier': id,
          'name': id,
          'role': 'system',
          'system_prompt': id == 'main' || id == 'jailbreak',
          'marker': id != 'main' && id != 'jailbreak',
          'content': '',
        },
    ],
    'prompt_order': [
      {
        'character_id': 100001,
        'order': [
          for (final id in identifiers) {'identifier': id, 'enabled': true},
        ],
      },
    ],
  });
}

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Guide',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'G',
        'mes_example': '',
        'creator_notes': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'alternate_greetings': <String>[],
        'tags': <String>[],
        'creator': '',
        'character_version': '',
        'extensions': <String, Object?>{},
      },
    }),
  ),
);

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};
List<Map<String, Object?>> _messages(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).cast<Map<String, Object?>>();

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

void _expectUsage(TavernUsage? usage) {
  expect(usage, isNotNull);
  expect(usage!.promptTokens, 7);
  expect(usage.completionTokens, 3);
  expect(usage.cacheHitTokens, 2);
  expect(usage.model, _model);
}

class _Wire {
  final requests = <Map<String, Object?>>[];
  final _plans = <({String contentType, Stream<List<int>> Function() body})>[];

  http.Client client() => _WireClient(this);

  void success({required bool stream, required String text, required String reasoning}) {
    if (stream) {
      _plans.add((contentType: 'text/event-stream', body: () => _successSse(text, reasoning)));
    } else {
      _plans.add((
        contentType: 'application/json; charset=utf-8',
        body: () => Stream<List<int>>.fromIterable([
          utf8.encode(
            jsonEncode({
              'model': _model,
              'choices': [
                {
                  'index': 0,
                  'message': {'role': 'assistant', 'content': text, 'reasoning_content': reasoning},
                  'finish_reason': 'stop',
                },
              ],
              'usage': _reportedUsage,
            }),
          ),
        ]),
      ));
    }
  }

  void reasoningThenSocketFailure() {
    _plans.add((contentType: 'text/event-stream', body: _reasoningThenSocketFailure));
  }

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final bytes = await request.finalize().toBytes();
    requests.add(jsonDecode(utf8.decode(bytes)) as Map<String, Object?>);
    if (_plans.isEmpty) {
      throw StateError('Unexpected HTTP request in fixture.');
    }
    final plan = _plans.removeAt(0);
    return http.StreamedResponse(plan.body(), 200, headers: {'content-type': plan.contentType});
  }
}

class _WireClient extends http.BaseClient {
  _WireClient(this.wire);
  final _Wire wire;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => wire.send(request);
  @override
  void close() {}
}

List<int> _sse(Map<String, Object?> packet) => utf8.encode('data: ${jsonEncode(packet)}\n\n');

Stream<List<int>> _successSse(String text, String reasoning) async* {
  yield _sse({
    'model': _model,
    'choices': [
      {
        'index': 0,
        'delta': {'reasoning_content': reasoning},
      },
    ],
  });
  yield _sse({
    'model': _model,
    'choices': [
      {
        'index': 0,
        'delta': {'content': text},
      },
    ],
  });
  yield _sse({
    'model': _model,
    'choices': [
      {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': 'stop'},
    ],
    'usage': _reportedUsage,
  });
  yield utf8.encode('data: [DONE]\n\n');
}

Stream<List<int>> _reasoningThenSocketFailure() async* {
  yield _sse({
    'model': _model,
    'choices': [
      {
        'index': 0,
        'delta': {'reasoning_content': 'NEW'},
      },
    ],
  });
  throw const SocketException('Synthetic disconnect after reasoning only.');
}
