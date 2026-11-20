import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late TavernEngine engine;
  late _Transport transport;
  final now = DateTime.utc(2026, 11, 11, 9);

  Future<TavernEngine> open() => TavernEngine.open(
    directory,
    config: TavernModelConfig(
      apiKey: () async => 'fake-key',
      baseUrl: 'https://example.invalid/v1',
      model: 'fake-model',
      deepseek: false,
    ),
    modelClient: transport.client,
    clock: () => now,
    random: () => 0.25,
  );
  Future<String> chat() async {
    final card = await engine.importCard(_card());
    return engine.createChat(card.id);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-tavern-persona-engine-');
    transport = _Transport();
    engine = await open();
  });
  tearDown(() async {
    await engine.close();
    transport.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'Tavern persona CRUD and default feed greeting, user text, speaker and prompt without changing old settings',
    () async {
      final Tavern tavern = engine;
      expect(await tavern.watchPersonas().first, isEmpty);
      await engine.setSettings({'userName': 'Legacy', 'persona': 'LEGACY_DESCRIPTION'});
      final first = await tavern.createPersona(
        name: 'First',
        description: 'FIRST_DESCRIPTION',
        avatarPath: '/caller/a.png',
      );
      await tavern.setDefaultPersona(first.id);
      final chatId = await chat();
      expect((await tavern.path(chatId)).single.text, 'Hello First');
      final initialSelection = await tavern.personaSelection(chatId: chatId);
      expect(initialSelection.boundPersonaId, isNull);
      expect(initialSelection.source, PersonaSelectionSource.globalDefault);
      expect(initialSelection.defaultPersonaId, first.id);
      _done(await tavern.send(chatId, '{{user}} speaks').toList());
      final user = (await tavern.path(chatId))[1];
      expect(user.speaker, 'First');
      expect(user.text, 'First speaks');
      expect(_requestText(transport.requests.last), contains('FIRST_DESCRIPTION'));
      expect(_requestText(transport.requests.last), isNot(contains('LEGACY_DESCRIPTION')));
      final second = await tavern.createPersona(name: 'Second', description: 'SECOND_DESCRIPTION');
      await tavern.setDefaultPersona(second.id);
      _done(await tavern.send(chatId, '{{user}} now').toList());
      final path = await tavern.path(chatId);
      expect(path.first.text, 'Hello First');
      expect(path[1].speaker, 'First');
      expect(path[3].speaker, 'Second');
      expect(path[3].text, 'Second now');
      expect(_requestText(transport.requests.last), contains('SECOND_DESCRIPTION'));
      final updated = await tavern.updatePersona(first.id, name: 'Renamed', clearAvatar: true);
      expect(updated.description, 'FIRST_DESCRIPTION');
      expect(updated.avatarPath, isNull);
      expect((await tavern.persona(first.id))!.name, 'Renamed');
      expect(engine.settings()['userName'], 'Legacy');
      expect(engine.settings()['persona'], 'LEGACY_DESCRIPTION');
      await tavern.setDefaultPersona(null);
      expect((await tavern.personaSelection()).persona, isNull);
      _done(await tavern.send(chatId, '{{user}} fallback').toList());
      expect((await tavern.path(chatId))[5].speaker, 'Legacy');
      expect(_requestText(transport.requests.last), contains('LEGACY_DESCRIPTION'));
    },
  );

  test('chat binding wins over default, unbinding inherits, and both persist on reopen', () async {
    final defaultPersona = await engine.createPersona(name: 'Default', description: 'DEFAULT_PROFILE');
    final boundPersona = await engine.createPersona(name: 'Bound', description: 'BOUND_PROFILE');
    await engine.setDefaultPersona(defaultPersona.id);
    final a = await chat();
    final b = await chat();
    await engine.bindPersona(a, boundPersona.id);
    expect((await engine.personaSelection(chatId: a)).source, PersonaSelectionSource.chat);
    _done(await engine.send(a, '{{user}} A').toList());
    expect((await engine.path(a))[1].speaker, 'Bound');
    expect(_requestText(transport.requests.last), contains('BOUND_PROFILE'));
    _done(await engine.send(b, '{{user}} B').toList());
    expect((await engine.path(b))[1].speaker, 'Default');
    expect(_requestText(transport.requests.last), contains('DEFAULT_PROFILE'));
    await engine.close();
    engine = await open();
    expect((await engine.personaSelection()).defaultPersonaId, defaultPersona.id);
    expect((await engine.personaSelection(chatId: a)).boundPersonaId, boundPersona.id);
    await engine.bindPersona(a, null);
    final inherited = await engine.personaSelection(chatId: a);
    expect(inherited.persona!.id, defaultPersona.id);
    expect(inherited.boundPersonaId, isNull);
    expect(inherited.source, PersonaSelectionSource.globalDefault);
    expect((await engine.path(a))[1].speaker, 'Bound');
  });

  test('only IN_PROMPT injects a persona marker; other positions remain stored and old 1 migrates to 0', () async {
    final profile = await engine.createPersona(
      name: 'Positioned',
      description: 'PROFILE_MARKER_TEXT',
      descriptionPosition: PersonaDescriptionPosition.none,
    );
    await engine.setDefaultPersona(profile.id);
    final chatId = await chat();
    for (final position in [2, 3, 4, 9]) {
      await engine.updatePersona(profile.id, descriptionPosition: position);
      _done(await engine.send(chatId, 'plain question').toList());
      expect(_requestText(transport.requests.last), isNot(contains('PROFILE_MARKER_TEXT')));
      expect((await engine.persona(profile.id))!.descriptionPosition, position);
      expect(
        (await engine.path(chatId)).where((message) => message.role == TavernRole.user).last.speaker,
        'Positioned',
      );
    }
    final migrated = await engine.updatePersona(profile.id, descriptionPosition: 1);
    expect(migrated.descriptionPosition, PersonaDescriptionPosition.inPrompt);
    _done(await engine.send(chatId, 'marker enabled').toList());
    expect(_requestText(transport.requests.last), contains('PROFILE_MARKER_TEXT'));
  });

  test('raw persona macros expand once for eager WI fields and separately for the prompt marker', () async {
    const raw = '  P={{incvar::n}}; {{user}}  ';
    final profile = await engine.createPersona(name: 'Macro user', description: raw);
    await engine.setDefaultPersona(profile.id);
    final chatId = await chat();
    expect(engine.variables(chatId).containsKey('n'), false);
    expect((await engine.persona(profile.id))!.description, raw);
    _done(await engine.send(chatId, 'question').toList());
    expect(engine.variables(chatId)['n'], 2);
    expect(_requestText(transport.requests.last), contains('P=2; Macro user'));
    expect(_requestText(transport.requests.last), isNot(contains('P=1;')));
    engine.inspect(chatId);
    await engine.personaSelection(chatId: chatId);
    expect(engine.variables(chatId)['n'], 2);
    expect((await engine.persona(profile.id))!.description, raw);
  });

  test(
    'a turn captures its profile before asynchronous work; edits and default changes affect the next turn',
    () async {
      final first = await engine.createPersona(name: 'Captured', description: 'CAPTURED_DESCRIPTION');
      final next = await engine.createPersona(name: 'Next', description: 'NEXT_DESCRIPTION');
      await engine.setDefaultPersona(first.id);
      final chatId = await chat();
      final pending = transport.pending();
      final running = engine.send(chatId, '{{user}} says hello').toList();
      await engine.updatePersona(first.id, name: 'Edited during turn', description: 'EDITED_DESCRIPTION');
      await engine.setDefaultPersona(next.id);
      await pending.connected.future;
      expect(_requestText(transport.requests.single), contains('CAPTURED_DESCRIPTION'));
      expect(_requestText(transport.requests.single), isNot(contains('EDITED_DESCRIPTION')));
      pending.text('answer before switch');
      pending.finish();
      _done(await running);
      expect((await engine.path(chatId))[1].speaker, 'Captured');
      expect((await engine.path(chatId))[1].text, 'Captured says hello');
      _done(await engine.send(chatId, '{{user}} goes next').toList());
      expect((await engine.path(chatId))[3].speaker, 'Next');
      expect(_requestText(transport.requests.last), contains('NEXT_DESCRIPTION'));
      expect((await engine.persona(first.id))!.name, 'Edited during turn');
    },
  );

  test('binding cancels a partial turn, keeps old speakers and ignores late chunks', () async {
    final first = await engine.createPersona(name: 'Before', description: 'BEFORE_PROFILE');
    final second = await engine.createPersona(name: 'After', description: 'AFTER_PROFILE');
    await engine.setDefaultPersona(first.id);
    final chatId = await chat();
    final pending = transport.pending();
    final running = _Running(engine.send(chatId, 'question before binding'));
    await pending.connected.future;
    pending.text('partial before binding');
    await running.firstText.future;
    await engine.bindPersona(chatId, second.id);
    final failure = (await running.done).whereType<TavernTurnFailed>().single;
    expect(failure.kind, TavernFailure.cancelled);
    expect(failure.partial!.text, 'partial before binding');
    pending.text('must not write late');
    pending.finish();
    await Future<void>.delayed(Duration.zero);
    expect((await engine.path(chatId)).last.text, 'partial before binding');
    expect((await engine.path(chatId))[1].speaker, 'Before');
    _done(await engine.send(chatId, '{{user}} after binding').toList());
    expect((await engine.path(chatId))[3].speaker, 'After');
    expect(_requestText(transport.requests.last), contains('AFTER_PROFILE'));
  });

  test('an unchanged binding or invalid profile does not cancel a valid active turn', () async {
    final profile = await engine.createPersona(name: 'Bound');
    final chatId = await chat();
    await engine.bindPersona(chatId, profile.id);
    final pending = transport.pending();
    final running = _Running(engine.send(chatId, 'question'));
    await pending.connected.future;
    pending.text('first');
    await running.firstText.future;
    await engine.bindPersona(chatId, profile.id);
    await expectLater(engine.bindPersona(chatId, 'missing'), throwsStateError);
    pending.text('second');
    pending.finish();
    expect(_done(await running.done).text, 'firstsecond');
    expect((await engine.personaSelection(chatId: chatId)).persona!.id, profile.id);
  });

  test(
    'deleting a profile drains bound and inherited chats together while an unrelated chat keeps streaming',
    () async {
      await engine.setSettings({'userName': 'Fallback', 'persona': 'FALLBACK_PROFILE'});
      final removed = await engine.createPersona(name: 'Removed', description: 'REMOVED_PROFILE');
      final retained = await engine.createPersona(name: 'Retained', description: 'RETAINED_PROFILE');
      await engine.setDefaultPersona(removed.id);
      final a = await chat();
      final b = await chat();
      final c = await chat();
      await engine.bindPersona(a, removed.id);
      await engine.bindPersona(c, retained.id);
      final pa = transport.pending();
      final ra = _Running(engine.send(a, 'A'));
      await pa.connected.future;
      pa.text('partial A');
      await ra.firstText.future;
      final pb = transport.pending();
      final rb = _Running(engine.send(b, 'B'));
      await pb.connected.future;
      pb.text('partial B');
      await rb.firstText.future;
      final pc = transport.pending();
      final rc = _Running(engine.send(c, 'C'));
      await pc.connected.future;
      pc.text('retained ');
      await rc.firstText.future;
      await engine.deletePersona(removed.id);
      for (final running in [ra, rb]) {
        expect((await running.done).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
      }
      expect((await engine.path(a)).last.text, 'partial A');
      expect((await engine.path(b)).last.text, 'partial B');
      expect(await engine.persona(removed.id), isNull);
      expect((await engine.personaSelection(chatId: a)).persona, isNull);
      expect((await engine.personaSelection(chatId: a)).boundPersonaId, isNull);
      expect((await engine.personaSelection(chatId: b)).persona, isNull);
      expect((await engine.personaSelection()).defaultPersonaId, isNull);
      expect((await engine.personaSelection(chatId: c)).persona!.id, retained.id);
      pc.text('answer');
      pc.finish();
      expect(_done(await rc.done).text, 'retained answer');
      pa.text('late A');
      pa.finish();
      pb.text('late B');
      pb.finish();
      _done(await engine.send(b, '{{user}} after deletion').toList());
      expect((await engine.path(b))[1].speaker, 'Removed');
      expect((await engine.path(b))[3].speaker, 'Fallback');
      expect(_requestText(transport.requests.last), contains('FALLBACK_PROFILE'));
      await engine.deletePersona(removed.id);
    },
  );

  test('deletion also cancels a turn that captured the old default before the default changed', () async {
    final old = await engine.createPersona(name: 'Old default');
    final next = await engine.createPersona(name: 'New default');
    await engine.setDefaultPersona(old.id);
    final chatId = await chat();
    final pending = transport.pending();
    final running = _Running(engine.send(chatId, 'old request'));
    await pending.connected.future;
    pending.text('old partial');
    await running.firstText.future;
    await engine.setDefaultPersona(next.id);
    expect((await engine.personaSelection(chatId: chatId)).persona!.id, next.id);
    await engine.deletePersona(old.id);
    expect((await running.done).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    pending.finish();
    expect((await engine.path(chatId)).last.text, 'old partial');
    _done(await engine.send(chatId, '{{user}} request').toList());
    expect((await engine.path(chatId))[3].speaker, 'New default');
  });

  test('queued deletion and binding acquire persona and chat barriers in a consistent order', () async {
    final removed = await engine.createPersona(name: 'Delete first');
    final fallback = await engine.createPersona(name: 'Fallback');
    await engine.setDefaultPersona(fallback.id);
    final chatId = await chat();
    await engine.bindPersona(chatId, removed.id);
    final deletion = engine.deletePersona(removed.id);
    final binding = expectLater(engine.bindPersona(chatId, removed.id), throwsStateError);
    await Future.wait([deletion, binding]).timeout(const Duration(seconds: 5));
    final selection = await engine.personaSelection(chatId: chatId);
    expect(selection.boundPersonaId, isNull);
    expect(selection.persona!.id, fallback.id);
    _done(await engine.send(chatId, 'queue remains usable').toList());
  });

  test('failed profile persistence releases every chat barrier and leaves the committed persona usable', () async {
    final profile = await engine.createPersona(name: 'Keep after failure', description: 'KEPT_PROFILE');
    await engine.setDefaultPersona(profile.id);
    final chatId = await chat();
    final pending = transport.pending();
    final running = _Running(engine.send(chatId, 'before failed deletion'));
    await pending.connected.future;
    pending.text('kept partial');
    await running.firstText.future;
    final obstruction = await Directory('${engine.directory.path}/personas/index.json.writing').create();
    await expectLater(engine.deletePersona(profile.id), throwsA(isA<FileSystemException>()));
    expect((await running.done).whereType<TavernTurnFailed>().single.kind, TavernFailure.cancelled);
    pending.finish();
    expect((await engine.personaSelection(chatId: chatId)).persona!.id, profile.id);
    await obstruction.delete();
    _done(await engine.send(chatId, 'after failure').toList());
    expect(_requestText(transport.requests.last), contains('KEPT_PROFILE'));
    await engine.deletePersona(profile.id);
    expect(await engine.persona(profile.id), isNull);
  });

  test('close drains accepted persona writes without waiting for a paused persona watcher', () async {
    final profile = await engine.createPersona(name: 'Before close');
    await engine.setDefaultPersona(profile.id);
    final subscription = engine.watchPersonas().listen((_) {})..pause();
    final saving = engine.updatePersona(profile.id, name: 'Saved before close', description: 'SAVED_PROFILE');
    final closing = engine.close();
    expect((await saving).name, 'Saved before close');
    await closing.timeout(const Duration(seconds: 5));
    await subscription.cancel();
    engine = await open();
    expect((await engine.persona(profile.id))!.description, 'SAVED_PROFILE');
    expect((await engine.personaSelection()).persona!.name, 'Saved before close');
    expect((await engine.watchPersonas().first).single.name, 'Saved before close');
  });

  test('regenerate, continue and impersonate all use the effective profile without rewriting history', () async {
    final first = await engine.createPersona(name: 'First user', description: 'FIRST_PERSONA');
    final next = await engine.createPersona(name: 'Next user', description: 'NEXT_PERSONA');
    await engine.setDefaultPersona(first.id);
    final chatId = await chat();
    final original = _done(await engine.send(chatId, '{{user}} original').toList());
    await engine.bindPersona(chatId, next.id);
    final regenerated = _done(await engine.regenerate(chatId, original.nodeId).toList());
    expect(_requestText(transport.requests.last), contains('NEXT_PERSONA'));
    expect((await engine.path(chatId))[1].speaker, 'First user');
    final continued = _done(await engine.continueReply(chatId, regenerated.nodeId).toList());
    expect(continued.nodeId, regenerated.nodeId);
    expect(_requestText(transport.requests.last), contains('NEXT_PERSONA'));
    final before = await engine.path(chatId);
    final drafted = _done(await engine.impersonate(chatId).toList());
    expect(drafted.role, TavernRole.user);
    expect(drafted.speaker, 'Next user');
    expect(_requestText(transport.requests.last), contains('NEXT_PERSONA'));
    expect((await engine.path(chatId)).map((message) => message.nodeId), before.map((message) => message.nodeId));
  });
}

Uint8List _card() => Uint8List.fromList(
  utf8.encode(
    jsonEncode({
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': {
        'name': 'Character',
        'description': '',
        'personality': '',
        'scenario': '',
        'first_mes': 'Hello {{user}}',
        'alternate_greetings': [],
        'mes_example': '',
        'system_prompt': '',
        'post_history_instructions': '',
        'creator_notes': '',
        'extensions': {},
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

class _Running {
  _Running(Stream<TavernEvent> stream) {
    done = stream.map((event) {
      if (event is TavernTextDelta && !firstText.isCompleted) firstText.complete();
      return event;
    }).toList();
  }
  final firstText = Completer<void>();
  late final Future<List<TavernEvent>> done;
}

class _Transport {
  final requests = <Map<String, Object?>>[];
  final _plans = Queue<Future<http.StreamedResponse> Function()>();
  final _pending = <_Pending>[];
  TavernModelClient get client => TavernModelClient(
    clientFactory: () => _Client((request) async {
      final body = utf8.decode(await request.finalize().toBytes());
      requests.add(jsonDecode(body) as Map<String, Object?>);
      if (_plans.isNotEmpty) return _plans.removeFirst()();
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            'data: {"choices":[{"index":0,"delta":{"content":"generated"},"finish_reason":"stop"}]}\n\n'
            'data: [DONE]\n\n',
          ),
        ),
        200,
      );
    }),
  );

  _Pending pending() {
    final value = _Pending();
    _pending.add(value);
    _plans.add(() async => http.StreamedResponse(value.stream.stream, 200));
    return value;
  }

  void dispose() {
    for (final value in _pending) {
      value.dispose();
    }
  }
}

class _Pending {
  _Pending() {
    stream = StreamController<List<int>>(
      onListen: () {
        connected.complete();
      },
    );
  }
  final connected = Completer<void>();
  late final StreamController<List<int>> stream;
  void text(String text) {
    if (!stream.isClosed) {
      stream.add(
        utf8.encode(
          'data: ${jsonEncode({
            'choices': [
              {
                'index': 0,
                'delta': {'content': text},
              },
            ],
          })}\n\n',
        ),
      );
    }
  }

  void finish() {
    if (stream.isClosed) return;
    stream.add(
      utf8.encode(
        'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
        'data: [DONE]\n\n',
      ),
    );
    unawaited(stream.close());
  }

  void dispose() {
    if (!stream.isClosed) unawaited(stream.close());
  }
}

class _Client extends http.BaseClient {
  _Client(this.handler);
  final Future<http.StreamedResponse> Function(http.BaseRequest request) handler;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => handler(request);
  @override
  void close() {}
}
