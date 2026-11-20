import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Database database;
  late ChatStore store;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dsh-t24-backup-store-');
    database = sqlite3.open('${directory.path}/source.sqlite3');
    store = ChatStore.fromDatabase(database);
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('online backup includes WAL data and all branches while leaving its source open', () async {
    final chat = store.createChat(
      characterId: 'card',
      metadata: {
        'foreign': {'keep': true},
      },
    );
    final root = store.append(
      chat,
      id: 'root',
      parentId: null,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'reported root',
      state: {'n': 1},
      extra: {
        'dshgo': {
          'inspection': {
            'version': 1,
            'chatId': chat,
            'nodeId': 'root',
            'reportedUsage': {'promptTokens': 11, 'cacheHitTokens': 3, 'completionTokens': 7},
          },
        },
      },
    );
    final a = store.append(
      chat,
      parentId: root.nodeId,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'hidden branch',
      state: {'n': 2},
    );
    final b = store.append(
      chat,
      parentId: root.nodeId,
      role: TavernRole.character,
      speaker: 'Guide',
      text: 'selected branch',
      state: {'n': 9},
    );
    final token = store.softDeleteFrom(chat, a.nodeId);
    final preset = store.createPreset(
      name: 'fixture',
      sourceText: 'original source',
      raw: {
        'future': [1, 2],
      },
    );
    store.setDefaultPreset(preset.id);
    final before = _snapshot(database);
    final destination = File('${directory.path}/backup.sqlite3');
    expect(await store.backupToFile(destination), ChatStore.schemaVersion);
    final copied = sqlite3.open(destination.path, mode: OpenMode.readOnly);
    try {
      expect(_snapshot(copied), before);
      expect(copied.select('PRAGMA journal_mode').single.values.single, 'delete');
      expect(copied.select('PRAGMA foreign_key_check'), isEmpty);
      expect(copied.select('PRAGMA integrity_check').single.values.single, 'ok');
    } finally {
      copied.close();
    }
    expect(File('${destination.path}-wal').existsSync(), isFalse);
    expect(store.path(chat).last.nodeId, b.nodeId);
    expect(store.undoDeleteFrom(chat, token), isTrue);
    store.append(chat, parentId: b.nodeId, role: TavernRole.user, speaker: 'User', text: 'source remains writable');
    await ChatStore.validateBackup(destination, sourceSchemaVersion: ChatStore.schemaVersion);
    final restored = ChatStore.open(destination.path);
    try {
      expect(restored.path(chat).last.nodeId, b.nodeId);
      expect(() => restored.node(chat, a.nodeId), throwsStateError);
      expect(restored.message(chat, root.nodeId).reportedUsage!.promptTokens, 11);
      expect(restored.nodeState(chat, b.nodeId), {'n': 9});
      expect(restored.defaultPresetId, preset.id);
      expect(restored.preset(preset.id)!.raw, {
        'future': [1, 2],
      });
      expect(restored.undoDeleteFrom(chat, token), isFalse);
    } finally {
      await restored.close();
    }
  });

  test('backup refuses existing files and directories without changing their contents', () async {
    final destination = File('${directory.path}/existing.sqlite3');
    final bytes = utf8.encode('not a database, still must be left alone');
    await destination.writeAsBytes(bytes);
    await expectLater(store.backupToFile(destination), throwsA(isA<FileSystemException>()));
    expect(await destination.readAsBytes(), bytes);
    await expectLater(store.backupToFile(File(directory.path)), throwsA(isA<FileSystemException>()));
    final chat = store.createChat(characterId: 'still-open');
    expect(store.chat(chat).characterId, 'still-open');
  });

  test('staging validation migrates a genuine v4 copy without touching the archived input', () async {
    final archived = File('${directory.path}/archived-v4.sqlite3');
    final old = sqlite3.open(archived.path);
    try {
      old.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
      old.execute("INSERT INTO chats(id,character_id,title,created_at,updated_at) VALUES('c','card','old',1,2)");
      old.execute(
        '''INSERT INTO nodes(id,chat_id,depth,role,speaker,text,at,extra)
        VALUES('n','c',1,'character','Guide','old body',1,?)''',
        [
          jsonEncode({
            'dshgo': {
              'inspection': {
                'version': 1,
                'chatId': 'c',
                'nodeId': 'n',
                'reportedUsage': {'promptTokens': 0, 'cacheHitTokens': 0, 'completionTokens': 0},
              },
            },
          }),
        ],
      );
      old.execute("INSERT INTO node_states(node_id,full_json) VALUES('n','{}')");
    } finally {
      old.close();
    }
    final staged = await archived.copy('${directory.path}/staged.sqlite3');
    await ChatStore.validateBackup(staged, sourceSchemaVersion: 4);
    final original = sqlite3.open(archived.path, mode: OpenMode.readOnly);
    final migrated = sqlite3.open(staged.path, mode: OpenMode.readOnly);
    try {
      expect(original.select('PRAGMA user_version').single['user_version'], 4);
      expect(original.select('PRAGMA table_info(nodes)').map((row) => row['name']), isNot(contains('reported_usage')));
      expect(migrated.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
      final usage = jsonDecode(migrated.select('SELECT reported_usage FROM nodes').single['reported_usage']! as String);
      expect(usage, {'promptTokens': 0, 'cacheHitTokens': 0, 'completionTokens': 0, 'model': null});
    } finally {
      original.close();
      migrated.close();
    }
  });

  test('manifest mismatch and unsupported versions fail before staging migration', () async {
    final target = File('${directory.path}/version.sqlite3');
    var original = sqlite3.open(target.path);
    original.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
    original.close();
    await expectLater(ChatStore.validateBackup(target, sourceSchemaVersion: 3), throwsFormatException);
    original = sqlite3.open(target.path);
    expect(original.select('PRAGMA user_version').single['user_version'], 4);
    expect(original.select('PRAGMA table_info(chats)').map((row) => row['name']), isNot(contains('tree_revision')));
    original.execute('PRAGMA user_version=999');
    original.close();
    await expectLater(ChatStore.validateBackup(target, sourceSchemaVersion: 999), throwsFormatException);
    original = sqlite3.open(target.path, mode: OpenMode.readOnly);
    expect(original.select('PRAGMA user_version').single['user_version'], 999);
    original.close();
  });

  test('foreign-key damage and non-database input are rejected without being silently repaired', () async {
    final target = File('${directory.path}/foreign-key.sqlite3');
    final broken = sqlite3.open(target.path);
    broken.execute(File('test/fixtures/t24_schema_v4.sql').readAsStringSync());
    broken.execute('PRAGMA foreign_keys=OFF');
    broken.execute("INSERT INTO chats(id,character_id,title,created_at,updated_at) VALUES('c','card','old',1,2)");
    broken.execute(
      "INSERT INTO nodes(id,chat_id,parent_id,depth,role,speaker,text,at) VALUES('n','c','missing',2,'user','User','broken',1)",
    );
    broken.close();
    await expectLater(ChatStore.validateBackup(target, sourceSchemaVersion: 4), throwsFormatException);
    final inspect = sqlite3.open(target.path, mode: OpenMode.readOnly);
    try {
      expect(inspect.select('PRAGMA user_version').single['user_version'], 4);
      expect(inspect.select('PRAGMA foreign_key_check'), isNotEmpty);
    } finally {
      inspect.close();
    }
    final malformed = File('${directory.path}/malformed.sqlite3');
    await malformed.writeAsString('not a SQLite database');
    final bytes = await malformed.readAsBytes();
    await expectLater(ChatStore.validateBackup(malformed, sourceSchemaVersion: 4), throwsA(isA<SqliteException>()));
    expect(await malformed.readAsBytes(), bytes);
    await expectLater(
      ChatStore.validateBackup(File('${directory.path}/missing.sqlite3'), sourceSchemaVersion: 4),
      throwsA(isA<FileSystemException>()),
    );
  });
}

Map<String, Object?> _snapshot(Database database) => {
  for (final table in ['chats', 'nodes', 'node_states', 'deleted_subtrees', 'presets', 'preset_preferences'])
    table: [for (final row in database.select('SELECT * FROM $table ORDER BY 1')) Map<String, Object?>.from(row)],
};
