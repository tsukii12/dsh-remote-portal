import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TavernEngine engine;
  late _Model model;
  late DateTime now;
  final importedAt = DateTime.utc(2026, 11, 10, 12);
  final editedAt = DateTime.utc(2026, 11, 11, 3, 4, 5, 678);

  Future<TavernEngine> open() => TavernEngine.open(
    directory,
    config: TavernModelConfig(
      apiKey: () async => 'fake-key',
      baseUrl: 'https://example.invalid/v1',
      model: 'fake-model',
      deepseek: false,
    ),
    modelClient: model.client,
    clock: () => now,
    random: () => 0.25,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-tavern-edit-engine-');
    model = _Model();
    now = importedAt;
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    model.dispose();
    await directory.delete(recursive: true);
  });

  test('Tavern exposes detached full fields, saves a partial patch and reloads it', () async {
    final Tavern tavern = engine;
    final card = await tavern.importCard(_card());
    final original = (await tavern.characterFields(card.id))!;
    expect(original['extensions'], {
      'otherApp': {'literal': r'{{x}} $1 🐋'},
    });
    final form = (await tavern.characterFields(card.id))!;
    (form['extensions']! as Map<String, Object?>).clear();
    form['scenario'] = 'not saved';
    expect(await tavern.characterFields(card.id), original);
    now = editedAt;
    final changed = await tavern.updateCharacterFields(card.id, {'name': 'edited', 'description': 'new description'});
    expect(changed.name, 'edited');
    expect(changed.description, 'new description');
    expect(changed.importedAt, importedAt);
    final expected = <String, Object?>{
      ...original,
      'name': 'edited',
      'description': 'new description',
      'modification_date': editedAt.millisecondsSinceEpoch ~/ 1000,
    };
    expect(await tavern.characterFields(card.id), expected);
    await engine.close();
    engine = await open();
    expect(await engine.characterFields(card.id), expected);
    expect((await engine.character(card.id))!.name, 'edited');
  });

  test('saving refreshes cached summaries and greetings without rewriting existing chats', () async {
    final card = await engine.importCard(_card());
    final oldChat = await engine.createChat(card.id);
    final oldMessage = (await engine.path(oldChat)).single;
    final oldSummary = (await engine.watchChats().first).single;
    expect((await engine.character(card.id))!.chatCount, 1);
    final initial = Completer<void>();
    final edited = Completer<List<TavernCharacter>>();
    final subscription = engine.watchCharacters().listen((value) {
      if (!initial.isCompleted) initial.complete();
      if (value.single.name == 'New name' && !edited.isCompleted) edited.complete(value);
    });
    try {
      await initial.future;
      now = editedAt;
      final updated = await engine.updateCharacterFields(card.id, {
        'name': 'New name',
        'nickname': 'New nickname',
        'tags': ['new'],
        'first_mes': '{{char}}: new greeting',
        'alternate_greetings': ['{{char}}: alternate'],
      });
      expect(updated.chatCount, 1);
      expect(updated.lastChatAt, oldSummary.updatedAt);
      final emitted = (await edited.future.timeout(const Duration(seconds: 3))).single;
      expect(emitted.greetings, isEmpty);
      expect(emitted.tags, ['new']);
      final detail = (await engine.character(card.id))!;
      expect(detail.nickname, 'New nickname');
      expect(detail.greetings, ['{{char}}: new greeting', '{{char}}: alternate']);
      final unchanged = (await engine.path(oldChat)).single;
      expect(unchanged.text, oldMessage.text);
      expect(unchanged.speaker, oldMessage.speaker);
      expect((await engine.watchChats().first).single.title, oldSummary.title);
      final firstChat = await engine.createChat(card.id);
      final alternateChat = await engine.createChat(card.id, greeting: 1);
      expect((await engine.path(firstChat)).single.text, 'New nickname: new greeting');
      expect((await engine.path(alternateChat)).single.text, 'New nickname: alternate');
      await engine.updateCharacterFields(card.id, {'nickname': ''});
      final withoutNickname = await engine.createChat(card.id);
      expect((await engine.path(withoutNickname)).single.speaker, 'New name');
      expect((await engine.path(withoutNickname)).single.text, 'New name: new greeting');
    } finally {
      await subscription.cancel();
    }
  });

  test('an active request keeps its card snapshot and the next turn reads the saved fields', () async {
    final card = await engine.importCard(_card());
    final chatId = await engine.createChat(card.id);
    final held = model.holdNext();
    final running = engine.send(chatId, 'first question').toList();
    await held.requested.future;
    expect(_requestText(model.requests.single), contains('OLD_DESCRIPTION'));
    await engine.updateCharacterFields(card.id, {
      'nickname': 'new speaker',
      'description': 'NEW_DESCRIPTION',
      'personality': 'NEW_PERSONALITY',
      'scenario': 'NEW_SCENARIO',
    });
    held.complete('old turn result');
    final oldReply = _done(await running);
    expect(oldReply.speaker, 'Old nickname');
    expect(oldReply.text, 'old turn result');
    final nextReply = _done(await engine.send(chatId, 'next question').toList());
    expect(nextReply.speaker, 'new speaker');
    final request = _requestText(model.requests.last);
    expect(request, contains('NEW_DESCRIPTION'));
    expect(request, contains('NEW_PERSONALITY'));
    expect(request, contains('NEW_SCENARIO'));
    expect(request, isNot(contains('OLD_DESCRIPTION')));
    expect((await engine.path(chatId))[2].speaker, 'Old nickname');
  });

  test('queued patches snapshot their form values and a following read sees both edits', () async {
    final card = await engine.importCard(_card());
    final tags = ['accepted'];
    final form = <String, Object?>{'description': 'first patch', 'tags': tags};
    final first = engine.updateCharacterFields(card.id, form);
    form['description'] = 'late mutation';
    tags.add('late tag');
    final second = engine.updateCharacterFields(card.id, {'name': 'second patch'});
    final afterBoth = engine.characterFields(card.id);
    await Future.wait([first, second]);
    final fields = (await afterBoth)!;
    expect(fields['description'], 'first patch');
    expect(fields['tags'], ['accepted']);
    expect(fields['name'], 'second patch');
  });

  test('an accepted save followed by character deletion cannot resurrect files or chats', () async {
    final card = await engine.importCard(_card());
    await engine.createChat(card.id);
    final saving = engine.updateCharacterFields(card.id, {'name': 'saved before deletion'});
    final deleting = engine.deleteCharacter(card.id);
    await saving;
    await deleting;
    expect(await engine.characterFields(card.id), isNull);
    expect(await engine.character(card.id), isNull);
    expect(await engine.watchChats().first, isEmpty);
    expect(await Directory('${engine.directory.path}/characters/${card.id}').exists(), false);
    await expectLater(
      engine.updateCharacterFields(card.id, {'name': 'cannot return'}),
      throwsA(isA<TavernImportError>()),
    );
  });

  test('close waits for an accepted edit before closing the database and files', () async {
    final card = await engine.importCard(_card());
    final saving = engine.updateCharacterFields(card.id, {'description': 'saved before close'});
    final closing = engine.close();
    expect((await saving).description, 'saved before close');
    await closing;
    engine = await open();
    expect((await engine.characterFields(card.id))!['description'], 'saved before close');
  });

  test('reading and saving raw macro fields has no generation side effects; invalid patches remain errors', () async {
    final card = await engine.importCard(_card());
    final chatId = await engine.createChat(card.id);
    await engine.updateCharacterFields(card.id, {'personality': '{{incvar::readEffect}}'});
    expect((await engine.characterFields(card.id))!['personality'], '{{incvar::readEffect}}');
    await engine.characterFields(card.id);
    expect(engine.variables(chatId).containsKey('readEffect'), false);
    expect(model.requests, isEmpty);
    await expectLater(engine.updateCharacterFields(card.id, {'nickname': null}), throwsArgumentError);
    await expectLater(engine.updateCharacterFields(card.id, {'extensions': <String, Object?>{}}), throwsArgumentError);
    expect((await engine.characterFields(card.id))!['nickname'], 'Old nickname');
    expect((await engine.characterFields(card.id))!['extensions'], {
      'otherApp': {'literal': r'{{x}} $1 🐋'},
    });
  });
}

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'unknown_root': {'retained': true},
      'data': {
        'name': 'Old name',
        'nickname': 'Old nickname',
        'description': 'OLD_DESCRIPTION',
        'personality': 'OLD_PERSONALITY',
        'scenario': 'OLD_SCENARIO',
        'first_mes': '{{char}}: old greeting',
        'alternate_greetings': ['old alternate'],
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': '',
        'tags': [],
        'extensions': {
          'otherApp': {'literal': r'{{x}} $1 🐋'},
        },
      },
    }),
  ),
);

TavernMessage _done(List<TavernEvent> events) {
  expect(events.whereType<TavernTurnFailed>(), isEmpty);
  return events.whereType<TavernTurnDone>().single.message;
}

String _requestText(Map<String, Object?> body) =>
    (body['messages']! as List<Object?>).cast<Map<String, Object?>>().map((message) => message['content']).join('\n');

class _Model {
  final requests = <Map<String, Object?>>[];
  final _held = <_HeldReply>[];
  _HeldReply? _next;

  TavernModelClient get client => TavernModelClient(
    clientFactory: () => MockClient((request) async {
      requests.add(jsonDecode(request.body) as Map<String, Object?>);
      final pending = _next;
      _next = null;
      if (pending != null) {
        pending.requested.complete();
        return pending.response.future;
      }
      return _response('generated reply');
    }),
  );

  _HeldReply holdNext() {
    final reply = _HeldReply();
    _held.add(reply);
    _next = reply;
    return reply;
  }

  void dispose() {
    for (final reply in _held) {
      if (!reply.response.isCompleted) reply.complete('disposed');
    }
  }
}

class _HeldReply {
  final requested = Completer<void>();
  final response = Completer<http.Response>();
  void complete(String text) => response.complete(_response(text));
}

http.Response _response(String text) {
  final data = jsonEncode({
    'choices': [
      {
        'index': 0,
        'delta': {'content': text},
        'finish_reason': 'stop',
      },
    ],
  });
  return http.Response(
    'data: $data\n\ndata: [DONE]\n\n',
    200,
    headers: {'content-type': 'text/event-stream; charset=utf-8'},
  );
}
