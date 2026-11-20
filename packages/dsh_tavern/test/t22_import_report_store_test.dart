import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('report collections are detached and immutable, with complete JSON roundtrip', () {
    final counts = <String, int>{'regexScripts': 2};
    final findings = <TavernImportFinding>[
      const TavernImportFinding(
        path: r'$.entries[2].content',
        code: 'example',
        message: '说明',
        kind: TavernImportFindingKind.conditional,
        identifier: 'same',
        line: 3,
        offset: 7,
        conditional: true,
        fallback: true,
      ),
    ];
    final report = TavernImportReport(
      kind: TavernImportKind.lorebook,
      checkedAt: DateTime.utc(2026, 11, 10),
      verdict: TavernImportVerdict.partial,
      counts: counts,
      findings: findings,
      renderLevel: 1,
      fingerprint: 'saved',
    );
    counts['regexScripts'] = 999;
    findings.clear();
    expect(report.counts['regexScripts'], 2);
    expect(report.findings.single.offset, 7);
    expect(() => report.counts['regexScripts'] = 0, throwsUnsupportedError);
    expect(() => report.findings.clear(), throwsUnsupportedError);
    final json = jsonDecode(jsonEncode(report.toJson())) as Map<String, Object?>;
    final restored = TavernImportReport.fromJson(json);
    expect(restored.toJson(), report.toJson());
    (json['counts']! as Map<String, Object?>)['regexScripts'] = 0;
    (json['findings']! as List<Object?>).clear();
    expect(restored.counts['regexScripts'], 2);
    expect(restored.findings.single.path, r'$.entries[2].content');
    expect(restored.withStale(true).stale, isTrue);
    expect(restored.stale, isFalse);
  });

  test('fingerprint ignores object ordering and resource ordering but detects actual input changes', () {
    final a = importFingerprint(
      TavernImportKind.character,
      {
        'b': [1, null, true],
        'a': {'z': '海', 'y': 2},
      },
      envelope: {'v': 1},
      embeddedAssetPaths: ['b.png', 'a.png'],
    );
    final b = importFingerprint(
      TavernImportKind.character,
      {
        'a': {'y': 2, 'z': '海'},
        'b': [1, null, true],
      },
      envelope: {'v': 1},
      embeddedAssetPaths: ['a.png', 'b.png', 'a.png'],
    );
    expect(a, b);
    for (final changed in [
      importFingerprint(
        TavernImportKind.character,
        {
          'a': {'y': 2, 'z': '海'},
          'b': [null, 1, true],
        },
        envelope: {'v': 1},
        embeddedAssetPaths: ['a.png', 'b.png'],
      ),
      importFingerprint(
        TavernImportKind.character,
        {
          'a': {'y': 2, 'z': '海'},
          'b': [1, null, true],
        },
        envelope: {'v': 2},
        embeddedAssetPaths: ['a.png', 'b.png'],
      ),
      importFingerprint(
        TavernImportKind.character,
        {
          'a': {'y': 2, 'z': '海'},
          'b': [1, null, true],
        },
        envelope: {'v': 1},
        embeddedAssetPaths: ['a.png'],
      ),
      importFingerprint(
        TavernImportKind.preset,
        {
          'a': {'y': 2, 'z': '海'},
          'b': [1, null, true],
        },
        envelope: {'v': 1},
        embeddedAssetPaths: ['a.png', 'b.png'],
      ),
    ]) {
      expect(changed, isNot(a));
    }
  });

  test('future report versions and impossible rendering levels fail visibly', () {
    final json = _report({'x': 1}).toJson();
    expect(() => TavernImportReport.fromJson({...json, 'version': 2}), throwsFormatException);
    expect(() => TavernImportReport.fromJson({...json, 'renderLevel': 3}), throwsFormatException);
  });

  group('schema three and report transactions', () {
    late Directory directory;
    late String path;
    ChatStore? store;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('t22-report-store-');
      path = '${directory.path}/tavern.sqlite3';
      store = null;
    });
    tearDown(() async {
      await store?.close();
      await directory.delete(recursive: true);
    });

    test('genuine v2 gains a nullable report without changing existing content or selections', () {
      const source = '\uFEFF{\r\n "海": "🌊"\r\n}\r\n';
      final before = _withDatabase(path, (database) {
        _createV2(database);
        database.execute('ALTER TABLE presets ADD COLUMN future_column TEXT');
        database.execute(
          '''INSERT INTO presets
          (id, name, source_text, raw_json, envelope_json, created_at, updated_at, future_column)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
          ['saved', '旧预设', source, '{"foreign":[null,true]}', '{"future":99}', 1000, 2000, 'keep'],
        );
        database.execute("UPDATE preset_preferences SET default_preset_id = 'saved'");
        database.execute('''INSERT INTO chats(id, character_id, title, created_at, updated_at, preset_id)
          VALUES ('chat', 'card', 'saved chat', 1, 2, 'saved')''');
        return _preservedRows(database);
      });
      final opened = ChatStore.open(path);
      store = opened;
      expect(ChatStore.schemaVersion, greaterThanOrEqualTo(3));
      final saved = opened.preset('saved')!;
      expect(saved.sourceText, source);
      expect(saved.raw, {
        'foreign': [null, true],
      });
      expect(saved.envelope, {'future': 99});
      expect(saved.importReport, isNull);
      expect(opened.defaultPresetId, 'saved');
      expect(opened.chat('chat').presetId, 'saved');
      _withDatabase(path, (database) {
        expect(database.select('PRAGMA user_version').single['user_version'], ChatStore.schemaVersion);
        expect(_preservedRows(database), before);
        expect(database.select('SELECT tree_revision FROM chats').single['tree_revision'], 0);
        expect(database.select('SELECT import_report_json FROM presets').single['import_report_json'], isNull);
        expect(database.select('PRAGMA foreign_key_check'), isEmpty);
      });
    });

    test('failed 2-to-3 migration retains v2 version data and conflicting unknown column', () {
      final before = _withDatabase(path, (database) {
        _createV2(database);
        database.execute('ALTER TABLE presets ADD COLUMN import_report_json TEXT');
        database.execute('''INSERT INTO presets
          (id, name, source_text, raw_json, created_at, updated_at, import_report_json)
          VALUES ('saved', 'old', '{}', '{}', 1, 2, 'external column')''');
        return _snapshot(database);
      });
      expect(() => ChatStore.open(path), throwsA(isA<SqliteException>()));
      _withDatabase(path, (database) {
        expect(_snapshot(database), before);
        expect(database.select('PRAGMA user_version').single['user_version'], 2);
      });
    });

    test('report commits with its preset and remains intact through edits and reopening', () async {
      final database = sqlite3.open(path);
      final opened = ChatStore.fromDatabase(database, clock: () => DateTime.utc(2026, 11, 10));
      store = opened;
      final raw = <String, Object?>{
        'unknown': [false, null],
      };
      final report = _report(raw);
      final saved = opened.createPreset(name: 'saved', sourceText: '\uFEFF{}\r\n', raw: raw, importReport: report);
      expect(saved.importReport!.toJson(), report.toJson());
      final changed = opened.updatePreset(
        saved.id,
        name: saved.name,
        raw: {
          'unknown': [true],
        },
        envelope: null,
      );
      expect(changed.importReport!.fingerprint, report.fingerprint);
      expect(changed.sourceText, saved.sourceText);
      await opened.close();
      final reopened = ChatStore.open(path);
      store = reopened;
      expect(reopened.preset(saved.id)!.importReport!.toJson(), report.toJson());
      expect(reopened.preset(saved.id)!.raw, {
        'unknown': [true],
      });
    });

    test('failed preset insert cannot publish either a row or its report', () {
      final database = sqlite3.open(path);
      final opened = ChatStore.fromDatabase(database);
      store = opened;
      database.execute('''CREATE TRIGGER reject_insert AFTER INSERT ON presets BEGIN
        SELECT RAISE(ABORT, 'fixture insert failure'); END;''');
      expect(
        () => opened.createPreset(name: 'failed', sourceText: '{}', raw: {}, importReport: _report({})),
        throwsA(isA<SqliteException>()),
      );
      expect(opened.listPresets(), isEmpty);
      expect(database.select('SELECT * FROM presets'), isEmpty);
      expect(opened.defaultPresetId, isNull);
    });

    test('failed report refresh preserves the old report and all preset content', () {
      final database = sqlite3.open(path);
      final opened = ChatStore.fromDatabase(database);
      store = opened;
      final saved = opened.createPreset(
        name: 'saved',
        sourceText: 'original',
        raw: {'x': 1},
        importReport: _report({'x': 1}),
      );
      final before = _rows(database, 'SELECT * FROM presets');
      database.execute('''CREATE TRIGGER reject_report BEFORE UPDATE OF import_report_json ON presets BEGIN
        SELECT RAISE(ABORT, 'fixture report failure'); END;''');
      expect(() => opened.savePresetImportReport(saved.id, _report({'x': 2})), throwsA(isA<SqliteException>()));
      expect(_rows(database, 'SELECT * FROM presets'), before);
      expect(opened.preset(saved.id)!.importReport!.toJson(), saved.importReport!.toJson());
      database.execute('DROP TRIGGER reject_report');
      final fresh = _report({'x': 1}, at: DateTime.utc(2026, 11, 11));
      opened.savePresetImportReport(saved.id, fresh);
      final reread = opened.preset(saved.id)!;
      expect(reread.importReport!.checkedAt, fresh.checkedAt);
      expect(reread.updatedAt, saved.updatedAt);
      expect(reread.sourceText, 'original');
      expect(reread.raw, {'x': 1});
    });
  });
}

TavernImportReport _report(Map<String, Object?> raw, {DateTime? at}) => TavernImportReport(
  kind: TavernImportKind.preset,
  checkedAt: at ?? DateTime.utc(2026, 11, 10),
  verdict: TavernImportVerdict.usable,
  counts: {'prompts': 0},
  findings: const [],
  fingerprint: importFingerprint(TavernImportKind.preset, raw),
);

void _createV2(Database database) {
  database.execute(File('test/fixtures/t22_schema_v2.sql').readAsStringSync());
  expect(database.select('PRAGMA user_version').single['user_version'], 2);
  expect(
    database.select('PRAGMA table_info(presets)').map((row) => row['name']),
    isNot(contains('import_report_json')),
  );
}

List<Map<String, Object?>> _rows(Database database, String sql) => [
  for (final row in database.select(sql)) Map<String, Object?>.from(row),
];

Map<String, Object?> _preservedRows(Database database) => {
  'presets': _rows(database, '''SELECT id, name, hex(CAST(source_text AS BLOB)) AS bytes,
    raw_json, envelope_json, created_at, updated_at, future_column FROM presets'''),
  'preferences': _rows(database, 'SELECT * FROM preset_preferences'),
  // Compare the complete v2 row; v5 adds tree_revision, checked separately.
  'chats': _rows(database, '''SELECT id, character_id, title, created_at, updated_at,
    persona_id, preset_id, selected_root_id, current_leaf_id, metadata, variables, settings FROM chats'''),
};

Map<String, Object?> _snapshot(Database database) => {
  'version': database.select('PRAGMA user_version').single['user_version'],
  'schema': _rows(database, 'SELECT type, name, sql FROM sqlite_master ORDER BY type, name'),
  'presets': _rows(database, 'SELECT * FROM presets'),
  'preferences': _rows(database, 'SELECT * FROM preset_preferences'),
};

T _withDatabase<T>(String path, T Function(Database database) operation) {
  final database = sqlite3.open(path);
  try {
    return operation(database);
  } finally {
    database.close();
  }
}
