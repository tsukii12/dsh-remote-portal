import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/src/api.dart';
import 'package:dsh_tavern/src/import_report.dart';
import 'package:dsh_tavern/src/io/card_codec.dart';
import 'package:dsh_tavern/src/io/import_intake.dart';
import 'package:dsh_tavern/src/store/character_library.dart';
import 'package:dsh_tavern/src/worldinfo/world_info.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late CharacterLibrary library;
  late DateTime now;
  final importedAt = DateTime.utc(2026, 11, 10, 1);
  final editedAt = DateTime.utc(2026, 11, 11, 2, 3, 4, 987);

  Future<StoredCharacter> importFixture() async =>
      library.importCard(await File('test/fixtures/card-assets.charx').readAsBytes());

  Future<StoredCharacter> importBook(Object? book, {bool include = true}) async {
    final json = jsonDecode(await File('test/fixtures/card-v3.json').readAsString()) as Map<String, Object?>;
    final data = json['data']! as Map<String, Object?>;
    if (include) {
      data['character_book'] = book;
    } else {
      data.remove('character_book');
    }
    return library.importCard(Uint8List.fromList(utf8.encode(jsonEncode(json))));
  }

  File cardFile(String id) => File('${root.path}/characters/$id/card.json');
  File indexFile(String id) => File('${root.path}/character-index/$id.json');
  File reportFile(String id) => File('${root.path}/characters/$id/import-report.json');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('dsh-tavern-book-edit-');
    now = importedAt;
    library = CharacterLibrary(root, now: () => now);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('all book controls persist while unknown card data and every non-card file remain exact', () async {
    final record = await importFixture();
    final directory = Directory('${root.path}/characters/${record.id}');
    final beforeFiles = await _files(directory);
    final expected = _copy(record.card.json);
    final fields = <String, Object?>{
      'enabled': false,
      'keys': ['灯塔', '鲸'],
      'secondary_keys': ['红', '蓝'],
      'selective': true,
      'position': 'after_char',
      'insertion_order': 0,
      'constant': true,
      'use_regex': true,
      'content': '@@depth 2\r\n 原文 {{user}} / \$1 🐋 \n',
      'comment': '保留空白的说明 ',
      'extensions': {
        'selectiveLogic': 3,
        'position': 4,
        'depth': 0,
        'role': 2,
        'probability': 0,
        'useProbability': false,
        'group': 'shared',
        'group_override': true,
        'group_weight': 0,
        'use_group_scoring': false,
        'unknown': {
          'added': ['nested', null],
        },
      },
    };
    now = editedAt;
    final edited = await library.updateBookEntry(record.id, 0, fields);
    final expectedData = expected['data']! as Map<String, Object?>;
    final expectedBook = expectedData['character_book']! as Map<String, Object?>;
    final expectedEntry = (expectedBook['entries']! as List<Object?>).single! as Map<String, Object?>;
    expectedEntry.addAll({
      for (final entry in fields.entries)
        if (entry.key != 'extensions') entry.key: entry.value,
    });
    expectedEntry['id'] = 0;
    expectedEntry['extensions'] = {
      ...(fields['extensions']! as Map<String, Object?>),
      'unknown': {
        'nested': '保留',
        'added': ['nested', null],
      },
    };
    expectedData['modification_date'] = editedAt.millisecondsSinceEpoch ~/ 1000;
    expect(edited.card.json, expected);
    expect(edited.importedAt, importedAt);
    expect(edited.avatarPath, record.avatarPath);
    expect(edited.card.originalBytes, orderedEquals(record.card.originalBytes!));
    expect(edited.card.png, record.card.png);
    expect(edited.card.assets, record.card.assets);
    final afterFiles = await _files(directory);
    expect(afterFiles.keys, unorderedEquals(beforeFiles.keys));
    for (final name in beforeFiles.keys.where((name) => name != 'card.json')) {
      expect(afterFiles[name], orderedEquals(beforeFiles[name]!), reason: name);
    }
    expect((await CharacterLibrary(root).read(record.id))!.card.json, expected);
  });

  test('extensions recursively merge objects replace arrays and retain explicit null', () async {
    final record = await importBook({
      'name': 'book',
      'opaqueBook': {
        'keep': [1, true],
      },
      'entries': [
        {
          ..._entry('original'),
          'id': 7,
          'opaqueEntry': {'keep': 'yes'},
          'extensions': {
            'vendor': {
              'nested': {'keep': 1, 'change': 2},
              'array': [1, 2],
              'nullable': {'old': true},
            },
            'untouched': {'value': 'exact'},
          },
        },
      ],
    });
    final edited = await library.updateBookEntry(record.id, 0, {
      'extensions': {
        'vendor': {
          'nested': {'change': 9},
          'array': [3],
          'nullable': null,
        },
      },
    });
    expect(_entries(edited).single['extensions'], {
      'vendor': {
        'nested': {'keep': 1, 'change': 9},
        'array': [3],
        'nullable': null,
      },
      'untouched': {'value': 'exact'},
    });
    expect(_entries(edited).single['opaqueEntry'], {'keep': 'yes'});
    expect(_book(edited)['opaqueBook'], {
      'keep': [1, true],
    });
    expect(_entries(edited).single['id'], 7);
  });

  test('adding starts a missing book and retains metadata on a book with no entries', () async {
    for (final value in <({bool include, Object? book})>[
      (include: false, book: null),
      (include: true, book: null),
      (include: true, book: {'name': 'kept', 'opaque': 5}),
      (include: true, book: {'name': 'kept', 'opaque': 5, 'entries': null}),
    ]) {
      final record = await importBook(value.book, include: value.include);
      expect(
        (await library.list()).singleWhere((item) => item.id == record.id).hasLorebook,
        value.book is Map<String, Object?>,
      );
      final added = await library.addBookEntry(record.id, {
        'keys': ['new'],
        'content': '正文',
      });
      expect((await CharacterLibrary(root).list()).singleWhere((item) => item.id == record.id).hasLorebook, isTrue);
      final entry = _entries(added).single;
      expect(entry, {
        'id': 0,
        'keys': ['new'],
        'secondary_keys': <String>[],
        'content': '正文',
        'enabled': true,
        'constant': false,
        'selective': false,
        'insertion_order': 100,
        'position': 'before_char',
        'use_regex': false,
        'extensions': <String, Object?>{},
      });
      if (value.book is Map<String, Object?>) {
        expect(_book(added)['name'], 'kept');
        expect(_book(added)['opaque'], 5);
        expect(_book(added).containsKey('extensions'), isFalse);
      } else {
        expect(_book(added)['extensions'], <String, Object?>{});
        final exported = const CardCodec().decode(await library.exportCard(record.id, format: TavernCardFormat.json));
        expect(exported.data['character_book'], _book(added));
      }
    }
  });

  test('new ids avoid JS-string-equivalent identities and preserve existing duplicate precedence', () async {
    final record = await importBook({
      'entries': [
        {..._entry('zero'), 'id': 0.0},
        {..._entry('first-one'), 'id': '1'},
        {..._entry('last-one'), 'id': 1},
        {
          ..._entry('array-two'),
          'id': [2],
        },
        {
          ..._entry('object'),
          'id': {'vendor': true},
        },
        {..._entry('null'), 'id': null},
        _entry('missing'),
      ],
    });
    final before = _entries(record);
    final edited = await library.addBookEntry(record.id, {'content': 'new'});
    final entries = _entries(edited);
    expect(entries.last['id'], 3);
    for (var index = 0; index < 5; index++) {
      expect(entries[index]['id'], before[index]['id']);
    }
    expect(entries[5]['id'], 5);
    expect(entries[6]['id'], 6);
    final execution = WorldInfoBook.fromJson(id: 'probe', source: WorldInfoSource.character, json: _book(edited));
    expect(execution.entries.singleWhere((entry) => entry.uid == '1').content, 'last-one');
    expect(execution.entries.map((entry) => entry.uid), containsAll(['0', '1', '2', '3', '5', '6']));
  });

  test('deleting fixes missing and null ids before indices shift without repairing duplicates', () async {
    final record = await importBook({
      'entries': [
        _entry('delete'),
        {..._entry('keep-null'), 'id': null},
        {..._entry('first-nine'), 'id': 9},
        {..._entry('last-nine'), 'id': 9},
      ],
    });
    final beforeExecution = WorldInfoBook.fromJson(id: 'probe', source: WorldInfoSource.character, json: _book(record));
    expect(beforeExecution.entries.singleWhere((entry) => entry.uid == '1').stKey, 'probe.null');
    final edited = await library.deleteBookEntry(record.id, 0);
    expect(_entries(edited).map((entry) => entry['id']), [1, 9, 9]);
    expect(_entries(edited).map((entry) => entry['content']), ['keep-null', 'first-nine', 'last-nine']);
    final next = await library.updateBookEntry(record.id, 0, {'content': 'changed by index'});
    expect(_entries(next).first['id'], 1);
    final execution = WorldInfoBook.fromJson(id: 'probe', source: WorldInfoSource.character, json: _book(next));
    expect(execution.entries.singleWhere((entry) => entry.uid == '9').content, 'last-nine');
    expect(execution.entries.singleWhere((entry) => entry.uid == '1').stKey, 'probe.1');
    expect(_entries(record).first.containsKey('id'), isFalse);
    expect(_entries(record)[1]['id'], isNull);
  });

  test('array index can address either of two entries with the same id', () async {
    final record = await importBook({
      'entries': [
        {..._entry('first'), 'id': 4},
        {..._entry('second'), 'id': 4},
      ],
    });
    final edited = await library.updateBookEntry(record.id, 0, {'content': 'changed-first'});
    expect(_entries(edited).map((entry) => entry['content']), ['changed-first', 'second']);
    final remaining = await library.deleteBookEntry(record.id, 1);
    expect(_entries(remaining).single['id'], 4);
    expect(_entries(remaining).single['content'], 'changed-first');
  });

  test('deleting the last entry keeps the empty book and its unknown metadata', () async {
    final record = await importBook({
      'name': 'kept',
      'opaque': {'retained': true},
      'entries': [_entry('last')],
    });
    final empty = await library.deleteBookEntry(record.id, 0);
    expect(_book(empty), {
      'name': 'kept',
      'opaque': {'retained': true},
      'entries': <Object?>[],
    });
    expect((await CharacterLibrary(root).list()).single.hasLorebook, isTrue);
    final reopened = (await CharacterLibrary(root).read(record.id))!;
    expect(_book(reopened), _book(empty));
    final added = await library.addBookEntry(record.id, {'content': 'after empty'});
    expect(_entries(added).single['id'], 0);
    expect(_book(added)['opaque'], {'retained': true});
  });

  test('empty updates only read the valid target without assigning ids or changing file and timestamp', () async {
    final record = await importBook({
      'entries': [
        _entry('missing'),
        {..._entry('null'), 'id': null},
      ],
    });
    await library.recheckImport(record.id, (card) async => _report(card, now));
    final before = await cardFile(record.id).readAsBytes();
    final indexBefore = await indexFile(record.id).readAsBytes();
    final reportBefore = await reportFile(record.id).readAsBytes();
    now = editedAt;
    final unchanged = await library.updateBookEntry(record.id, 1, {});
    expect(unchanged.card.json, record.card.json);
    expect(_entries(unchanged).first.containsKey('id'), isFalse);
    expect(_entries(unchanged)[1]['id'], isNull);
    expect(await cardFile(record.id).readAsBytes(), orderedEquals(before));
    expect(await indexFile(record.id).readAsBytes(), orderedEquals(indexBefore));
    expect(await reportFile(record.id).readAsBytes(), orderedEquals(reportBefore));
    expect((await library.readImportReport(record.id))!.stale, isFalse);
  });

  test('callers cannot supply or change an id even through an otherwise valid patch', () async {
    final record = await importBook({
      'entries': [_entry('keep')],
    });
    final before = await cardFile(record.id).readAsBytes();
    for (final id in <Object?>[null, 0, 'other', <Object?>[]]) {
      await expectLater(library.addBookEntry(record.id, {'content': 'discard', 'id': id}), throwsArgumentError);
      await expectLater(library.updateBookEntry(record.id, 0, {'content': 'discard', 'id': id}), throwsArgumentError);
      expect(await cardFile(record.id).readAsBytes(), orderedEquals(before));
    }
  });

  test('known field and JSON type failures are atomic and do not poison later edits', () async {
    final record = await importBook({
      'entries': [_entry('keep')],
    });
    final before = await cardFile(record.id).readAsBytes();
    for (final invalid in <Map<String, Object?>>[
      {'keys': 'one'},
      {
        'secondary_keys': ['valid', 2],
      },
      {'enabled': 'yes'},
      {'constant': null},
      {'selective': 1},
      {'content': 2},
      {'position': 4},
      {'insertion_order': double.nan},
      {'extensions': <Object?>[]},
      {
        'extensions': {'depth': 0.5},
      },
      {
        'extensions': {'selectiveLogic': 'AND_ANY'},
      },
      {
        'extensions': {'useProbability': 1},
      },
      {
        'extensions': {'probability': double.infinity},
      },
      {
        'extensions': {'group': false},
      },
      {'opaque': Object()},
    ]) {
      await expectLater(
        library.updateBookEntry(record.id, 0, {'comment': 'must not leak', ...invalid}),
        throwsArgumentError,
      );
      expect(await cardFile(record.id).readAsBytes(), orderedEquals(before));
    }
    final accepted = await library.updateBookEntry(record.id, 0, {
      'content': 'after errors',
      'opaque': {'new': null},
    });
    expect(_entries(accepted).single['content'], 'after errors');
    expect(_entries(accepted).single['opaque'], {'new': null});
  });

  test('invalid indices and malformed entry arrays leave the committed card unchanged', () async {
    final record = await importBook({
      'entries': [_entry('only')],
    });
    final before = await cardFile(record.id).readAsBytes();
    for (final index in [-1, 1, 10]) {
      await expectLater(library.updateBookEntry(record.id, index, {'content': 'discard'}), throwsRangeError);
      await expectLater(library.deleteBookEntry(record.id, index), throwsRangeError);
      expect(await cardFile(record.id).readAsBytes(), orderedEquals(before));
    }
    final malformed = await importBook({
      'entries': [_entry('valid'), 'not-an-entry'],
    });
    final malformedBefore = await cardFile(malformed.id).readAsBytes();
    await expectLater(library.addBookEntry(malformed.id, {'content': 'discard'}), throwsArgumentError);
    await expectLater(library.updateBookEntry(malformed.id, 0, {'content': 'discard'}), throwsArgumentError);
    await expectLater(library.deleteBookEntry(malformed.id, 0), throwsArgumentError);
    expect(await cardFile(malformed.id).readAsBytes(), orderedEquals(malformedBefore));
  });

  test('native ST map entries remain readable and cannot be silently converted by editing', () async {
    final record = await importBook({
      'name': 'native',
      'opaque': [1, 2],
      'entries': {
        '9': {
          'uid': 9,
          'key': ['key'],
          'content': 'native entry',
          'constant': true,
          'position': 0,
        },
      },
    });
    final before = await cardFile(record.id).readAsBytes();
    expect(
      WorldInfoBook.fromJson(id: 'probe', source: WorldInfoSource.character, json: _book(record)).entries.single.uid,
      '9',
    );
    await expectLater(library.addBookEntry(record.id, {'content': 'discard'}), throwsArgumentError);
    await expectLater(library.updateBookEntry(record.id, 0, {'content': 'discard'}), throwsArgumentError);
    await expectLater(library.deleteBookEntry(record.id, 0), throwsArgumentError);
    expect((await library.read(record.id))!.card.json, record.card.json);
    expect(await cardFile(record.id).readAsBytes(), orderedEquals(before));
  });

  test('deep caller snapshots and queued edits preserve each other and unrelated character changes', () async {
    final record = await importBook({
      'entries': [_entry('original')],
    });
    final entry = <String, Object?>{
      'content': 'new',
      'keys': <Object?>['captured'],
      'extensions': <String, Object?>{
        'vendor': <String, Object?>{'value': 1},
      },
    };
    final adding = library.addBookEntry(record.id, entry);
    (entry['keys']! as List<Object?>).add('too late');
    ((entry['extensions']! as Map<String, Object?>)['vendor']! as Map<String, Object?>)['value'] = 99;
    final changingName = library.updateFields(record.id, {'name': 'renamed'});
    final updating = library.updateBookEntry(record.id, 1, {
      'extensions': {
        'vendor': {'second': true},
      },
    });
    await Future.wait([adding, changingName, updating]);
    final after = (await library.read(record.id))!;
    expect(after.card.name, 'renamed');
    expect(_entries(after)[1]['keys'], ['captured']);
    expect(_entries(after)[1]['extensions'], {
      'vendor': {'value': 1, 'second': true},
    });
    final patch = <String, Object?>{
      'keys': <Object?>['updated'],
      'extensions': <String, Object?>{
        'vendor': <String, Object?>{'value': 2},
      },
    };
    final saving = library.updateBookEntry(record.id, 1, patch);
    (patch['keys']! as List<Object?>).clear();
    ((patch['extensions']! as Map<String, Object?>)['vendor']! as Map<String, Object?>)['value'] = 99;
    final saved = await saving;
    expect(_entries(saved)[1]['keys'], ['updated']);
    expect(_entries(saved)[1]['extensions'], {
      'vendor': {'value': 2, 'second': true},
    });
  });

  test('a failed book write keeps the previous complete card and later writes recover', () async {
    final record = await importBook({
      'entries': [_entry('keep')],
    });
    await library.recheckImport(record.id, (card) async => _report(card, now));
    final file = cardFile(record.id);
    final before = await file.readAsBytes();
    final reportBefore = await reportFile(record.id).readAsBytes();
    final obstruction = await Directory('${file.path}.writing').create();
    await expectLater(
      library.addBookEntry(record.id, {'content': 'not committed'}),
      throwsA(isA<FileSystemException>()),
    );
    expect(await file.readAsBytes(), orderedEquals(before));
    expect(await indexFile(record.id).exists(), isFalse);
    expect((await library.read(record.id))!.card.json, record.card.json);
    expect((await CharacterLibrary(root).list()).single.hasLorebook, isTrue);
    expect(await indexFile(record.id).exists(), isTrue);
    expect(await reportFile(record.id).readAsBytes(), orderedEquals(reportBefore));
    expect((await library.readImportReport(record.id))!.stale, isFalse);
    await obstruction.delete();
    final saved = await library.addBookEntry(record.id, {'content': 'committed'});
    expect(_entries(saved).map((entry) => entry['content']), ['keep', 'committed']);
    expect(await File('${file.path}.writing').exists(), isFalse);
    expect((await library.readImportReport(record.id))!.stale, isTrue);
  });

  test('a failed summary publication cannot discard the committed first book and can later recover', () async {
    final record = await importBook(null, include: false);
    expect((await library.list()).single.hasLorebook, isFalse);
    final index = indexFile(record.id);
    final obstruction = await Directory('${index.path}.writing').create();
    final saved = await library.addBookEntry(record.id, {'content': 'committed'});
    expect(_entries(saved).single['content'], 'committed');
    expect(await index.exists(), isFalse);
    expect((await CharacterLibrary(root).read(record.id))!.card.json, saved.card.json);
    expect((await CharacterLibrary(root).list()).single.hasLorebook, isTrue);
    expect(await index.exists(), isFalse);
    await obstruction.delete();
    expect((await CharacterLibrary(root).list()).single.hasLorebook, isTrue);
    expect(await index.exists(), isTrue);
  });

  test('book editing waits behind inspection and keeps its old report until an explicit recheck', () async {
    final record = await importBook({
      'entries': [_entry('old')],
    });
    final started = Completer<void>();
    final release = Completer<void>();
    final checking = library.recheckImport(record.id, (card) async {
      started.complete();
      await release.future;
      expect((card.data['character_book']! as Map<String, Object?>)['entries'], hasLength(1));
      return _report(card, importedAt);
    });
    await started.future;
    var edited = false;
    final editing = library.addBookEntry(record.id, {'content': '{{banned::x}}'}).then((value) {
      edited = true;
      return value;
    });
    try {
      await Future<void>.delayed(Duration.zero);
      expect(edited, isFalse);
    } finally {
      release.complete();
    }
    final checked = await checking;
    await editing;
    final bytes = await reportFile(record.id).readAsBytes();
    final oldReport = (await library.readImportReport(record.id))!;
    expect(oldReport.fingerprint, checked.fingerprint);
    expect(oldReport.checkedAt, importedAt);
    expect(oldReport.counts['entriesStored'], 1);
    expect(oldReport.stale, isTrue);
    expect(await reportFile(record.id).readAsBytes(), orderedEquals(bytes));
    final refreshed = await library.recheckImport(record.id, (card) async => _report(card, editedAt));
    expect(refreshed.checkedAt, editedAt);
    expect(refreshed.counts['entriesStored'], 2);
    expect(
      refreshed.findings.any(
        (finding) =>
            finding.code == 'macro-banned-no-effect' && finding.path == r'$.data.character_book.entries[1].content',
      ),
      isTrue,
    );
    expect((await library.readImportReport(record.id))!.stale, isFalse);
  });

  test('edited books survive all export formats and reopening while original CHARX assets stay exact', () async {
    final record = await importFixture();
    now = editedAt;
    await library.updateBookEntry(record.id, 0, {
      'keys': ['edited'],
      'content': '@@depth 0\r\n{{user}} 中文',
    });
    final edited = await library.addBookEntry(record.id, {
      'content': 'new entry',
      'opaque': {'keep': true},
    });
    for (final format in TavernCardFormat.values) {
      final decoded = const CardCodec().decode(await library.exportCard(record.id, format: format));
      expect(decoded.data['character_book'], _book(edited), reason: format.name);
      expect(decoded.json['unknown_root'], record.card.json['unknown_root']);
      expect(decoded.data['modification_date'], editedAt.millisecondsSinceEpoch ~/ 1000);
      if (format == TavernCardFormat.charx) {
        expect(decoded.assets, record.card.assets);
      }
    }
    final reopened = (await CharacterLibrary(root).read(record.id))!;
    expect(_book(reopened), _book(edited));
    expect(reopened.card.originalBytes, orderedEquals(record.card.originalBytes!));
    expect(reopened.card.assets, record.card.assets);
  });

  test('missing books or characters and malformed ids cannot affect another record', () async {
    final record = await importBook(null, include: false);
    await expectLater(library.updateBookEntry(record.id, 0, {'content': 'none'}), throwsRangeError);
    await expectLater(library.deleteBookEntry(record.id, 0), throwsRangeError);
    const missing = 'card-00000000000000000000000000000000';
    await expectLater(library.addBookEntry(missing, {}), throwsA(isA<TavernImportError>()));
    await expectLater(library.updateBookEntry(missing, 0, {}), throwsA(isA<TavernImportError>()));
    await expectLater(library.deleteBookEntry(missing, 0), throwsA(isA<TavernImportError>()));
    await expectLater(library.addBookEntry('../outside', {}), throwsArgumentError);
    await expectLater(library.updateBookEntry('../outside', 0, {}), throwsArgumentError);
    await expectLater(library.deleteBookEntry('../outside', 0), throwsArgumentError);
    expect((await library.read(record.id))!.card.json, record.card.json);
  });
}

Map<String, Object?> _entry(String content) => {
  'keys': ['key'],
  'content': content,
  'enabled': true,
  'insertion_order': 100,
  'position': 'before_char',
  'use_regex': false,
  'extensions': <String, Object?>{},
};

Map<String, Object?> _copy(Map<String, Object?> value) => jsonDecode(jsonEncode(value)) as Map<String, Object?>;

TavernImportReport _report(TavernCard card, DateTime checkedAt) => assessImport(
  kind: TavernImportKind.character,
  document: card.json,
  embeddedAssetPaths: card.assets.keys,
  checkedAt: checkedAt,
);

Map<String, Object?> _book(StoredCharacter record) => record.card.data['character_book']! as Map<String, Object?>;

List<Map<String, Object?>> _entries(StoredCharacter record) =>
    (_book(record)['entries']! as List<Object?>).cast<Map<String, Object?>>();

Future<Map<String, Uint8List>> _files(Directory directory) async {
  final result = <String, Uint8List>{};
  await for (final file in directory.list(recursive: true, followLinks: false)) {
    if (file is File) {
      result[file.path.substring(directory.path.length + 1)] = await file.readAsBytes();
    }
  }
  return result;
}
