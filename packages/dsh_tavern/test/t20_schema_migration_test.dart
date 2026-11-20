import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// This fixture is the unchanged v1 SQL from frozen T19 tree
// e26ddf9b783a8bbd117a03ded0f1eb821f1e3382. It builds genuine v1 files;
// no test first creates v2 and then downgrades only its version header.
void main() {
  late Directory directory;
  late String path;
  ChatStore? store;
  final now = DateTime.utc(2026, 11, 10, 8);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t20-migration-');
    path = '${directory.path}/tavern.sqlite3';
    store = null;
  });
  tearDown(() async {
    await store?.close();
    await directory.delete(recursive: true);
  });

  test('a fresh file executes the full real migration chain and supports presets, tree state, and FTS', () {
    final database = sqlite3.open(path);
    expect(_version(database), 0);
    final opened = ChatStore.fromDatabase(database, clock: () => now);
    store = opened;
    expect(ChatStore.schemaVersion, greaterThanOrEqualTo(2));
    expect(_version(database), ChatStore.schemaVersion);
    expect(
      _tableNames(database),
      containsAll([
        'chats',
        'nodes',
        'node_states',
        'summaries',
        'memories',
        'agent_runs',
        'nodes_fts',
        'presets',
        'preset_preferences',
        'group_chats',
        'group_members',
      ]),
    );
    expect(database.select('SELECT * FROM preset_preferences').single['default_preset_id'], isNull);
    final preset = opened.createPreset(name: 'fresh', sourceText: '{ "x": 1 }', raw: {'x': 1});
    final chat = opened.createChat(characterId: 'card');
    opened.setDefaultPreset(preset.id);
    opened.bindPreset(chat, preset.id);
    final message = opened.append(
      chat,
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸',
      text: 'migration beacon',
      state: {
        'variables': {'n': 2},
        'future': [false, null],
      },
    );
    expect(opened.defaultPresetId, preset.id);
    expect(opened.chat(chat).presetId, preset.id);
    expect(opened.nodeState(chat, message.nodeId), {
      'variables': {'n': 2},
      'future': [false, null],
    });
    expect(opened.search('beacon').single.nodeId, message.nodeId);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('genuine v1 upgrades without rewriting chats, unknown columns, old bindings, or tree data', () {
    final before = _inspect(path, (database) {
      _legacyDatabase(database);
      expect(_version(database), 1);
      expect(_tableNames(database), isNot(contains('presets')));
      return {'definitions': _definitions(database), 'data': _legacyData(database)};
    });
    final opened = ChatStore.open(path, clock: () => now);
    store = opened;
    expect(opened.listPresets(), isEmpty);
    expect(opened.defaultPresetId, isNull);
    expect(opened.chat('chat').presetId, 'legacy-unresolved');
    expect(opened.chat('chat').settings, {
      'preset': {
        'unknown': [null],
      },
      'other': true,
    });
    expect(opened.path('chat').map((message) => message.nodeId), ['root', 'a']);
    expect(opened.nodeState('chat', 'a'), {
      'variables': {'n': 2},
      'unknown': [false, null],
    });
    expect(opened.nodeState('chat', 'b'), {
      'variables': {'n': 9},
      'unknown': [false, null],
    });
    expect(opened.search('beacon').single.nodeId, 'a');
    _inspect(path, (database) {
      expect(_version(database), ChatStore.schemaVersion);
      _expectUpgradedLegacyData(database, before['data']);
      final oldDefinitions = before['definitions']! as List<Map<String, Object?>>;
      // V8 deliberately rebuilds memories with constrained provenance. Its
      // original columns and data are checked separately below.
      final retainedOld = oldDefinitions.where((row) => row['type'] != 'table' || row['name'] != 'memories').toList();
      final keys = retainedOld.map((row) => '${row['type']}:${row['name']}').toSet();
      final retainedDefinitions = _definitions(
        database,
      ).where((row) => keys.contains('${row['type']}:${row['name']}')).toList();
      const additions = {
        'chats': ', tree_revision INTEGER NOT NULL DEFAULT 0',
        'nodes':
            ', stream_text TEXT, stream_reasoning TEXT, '
            'deleted_by TEXT REFERENCES deleted_subtrees(id) DEFERRABLE INITIALLY DEFERRED, reported_usage TEXT, '
            'speaker_character_id TEXT, source_epoch INTEGER NOT NULL DEFAULT 0\n'
            "  CHECK(typeof(source_epoch) = 'integer' AND source_epoch >= 0), "
            'content_version INTEGER NOT NULL DEFAULT 1\n'
            "  CHECK(typeof(content_version) = 'integer' AND content_version > 0), display_context TEXT",
      };
      for (final row in retainedDefinitions) {
        final addition = additions[row['name']];
        if (row['type'] == 'table' && addition != null) {
          final sql = row['sql']! as String;
          expect(sql.endsWith('$addition)'), true);
          row['sql'] = '${sql.substring(0, sql.length - addition.length - 1)})';
        }
      }
      expect(retainedDefinitions, retainedOld);
      expect(database.select('SELECT * FROM group_chats'), isEmpty);
      expect(database.select('SELECT * FROM group_members'), isEmpty);
      expect(opened.path('chat').map((message) => message.speakerCharacterId), [null, null]);
      expect(database.select('PRAGMA application_id').single['application_id'], 765);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      expect(
        database.select("SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'chats_preset'"),
        hasLength(1),
      );
    });
  });

  test('a failure in step two rolls completed v1 DDL and its temporary version back to zero', () {
    final before = _inspect(path, (database) {
      database.execute('CREATE TABLE preset_preferences(keep TEXT)');
      database.execute("INSERT INTO preset_preferences VALUES ('original conflict')");
      database.execute('CREATE TABLE unrelated(payload BLOB)');
      database.execute("INSERT INTO unrelated VALUES (X'00017fff')");
      return _conflictSnapshot(database);
    });
    // V1 does not use either existing name. V2 first creates presets, then
    // fails at preset_preferences after V1's user_version was advanced to1.
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    _inspect(path, (database) {
      expect(_conflictSnapshot(database), before);
      expect(_version(database), 0);
      expect(_tableNames(database), ['preset_preferences', 'unrelated']);
      database.execute('DROP TABLE preset_preferences');
    });
    final recovered = ChatStore.open(path, clock: () => now);
    store = recovered;
    expect(recovered.defaultPresetId, isNull);
    expect(recovered.createPreset(name: 'recovered', sourceText: '{}', raw: {}).name, 'recovered');
    _inspect(path, (database) {
      expect(_version(database), ChatStore.schemaVersion);
      expect(database.select('SELECT hex(payload) AS value FROM unrelated').single['value'], '00017FFF');
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  test('a failed real 1-to-2 step preserves the complete v1 database and can be retried', () {
    final before = _inspect(path, (database) {
      _legacyDatabase(database);
      database.execute('CREATE TABLE preset_preferences(keep TEXT)');
      database.execute("INSERT INTO preset_preferences VALUES ('original conflict')");
      return {
        'schema': _schema(database),
        'data': _legacyData(database),
        'conflict': _rows(database, 'SELECT * FROM preset_preferences'),
      };
    });
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    _inspect(path, (database) {
      expect(_schema(database), before['schema']);
      expect(_legacyData(database), before['data']);
      expect(_rows(database, 'SELECT * FROM preset_preferences'), before['conflict']);
      expect(_version(database), 1);
      expect(_tableNames(database), isNot(contains('presets')));
      database.execute('DROP TABLE preset_preferences');
    });
    final recovered = ChatStore.open(path, clock: () => now);
    store = recovered;
    expect(recovered.path('chat').map((message) => message.nodeId), ['root', 'a']);
    expect(recovered.search('beacon').single.nodeId, 'a');
    expect(recovered.nodeState('chat', 'b')['variables'], {'n': 9});
    _inspect(path, (database) {
      expect(_version(database), ChatStore.schemaVersion);
      _expectUpgradedLegacyData(database, before['data']);
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });

  test('current schema reopening retains presets, selections, exact source, and unknown database columns', () async {
    final database = sqlite3.open(path);
    final first = ChatStore.fromDatabase(database, clock: () => now);
    store = first;
    const source = '\uFEFF{\r\n "海": "🌊 {{user}}"\r\n}\r\n';
    final preset = first.createPreset(
      name: 'saved',
      sourceText: source,
      raw: {
        'unknown': [false, null],
      },
      envelope: {
        'future': {'version': 99},
      },
    );
    final chat = first.createChat(id: 'chat', characterId: 'card', variables: {'n': 3});
    first.bindPreset(chat, preset.id);
    first.setDefaultPreset(preset.id);
    final message = first.append(
      chat,
      id: 'root',
      parentId: null,
      role: TavernRole.user,
      speaker: '我',
      text: 'saved beacon',
      state: {
        'variables': {'n': 3},
      },
    );
    await first.close();
    final before = _inspect(path, (database) {
      database.execute('ALTER TABLE presets ADD COLUMN future_column TEXT');
      database.execute("UPDATE presets SET future_column = 'preserve me'");
      database.execute('CREATE TABLE unrelated(payload BLOB)');
      database.execute("INSERT INTO unrelated VALUES (X'03ff')");
      return _currentSnapshot(database);
    });
    final reopened = ChatStore.open(path, clock: () => now.add(const Duration(days: 1)));
    store = reopened;
    expect(reopened.preset(preset.id)!.sourceText, source);
    expect(reopened.preset(preset.id)!.raw, {
      'unknown': [false, null],
    });
    expect(reopened.preset(preset.id)!.envelope, {
      'future': {'version': 99},
    });
    expect(reopened.chat(chat).presetId, preset.id);
    expect(reopened.defaultPresetId, preset.id);
    expect(reopened.search('beacon').single.nodeId, message.nodeId);
    expect(_inspect(path, _currentSnapshot), before);
  });
}

int _version(Database database) => database.select('PRAGMA user_version').single['user_version'] as int;
List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];
List<String> _tableNames(Database database) => [
  for (final row in database.select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"))
    row['name'] as String,
];
List<Map<String, Object?>> _definitions(Database database) =>
    _rows(database, 'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name');
Map<String, Object?> _schema(Database database) => {
  'userVersion': _version(database),
  'schemaVersion': database.select('PRAGMA schema_version').single['schema_version'],
  'definitions': _definitions(database),
};
Map<String, Object?> _legacyData(Database database) => {
  'chats': _rows(database, 'SELECT * FROM chats ORDER BY id'),
  'nodes': _rows(database, 'SELECT * FROM nodes ORDER BY seq'),
  'states': _rows(database, 'SELECT * FROM node_states ORDER BY node_id'),
  'summaries': _rows(database, 'SELECT * FROM summaries ORDER BY id'),
  'memories': _rows(database, 'SELECT * FROM memories ORDER BY id'),
  'runs': _rows(database, 'SELECT * FROM agent_runs ORDER BY id'),
  'unrelated': _rows(database, 'SELECT * FROM unrelated'),
};
void _expectUpgradedLegacyData(Database database, Object? expected) {
  // Keep every old row, field, and unknown column under exact comparison.
  // Strip only the explicitly checked later additions from this genuine v1
  // fixture. Its extra has neither owned inspection nor portable display data.
  const addedNames = {'stream_text', 'stream_reasoning', 'deleted_by', 'reported_usage', 'speaker_character_id'};
  expect(
    _rows(database, 'PRAGMA table_info(nodes)')
        .where(
          (row) =>
              addedNames.contains(row['name']) ||
              row['name'] == 'source_epoch' ||
              row['name'] == 'content_version' ||
              row['name'] == 'display_context',
        )
        .toList(),
    [
      {'cid': 15, 'name': 'stream_text', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      {'cid': 16, 'name': 'stream_reasoning', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      {'cid': 17, 'name': 'deleted_by', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      {'cid': 18, 'name': 'reported_usage', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      {'cid': 19, 'name': 'speaker_character_id', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
      {'cid': 20, 'name': 'source_epoch', 'type': 'INTEGER', 'notnull': 1, 'dflt_value': '0', 'pk': 0},
      {'cid': 21, 'name': 'content_version', 'type': 'INTEGER', 'notnull': 1, 'dflt_value': '1', 'pk': 0},
      {'cid': 22, 'name': 'display_context', 'type': 'TEXT', 'notnull': 0, 'dflt_value': null, 'pk': 0},
    ],
  );
  expect(_rows(database, 'PRAGMA table_info(chats)').where((row) => row['name'] == 'tree_revision').toList(), [
    {'cid': 13, 'name': 'tree_revision', 'type': 'INTEGER', 'notnull': 1, 'dflt_value': '0', 'pk': 0},
  ]);
  final memoryColumns = _rows(database, 'PRAGMA table_info(memories)');
  expect(memoryColumns.take(3).toList(), [
    {'cid': 0, 'name': 'id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 1},
    {'cid': 1, 'name': 'chat_id', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
    {'cid': 2, 'name': 'entry_json', 'type': 'TEXT', 'notnull': 1, 'dflt_value': null, 'pk': 0},
  ]);
  const memoryNames = [
    'origin',
    'origin_proposal_id',
    'origin_logical_turn_id',
    'origin_receipt_id',
    'source_node_id',
    'source_seq',
    'source_epoch',
    'source_content_version',
    'source_live_node_id',
    'source_validity',
    'invalidated_reason',
  ];
  expect(memoryColumns.skip(3).map((column) => column['name']), memoryNames);
  final actual = _legacyData(database);
  for (final row in actual['chats']! as List<Map<String, Object?>>) {
    expect(row.remove('tree_revision'), 0);
  }
  for (final row in actual['nodes']! as List<Map<String, Object?>>) {
    for (final name in addedNames) {
      expect(row.containsKey(name), true);
      expect(row.remove(name), isNull);
    }
    expect(row.remove('source_epoch'), 0);
    expect(row.remove('content_version'), 1);
    expect(jsonDecode(row.remove('display_context')! as String), {
      'dshgo': {'tavernState': null, 'chatJsonl': null},
    });
  }
  for (final row in actual['memories']! as List<Map<String, Object?>>) {
    expect(row.remove('origin'), 'legacy');
    for (final name in memoryNames.skip(1)) {
      expect(row.containsKey(name), true, reason: name);
      expect(row.remove(name), isNull, reason: name);
    }
  }
  expect(actual, expected);
}

Map<String, Object?> _conflictSnapshot(Database database) => {
  'schema': _schema(database),
  'conflict': _rows(database, 'SELECT * FROM preset_preferences'),
  'unrelated': _rows(database, 'SELECT * FROM unrelated'),
};
Map<String, Object?> _currentSnapshot(Database database) => {
  'schema': _schema(database),
  'data': _legacyData(database),
  'presets': _rows(database, 'SELECT * FROM presets ORDER BY id'),
  'preferences': _rows(database, 'SELECT * FROM preset_preferences ORDER BY singleton'),
};
T _inspect<T>(String path, T Function(Database database) operation) {
  final database = sqlite3.open(path);
  try {
    return operation(database);
  } finally {
    database.close();
  }
}

void _legacyDatabase(Database database) {
  database.execute('PRAGMA foreign_keys = ON');
  database.execute(_schemaV1);
  database.execute('PRAGMA user_version = 1');
  database.execute('PRAGMA application_id = 765');
  database.execute('ALTER TABLE chats ADD COLUMN future_column TEXT');
  database.execute('CREATE TABLE unrelated(value TEXT, payload BLOB)');
  database.execute("INSERT INTO unrelated VALUES ('海 {{literal}}', X'0102ff')");
  database.execute(
    '''INSERT INTO chats
    (id, character_id, title, created_at, updated_at, persona_id, preset_id, metadata, variables, settings, future_column)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
    [
      'chat',
      'card',
      'old title',
      1000,
      2000,
      'persona',
      'legacy-unresolved',
      jsonEncode({
        'future': {
          'keep': [1, null],
        },
      }),
      jsonEncode({'n': 2}),
      jsonEncode({
        'preset': {
          'unknown': [null],
        },
        'other': true,
      }),
      'old future column',
    ],
  );
  for (final entry in [
    ('root', null, 1, 'character', 'greeting'),
    ('a', 'root', 2, 'user', 'saved beacon'),
    ('b', 'root', 2, 'narrator', 'alternate'),
  ]) {
    database.execute(
      '''INSERT INTO nodes
      (id, chat_id, parent_id, depth, role, speaker, text, at, extra, original)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        entry.$1,
        'chat',
        entry.$2,
        entry.$3,
        entry.$4,
        '鲸',
        entry.$5,
        1000,
        jsonEncode({
          'unknown': [false, '海'],
        }),
        jsonEncode({'source': null}),
      ],
    );
  }
  database.execute('INSERT INTO node_states(node_id, full_json) VALUES (?, ?)', [
    'root',
    jsonEncode({
      'variables': {'n': 1},
      'unknown': [false, null],
    }),
  ]);
  for (final entry in [('a', 2), ('b', 9)]) {
    database.execute('INSERT INTO node_states(node_id, delta_json) VALUES (?, ?)', [
      entry.$1,
      jsonEncode([
        {
          'op': 'replace',
          'path': '/variables',
          'value': {'n': entry.$2},
        },
      ]),
    ]);
  }
  database.execute("UPDATE nodes SET selected_child_id = 'a' WHERE id = 'root'");
  database.execute("UPDATE chats SET selected_root_id = 'root', current_leaf_id = 'a' WHERE id = 'chat'");
  database.execute("INSERT INTO summaries VALUES ('summary', 'chat', 'root', 'a', 'saved summary', 1)");
  database.execute("INSERT INTO memories VALUES ('memory', 'chat', '{\"unknown\":null}')");
  database.execute("INSERT INTO agent_runs VALUES ('run', 'chat', 'a', 'future', 1000, NULL, '{\"keep\":true}')");
}

// Frozen v1 SQL is appended below; it is deliberately independent of the
// production registry so these are real 1 -> 2 migration fixtures.

const _schemaV1 = '''
CREATE TABLE chats (
  id TEXT PRIMARY KEY NOT NULL,
  character_id TEXT NOT NULL,
  title TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  persona_id TEXT,
  preset_id TEXT,
  selected_root_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  current_leaf_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  metadata TEXT NOT NULL DEFAULT '{}',
  variables TEXT NOT NULL DEFAULT '{}',
  settings TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX chats_character_updated ON chats(character_id, updated_at DESC);
CREATE TABLE nodes (
  seq INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT UNIQUE NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  parent_id TEXT REFERENCES nodes(id) DEFERRABLE INITIALLY DEFERRED,
  selected_child_id TEXT REFERENCES nodes(id) ON DELETE SET NULL DEFERRABLE INITIALLY DEFERRED,
  depth INTEGER NOT NULL CHECK(depth >= 1),
  role TEXT NOT NULL CHECK(role IN ('user', 'character', 'narrator', 'system')),
  speaker TEXT NOT NULL,
  text TEXT NOT NULL,
  reasoning TEXT,
  at INTEGER NOT NULL,
  hidden INTEGER NOT NULL DEFAULT 0 CHECK(hidden IN (0, 1)),
  usage TEXT,
  extra TEXT NOT NULL DEFAULT '{}',
  original TEXT NOT NULL DEFAULT '{}'
);
CREATE INDEX nodes_chat_parent ON nodes(chat_id, parent_id, seq);
CREATE INDEX nodes_parent ON nodes(parent_id);
CREATE INDEX nodes_selected_child ON nodes(selected_child_id);
CREATE INDEX chats_selected_root ON chats(selected_root_id);
CREATE INDEX chats_current_leaf ON chats(current_leaf_id);
CREATE TABLE node_states (
  node_id TEXT PRIMARY KEY NOT NULL REFERENCES nodes(id) ON DELETE CASCADE,
  delta_json TEXT NOT NULL DEFAULT '[]',
  full_json TEXT
);
CREATE TABLE summaries (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  from_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  to_node_id TEXT REFERENCES nodes(id) ON DELETE CASCADE,
  text TEXT NOT NULL,
  manually_edited INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE memories (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  entry_json TEXT NOT NULL
);
CREATE TABLE agent_runs (
  id TEXT PRIMARY KEY NOT NULL,
  chat_id TEXT NOT NULL REFERENCES chats(id) ON DELETE CASCADE,
  node_id TEXT REFERENCES nodes(id) ON DELETE SET NULL,
  kind TEXT NOT NULL,
  at INTEGER NOT NULL,
  usage TEXT,
  result_json TEXT
);
CREATE VIRTUAL TABLE nodes_fts USING fts5(text, speaker, content = 'nodes', content_rowid = 'seq');
CREATE TRIGGER nodes_fts_insert AFTER INSERT ON nodes BEGIN
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
CREATE TRIGGER nodes_fts_delete AFTER DELETE ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
END;
CREATE TRIGGER nodes_fts_update AFTER UPDATE OF text, speaker ON nodes BEGIN
  INSERT INTO nodes_fts(nodes_fts, rowid, text, speaker) VALUES ('delete', old.seq, old.text, old.speaker);
  INSERT INTO nodes_fts(rowid, text, speaker) VALUES (new.seq, new.text, new.speaker);
END;
''';
