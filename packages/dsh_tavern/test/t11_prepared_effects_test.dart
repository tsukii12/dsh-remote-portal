import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

// Offline recovery draft. Not compiled or run. Check the new trace keys
// against the final engine before materialising this file in the repository.
// The counter measures UTF-16 content units, not billable model tokens.
void main() {
  late Directory directory;
  late TavernEngine engine;
  late _RecordingModel model;

  Future<TavernEngine> open() => TavernEngine.openDirectory(
    directory,
    config: TavernModelConfig(apiKey: () async => 'fixture', model: 'fixture', deepseek: false),
    modelClient: model,
    counter: const _ContentCounter(),
    clock: () => _at,
    random: () => 0.25,
  );

  Future<void> reopen() async {
    await engine.close();
    engine = await open();
  }

  Future<String> fixture(int capacity, List<Map<String, Object?>> entries, {required String main}) async {
    await engine.setPreset(_preset(capacity, main));
    await engine.putLorebook(_bookId, {
      'entries': {for (final entry in entries) (entry['uid']! as int).toString(): entry},
    });
    await engine.setSettings({
      'lorebooks': {
        'global': [_bookId],
      },
      'worldInfo': {
        'world_info_depth': 100,
        'world_info_budget': 100,
        'world_info_match_whole_words': false,
        'world_info_recursive': false,
      },
    });
    final card = await engine.importCard(_card());
    return engine.createChat(card.id);
  }

  Future<Map<String, Object?>> matchingTrace(String chatId) async {
    final live = engine.inspect(chatId);
    final stored = await engine.inspectTurn(chatId);
    expect(live, isNotNull);
    expect(stored, isNotNull);
    final liveTrace = _map(live!.toJson()['worldInfo']);
    // This equality checks the old inspection serializer as well as the
    // immutable, persisted turn DTO. It must include preparedEffects.
    expect(stored!.worldInfo, liveTrace);
    return _map(stored.worldInfo);
  }

  Future<Map<String, Object?>> timers(String chatId) async {
    final files = await engine.exportChat(chatId);
    final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
    return _map(_map(document.header['chat_metadata'])['timedWorldInfo']);
  }

  Future<Map<String, Object?>> admissions(String chatId) async {
    final files = await engine.exportChat(chatId);
    final document = StChatDocument.decode(files.first.fileName, files.first.bytes);
    return _map(_map(document.header['chat_metadata'])['decoratorState']);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-t11-prepared-effects-');
    model = _RecordingModel();
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    await directory.delete(recursive: true);
  });

  for (final capacity in [10, 100]) {
    test('prepared UI effect survives optional trimming at capacity $capacity and is recorded honestly', () async {
      final chatId = await fixture(capacity, [
        _entry(1, '@@ignore_on_max_context\n@@disable_ui_prompt system_prompt\nWWWWWW{{incvar::seen}}'),
      ], main: 'M{{incvar::ui}}');
      final greetingId = (await engine.path(chatId)).single.nodeId;
      final firstReply = _done(await engine.send(chatId, '').toList());
      final retained = capacity == 100;
      final live = engine.inspect(chatId)!;
      final trace = await matchingTrace(chatId);
      final effect = _effect(trace, '1');
      final body = _bodyText(model.bodies.single);

      expect(effect['contentRetained'], retained);
      expect(_objects(trace['preparedEffects']), hasLength(1));
      expect(engine.variables(chatId)['seen'], 1);
      expect(engine.variables(chatId).containsKey('ui'), isFalse);
      expect(body, contains('HHHHHH'));
      expect(body, isNot(contains('M1')));
      expect(body.contains('WWWWWW1'), retained);
      expect(live.worldInfo.activated.map((hit) => hit.uid), retained ? ['1'] : <String>[]);
      final dropped = live.prompt.excluded.where((item) => item.reason == 'v3-ignore-on-max-context');
      expect(dropped, retained ? isEmpty : isNotEmpty);
      final sticky = _map((await timers(chatId))['sticky']);
      expect(sticky.keys, retained ? ['$_bookId.1'] : <String>[]);
      final expectedAdmissions = retained
          ? <String, Object?>{
              '338842626910292': {'matches': 1, 'lastMessageCount': 1},
            }
          : <String, Object?>{};
      expect(await admissions(chatId), expectedAdmissions);
      expect(engine.variables(chatId)['seen'], 1);
      expect(engine.variables(chatId).containsKey('ui'), isFalse);

      await reopen();
      expect(
        (await engine.inspectTurn(chatId))!.worldInfo,
        trace,
        reason: 'The prepared effect is part of the captured turn, not an in-memory explanation only.',
      );
      expect(engine.variables(chatId)['seen'], 1);
      expect(engine.variables(chatId).containsKey('ui'), isFalse);
      expect(await admissions(chatId), expectedAdmissions);
      expect(engine.variables(chatId)['seen'], 1);
      expect(engine.variables(chatId).containsKey('ui'), isFalse);

      if (!retained) {
        // The discarded entry did not acquire sticky admission. Removing H
        // from the actual greeting makes the next scan miss it completely.
        await engine.edit(chatId, greetingId, 'NO');
        _done(await engine.send(chatId, '').toList());
        final nextTrace = await matchingTrace(chatId);
        expect(_objects(nextTrace['preparedEffects']), isEmpty);
        expect(engine.inspect(chatId)!.worldInfo.activated, isEmpty);
        expect(engine.variables(chatId)['seen'], 1);
        expect(engine.variables(chatId)['ui'], 1);
        expect(_bodyText(model.bodies.last), contains('M1'));
        expect(_bodyText(model.bodies.last), isNot(contains('WWWWWW1')));
        expect(_map((await timers(chatId))['sticky']), isEmpty);
        expect(await admissions(chatId), isEmpty);
        expect(engine.variables(chatId)['seen'], 1);
        expect(engine.variables(chatId)['ui'], 1);
        expect(
          (await engine.inspectTurn(chatId, nodeId: firstReply.nodeId))!.worldInfo,
          trace,
          reason: 'A later turn must not rewrite the earlier prepared-effects record.',
        );
      }
    });
  }

  test('optional and required entries both disable main but only retained content acquires a timer', () async {
    // Actual prompt capacity is 12. H6 + required RR fits; adding optional
    // WWWWWW1 does not. WI's separate scan budget is large enough for both.
    final chatId = await fixture(12, [
      _entry(1, '@@ignore_on_max_context\n@@disable_ui_prompt system_prompt\nWWWWWW{{incvar::seen}}', order: 200),
      _entry(2, '@@disable_ui_prompt system_prompt\nRR', order: 100),
    ], main: 'M{{incvar::ui}}');
    _done(await engine.send(chatId, '').toList());
    final live = engine.inspect(chatId)!;
    final trace = await matchingTrace(chatId);
    expect(_objects(trace['preparedEffects']), hasLength(2));
    expect(_effect(trace, '1')['contentRetained'], isFalse);
    expect(_effect(trace, '2')['contentRetained'], isTrue);
    expect(engine.variables(chatId)['seen'], 1);
    expect(engine.variables(chatId).containsKey('ui'), isFalse);
    final body = _bodyText(model.bodies.single);
    expect(body, contains('HHHHHH'));
    expect(body, contains('RR'));
    expect(body, isNot(contains('WWWWWW1')));
    expect(body, isNot(contains('M1')));
    expect(live.worldInfo.activated.map((hit) => hit.uid), ['2']);
    const expectedAdmissions = <String, Object?>{
      '5687523751103075': {'matches': 1, 'lastMessageCount': 1},
    };
    // The dropped uid 1 has hash 4504743785712552 and must not be admitted.
    expect(await admissions(chatId), expectedAdmissions);
    expect(_map((await timers(chatId))['sticky']).keys, ['$_bookId.2']);
    expect(live.prompt.excluded.where((item) => item.reason == 'v3-ignore-on-max-context'), isNotEmpty);
    expect(engine.variables(chatId)['seen'], 1);
    expect(engine.variables(chatId).containsKey('ui'), isFalse);
    await reopen();
    expect((await engine.inspectTurn(chatId))!.worldInfo, trace);
    expect(_map((await timers(chatId))['sticky']).keys, ['$_bookId.2']);
    expect(await admissions(chatId), expectedAdmissions);
    expect(engine.variables(chatId)['seen'], 1);
    expect(engine.variables(chatId).containsKey('ui'), isFalse);
  });

  test('outlet role and optional-trim decorators remain unapplied without changing the host prompt', () async {
    // HOST=OUTLET is 11 content units and is mandatory. With capacity 13,
    // the six-unit history is dropped; the outlet is not a standalone
    // optional/user message and must not acquire a fake trim exclusion.
    final chatId = await fixture(13, [
      _entry(1, '@@role user\n@@ignore_on_max_context\nOUTLET', position: 7, outlet: 'slot'),
    ], main: 'HOST={{outlet::slot}}');
    _done(await engine.send(chatId, '').toList());
    final live = engine.inspect(chatId)!;
    final trace = await matchingTrace(chatId);
    final messages = _messages(model.bodies.single);
    final host = messages.singleWhere((message) => message['content'] == 'HOST=OUTLET');
    expect(host['role'], 'system');
    expect(messages.where((message) => message['content'] == 'OUTLET'), isEmpty);
    expect(_bodyText(model.bodies.single), isNot(contains('HHHHHH')));
    expect(live.prompt.excluded.where((item) => item.reason == 'history-budget'), isNotEmpty);
    expect(live.prompt.excluded.where((item) => item.reason == 'v3-ignore-on-max-context'), isEmpty);
    expect(live.worldInfo.activated, hasLength(1));
    expect(live.worldInfo.activated.single.uid, '1');
    expect(live.worldInfo.activated.single.position, 7);
    expect(live.worldInfo.activated.single.section, isNull);
    final hit = _objects(trace['activated']).singleWhere((item) => item['uid'] == '1');
    expect(hit['unappliedDecorators'], unorderedEquals(['role', 'ignore_on_max_context']));
    expect(_objects(trace['preparedEffects']), isEmpty);
    const expectedAdmissions = <String, Object?>{
      '2131418939926495': {'matches': 1, 'lastMessageCount': 1},
    };
    expect(await admissions(chatId), expectedAdmissions);
    expect(_map((await timers(chatId))['sticky']).keys, ['$_bookId.1']);
    await reopen();
    expect((await engine.inspectTurn(chatId))!.worldInfo, trace);
    expect(await admissions(chatId), expectedAdmissions);
  });
}

const _bookId = 'prepared-effects';
final _at = DateTime.utc(2026, 11, 10, 12);

Map<String, Object?> _map(Object? value) =>
    value is Map<String, Object?> ? jsonDecode(jsonEncode(value)) as Map<String, Object?> : {};

List<Map<String, Object?>> _objects(Object? value) {
  expect(value, isA<List<Object?>>());
  return (value! as List<Object?>).map(_map).toList();
}

Map<String, Object?> _effect(Map<String, Object?> trace, String uid) {
  final result = _objects(
    trace['preparedEffects'],
  ).singleWhere((item) => _map(_map(item['source'])['details'])['uid'] == uid);
  expect(result['kind'], 'disable_ui_prompt');
  expect(result['prompt'], 'system_prompt');
  expect(result['stage'], 'before-assembly');
  final source = _map(result['source']);
  expect(source['kind'], 'worldInfo');
  expect(source['id'], '$_bookId:$uid');
  expect(_map(source['details'])['bookId'], _bookId);
  expect(_map(source['details'])['source'], 'global');
  return result;
}

Map<String, Object?> _entry(int uid, String content, {int order = 100, int position = 0, String? outlet}) => {
  'uid': uid,
  'key': ['H'],
  'keysecondary': <String>[],
  'content': content,
  'constant': false,
  'disable': false,
  'order': order,
  'position': position,
  'role': 0,
  'outletName': ?outlet,
  'sticky': 3,
  'matchWholeWords': false,
  'caseSensitive': false,
};

ChatPreset _preset(int capacity, String main) {
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
    'openai_max_context': capacity + 3,
    'openai_max_tokens': 0,
    'stream_openai': true,
    'names_behavior': 0,
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
          'content': id == 'main' ? main : '',
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
        'first_mes': 'HHHHHH',
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

List<Map<String, Object?>> _messages(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).cast<Map<String, Object?>>();

String _bodyText(Map<String, Object?> body) => _messages(body).map((message) => message['content']).join('\n');

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

final class _ContentCounter implements PromptTokenCounter {
  const _ContentCounter();
  @override
  String get name => 'test UTF-16 content units; not model tokens';
  @override
  bool get exact => false;
  @override
  int countMessage(Map<String, Object?> message) => (message['content'] as String? ?? '').length;
  @override
  int countText(String text) => text.length;
}

class _RecordingModel extends TavernModelClient {
  final bodies = <Map<String, Object?>>[];
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) {
    bodies.add(_map(body));
    return Stream<ModelDelta>.fromIterable([const ModelText('R'), const ModelFinished('stop')]);
  }
}
