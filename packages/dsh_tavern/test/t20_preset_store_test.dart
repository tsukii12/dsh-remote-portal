import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late Database database;
  late ChatStore store;
  var milliseconds = 1000;
  var nextId = 0;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t20-preset-store-');
    path = '${directory.path}/tavern.sqlite3';
    database = sqlite3.open(path);
    milliseconds = 1000;
    nextId = 0;
    store = ChatStore.fromDatabase(
      database,
      clock: () => DateTime.fromMillisecondsSinceEpoch(milliseconds, isUtc: true),
      createId: () => 'preset-${nextId++}',
    );
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  StoredPreset create(String name, {Map<String, Object?>? raw, Map<String, Object?>? envelope}) =>
      store.createPreset(name: name, sourceText: 'source:$name', raw: raw ?? {'temperature': 0.7}, envelope: envelope);

  test('source text is exact and both stored JSON documents are detached', () {
    const source = '\uFEFF{\r\n  "unknown": "海 🌊 {{user}}"\r\n}\r\n';
    final raw = <String, Object?>{
      'prompts': [
        {'identifier': 'x', 'role': 'user', 'content': '海 {{user}}'},
      ],
      'unknown': <String, Object?>{
        'nested': [1, null, true],
      },
    };
    final envelope = <String, Object?>{
      'format': 'dsh-preset-enhance',
      'version': 1,
      'preset': {
        'format': 'sillytavern',
        'data': raw,
        'future': ['kept'],
      },
      'prefill': {
        'enabled': true,
        'unknown': [null, 'future'],
      },
      'tools': {
        'version': 99,
        'opaque': {'x': 7},
      },
      'foreign': <String, Object?>{'value': false},
    };
    final expectedRaw = jsonDecode(jsonEncode(raw));
    final expectedEnvelope = jsonDecode(jsonEncode(envelope));
    final saved = store.createPreset(name: '海', sourceText: source, raw: raw, envelope: envelope);
    expect(saved.id, 'preset-0');
    expect(saved.name, '海');
    expect(saved.createdAt, DateTime.fromMillisecondsSinceEpoch(1000, isUtc: true));
    expect(saved.updatedAt, saved.createdAt);
    expect(saved.sourceText, source);
    expect(saved.raw, expectedRaw);
    expect(saved.envelope, expectedEnvelope);
    (raw['unknown']! as Map<String, Object?>)['nested'] = 'changed input';
    (envelope['foreign']! as Map<String, Object?>)['value'] = 'changed input';
    (saved.raw['unknown']! as Map<String, Object?>)['nested'] = 'changed output';
    (saved.envelope!['tools']! as Map<String, Object?>)['opaque'] = 'changed output';
    final again = store.preset(saved.id)!;
    expect(again.raw, expectedRaw);
    expect(again.envelope, expectedEnvelope);
    expect(again.sourceText, source);
    expect(store.defaultPresetId, isNull);
    expect(store.preset('missing'), isNull);
  });

  for (final entry in <String, String>{
    'no BOM': '{"x":"海 🌊"}\r\n',
    'one leading BOM': '\uFEFF{}',
    'two leading BOMs': '\uFEFF\uFEFF{}',
    'interior BOM': '{"x":"\uFEFF"}',
    'only BOM': '\uFEFF',
    'empty text': '',
  }.entries) {
    test('original TEXT ${entry.key} survives reads, edits, and reopening', () async {
      final source = entry.value;
      final saved = store.createPreset(name: 'original', sourceText: source, raw: {});
      final storedBytes = utf8.encode(source);
      final row = database.select(
        'SELECT typeof(source_text) AS kind, CAST(source_text AS BLOB) AS bytes FROM presets WHERE id = ?',
        [saved.id],
      ).single;
      expect(row['kind'], 'text');
      expect(row['bytes'], storedBytes);
      expect(saved.sourceText, source);
      expect(store.preset(saved.id)!.sourceText, source);
      expect(store.updatePreset(saved.id, name: 'edited', raw: {'x': true}, envelope: null).sourceText, source);
      await store.close();
      database = sqlite3.open(path);
      store = ChatStore.fromDatabase(database);
      expect(store.preset(saved.id)!.sourceText, source);
      expect(
        database.select('SELECT CAST(source_text AS BLOB) AS bytes FROM presets WHERE id = ?', [
          saved.id,
        ]).single['bytes'],
        storedBytes,
      );
    });
  }

  test('summary queries sort deterministically and do not decode either JSON column', () {
    final first = create('first');
    final second = create('second', envelope: {'foreign': 'kept'});
    milliseconds = 2000;
    final last = create('last');
    // Malformed fixture bytes distinguish a metadata-only query from loading
    // full records and then throwing their JSON away.
    database.execute('UPDATE presets SET raw_json = ?, envelope_json = ? WHERE id = ?', [
      '{malformed',
      '{also malformed',
      second.id,
    ]);
    final summaries = store.listPresets();
    expect(summaries.map((item) => item.id), [last.id, first.id, second.id]);
    expect(summaries.map((item) => item.name), ['last', 'first', 'second']);
    expect(summaries.map((item) => item.hasEnvelope), [false, false, true]);
    expect(summaries.first.updatedAt.millisecondsSinceEpoch, 2000);
    expect(() => store.preset(second.id), throwsFormatException);
    summaries.clear();
    expect(store.listPresets(), hasLength(3));
  });

  test('updating editable JSON preserves original text and creation time across reopening', () async {
    final saved = create('old', envelope: {'unknown': 1});
    milliseconds = 3000;
    final raw = <String, Object?>{
      'unknown': {
        'value': ['new', null],
      },
      'temperature': 0.3,
    };
    final envelope = <String, Object?>{
      'unknown': {'keep': true},
      'preset': {'data': raw},
    };
    final updated = store.updatePreset(saved.id, name: '', raw: raw, envelope: envelope);
    expect(updated.name, '');
    expect(updated.sourceText, saved.sourceText);
    expect(updated.createdAt, saved.createdAt);
    expect(updated.updatedAt.millisecondsSinceEpoch, 3000);
    raw['temperature'] = 9;
    (envelope['unknown']! as Map<String, Object?>)['keep'] = false;
    updated.raw['temperature'] = 7;
    expect(store.preset(saved.id)!.raw['temperature'], 0.3);
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    final reopened = store.preset(saved.id)!;
    expect(reopened.sourceText, 'source:old');
    expect(reopened.createdAt, saved.createdAt);
    expect(reopened.updatedAt, updated.updatedAt);
    expect(reopened.raw['temperature'], 0.3);
    expect(reopened.envelope!['unknown'], {'keep': true});
    final cleared = store.updatePreset(saved.id, name: 'native', raw: reopened.raw, envelope: null);
    expect(cleared.envelope, isNull);
    expect(cleared.sourceText, 'source:old');
    expect(store.listPresets().single.hasEnvelope, isFalse);
  });

  test('unknown ids and non-JSON values leave records and notifications unchanged', () async {
    final saved = create('kept');
    final before = _presets(database);
    var events = 0;
    final subscription = store.presetChanges.listen((_) => events++);
    expect(() => store.updatePreset('missing', name: 'bad', raw: {}, envelope: null), throwsStateError);
    expect(
      () => store.createPreset(name: 'bad', sourceText: 'unchanged', raw: {'bad': Object()}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(
      () => store.updatePreset(saved.id, name: 'bad', raw: {}, envelope: {'bad': Object()}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
    expect(_presets(database), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    await subscription.cancel();
  });

  test('binding validates both ids and changes only the intended chat binding', () async {
    final selected = create('chosen');
    final chat = store.createChat(
      id: 'chat',
      characterId: 'card',
      metadata: {'future': true},
      variables: {'n': 4},
      settings: {
        'preset': {'legacy': 'keep until facade clears it'},
        'other': [null],
      },
    );
    final other = store.createChat(id: 'other', characterId: 'card');
    final node = store.append(
      chat,
      id: 'root',
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸',
      text: 'saved beacon',
      state: {
        'variables': {'n': 4},
      },
    );
    final before = store.chat(chat);
    final nodes = _rows(database, 'SELECT * FROM nodes ORDER BY seq');
    var presetEvents = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => presetEvents++);
    final chats = store.changes.listen(chatEvents.add);
    expect(() => store.bindPreset(chat, 'missing'), throwsStateError);
    expect(() => store.bindPreset('missing', selected.id), throwsStateError);
    milliseconds = 2000;
    store.bindPreset(chat, selected.id);
    expect(store.chat(chat).presetId, selected.id);
    expect(store.chat(other).presetId, isNull);
    expect(store.chat(chat).metadata, before.metadata);
    expect(store.chat(chat).variables, before.variables);
    expect(store.chat(chat).settings, before.settings);
    expect(store.chat(chat).currentLeafId, node.nodeId);
    expect(_rows(database, 'SELECT * FROM nodes ORDER BY seq'), nodes);
    expect(store.chatsBoundToPreset(selected.id), [chat]);
    expect(store.chatsBoundToPreset('missing'), isEmpty);
    store.bindPreset(chat, selected.id);
    await Future<void>.delayed(Duration.zero);
    expect(presetEvents, 1);
    expect(chatEvents, [chat]);
    expect(store.chat(chat).updatedAt.millisecondsSinceEpoch, 2000);
    store.bindPreset(chat, null);
    expect(store.chat(chat).presetId, isNull);
    expect(store.chat(chat).settings, before.settings);
    await presets.cancel();
    await chats.cancel();
  });

  test('default selection is validated, persistent, and does not write chat bindings', () async {
    final first = create('first');
    final second = create('second');
    final bound = store.createChat(id: 'bound', characterId: 'card', presetId: first.id);
    final inherited = store.createChat(id: 'inherited', characterId: 'card');
    final before = _rows(database, 'SELECT * FROM chats ORDER BY id');
    var events = 0;
    final chatEvents = <String>[];
    final subscription = store.presetChanges.listen((_) => events++);
    final chatSubscription = store.changes.listen(chatEvents.add);
    expect(() => store.setDefaultPreset('missing'), throwsStateError);
    store.setDefaultPreset(null);
    store.setDefaultPreset(second.id);
    store.setDefaultPreset(second.id);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    expect(chatEvents, isEmpty);
    expect(_rows(database, 'SELECT * FROM chats ORDER BY id'), before);
    expect(store.chat(bound).presetId, first.id);
    expect(store.chat(inherited).presetId, isNull);
    await subscription.cancel();
    await chatSubscription.cancel();
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    expect(store.defaultPresetId, second.id);
    store.setDefaultPreset(null);
    expect(store.defaultPresetId, isNull);
    expect(store.chat(bound).presetId, first.id);
  });

  test('an outer transaction publishes one coherent preset snapshot after commit', () async {
    final chat = store.createChat(id: 'chat', characterId: 'card');
    final observations = <Map<String, Object?>>[];
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) {
      observations.add({
        'names': store.listPresets().map((item) => item.name).toList(),
        'default': store.defaultPresetId,
        'bound': store.chat(chat).presetId,
        'settings': store.chat(chat).settings,
      });
    });
    final chats = store.changes.listen(chatEvents.add);
    late String id;
    store.transaction<void>(() {
      final saved = create('draft');
      id = saved.id;
      store.updatePreset(
        id,
        name: 'final',
        raw: {
          'future': [1],
        },
        envelope: null,
      );
      store.setDefaultPreset(id);
      store.bindPreset(chat, id);
      store.updateChat(chat, settings: {'other': 'same transaction'});
      expect(observations, isEmpty);
      expect(chatEvents, isEmpty);
    });
    await Future<void>.delayed(Duration.zero);
    expect(observations, [
      {
        'names': ['final'],
        'default': id,
        'bound': id,
        'settings': {'other': 'same transaction'},
      },
    ]);
    expect(chatEvents, [chat]);
    await presets.cancel();
    await chats.cancel();
  });

  test('outer rollback discards preset creation, selection, chat changes, and both event kinds', () async {
    final chat = store.createChat(id: 'chat', characterId: 'card', settings: {'kept': true});
    final before = _selectionSnapshot(database);
    var events = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => events++);
    final chats = store.changes.listen(chatEvents.add);
    expect(
      () => store.transaction<void>(() {
        final saved = create('rollback');
        store.setDefaultPreset(saved.id);
        store.bindPreset(chat, saved.id);
        store.updateChat(chat, settings: {'kept': false});
        throw StateError('abort outer');
      }),
      throwsStateError,
    );
    expect(_selectionSnapshot(database), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    expect(chatEvents, isEmpty);
    await presets.cancel();
    await chats.cancel();
  });

  test('a caught nested rollback does not leak a preset event into an unrelated chat commit', () async {
    final chat = store.createChat(id: 'chat', characterId: 'card');
    var events = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => events++);
    final chats = store.changes.listen(chatEvents.add);
    store.transaction<void>(() {
      try {
        store.transaction<void>(() {
          final saved = create('discarded');
          store.bindPreset(chat, saved.id);
          store.setDefaultPreset(saved.id);
          throw StateError('abort nested');
        });
      } on StateError {
        // The enclosing edit is still allowed after this savepoint rollback.
      }
      store.updateChat(chat, title: 'committed chat only');
    });
    expect(store.listPresets(), isEmpty);
    expect(store.chat(chat).presetId, isNull);
    expect(store.defaultPresetId, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    expect(chatEvents, [chat]);
    await presets.cancel();
    await chats.cancel();
  });

  test('a nested rollback restores an already pending preset notification', () async {
    var events = 0;
    final subscription = store.presetChanges.listen((_) => events++);
    late String id;
    store.transaction<void>(() {
      id = create('kept').id;
      try {
        store.transaction<void>(() {
          store.updatePreset(id, name: 'discarded edit', raw: {'discarded': true}, envelope: null);
          final discarded = create('discarded row');
          store.setDefaultPreset(discarded.id);
          throw StateError('abort nested');
        });
      } on StateError {
        // The first creation still needs its one committed notification.
      }
    });
    expect(store.listPresets().map((item) => item.name), ['kept']);
    expect(store.preset(id)!.raw, {'temperature': 0.7});
    expect(store.defaultPresetId, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await subscription.cancel();
  });

  test('deletion clears every matching binding and the default but retains unrelated data', () async {
    final removed = create('removed');
    final kept = create('kept');
    final first = store.createChat(
      id: 'a',
      characterId: 'card',
      presetId: removed.id,
      metadata: {
        'unknown': [1, null],
      },
      variables: {'n': 7},
      settings: {'future': true},
    );
    final second = store.createChat(id: 'b', characterId: 'card', presetId: removed.id);
    final other = store.createChat(id: 'c', characterId: 'card', presetId: kept.id);
    store.createChat(id: 'd', characterId: 'card');
    final node = store.append(
      first,
      id: 'node',
      parentId: null,
      role: TavernRole.user,
      speaker: '我',
      text: 'retained beacon',
      state: {
        'variables': {'n': 7},
      },
    );
    store.setDefaultPreset(removed.id);
    final beforeNode = _rows(database, 'SELECT * FROM nodes ORDER BY seq');
    final beforeState = _rows(database, 'SELECT * FROM node_states ORDER BY node_id');
    final otherChat = _rows(database, "SELECT * FROM chats WHERE id IN ('c', 'd') ORDER BY id");
    var events = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => events++);
    final chats = store.changes.listen(chatEvents.add);
    milliseconds = 4000;
    expect(store.deletePreset(removed.id), isTrue);
    expect(store.preset(removed.id), isNull);
    expect(store.preset(kept.id), isNotNull);
    expect(store.defaultPresetId, isNull);
    expect(store.chat(first).presetId, isNull);
    expect(store.chat(second).presetId, isNull);
    expect(store.chat(other).presetId, kept.id);
    expect(store.chat(first).metadata, {
      'unknown': [1, null],
    });
    expect(store.chat(first).variables, {'n': 7});
    expect(store.chat(first).settings, {'future': true});
    expect(store.chat(first).updatedAt.millisecondsSinceEpoch, 4000);
    expect(store.path(first).single.nodeId, node.nodeId);
    expect(store.search('beacon').single.nodeId, node.nodeId);
    expect(_rows(database, 'SELECT * FROM nodes ORDER BY seq'), beforeNode);
    expect(_rows(database, 'SELECT * FROM node_states ORDER BY node_id'), beforeState);
    expect(_rows(database, "SELECT * FROM chats WHERE id IN ('c', 'd') ORDER BY id"), otherChat);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    expect(chatEvents, [first, second]);
    await presets.cancel();
    await chats.cancel();
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    expect(store.preset(removed.id), isNull);
    expect(store.defaultPresetId, isNull);
    expect(store.chat(first).presetId, isNull);
    expect(store.chat(other).presetId, kept.id);
  });

  test('a real delete trigger fails after selections clear and rolls everything back without events', () async {
    final saved = create('kept');
    final first = store.createChat(id: 'a', characterId: 'card', presetId: saved.id);
    store.createChat(id: 'b', characterId: 'card', presetId: saved.id);
    store.setDefaultPreset(saved.id);
    database.execute('''CREATE TRIGGER block_preset_delete BEFORE DELETE ON presets BEGIN
      SELECT RAISE(ABORT, 'binding was not cleared') WHERE EXISTS (
        SELECT 1 FROM chats WHERE preset_id = old.id);
      SELECT RAISE(ABORT, 'default was not cleared') WHERE EXISTS (
        SELECT 1 FROM preset_preferences WHERE default_preset_id = old.id);
      SELECT RAISE(ABORT, 'blocked after selections clear');
    END''');
    final before = _selectionSnapshot(database);
    var events = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => events++);
    final chats = store.changes.listen(chatEvents.add);
    milliseconds = 9000;
    expect(
      () => store.deletePreset(saved.id),
      throwsA(
        isA<SqliteException>().having(
          (error) => error.message,
          'failure stage',
          contains('blocked after selections clear'),
        ),
      ),
    );
    expect(_selectionSnapshot(database), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    expect(chatEvents, isEmpty);
    database.execute('DROP TRIGGER block_preset_delete');
    expect(store.deletePreset(saved.id), isTrue);
    expect(store.chat(first).presetId, isNull);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    expect(chatEvents, ['a', 'b']);
    await presets.cancel();
    await chats.cancel();
  });

  test('deletion inside a later-failing outer transaction restores the row and selections', () async {
    final saved = create('kept');
    store.createChat(id: 'chat', characterId: 'card', presetId: saved.id);
    store.setDefaultPreset(saved.id);
    final before = _selectionSnapshot(database);
    var events = 0;
    final subscription = store.presetChanges.listen((_) => events++);
    expect(
      () => store.transaction<void>(() {
        expect(store.deletePreset(saved.id), isTrue);
        expect(store.preset(saved.id), isNull);
        throw StateError('abort after successful delete');
      }),
      throwsStateError,
    );
    expect(_selectionSnapshot(database), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    await subscription.cancel();
  });

  test('a missing record is a no-op unless legacy dangling bindings still need cleaning', () async {
    var events = 0;
    final subscription = store.presetChanges.listen((_) => events++);
    expect(store.deletePreset('missing'), isFalse);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    final chat = store.createChat(id: 'chat', characterId: 'card', presetId: 'missing', settings: {'keep': 1});
    expect(() => store.bindPreset(chat, 'missing'), throwsStateError);
    expect(store.deletePreset('missing'), isFalse);
    expect(store.chat(chat).presetId, isNull);
    expect(store.chat(chat).settings, {'keep': 1});
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await subscription.cancel();
  });

  test('a duplicate id rolls back only its savepoint and preserves earlier pending writes', () async {
    var events = 0;
    final subscription = store.presetChanges.listen((_) => events++);
    store.transaction<void>(() {
      final original = create('original');
      nextId = 0;
      expect(() => create('duplicate'), throwsA(isA<SqliteException>()));
      store.setDefaultPreset(original.id);
    });
    expect(store.listPresets().map((item) => item.name), ['original']);
    expect(store.defaultPresetId, 'preset-0');
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await subscription.cancel();
  });

  test('SQLite automatic rollback discards pending preset events and poisons the enclosing transaction', () async {
    final saved = create('kept');
    final chat = store.createChat(id: 'chat', characterId: 'card', title: 'before');
    final before = _selectionSnapshot(database);
    final pages = database.select('PRAGMA page_count').single['page_count'] as int;
    final previousLimit = database.select('PRAGMA max_page_count').single['max_page_count'] as int;
    database.execute('PRAGMA max_page_count = $pages');
    var events = 0;
    final chatEvents = <String>[];
    final presets = store.presetChanges.listen((_) => events++);
    final chats = store.changes.listen(chatEvents.add);
    SqliteException? original;
    Object? outer;
    try {
      store.transaction<void>(() {
        store.setDefaultPreset(saved.id);
        store.updateChat(chat, title: 'pending');
        try {
          store.updatePreset(
            saved.id,
            name: 'too large',
            raw: {'huge': List<String>.filled(1000000, 'x').join()},
            envelope: null,
          );
        } on SqliteException catch (error) {
          original = error;
        }
        expect(original?.resultCode, 13);
        expect(database.autocommit, isTrue);
        database.execute('PRAGMA max_page_count = $previousLimit');
        expect(() => store.bindPreset(chat, saved.id), throwsA(same(original)));
      });
    } catch (error) {
      outer = error;
    } finally {
      database.execute('PRAGMA max_page_count = $previousLimit');
    }
    expect(outer, same(original));
    expect(original, isNotNull);
    expect(_selectionSnapshot(database), before);
    await Future<void>.delayed(Duration.zero);
    expect(events, 0);
    expect(chatEvents, isEmpty);
    store.setDefaultPreset(saved.id);
    await Future<void>.delayed(Duration.zero);
    expect(events, 1);
    await presets.cancel();
    await chats.cancel();
  });

  test('closing ends preset notifications and all new operations reject a closed store', () async {
    final closed = store.presetChanges.drain<void>();
    await store.close();
    await closed;
    expect(() => store.preset('x'), throwsStateError);
    expect(store.listPresets, throwsStateError);
    expect(() => store.defaultPresetId, throwsStateError);
    expect(() => store.chatsBoundToPreset('x'), throwsStateError);
    expect(() => create('x'), throwsStateError);
    expect(() => store.updatePreset('x', name: 'x', raw: {}, envelope: null), throwsStateError);
    expect(() => store.setDefaultPreset(null), throwsStateError);
    expect(() => store.bindPreset('x', null), throwsStateError);
    expect(() => store.deletePreset('x'), throwsStateError);
  });
}

List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];
List<Map<String, Object?>> _presets(Database database) => _rows(database, 'SELECT * FROM presets ORDER BY id');
Map<String, Object?> _selectionSnapshot(Database database) => {
  'presets': _presets(database),
  'preferences': _rows(database, 'SELECT * FROM preset_preferences ORDER BY singleton'),
  'chats': _rows(database, 'SELECT * FROM chats ORDER BY id'),
};
