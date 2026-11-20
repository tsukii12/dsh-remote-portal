import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late String path;
  late Database database;
  late ChatStore store;
  late String chat;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-t24-reported-usage-');
    path = '${directory.path}/chat.sqlite3';
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    chat = store.createChat(characterId: 'card');
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('message collections expose this owned reported usage without decoding its prompt or falling back to usage', () {
    const node = 'reply';
    final extra = _owned(
      chat,
      node,
      inspection: {
        // Deliberately not a PromptAssembly. This projection reads only the
        // owned identity and the small reported value, never the prompt tree.
        'prompt': {
          'body': {
            'messages': List<Object?>.filled(1000, {'content': 'irrelevant'}),
          },
        },
      },
    );
    store.append(
      chat,
      id: node,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'usageword',
      usage: const TavernUsage(promptTokens: 999, completionTokens: 888),
      extra: extra,
    );
    for (final message in [
      store.message(chat, node),
      store.node(chat, node).message,
      store.path(chat).single,
      store.historyTo(chat, node).single.message,
      store.allNodes(chat).single.message,
      store.children(chat, null).single.message,
      store.search('usageword').single,
      store.searchChat(chat, 'usageword').single,
    ]) {
      expect(_counts(message.reportedUsage), [12, 3, 4, 'reported-model']);
      expect(_counts(message.usage), [999, 0, 888, null]);
    }
    expect(store.node(chat, node).extra, extra);
  });

  test('missing malformed foreign and estimated-only values remain null instead of becoming reported zero', () {
    final invalid = <Map<String, Object?>>[
      {'version': 2},
      {'version': true},
      {'chatId': 'elsewhere'},
      {'nodeId': 'elsewhere'},
      {'reportedUsage': null},
      {'reportedUsage': <String, Object?>{}},
      {
        'reportedUsage': {'promptTokens': '12', 'cacheHitTokens': 3, 'completionTokens': 4},
      },
      {
        'reportedUsage': {'promptTokens': 12.0, 'cacheHitTokens': 3, 'completionTokens': 4},
      },
      {
        'reportedUsage': {'promptTokens': 12, 'cacheHitTokens': true, 'completionTokens': 4},
      },
      {
        'reportedUsage': {'promptTokens': 12, 'cacheHitTokens': 3, 'completionTokens': 4, 'model': 7},
      },
      {
        'reportedUsage': null,
        'prompt': {'promptTokens': 800, 'exactTokenCounts': false},
      },
    ];
    for (var i = 0; i < invalid.length; i++) {
      final id = 'invalid-$i';
      store.append(
        chat,
        id: id,
        parentId: null,
        role: TavernRole.character,
        speaker: 'Guide',
        text: id,
        usage: const TavernUsage(promptTokens: 91),
        extra: _owned(chat, id, inspection: invalid[i]),
      );
      expect(store.message(chat, id).reportedUsage, isNull, reason: '$i');
      expect(store.message(chat, id).usage!.promptTokens, 91);
      expect(database.select('SELECT reported_usage FROM nodes WHERE id=?', [id]).single['reported_usage'], isNull);
    }
    store.append(
      chat,
      id: 'unowned',
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'unowned',
      extra: {
        'foreign': {
          'reportedUsage': {'promptTokens': 12},
        },
      },
    );
    expect(store.message(chat, 'unowned').reportedUsage, isNull);
  });

  test('extra replacement refreshes the small column while zero and unrelated writes retain their meaning', () {
    const id = 'reply';
    store.append(
      chat,
      id: id,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'body',
      extra: _owned(chat, id),
    );
    store.updateMessage(
      chat,
      id,
      extra: _owned(chat, id, reported: {'promptTokens': 0, 'cacheHitTokens': 0, 'completionTokens': 0}),
    );
    expect(_counts(store.message(chat, id).reportedUsage), [0, 0, 0, null]);
    store.updateMessage(
      chat,
      id,
      text: 'edited',
      usage: const TavernUsage(promptTokens: 1000),
      original: {'keep': true},
    );
    expect(_counts(store.message(chat, id).reportedUsage), [0, 0, 0, null]);
    store.updateMessage(chat, id, extra: {'foreign': 'kept without owned inspection'});
    expect(store.message(chat, id).reportedUsage, isNull);
    expect(store.message(chat, id).usage!.promptTokens, 1000);
  });

  test('pending projection suppresses old reporting and generic promotion clears stale evidence', () {
    const id = 'reply';
    store.append(
      chat,
      id: id,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'old',
      extra: _owned(chat, id),
    );
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, id, text: '');
    expect(store.message(chat, id).reportedUsage, isNull);
    expect(store.path(chat).single.reportedUsage, isNull);
    expect(database.select('SELECT reported_usage FROM nodes').single['reported_usage'], isNotNull);
    store.updateMessage(chat, id, text: 'edited draft');
    expect(store.message(chat, id).reportedUsage, isNull);
    expect((store.node(chat, id).extra['dshgo']! as Map<String, Object?>).containsKey('inspection'), isFalse);
    expect(store.node(chat, id).extra['foreign'], {'keep': true});
    store.writeStreamingBody(chat, id, text: 'next draft');
    store.updateMessage(
      chat,
      id,
      text: 'terminal',
      extra: _owned(
        chat,
        id,
        reported: {'promptTokens': 21, 'cacheHitTokens': 8, 'completionTokens': 13, 'model': 'new-model'},
      ),
    );
    store.endStreamingWrites();
    expect(_counts(store.message(chat, id).reportedUsage), [21, 8, 13, 'new-model']);
  });

  test(
    'genuine schema4 backfill accepts only matching owned integer reporting and preserves original columns',
    () async {
      await store.close();
      path = '${directory.path}/schema4.sqlite3';
      database = sqlite3.open(path);
      database.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
      expect(database.select('PRAGMA user_version').single['user_version'], 4);
      database.execute('ALTER TABLE nodes ADD COLUMN future_vendor TEXT');
      database.execute("INSERT INTO chats(id,character_id,title,created_at,updated_at) VALUES('c','card','old',1,2)");
      final cases = <String, String>{
        'valid': jsonEncode(_owned('c', 'valid')),
        'zero': jsonEncode(
          _owned('c', 'zero', reported: {'promptTokens': 0, 'cacheHitTokens': 0, 'completionTokens': 0}),
        ),
        'foreign': jsonEncode(_owned('wrong-chat', 'foreign')),
        'wrong-node': jsonEncode(_owned('c', 'other-node')),
        'bool-version': jsonEncode(_owned('c', 'bool-version', inspection: {'version': true})),
        'bad-count': jsonEncode(
          _owned('c', 'bad-count', reported: {'promptTokens': '1', 'cacheHitTokens': 0, 'completionTokens': 0}),
        ),
        'empty': jsonEncode(_owned('c', 'empty', reported: <String, Object?>{})),
        'malformed': 'not JSON',
      };
      for (final entry in cases.entries) {
        database.execute(
          '''INSERT INTO nodes(id,chat_id,depth,role,speaker,text,at,extra,future_vendor)
        VALUES(?,'c',1,'character','Guide','body',1,?,'preserved')''',
          [entry.key, entry.value],
        );
        database.execute('INSERT INTO node_states(node_id,full_json) VALUES(?,?)', [entry.key, '{}']);
      }
      final before = _originalRows(database);
      store = ChatStore.fromDatabase(database);
      expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
      expect(_originalRows(database), before);
      expect(_counts(store.message('c', 'valid').reportedUsage), [12, 3, 4, 'reported-model']);
      expect(_counts(store.message('c', 'zero').reportedUsage), [0, 0, 0, null]);
      for (final id in cases.keys.where((id) => id != 'valid' && id != 'zero')) {
        expect(store.message('c', id).reportedUsage, isNull, reason: id);
      }
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test('schema5 collision rolls the whole genuine schema4 upgrade back before retry', () async {
    await store.close();
    path = '${directory.path}/collision.sqlite3';
    database = sqlite3.open(path);
    database.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
    database.execute('ALTER TABLE nodes ADD COLUMN reported_usage TEXT');
    database.close();
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    database = sqlite3.open(path);
    expect(database.select('PRAGMA user_version').single['user_version'], 4);
    expect(database.select('PRAGMA table_info(chats)').map((row) => row['name']), isNot(contains('tree_revision')));
    expect(database.select('PRAGMA table_info(nodes)').map((row) => row['name']), isNot(contains('deleted_by')));
    expect(database.select("SELECT name FROM sqlite_master WHERE name='deleted_subtrees'"), isEmpty);
    database.execute('ALTER TABLE nodes DROP COLUMN reported_usage');
    store = ChatStore.fromDatabase(database);
    expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
  });

  test('recovery promotes pending text without retaining previous completed reporting', () async {
    const id = 'reply';
    store.append(
      chat,
      id: id,
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'old',
      usage: const TavernUsage(promptTokens: 99),
      extra: _owned(chat, id),
    );
    store.beginStreamingWrites();
    store.writeStreamingBody(chat, id, text: 'recovered');
    await store.close();
    database = sqlite3.open(path);
    store = ChatStore.fromDatabase(database);
    expect(store.message(chat, id).text, 'recovered');
    expect(store.message(chat, id).usage, isNull);
    expect(store.message(chat, id).reportedUsage, isNull);
    expect(store.node(chat, id).extra['foreign'], {'keep': true});
    expect(database.select('SELECT reported_usage FROM nodes').single['reported_usage'], isNull);
  });
}

Map<String, Object?> _owned(
  String chat,
  String node, {
  Object? reported = const {'promptTokens': 12, 'cacheHitTokens': 3, 'completionTokens': 4, 'model': 'reported-model'},
  Map<String, Object?> inspection = const {},
}) => {
  'foreign': {'keep': true},
  'dshgo': <String, Object?>{
    'inspection': <String, Object?>{
      'version': 1,
      'chatId': chat,
      'nodeId': node,
      'reportedUsage': reported,
      ...inspection,
    },
  },
};

List<Object?>? _counts(TavernUsage? value) =>
    value == null ? null : [value.promptTokens, value.cacheHitTokens, value.completionTokens, value.model];

List<Map<String, Object?>> _originalRows(Database database) => [
  for (final row in database.select(
    'SELECT id,seq,chat_id,parent_id,depth,text,extra,usage,future_vendor FROM nodes ORDER BY seq',
  ))
    Map<String, Object?>.from(row),
];
