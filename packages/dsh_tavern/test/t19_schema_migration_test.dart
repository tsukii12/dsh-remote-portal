import 'dart:io';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// These bootstrap/reopen regressions also run against later real schemas.
// T20 separately checks genuine v1 files and rollback during its v2 step.
void main() {
  late Directory directory;
  late String path;
  ChatStore? store;
  final now = DateTime.utc(2026, 11, 10, 6);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('t19-schema-');
    path = '${directory.path}/tavern.sqlite3';
    store = null;
  });
  tearDown(() async {
    final current = store;
    if (current != null) {
      await current.close();
    }
    await directory.delete(recursive: true);
  });

  test('empty version zero reaches current schema with working tree state and FTS', () {
    final database = sqlite3.open(path);
    expect(_version(database), 0);
    final opened = ChatStore.fromDatabase(database, clock: () => now);
    store = opened;
    expect(_version(database), ChatStore.schemaVersion);
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    final tables = database
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'])
        .toSet();
    expect(tables, containsAll(['chats', 'nodes', 'node_states', 'summaries', 'memories', 'agent_runs', 'nodes_fts']));
    final chat = opened.createChat(id: 'chat', characterId: 'card', variables: {'n': 7});
    final root = opened.append(
      chat,
      id: 'root',
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸',
      text: 'migration beacon',
      state: {
        'variables': {'n': 7},
        'nested': [
          null,
          {'海': true},
        ],
      },
    );
    expect(opened.path(chat).single.nodeId, root.nodeId);
    expect(opened.nodeState(chat, root.nodeId), {
      'variables': {'n': 7},
      'nested': [
        null,
        {'海': true},
      ],
    });
    expect(opened.search('beacon').single.nodeId, root.nodeId);
    expect(database.select('PRAGMA journal_mode').single['journal_mode'], 'wal');
  });

  test('bootstrapping zero retains unrelated tables and original values', () {
    final database = sqlite3.open(path);
    database.execute('CREATE TABLE unrelated(id INTEGER PRIMARY KEY, text_value TEXT, payload BLOB)');
    database.execute("INSERT INTO unrelated VALUES (7, '海 {{literal}}', X'00017fff')");
    final before = _rows(database, 'SELECT * FROM unrelated');
    final opened = ChatStore.fromDatabase(database);
    store = opened;
    expect(_version(database), ChatStore.schemaVersion);
    expect(_rows(database, 'SELECT * FROM unrelated'), before);
    expect(opened.listChats(), isEmpty);
  });

  test('current schema reopening preserves unknown columns and every stored chat document', () async {
    final first = ChatStore.open(path, clock: () => now);
    store = first;
    final chat = first.createChat(
      id: 'chat',
      characterId: 'card',
      metadata: {
        'future': {
          'keep': [1, null],
        },
      },
      variables: {'n': 3},
      settings: {'unknown': 'kept'},
    );
    final root = first.append(
      chat,
      id: 'root',
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸',
      text: 'root',
      state: {
        'variables': {'n': 1},
      },
    );
    final a = first.append(
      chat,
      id: 'a',
      parentId: root.nodeId,
      role: TavernRole.user,
      speaker: 'user',
      text: 'saved beacon',
      extra: {
        'future': [false, '海'],
      },
      original: {'unknown_source': null},
      state: {
        'variables': {'n': 2},
        'a/~': [1, null],
      },
    );
    first.append(
      chat,
      id: 'b',
      parentId: root.nodeId,
      role: TavernRole.narrator,
      speaker: 'narrator',
      text: 'alternate',
      state: {
        'variables': {'n': 9},
      },
    );
    first.selectNode(chat, a.nodeId);
    final expectedState = first.nodeState(chat, a.nodeId);
    await first.close();
    final before = _inspect(path, (database) {
      database.execute('ALTER TABLE chats ADD COLUMN future_column TEXT');
      database.execute("UPDATE chats SET future_column = 'do not discard'");
      database.execute('CREATE TABLE unrelated(value TEXT)');
      database.execute("INSERT INTO unrelated VALUES ('preserved')");
      return _chatSnapshot(database);
    });
    final reopened = ChatStore.open(path, clock: () => now.add(const Duration(days: 1)));
    store = reopened;
    expect(reopened.path(chat).map((message) => message.nodeId), [root.nodeId, a.nodeId]);
    expect(reopened.nodeState(chat, a.nodeId), expectedState);
    expect(reopened.chat(chat).variables, {'n': 3});
    expect(reopened.node(chat, a.nodeId).extra, {
      'future': [false, '海'],
    });
    expect(reopened.search('beacon').single.nodeId, a.nodeId);
    expect(_inspect(path, _chatSnapshot), before);
  });

  test('future schema fails before persistent pragmas or database bytes change', () async {
    final version = ChatStore.schemaVersion + 1;
    _sentinel(path, version);
    final beforeBytes = await File(path).readAsBytes();
    final before = _inspect(path, _schema);
    expect(
      () => ChatStore.open(path),
      throwsA(isA<StateError>().having((error) => error.message, 'reason', contains('uses schema $version'))),
    );
    expect(await File(path).readAsBytes(), orderedEquals(beforeBytes));
    _inspect(path, (database) {
      expect(_schema(database), before);
      expect(_version(database), version);
      expect(database.select('PRAGMA journal_mode').single['journal_mode'], 'delete');
      expect(database.select('PRAGMA application_id').single['application_id'], 777);
      expect(database.select('SELECT hex(payload) AS value FROM sentinel').single['value'], '00017FFF');
    });
  });

  test('negative schema has an explicit error before persistent pragmas or bytes change', () async {
    _sentinel(path, -1);
    final beforeBytes = await File(path).readAsBytes();
    final before = _inspect(path, _schema);
    expect(
      () => ChatStore.open(path),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'reason',
          contains('Invalid tavern database schema version: -1'),
        ),
      ),
    );
    expect(await File(path).readAsBytes(), orderedEquals(beforeBytes));
    _inspect(path, (database) {
      expect(_schema(database), before);
      expect(_version(database), -1);
      expect(database.select('PRAGMA journal_mode').single['journal_mode'], 'delete');
      expect(database.select('PRAGMA application_id').single['application_id'], 777);
      expect(database.select('SELECT hex(payload) AS value FROM sentinel').single['value'], '00017FFF');
    });
  });

  test('late bootstrap failure rolls back earlier DDL and version then permits recovery', () {
    final before = _inspect(path, (database) {
      // agent_runs follows chats/nodes/node_states/summaries/memories in the
      // real v1 step. Its existing name forces failure partway through DDL.
      database.execute('CREATE TABLE agent_runs(keep TEXT)');
      database.execute("INSERT INTO agent_runs VALUES ('original conflicting table')");
      database.execute('CREATE TABLE unrelated(payload BLOB)');
      database.execute("INSERT INTO unrelated VALUES (X'0102ff')");
      return _schema(database);
    });
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    _inspect(path, (database) {
      expect(_schema(database), before);
      expect(_version(database), 0);
      expect(database.select('SELECT keep FROM agent_runs').single['keep'], 'original conflicting table');
      expect(database.select('SELECT hex(payload) AS value FROM unrelated').single['value'], '0102FF');
      final tables = database
          .select("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
          .map((row) => row['name']);
      expect(tables, ['agent_runs', 'unrelated']);
      database.execute('DROP TABLE agent_runs');
    });
    final recovered = ChatStore.open(path);
    store = recovered;
    expect(_inspect(path, _version), ChatStore.schemaVersion);
    final chat = recovered.createChat(id: 'recovered', characterId: 'card');
    recovered.append(
      chat,
      id: 'node',
      parentId: null,
      role: TavernRole.character,
      speaker: '鲸',
      text: 'recovered beacon',
    );
    expect(recovered.search('beacon').single.nodeId, 'node');
    _inspect(path, (database) {
      expect(database.select('SELECT hex(payload) AS value FROM unrelated').single['value'], '0102FF');
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    });
  });
}

int _version(Database database) => database.select('PRAGMA user_version').single['user_version'] as int;
List<Map<String, Object?>> _rows(Database database, String query) => [
  for (final row in database.select(query)) Map<String, Object?>.from(row),
];
Map<String, Object?> _schema(Database database) => {
  'userVersion': _version(database),
  'schemaVersion': database.select('PRAGMA schema_version').single['schema_version'],
  'definitions': _rows(database, 'SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name'),
};
Map<String, Object?> _chatSnapshot(Database database) => {
  'schema': _schema(database),
  'chats': _rows(database, 'SELECT * FROM chats ORDER BY id'),
  'nodes': _rows(database, 'SELECT * FROM nodes ORDER BY seq'),
  'states': _rows(database, 'SELECT * FROM node_states ORDER BY node_id'),
  'unrelated': _rows(database, 'SELECT * FROM unrelated'),
};
T _inspect<T>(String path, T Function(Database database) operation) {
  final database = sqlite3.open(path);
  try {
    return operation(database);
  } finally {
    database.close();
  }
}

void _sentinel(String path, int version) {
  _inspect(path, (database) {
    database.execute('PRAGMA journal_mode = DELETE');
    database.execute('CREATE TABLE sentinel(payload BLOB)');
    database.execute("INSERT INTO sentinel VALUES (X'00017fff')");
    database.execute('PRAGMA application_id = 777');
    database.execute('PRAGMA user_version = $version');
    expect(_version(database), version);
  });
}
