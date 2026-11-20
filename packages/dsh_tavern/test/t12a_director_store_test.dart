import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// Real SQLite queries and a fixed historical schema. No elapsed-time claim or
// production query hook substitutes for the result and migration contracts.
void main() {
  test('a new database retains the exact chat and kind index and reopens without replaying it', () async {
    final directory = await _temporaryDirectory();
    final path = '${directory.path}/current.sqlite3';
    final first = ChatStore.open(path);
    try {
      first.createChat(id: 'kept', characterId: 'card');
    } finally {
      await first.close();
    }
    final database = sqlite3.open(path);
    final store = _own(database);
    expect(_version(database), ChatStore.schemaVersion);
    _expectEmptyGroups(database);
    expect(_indexColumns(database), ['chat_id', 'kind']);
    expect(database.select("SELECT name FROM sqlite_master WHERE name = 'agent_runs_chat_kind'"), hasLength(1));
    expect(store.chat('kept').characterId, 'card');
    expect(database.select('PRAGMA foreign_key_check'), isEmpty);
  });

  test('single-kind queries separate chat and exact kind through clock rollback and unrelated audit tails', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    _run(store, 'first', 'director.success', at: 9000);
    _run(store, 'second', 'director.success', at: 1);
    _run(store, 'quoted', "director.'literal", at: 3000);
    for (var i = 0; i < 120; i++) {
      _run(store, 'state-$i', 'state.tool', at: 10000 + i);
      _run(store, 'foreign-$i', 'director.success', chat: 'other', at: 20000 + i);
    }
    final before = _data(database);
    expect(_ids(store.agentRunsByKind('chat', {'director.success'}, limit: 1)), ['second']);
    expect(_ids(store.agentRunsByKind('chat', {'director.success'}, beforeId: 'second')), ['first']);
    expect(_ids(store.agentRunsByKind('chat', {"director.'literal"})), ['quoted']);
    expect(store.agentRunsByKind('chat', {'absent'}), isEmpty);
    expect(store.agentRuns('chat').first.id, 'state-119');
    expect(_data(database), before);
  });

  test('multi-kind top N agrees with global rowid ordering for limits and either-kind exclusive cursors', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    final sequence = [
      'director.success',
      'state.tool',
      'director.failure',
      'director.success',
      'director.event',
      'director.failure',
      'director.failure',
      'director.success',
    ];
    for (var i = 0; i < 48; i++) {
      _run(store, 'local-$i', sequence[i % sequence.length], at: 5000 - i);
      _run(store, 'foreign-$i', sequence[(i + 1) % sequence.length], chat: 'other', at: i);
    }
    final before = _data(database);
    for (final kinds in <Set<String>>[
      {'director.success', 'director.failure'},
      {'director.failure', 'director.success'},
      {'director.success', 'director.event', 'director.failure', 'absent'},
    ]) {
      final all = _oracle(database, kinds, limit: 100);
      for (final limit in [1, 2, 7, 50]) {
        for (final cursor in <String?>[null, all[1], all[all.length ~/ 2], all.last]) {
          expect(
            _ids(store.agentRunsByKind('chat', kinds, limit: limit, beforeId: cursor)),
            _oracle(database, kinds, limit: limit, beforeId: cursor),
            reason: 'kinds=$kinds limit=$limit cursor=$cursor',
          );
        }
      }
    }
    expect(_data(database), before);
  });

  test('multi-kind pages remain exclusive when newer publications arrive between reads', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    for (var i = 0; i < 7; i++) {
      _run(store, 'run-$i', i.isEven ? 'director.success' : 'director.failure', at: 100 - i);
    }
    const kinds = {'director.success', 'director.failure'};
    final first = store.agentRunsByKind('chat', kinds, limit: 3);
    _run(store, 'later', 'director.failure', at: 0);
    final second = store.agentRunsByKind('chat', kinds, limit: 3, beforeId: first.last.id);
    final third = store.agentRunsByKind('chat', kinds, limit: 3, beforeId: second.last.id);
    expect(
      [..._ids(first), ..._ids(second), ..._ids(third)],
      ['run-6', 'run-5', 'run-4', 'run-3', 'run-2', 'run-1', 'run-0'],
    );
    expect(store.agentRunsByKind('chat', kinds, beforeId: third.last.id), isEmpty);
    expect(store.agentRunsByKind('chat', kinds, limit: 1).single.id, 'later');
  });

  test('validation order and cursor identity remain stable for zero empty and invalid requests', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    _run(store, 'success', 'director.success');
    _run(store, 'failure', 'director.failure');
    _run(store, 'foreign', 'director.success', chat: 'other');
    final before = _data(database);
    expect(() => store.agentRunsByKind('missing', {}, limit: 0), throwsStateError);
    expect(() => store.agentRunsByKind('missing', {}, limit: -1), throwsStateError);
    expect(() => store.agentRunsByKind('chat', {}, limit: -1), throwsArgumentError);
    expect(store.agentRunsByKind('chat', {}, beforeId: 'absent'), isEmpty);
    expect(store.agentRunsByKind('chat', {'director.success'}, limit: 0, beforeId: 'absent'), isEmpty);
    for (final cursor in ['absent', 'foreign', 'failure']) {
      expect(() => store.agentRunsByKind('chat', {'director.success'}, beforeId: cursor), throwsStateError);
    }
    expect(_ids(store.agentRunsByKind('chat', {'director.success', 'director.failure'}, beforeId: 'failure')), [
      'success',
    ]);
    expect(_data(database), before);
  });

  test('selected malformed documents retain their row positions and are valid exclusive cursors', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    _run(store, 'older-valid', 'director.success');
    final invalid = <({String id, String column, String raw})>[
      (id: 'bad-result', column: 'result_json', raw: '{invalid'),
      (id: 'non-map-result', column: 'result_json', raw: '[]'),
      (id: 'nonfinite-result', column: 'result_json', raw: '{"x":1e999}'),
      (id: 'bad-usage', column: 'usage', raw: '{invalid'),
      (id: 'nonfinite-usage', column: 'usage', raw: '{"x":1e999}'),
    ];
    for (var i = 0; i < invalid.length; i++) {
      final bad = invalid[i];
      _run(store, bad.id, i.isEven ? 'director.failure' : 'director.success');
      database.execute('UPDATE agent_runs SET ${bad.column} = ? WHERE id = ?', [bad.raw, bad.id]);
    }
    final before = _data(database);
    const kinds = {'director.success', 'director.failure'};
    final selected = store.agentRunsByKind('chat', kinds, limit: invalid.length);
    expect(_ids(selected), invalid.reversed.map((row) => row.id).toList());
    for (final row in selected) {
      expect(row.result, {'version': 0, 'unavailable': 'invalid_saved_director_json'});
      expect(row.usage, isNull);
    }
    expect(_ids(store.agentRunsByKind('chat', kinds, beforeId: selected.last.id)), ['older-valid']);
    expect(_data(database), before);
  });

  test('a per-kind candidate excluded from the global top N is never decoded', () {
    final database = sqlite3.openInMemory();
    final store = _own(database);
    _chats(store);
    _run(store, 'old-invalid-date', 'director.failure');
    // Unlike malformed JSON, an invalid SQL date cannot construct even the
    // unavailable DTO. It exposes premature decoding without a test hook.
    database.execute("UPDATE agent_runs SET at = 'not-an-integer' WHERE id = 'old-invalid-date'");
    _run(store, 'newer-1', 'director.success');
    _run(store, 'newer-2', 'director.success');
    final before = _data(database);
    expect(_ids(store.agentRunsByKind('chat', {'director.failure', 'director.success'}, limit: 1)), ['newer-2']);
    expect(_ids(store.agentRunsByKind('chat', {'director.success', 'director.failure'}, limit: 2)), [
      'newer-2',
      'newer-1',
    ]);
    expect(() => store.agentRunsByKind('chat', {'director.failure'}), throwsA(isA<TypeError>()));
    expect(_data(database), before);
  });

  test(
    'a genuine V5 database gains the index and group schema while user rows and original JSON bytes survive',
    () async {
      final directory = await _temporaryDirectory();
      final database = _createV5('${directory.path}/old.sqlite3');
      expect(_version(database), 5);
      expect(_indexColumns(database), isEmpty);
      final before = _data(database, includeVendor: true);
      final store = _own(database);
      expect(_version(database), ChatStore.schemaVersion);
      _expectEmptyGroups(database);
      expect(_indexColumns(database), ['chat_id', 'kind']);
      expect(_data(database, includeVendor: true), before);
      expect(_ids(store.agentRunsByKind('chat', {'director.success', 'director.failure'})), ['audit-new', 'audit-old']);
      final history = store.historyTo('chat', 'leaf');
      expect(history.map((node) => node.message.nodeId), ['root', 'leaf']);
      expect(history.last.message.usage!.cacheHitTokens, 1);
      expect(history.last.message.reportedUsage!.cacheHitTokens, 2);
      expect(database.select("SELECT rowid FROM nodes_fts WHERE nodes_fts MATCH 'V5needle'"), hasLength(1));
      expect(database.select('PRAGMA integrity_check').single['integrity_check'], 'ok');
      expect(database.select('PRAGMA foreign_key_check'), isEmpty);
    },
  );

  test('a real V6 DDL failure rolls back the version and preserves V5 rows for a clean retry', () async {
    final directory = await _temporaryDirectory();
    final path = '${directory.path}/failed.sqlite3';
    final legacy = _createV5(path);
    legacy.execute('CREATE INDEX agent_runs_chat_kind ON agent_runs(at)');
    final before = _data(legacy, includeVendor: true);
    final schemaBefore = _schema(legacy);
    legacy.close();
    expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
    final repaired = sqlite3.open(path);
    try {
      expect(_version(repaired), 5);
      expect(_schema(repaired), schemaBefore);
      expect(_data(repaired, includeVendor: true), before);
      repaired.execute('DROP INDEX agent_runs_chat_kind');
    } finally {
      repaired.close();
    }
    final database = sqlite3.open(path);
    _own(database);
    expect(_version(database), ChatStore.schemaVersion);
    _expectEmptyGroups(database);
    expect(_indexColumns(database), ['chat_id', 'kind']);
    expect(_data(database, includeVendor: true), before);
  });

  test('backup validation upgrades a genuine V5 staging copy without changing the archived source', () async {
    final directory = await _temporaryDirectory();
    final archive = File('${directory.path}/archived-v5.sqlite3');
    final legacy = _createV5(archive.path);
    final before = _data(legacy, includeVendor: true);
    legacy.close();
    final archivedBytes = await archive.readAsBytes();
    final staging = await archive.copy('${directory.path}/staging.sqlite3');
    await expectLater(ChatStore.validateBackup(staging, sourceSchemaVersion: 6), throwsFormatException);
    final unmodified = sqlite3.open(staging.path, mode: OpenMode.readOnly);
    try {
      expect(_version(unmodified), 5);
      expect(_indexColumns(unmodified), isEmpty);
    } finally {
      unmodified.close();
    }
    await ChatStore.validateBackup(staging, sourceSchemaVersion: 5);
    final migrated = sqlite3.open(staging.path, mode: OpenMode.readOnly);
    try {
      expect(_version(migrated), ChatStore.schemaVersion);
      expect(_indexColumns(migrated), ['chat_id', 'kind']);
      expect(_data(migrated, includeVendor: true), before);
    } finally {
      migrated.close();
    }
    expect(await archive.readAsBytes(), archivedBytes);
  });

  test('failed backup staging migration leaves original V5 data recoverable and releases its handles', () async {
    final directory = await _temporaryDirectory();
    final archive = File('${directory.path}/archive.sqlite3');
    final legacy = _createV5(archive.path);
    legacy.execute('CREATE INDEX agent_runs_chat_kind ON agent_runs(at)');
    final before = _data(legacy, includeVendor: true);
    legacy.close();
    final original = await archive.readAsBytes();
    final staging = await archive.copy('${directory.path}/staging.sqlite3');
    await expectLater(ChatStore.validateBackup(staging, sourceSchemaVersion: 5), throwsA(isA<SqliteException>()));
    final repair = sqlite3.open(staging.path);
    try {
      expect(_version(repair), 5);
      expect(_data(repair, includeVendor: true), before);
      repair.execute('DROP INDEX agent_runs_chat_kind');
    } finally {
      repair.close();
    }
    await ChatStore.validateBackup(staging, sourceSchemaVersion: 5);
    // Renaming after the validator returns also exercises closed native handles
    // on platforms which prohibit moving an open SQLite file.
    final renamed = await staging.rename('${directory.path}/validated.sqlite3');
    final check = sqlite3.open(renamed.path, mode: OpenMode.readOnly);
    try {
      expect(_version(check), ChatStore.schemaVersion);
      expect(_data(check, includeVendor: true), before);
    } finally {
      check.close();
    }
    expect(await archive.readAsBytes(), original);
  });

  test('an online backup includes the index and latest audit rows while its source remains writable', () async {
    final directory = await _temporaryDirectory();
    final database = sqlite3.open('${directory.path}/live.sqlite3');
    final store = _own(database);
    _chats(store);
    _run(store, 'before-backup', 'director.success');
    final destination = File('${directory.path}/snapshot.sqlite3');
    expect(await store.backupToFile(destination), ChatStore.schemaVersion);
    final captured = sqlite3.open(destination.path, mode: OpenMode.readOnly);
    try {
      expect(captured.select('PRAGMA journal_mode').single['journal_mode'], 'delete');
    } finally {
      captured.close();
    }
    _run(store, 'after-backup', 'director.failure');
    await ChatStore.validateBackup(destination, sourceSchemaVersion: ChatStore.schemaVersion);
    final copy = sqlite3.open(destination.path, mode: OpenMode.readOnly);
    try {
      expect(_version(copy), ChatStore.schemaVersion);
      expect(_indexColumns(copy), ['chat_id', 'kind']);
      expect(copy.select('SELECT id FROM agent_runs ORDER BY rowid').map((row) => row['id']), ['before-backup']);
    } finally {
      copy.close();
    }
    expect(_ids(store.agentRunsByKind('chat', {'director.success', 'director.failure'})), [
      'after-backup',
      'before-backup',
    ]);
  });
}

Future<Directory> _temporaryDirectory() async {
  final directory = await Directory.systemTemp.createTemp('dsh-t12a-director-');
  addTearDown(() async {
    await directory.delete(recursive: true);
  });
  return directory;
}

ChatStore _own(Database database) {
  final store = ChatStore.fromDatabase(database);
  addTearDown(store.close);
  return store;
}

void _chats(ChatStore store) {
  store.createChat(id: 'chat', characterId: 'card');
  store.createChat(id: 'other', characterId: 'card');
}

void _run(ChatStore store, String id, String kind, {String chat = 'chat', int at = 1000}) {
  store.writeAgentRun(
    StoredAgentRun(
      id: id,
      chatId: chat,
      kind: kind,
      at: DateTime.fromMillisecondsSinceEpoch(at, isUtc: true),
      result: {'id': id, 'version': 1},
    ),
  );
}

List<String> _ids(List<StoredAgentRun> rows) => [for (final row in rows) row.id];

List<String> _oracle(Database database, Set<String> kinds, {required int limit, String? beforeId}) {
  final slots = List.filled(kinds.length, '?').join(',');
  final int? before = beforeId == null
      ? null
      : database.select('SELECT rowid FROM agent_runs WHERE id = ?', [beforeId]).single['rowid'] as int;
  return [
    for (final row in database.select(
      '''SELECT id FROM agent_runs
    WHERE chat_id = ? AND kind IN ($slots) AND (? IS NULL OR rowid < ?)
    ORDER BY rowid DESC LIMIT ?''',
      ['chat', ...kinds, before, before, limit],
    ))
      row['id'] as String,
  ];
}

int _version(Database database) => database.select('PRAGMA user_version').single['user_version'] as int;

List<String> _indexColumns(Database database) => [
  for (final row in database.select('PRAGMA index_info(agent_runs_chat_kind)')) row['name'] as String,
];

List<Map<String, Object?>> _schema(Database database) => [
  for (final row in database.select('SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name'))
    Map<String, Object?>.from(row),
];

Map<String, Object?> _data(Database database, {bool includeVendor = false}) => {
  for (final table in [
    'chats',
    'nodes',
    'node_states',
    'summaries',
    'memories',
    'agent_runs',
    'presets',
    'preset_preferences',
    'deleted_subtrees',
    if (includeVendor) 'vendor_extension',
  ])
    table: [
      for (final row in database.select('SELECT rowid AS storage_rowid, * FROM $table ORDER BY rowid'))
        _legacyRow(table, row),
    ],
};

// Compare every historical column byte-for-byte. Check each deliberate schema
// addition before omitting it from the historical projection; retain vendor data.
Map<String, Object?> _legacyRow(String table, Row row) {
  final result = Map<String, Object?>.from(row);
  if (table == 'nodes' && result.containsKey('speaker_character_id')) {
    expect(result['speaker_character_id'], isNull);
    result.remove('speaker_character_id');
  }
  if (table == 'nodes' && result.containsKey('source_epoch')) {
    expect(result.remove('source_epoch'), 0);
    expect(result.remove('content_version'), 1);
  }
  if (table == 'nodes' && result.containsKey('display_context')) {
    expect(jsonDecode(result.remove('display_context')! as String), {
      'dshgo': {'tavernState': null, 'chatJsonl': null},
    });
  }
  if (table == 'memories' && result.containsKey('origin')) {
    expect(result.remove('origin'), 'legacy');
    for (final name in [
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
    ]) {
      expect(result.containsKey(name), true, reason: name);
      expect(result.remove(name), isNull, reason: name);
    }
  }
  return result;
}

void _expectEmptyGroups(Database database) {
  expect(database.select('SELECT * FROM group_chats'), isEmpty);
  expect(database.select('SELECT * FROM group_members'), isEmpty);
}

Database _createV5(String path) {
  final database = sqlite3.open(path);
  try {
    database.execute(File('test/fixtures/t12a_schema_v5.sql').readAsStringSync());
    database.execute('BEGIN');
    database.execute('ALTER TABLE chats ADD COLUMN vendor_note TEXT');
    database.execute('CREATE TABLE vendor_extension(id TEXT PRIMARY KEY, bytes BLOB NOT NULL)');
    database.execute("INSERT INTO vendor_extension VALUES ('opaque', X'0001FF80')");
    database.execute(
      '''INSERT INTO chats(id, character_id, title, created_at, updated_at,
      selected_root_id, current_leaf_id, metadata, variables, settings, tree_revision, vendor_note)
      VALUES ('chat', 'card', 'V5 retained', 100, 200, 'root', 'leaf', ?, ?, ?, 17, 'unknown column')''',
      [' {"vendor":[null,true,"海"]} ', '{ "counter" : 3 }', '{"director":{"enabled":true}}'],
    );
    database.execute(
      '''INSERT INTO nodes(id, chat_id, parent_id, selected_child_id, depth, role, speaker,
      text, reasoning, at, hidden, usage, reported_usage, extra, original)
      VALUES ('root', 'chat', NULL, 'leaf', 1, 'character', 'Guide', 'V5needle root', NULL, 100,
      0, NULL, NULL, ?, ?)''',
      [' {"opaque":" root "} ', '{ "original" : [1,null] }'],
    );
    database.execute(
      '''INSERT INTO nodes(id, chat_id, parent_id, depth, role, speaker, text, reasoning,
      at, hidden, usage, reported_usage, extra, original)
      VALUES ('leaf', 'chat', 'root', 2, 'character', 'Guide', 'leaf', 'reasoning', 110, 1, ?, ?, ?, ?)''',
      [
        '{"promptTokens":4,"cacheHitTokens":1,"completionTokens":2}',
        '{"promptTokens":7,"cacheHitTokens":2,"completionTokens":5}',
        '{ "dshgo" : {"opaque":true}, "vendor": 8 }',
        '{"preserved":true}',
      ],
    );
    database.execute('''INSERT INTO nodes(id, chat_id, parent_id, depth, role, speaker, text, at)
      VALUES ('sibling', 'chat', 'root', 2, 'character', 'Guide', 'sibling', 120)''');
    database.execute('INSERT INTO node_states(node_id, delta_json, full_json) VALUES (?, ?, ?)', [
      'leaf',
      '[ {"op":"replace","path":"/score","value":3} ]',
      '{ "score" : 3 }',
    ]);
    database.execute("INSERT INTO summaries VALUES ('summary', 'chat', 'root', 'leaf', 'retained summary', 1)");
    database.execute('INSERT INTO memories VALUES (?, ?, ?)', [
      'memory',
      'chat',
      ' {"key":["native"],"content":"literal {{unchanged}}","opaque":null} ',
    ]);
    database.execute('INSERT INTO agent_runs VALUES (?, ?, ?, ?, ?, ?, ?)', [
      'audit-old',
      'chat',
      'root',
      'director.success',
      9000,
      null,
      ' {"version":1,"notes":"old"} ',
    ]);
    database.execute('INSERT INTO agent_runs VALUES (?, ?, ?, ?, ?, ?, ?)', [
      'audit-new',
      'chat',
      'leaf',
      'director.failure',
      1,
      '{ "tokens" : 2 }',
      '{"version":1,"future":[1,null]}',
    ]);
    database.execute(
      '''INSERT INTO presets(id, name, source_text, raw_json, envelope_json,
      created_at, updated_at, import_report_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
      [
        'preset',
        'Kept preset',
        'original source',
        ' {"prompts":[]} ',
        '{ "opaque" : 9 }',
        10,
        20,
        '{"version":1,"fingerprint":"retained"}',
      ],
    );
    database.execute("UPDATE preset_preferences SET default_preset_id = 'preset' WHERE singleton = 1");
    database.execute("UPDATE chats SET preset_id = 'preset' WHERE id = 'chat'");
    database.execute('COMMIT');
    return database;
  } catch (_) {
    database.close();
    rethrow;
  }
}
