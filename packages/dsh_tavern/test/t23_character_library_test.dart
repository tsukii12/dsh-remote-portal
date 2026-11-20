import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/import_report.dart';
import 'package:dsh_tavern/src/io/card_codec.dart';
import 'package:dsh_tavern/src/store/character_library.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CharacterLibrary library;
  late DateTime now;
  final importedAt = DateTime.utc(2026, 11, 10, 1);
  final editedAt = DateTime.utc(2026, 11, 11, 2, 3, 4);

  Future<StoredCharacter> importFixture([String fixture = 'card-v3.json']) async =>
      library.importCard(await File('test/fixtures/$fixture').readAsBytes(), fileName: fixture);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-tavern-t23-cards-');
    now = importedAt;
    library = CharacterLibrary(root, now: () => now);
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('list uses an immutable small projection while details retain full card data', () async {
    final record = await library.importCard(_jsonBytes(_sampleCard()));
    final summary = (await CharacterLibrary(root).list()).single;
    expect(summary.id, record.id);
    expect(summary.name, '摘要测试 🐳');
    expect(summary.nickname, '昵称');
    expect(summary.creator, '作者');
    expect(summary.tags, ['中文', 'fixture']);
    expect(summary.importedAt, importedAt);
    expect(summary.avatarPath, isNull);
    expect(summary.regexCount, 2);
    expect(summary.scriptCount, 3);
    expect(summary.hasLorebook, true);
    expect(() => summary.tags.add('must not mutate'), throwsUnsupportedError);
    final projected = summary.toCharacter(chatCount: 4, lastChatAt: editedAt);
    expect(projected.chatCount, 4);
    expect(projected.lastChatAt, editedAt);
    expect(projected.description, isEmpty);
    expect(projected.creatorNotes, isEmpty);
    expect(projected.greetings, isEmpty);
    expect(projected.regexDiagnostics, isEmpty);

    final index = await _readJson(_index(root, record.id));
    expect(
      index.keys,
      unorderedEquals(const [
        'version',
        'id',
        'name',
        'nickname',
        'creator',
        'tags',
        'importedAt',
        'hasPortrait',
        'regexCount',
        'scriptCount',
        'hasLorebook',
      ]),
    );
    expect(index['version'], 1);
    expect(index['hasPortrait'], false);
    final indexText = await _index(root, record.id).readAsString();
    expect(indexText, isNot(contains('detail-description-only')));
    expect(indexText, isNot(contains('detail-greeting-only')));
    expect(indexText, isNot(contains('detail-note-only')));
    expect(indexText, isNot(contains(root.path)));
    final detail = (await library.read(record.id))!.toCharacter();
    expect(detail.description, 'detail-description-only');
    expect(detail.creatorNotes, 'detail-note-only');
    expect(detail.greetings, ['detail-greeting-only', 'detail-alternate-only']);
  });

  test('a valid index lists a card without reading any file inside its card directory', () async {
    final record = await importFixture('card-assets.charx');
    final directory = _cardDirectory(root, record.id);
    await for (final entity in directory.list(recursive: true, followLinks: false)) {
      if (entity is File) await entity.delete();
    }
    final summary = (await CharacterLibrary(root).list()).single;
    expect(summary.id, record.id);
    expect(summary.name, '知更');
    expect(summary.avatarPath, '${directory.path}/portrait.png');
    await expectLater(CharacterLibrary(root).read(record.id), throwsA(isA<FileSystemException>()));
  });

  test('a legacy library recovers missing indexes from JSON without opening original or resource bytes', () async {
    final record = await importFixture('card-assets.charx');
    final directory = _cardDirectory(root, record.id);
    final sourceBefore = await File('${directory.path}/card.json').readAsBytes();
    final metadataBefore = await File('${directory.path}/library.json').readAsBytes();
    await Directory('${root.path}/character-index').delete(recursive: true);
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File && const {'card.json', 'library.json'}.contains(entity.uri.pathSegments.last)) continue;
      await entity.delete(recursive: true);
    }
    final summary = (await CharacterLibrary(root).list()).single;
    expect(summary.id, record.id);
    expect(summary.name, '知更');
    expect(summary.avatarPath, record.avatarPath);
    expect(await _index(root, record.id).exists(), true);
    expect(await File('${directory.path}/card.json').readAsBytes(), orderedEquals(sourceBefore));
    expect(await File('${directory.path}/library.json').readAsBytes(), orderedEquals(metadataBefore));
    // The rebuilt index, rather than a hidden in-memory cache, serves reopen.
    await File('${directory.path}/card.json').writeAsString('{broken after recovery');
    expect((await CharacterLibrary(root).list()).single.name, '知更');
  });

  test('invalid JSON and UTF-8 in a derived index recover without discarding the card', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    for (final bytes in <List<int>>[
      utf8.encode('{broken'),
      utf8.encode('null'),
      utf8.encode('[]'),
      [0xff, 0xfe, 0xfd],
    ]) {
      await file.writeAsBytes(bytes);
      expect((await CharacterLibrary(root).list()).single.name, '知更');
      expect((await _readJson(file))['id'], record.id);
    }
  });

  test('every required summary field has a strict type and version before the cache is accepted', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    final valid = await _readJson(file);
    final invalid = <Map<String, Object?>>[
      for (final key in valid.keys) (Map<String, Object?>.of(valid)..remove(key)),
      for (final patch in <Map<String, Object?>>[
        {'version': 2},
        {'version': 1.0},
        {'id': 'not-this-card'},
        {'name': 1},
        {'nickname': false},
        {'creator': <Object?>[]},
        {'tags': 'fixture'},
        {
          'tags': ['valid', 1],
        },
        {'importedAt': 'not-a-date'},
        {'importedAt': 0},
        {'hasPortrait': 1},
        {'regexCount': -1},
        {'regexCount': 0.0},
        {'scriptCount': -1},
        {'scriptCount': '0'},
        {'hasLorebook': 'true'},
      ])
        {...valid, ...patch},
    ];
    for (var index = 0; index < invalid.length; index++) {
      final value = invalid[index];
      if (value['name'] is String) value['name'] = 'must not trust this cache';
      await file.writeAsString(jsonEncode(value));
      expect((await CharacterLibrary(root).list()).single.name, '知更', reason: 'invalid index $index');
      expect(await _readJson(file), valid, reason: 'repaired index $index');
    }
  });

  test('a non-file index path falls back without recursively deleting its contents', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    await file.delete();
    final obstruction = await Directory(file.path).create();
    final sentinel = File('${obstruction.path}/keep.txt');
    await sentinel.writeAsString('unrelated directory contents');
    expect((await library.list()).single.name, '知更');
    await library.updateFields(record.id, {'name': 'current source'});
    expect((await CharacterLibrary(root).list()).single.name, 'current source');
    expect(await sentinel.readAsString(), 'unrelated directory contents');
  });

  test('index recovery exposes authoritative metadata errors and does not poison the queue', () async {
    final record = await importFixture();
    final metadata = File('${_cardDirectory(root, record.id).path}/library.json');
    final valid = await _readJson(metadata);
    final file = _index(root, record.id);
    for (final patch in <Map<String, Object?>>[
      {'version': 2},
      {'sourceFormat': 'unknown'},
      {'resources': 'not-a-list'},
      {
        'resources': ['../outside'],
      },
      {
        'resources': [1],
      },
      {'importedAt': null},
      {'importedAt': 'not-a-date'},
    ]) {
      if (await file.exists()) await file.delete();
      await metadata.writeAsString(jsonEncode({...valid, ...patch}));
      await expectLater(library.list(), throwsA(isA<TavernImportError>()), reason: '$patch');
      expect(await file.exists(), false);
    }
    await metadata.writeAsString(jsonEncode(valid));
    expect((await library.list()).single.name, '知更');
  });

  test('index recovery exposes corrupt source JSON and can recover after the source is repaired', () async {
    final record = await importFixture();
    final source = File('${_cardDirectory(root, record.id).path}/card.json');
    final valid = await source.readAsBytes();
    await _index(root, record.id).delete();
    await source.writeAsString('{broken');
    await expectLater(library.list(), throwsA(isA<TavernImportError>()));
    expect(await _index(root, record.id).exists(), false);
    await source.writeAsBytes(valid);
    expect((await library.list()).single.name, '知更');
  });

  test('editing replaces only its own summary and preserves every non-card source file and T22 report', () async {
    final original = await File('test/fixtures/card-assets.charx').readAsBytes();
    final first = await library.importCard(original, inspect: (card) async => _report(card, importedAt));
    final second = await importFixture();
    final directory = _cardDirectory(root, first.id);
    final beforeFiles = await _files(directory);
    final secondIndex = _index(root, second.id);
    // Distinct formatting makes an unnecessary rewrite observable.
    await secondIndex.writeAsString('${const JsonEncoder.withIndent('  ').convert(await _readJson(secondIndex))}\n');
    final secondBefore = await secondIndex.readAsBytes();
    now = editedAt;
    await library.updateFields(first.id, {
      'name': '更新后的角色',
      'nickname': '新昵称',
      'creator': '新作者',
      'tags': ['new', '中文'],
      'first_mes': 'updated detail greeting',
    });
    final summary = (await CharacterLibrary(root).list()).singleWhere((item) => item.id == first.id);
    expect(summary.name, '更新后的角色');
    expect(summary.nickname, '新昵称');
    expect(summary.creator, '新作者');
    expect(summary.tags, ['new', '中文']);
    expect(summary.importedAt, importedAt);
    expect(summary.avatarPath, first.avatarPath);
    expect((await library.read(first.id))!.toCharacter().greetings.first, 'updated detail greeting');
    final afterFiles = await _files(directory);
    expect(afterFiles.keys, unorderedEquals(beforeFiles.keys));
    for (final path in beforeFiles.keys.where((path) => path != 'card.json')) {
      expect(afterFiles[path], orderedEquals(beforeFiles[path]!), reason: path);
    }
    expect(await secondIndex.readAsBytes(), orderedEquals(secondBefore));
    expect((await library.readImportReport(first.id))!.stale, true);
  });

  test('an empty field patch rewrites neither the source nor the existing summary', () async {
    final record = await importFixture();
    final source = File('${_cardDirectory(root, record.id).path}/card.json');
    final file = _index(root, record.id);
    final index = await _readJson(file);
    index['futureExtraField'] = 'keep exact cache bytes for no-op';
    await file.writeAsString('${const JsonEncoder.withIndent('  ').convert(index)}\n');
    final sourceBefore = await source.readAsBytes();
    final indexBefore = await file.readAsBytes();
    now = editedAt;
    final unchanged = await library.updateFields(record.id, {});
    expect(unchanged.card.data['modification_date'], 0);
    expect(await source.readAsBytes(), orderedEquals(sourceBefore));
    expect(await file.readAsBytes(), orderedEquals(indexBefore));
  });

  test('an invalid patch cannot invalidate the current index or partially change the card', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    final before = await file.readAsBytes();
    await expectLater(
      library.updateFields(record.id, {
        'name': 'must not persist',
        'tags': [1],
      }),
      throwsArgumentError,
    );
    expect(await file.readAsBytes(), orderedEquals(before));
    expect((await library.list()).single.name, '知更');
    expect((await library.read(record.id))!.card.name, '知更');
  });

  test('a card publication failure leaves no stale index and rebuilds the still-current source', () async {
    final record = await importFixture();
    final source = File('${_cardDirectory(root, record.id).path}/card.json');
    final sourceBefore = await source.readAsBytes();
    final blocked = await Directory('${source.path}.writing').create();
    await expectLater(library.updateFields(record.id, {'name': 'not committed'}), throwsA(isA<FileSystemException>()));
    expect(await _index(root, record.id).exists(), false);
    expect(await source.readAsBytes(), orderedEquals(sourceBefore));
    expect((await CharacterLibrary(root).list()).single.name, '知更');
    await blocked.delete();
    await library.updateFields(record.id, {'name': 'committed after failure'});
    expect((await CharacterLibrary(root).list()).single.name, 'committed after failure');
  });

  test('an unavailable cache directory cannot turn a successfully committed import into a failure', () async {
    final obstruction = File('${root.path}/character-index');
    await obstruction.writeAsString('keep this file');
    final record = await importFixture();
    expect((await library.read(record.id))!.card.name, '知更');
    expect((await CharacterLibrary(root).list()).single.id, record.id);
    expect(await obstruction.readAsString(), 'keep this file');
    await obstruction.delete();
    expect((await CharacterLibrary(root).list()).single.id, record.id);
    expect(await _index(root, record.id).exists(), true);
  });

  test('cache publication failure after an edit keeps the new source and allows later repair', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    final obstruction = await Directory('${file.path}.writing').create();
    final updated = await library.updateFields(record.id, {'name': 'source committed'});
    expect(updated.card.name, 'source committed');
    expect(await file.exists(), false);
    expect((await CharacterLibrary(root).read(record.id))!.card.name, 'source committed');
    expect((await CharacterLibrary(root).list()).single.name, 'source committed');
    expect(await file.exists(), false);
    await obstruction.delete();
    expect((await CharacterLibrary(root).list()).single.name, 'source committed');
    expect((await _readJson(file))['name'], 'source committed');
  });

  test('deletion removes its own index and residual indexes cannot resurrect absent card directories', () async {
    final first = await importFixture();
    final second = await importFixture();
    final firstFile = _index(root, first.id);
    final oldFirst = await firstFile.readAsBytes();
    final secondBefore = await _index(root, second.id).readAsBytes();
    await library.delete(first.id);
    expect(await firstFile.exists(), false);
    await firstFile.writeAsBytes(oldFirst);
    expect((await CharacterLibrary(root).list()).map((item) => item.id), [second.id]);
    expect(await CharacterLibrary(root).read(first.id), isNull);
    await library.delete(first.id);
    expect(await firstFile.exists(), false);
    expect(await _index(root, second.id).readAsBytes(), orderedEquals(secondBefore));
  });

  test('summary ordering preserves descending import time and deterministic id ties after reopen', () async {
    final older = await importFixture();
    now = editedAt;
    final recentFirst = await importFixture();
    final recentSecond = await importFixture();
    final recentIds = [recentFirst.id, recentSecond.id]..sort();
    final expected = [...recentIds, older.id];
    expect((await library.list()).map((item) => item.id), expected);
    expect((await CharacterLibrary(root).list()).map((item) => item.id), expected);
  });

  test('moving the complete library derives the avatar path from the new root without rewriting the index', () async {
    final record = await importFixture('card-assets.charx');
    final oldPath = root.path;
    final before = await _index(root, record.id).readAsBytes();
    root = await root.rename('$oldPath-moved');
    final relocated = CharacterLibrary(root);
    final summary = (await relocated.list()).single;
    expect(summary.avatarPath, '${root.path}/characters/${record.id}/portrait.png');
    expect(await File(summary.avatarPath!).exists(), true);
    expect(await _index(root, record.id).readAsBytes(), orderedEquals(before));
    expect(await _index(root, record.id).readAsString(), isNot(contains(oldPath)));
    expect((await relocated.read(record.id))!.card.assets['unknown-app.bin'], record.card.assets['unknown-app.bin']);
  });

  test('the existing operation queue keeps import and successive edit summaries in invocation order', () async {
    final started = Completer<void>();
    final gate = Completer<void>();
    final importing = library.importCard(
      await File('test/fixtures/card-v3.json').readAsBytes(),
      beforeSave: (_) async {
        started.complete();
        await gate.future;
      },
    );
    await started.future;
    var listed = false;
    final firstList = library.list().then((value) {
      listed = true;
      return value;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(listed, false);
    } finally {
      gate.complete();
    }
    final record = await importing;
    expect((await firstList).single.id, record.id);
    final firstEdit = library.updateFields(record.id, {'name': 'first edit'});
    final betweenEdits = library.list();
    final secondEdit = library.updateFields(record.id, {'name': 'second edit'});
    await firstEdit;
    expect((await betweenEdits).single.name, 'first edit');
    await secondEdit;
    expect((await library.list()).single.name, 'second edit');
  });

  test(
    'a failed compatibility inspection publishes neither a card nor a summary and leaves the queue usable',
    () async {
      await expectLater(
        library.importCard(
          await File('test/fixtures/card-v3.json').readAsBytes(),
          inspect: (_) async => throw StateError('inspection failed'),
        ),
        throwsStateError,
      );
      expect(await library.list(), isEmpty);
      expect(await Directory('${root.path}/character-index').exists(), false);
      final record = await importFixture();
      expect((await library.list()).single.id, record.id);
    },
  );

  test('an interrupted pending index is ignored and replaced during recovery', () async {
    final record = await importFixture();
    final file = _index(root, record.id);
    final pending = File('${file.path}.writing');
    await pending.writeAsString('{uncommitted');
    expect((await CharacterLibrary(root).list()).single.name, '知更');
    await file.delete();
    expect((await CharacterLibrary(root).list()).single.name, '知更');
    expect(await pending.exists(), false);
    expect((await _readJson(file))['id'], record.id);
  });

  test('missing-index recovery of an imported V1 card preserves its id and all stored source bytes', () async {
    final record = await importFixture('card-v1.json');
    final directory = _cardDirectory(root, record.id);
    final before = await _files(directory);
    await _index(root, record.id).delete();
    final summary = (await CharacterLibrary(root).list()).single;
    expect(summary.id, record.id);
    expect(summary.name, '灯塔守望者 🐳');
    final after = await _files(directory);
    expect(after.keys, unorderedEquals(before.keys));
    for (final path in before.keys) {
      expect(after[path], orderedEquals(before[path]!), reason: path);
    }
    final exported = const CardCodec().decode(await library.exportCard(record.id, format: TavernCardFormat.json));
    expect(exported.name, summary.name);
  });
}

File _index(Directory root, String id) => File('${root.path}/character-index/$id.json');

Directory _cardDirectory(Directory root, String id) => Directory('${root.path}/characters/$id');

Future<Map<String, Object?>> _readJson(File file) async =>
    jsonDecode(await file.readAsString()) as Map<String, Object?>;

Future<Map<String, Uint8List>> _files(Directory directory) async {
  final result = <String, Uint8List>{};
  await for (final entity in directory.list(recursive: true, followLinks: false)) {
    if (entity is File) result[entity.path.substring(directory.path.length + 1)] = await entity.readAsBytes();
  }
  return result;
}

Uint8List _jsonBytes(Map<String, Object?> value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

TavernImportReport _report(TavernCard card, DateTime checkedAt) => TavernImportReport(
  kind: TavernImportKind.character,
  checkedAt: checkedAt,
  verdict: TavernImportVerdict.usable,
  counts: const {},
  findings: const [],
  fingerprint: importFingerprint(TavernImportKind.character, card.json, embeddedAssetPaths: card.assets.keys),
);

Map<String, Object?> _sampleCard() => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'data': {
    'name': '摘要测试 🐳',
    'nickname': '昵称',
    'creator': '作者',
    'tags': ['中文', 'fixture'],
    'description': 'detail-description-only',
    'creator_notes': 'detail-note-only',
    'first_mes': 'detail-greeting-only',
    'alternate_greetings': ['detail-alternate-only'],
    'character_book': {'entries': <Object?>[]},
    'extensions': {
      'regex_scripts': [
        {'findRegex': 'one'},
        {'findRegex': 'two'},
      ],
      'tavern_helper': {
        'scripts': [
          {'type': 'script', 'content': 'preserved, never executed'},
          {
            'type': 'folder',
            'children': [
              {'type': 'script', 'content': 'second'},
              {'type': 'script', 'content': 'third'},
            ],
          },
        ],
      },
    },
  },
};
