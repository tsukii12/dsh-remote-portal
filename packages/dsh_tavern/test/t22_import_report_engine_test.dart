import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('all four import routes persist reports across reopening without exporting them', () async {
    final h = await _open();
    final source = _cardBytes({
      'first_mes': '<b>Hi</b>{{banned::word}}',
      'extensions': {
        'tavern_helper': {
          'scripts': [
            {'id': 'script', 'type': 'script', 'content': 'void 0;'},
          ],
        },
        'foreign': {
          'keep': [false, null],
        },
      },
    });
    final card = await h.engine.importCard(source);
    final presetPayload = jsonEncode({
      'prompts': [
        {'identifier': 'p', 'role': 'system', 'content': '{{banned::word}}'},
      ],
      'foreign': [null, '海'],
    });
    final presetSource = '\uFEFF$presetPayload\r\n';
    final preset = (await h.engine.importPreset(presetSource)).preset;
    final rawBook = _book(extra: {'vectorized': true, 'automationId': 'action'});
    final book = (await h.engine.importLorebook(jsonEncode(rawBook))).book;
    final regex = (await h.engine.importRegexScripts(jsonEncode(_rule('[')))).scripts.single;
    final assets = <TavernImportKind, String>{
      TavernImportKind.character: card.id,
      TavernImportKind.preset: preset.id,
      TavernImportKind.lorebook: book.id,
      TavernImportKind.regex: regex.id,
    };
    final before = <TavernImportKind, Map<String, Object?>>{};
    for (final entry in assets.entries) {
      final report = (await h.engine.readImportReport(entry.key, entry.value))!;
      expect(report.kind, entry.key);
      expect(report.checkedAt, h.at);
      expect(report.counts, isNotEmpty);
      expect(report.findings, isNotEmpty);
      expect(report.stale, isFalse);
      before[entry.key] = report.toJson();
    }
    expect(before[TavernImportKind.regex]!['verdict'], 'preserveOnly');
    expect(before[TavernImportKind.character]!['renderLevel'], 2);
    expect(regex.raw['disabled'], isFalse);
    expect(preset.sourceText, presetSource);
    expect(await File('${h.directory.path}/characters/${card.id}/original.json').readAsBytes(), source);
    expect(jsonDecode(await h.engine.exportLorebook(book.id)), rawBook);
    expect(jsonDecode(await h.engine.exportRegex(regexId: regex.id)), _rule('['));
    expect(jsonDecode(await h.engine.exportPreset(preset.id)), preset.raw);
    final exportedCard = const CardCodec().decode(await h.engine.exportCard(card.id, format: TavernCardFormat.json));
    expect(exportedCard.data['extensions'], (await h.engine.characterFields(card.id))!['extensions']);
    expect(exportedCard.json.containsKey('importReport'), isFalse);
    await h.reopen();
    for (final entry in assets.entries) {
      expect((await h.engine.readImportReport(entry.key, entry.value))!.toJson(), before[entry.key]);
    }
    expect(h.model.calls, 0);
  });

  test('character edits mark old report stale and recheck leaves content untouched', () async {
    final h = await _open();
    final card = await h.engine.importCard(_cardBytes());
    final original = (await h.engine.readImportReport(TavernImportKind.character, card.id))!;
    await h.engine.updateCharacterFields(card.id, {'first_mes': '<div>new</div>{{setglobalvar::shouldNotRun::yes}}'});
    final file = File('${h.directory.path}/characters/${card.id}/card.json');
    final bytes = await file.readAsBytes();
    final stale = (await h.engine.readImportReport(TavernImportKind.character, card.id))!;
    expect(stale.stale, isTrue);
    expect(stale.fingerprint, original.fingerprint);
    expect(stale.checkedAt, original.checkedAt);
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.character, card.id);
    expect(fresh.stale, isFalse);
    expect(fresh.checkedAt, h.at);
    expect(fresh.fingerprint, isNot(original.fingerprint));
    expect(await file.readAsBytes(), bytes);
    expect(h.engine.globalVariables, isEmpty);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.character, card.id))!.toJson(), fresh.toJson());
  });

  test('preset recheck keeps source text dates selections and both JSON documents', () async {
    final h = await _open();
    const source = '\uFEFF{ "temperature": 0.7, "unknown": [null] }\r\n';
    final preset = (await h.engine.importPreset(source)).preset;
    await h.engine.setDefaultPreset(preset.id);
    await h.engine.updatePreset(preset.id, {
      'prompts': [
        {'identifier': 'p', 'role': 'system', 'content': '{{banned::word}}'},
      ],
    });
    final edited = (await h.engine.preset(preset.id))!;
    expect((await h.engine.readImportReport(TavernImportKind.preset, preset.id))!.stale, isTrue);
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.preset, preset.id);
    final reread = (await h.engine.preset(preset.id))!;
    expect(fresh.stale, isFalse);
    expect(fresh.checkedAt, h.at);
    expect(reread.raw, edited.raw);
    expect(reread.envelope, edited.envelope);
    expect(reread.updatedAt, edited.updatedAt);
    expect(reread.createdAt, preset.createdAt);
    expect(reread.sourceText, source);
    expect((await h.engine.presetSelection()).defaultPresetId, preset.id);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.preset, preset.id))!.toJson(), fresh.toJson());
  });

  test('regex toggle exposes stale report in both its DTO and the read API', () async {
    final h = await _open();
    final source = '\uFEFF${jsonEncode(_rule('A'))}\r\n';
    final script = (await h.engine.importRegexScripts(source)).scripts.single;
    final old = (await h.engine.readImportReport(TavernImportKind.regex, script.id))!;
    final disabled = await h.engine.setRegexEnabled(script.id, false);
    expect(disabled.importReport!.stale, isTrue);
    final stale = (await h.engine.readImportReport(TavernImportKind.regex, script.id))!;
    expect(stale.stale, isTrue);
    expect(stale.fingerprint, old.fingerprint);
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.regex, script.id);
    expect(fresh.stale, isFalse);
    expect(fresh.verdict, TavernImportVerdict.usable);
    final current = (await h.engine.listRegexScripts()).single;
    expect(current.enabled, isFalse);
    expect(current.sourceText, source);
    expect(current.importReport!.stale, isFalse);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.regex, script.id))!.toJson(), fresh.toJson());
  });

  test('lorebook edits keep its origin and old report then recheck updates the snapshot', () async {
    final h = await _open();
    final book = (await h.engine.importLorebook(jsonEncode(_book()), fileName: 'source.json')).book;
    final old = (await h.engine.readImportReport(TavernImportKind.lorebook, book.id))!;
    final changed = _book(extra: {'vectorized': true});
    await h.engine.putLorebook(book.id, changed);
    await h.reopen();
    expect((await h.engine.listLorebooks()).single.stWorldName, 'source');
    final stale = (await h.engine.readImportReport(TavernImportKind.lorebook, book.id))!;
    expect(stale.stale, isTrue);
    expect(stale.fingerprint, old.fingerprint);
    h.at = h.at.add(const Duration(days: 1));
    final fresh = await h.engine.recheckImport(TavernImportKind.lorebook, book.id);
    expect(fresh.stale, isFalse);
    expect(fresh.verdict, TavernImportVerdict.partial);
    expect(await h.engine.lorebook(book.id), changed);
    expect(jsonDecode(await h.engine.exportLorebook(book.id)), changed);
    await h.reopen();
    expect((await h.engine.readImportReport(TavernImportKind.lorebook, book.id))!.toJson(), fresh.toJson());
    expect((await h.engine.listLorebooks()).single.stWorldName, 'source');
  });

  test('report reads do not load the original card or resource bytes', () async {
    final h = await _open();
    final card = TavernCard(
      json: _cardJson({
        'assets': [
          {'type': 'other', 'name': 'opaque', 'uri': 'embeded://assets/value.bin', 'ext': 'bin'},
        ],
      }),
      assets: {
        'assets/value.bin': Uint8List.fromList([0, 1, 255]),
      },
    );
    final bytes = const CardCodec().encode(card, format: TavernCardFormat.charx);
    final imported = await h.engine.importCard(bytes);
    final expected = (await h.engine.readImportReport(TavernImportKind.character, imported.id))!.toJson();
    final base = '${h.directory.path}/characters/${imported.id}';
    final original = File('$base/original.charx');
    final resource = File('$base/resources/assets/value.bin');
    final hiddenOriginal = await original.rename('${original.path}.unavailable');
    final hiddenResource = await resource.rename('${resource.path}.unavailable');
    try {
      expect((await h.engine.readImportReport(TavernImportKind.character, imported.id))!.toJson(), expected);
    } finally {
      await hiddenOriginal.rename(original.path);
      await hiddenResource.rename(resource.path);
    }
  });

  test('legacy assets have no invented report and explicit recheck fills all four kinds', () async {
    final h = await _open();
    final card = await h.engine.importCard(_cardBytes());
    final preset = (await h.engine.importPreset('{}')).preset;
    final book = (await h.engine.importLorebook(jsonEncode(_book()), fileName: 'legacy-source.json')).book;
    final regex = (await h.engine.importRegexScripts(jsonEncode(_rule('A')))).scripts.single;
    await h.engine.close();
    await File('${h.directory.path}/characters/${card.id}/import-report.json').delete();
    final database = sqlite3.open('${h.directory.path}/tavern.sqlite3');
    try {
      database.execute('UPDATE presets SET import_report_json = NULL');
    } finally {
      database.close();
    }
    final regexFile = File('${h.directory.path}/regex-library.json');
    final regexDocument = jsonDecode(await regexFile.readAsString()) as Map<String, Object?>;
    for (final item in regexDocument['scripts']! as List<Object?>) {
      (item! as Map<String, Object?>).remove('importReport');
    }
    await regexFile.writeAsString(jsonEncode(regexDocument));
    final bookFile = File('${h.directory.path}/lorebooks/${book.id}.json');
    final bookDocument = jsonDecode(await bookFile.readAsString()) as Map<String, Object?>;
    bookDocument.remove('importReport');
    await bookFile.writeAsString(jsonEncode(bookDocument));
    await h.open();
    final ids = <TavernImportKind, String>{
      TavernImportKind.character: card.id,
      TavernImportKind.preset: preset.id,
      TavernImportKind.lorebook: book.id,
      TavernImportKind.regex: regex.id,
    };
    for (final entry in ids.entries) {
      expect(await h.engine.readImportReport(entry.key, entry.value), isNull);
      final report = await h.engine.recheckImport(entry.key, entry.value);
      expect(report.kind, entry.key);
      expect(report.stale, isFalse);
      expect((await h.engine.readImportReport(entry.key, entry.value))!.toJson(), report.toJson());
    }
    expect((await h.engine.listLorebooks()).single.stWorldName, 'legacy-source');
  });

  test('a legacy raw lorebook gains a report without inventing a source filename', () async {
    final h = await _open();
    await h.engine.putLorebook('legacy', _book());
    expect(await h.engine.readImportReport(TavernImportKind.lorebook, 'legacy'), isNull);
    await h.engine.recheckImport(TavernImportKind.lorebook, 'legacy');
    await h.reopen();
    expect((await h.engine.listLorebooks()).single.stWorldName, isNull);
    expect((await h.engine.readImportReport(TavernImportKind.lorebook, 'legacy'))!.stale, isFalse);
    expect(jsonDecode(await h.engine.exportLorebook('legacy')), _book());
  });

  test('rechecking a permissive legacy preset reports invalid fields without normalizing its JSON', () async {
    final h = await _open();
    await h.engine.setPreset(
      ChatPreset({
        'prompts': [
          {'identifier': 'legacy', 'role': 3, 'content': 'preserved'},
        ],
        'foreign': [null, false],
      }),
    );
    final id = (await h.engine.listPresets()).single.id;
    final before = (await h.engine.preset(id))!;
    expect(await h.engine.readImportReport(TavernImportKind.preset, id), isNull);
    final report = await h.engine.recheckImport(TavernImportKind.preset, id);
    expect(report.findings.any((value) => value.kind == TavernImportFindingKind.invalid), isTrue);
    expect((await h.engine.preset(id))!.raw, before.raw);
    expect((await h.engine.preset(id))!.sourceText, before.sourceText);
  });

  test('invalid imports publish no asset or orphan report', () async {
    final h = await _open();
    await expectLater(h.engine.importCard(Uint8List.fromList(utf8.encode('{'))), throwsA(isA<TavernImportError>()));
    await expectLater(h.engine.importPreset('{'), throwsA(isA<TavernPresetImportError>()));
    await expectLater(h.engine.importLorebook('{'), throwsA(isA<TavernImportError>()));
    await expectLater(h.engine.importRegexScripts('[3]'), throwsA(isA<TavernImportError>()));
    expect(await h.engine.watchCharacters().first, isEmpty);
    expect(await h.engine.listPresets(), isEmpty);
    expect(await h.engine.listLorebooks(), isEmpty);
    expect(await h.engine.listRegexScripts(), isEmpty);
    expect(
      await h.directory.list(recursive: true).where((file) => file.path.endsWith('import-report.json')).toList(),
      isEmpty,
    );
  });

  test('failed file-backed rechecks preserve the exact committed report and asset', () async {
    final h = await _open();
    final card = await h.engine.importCard(_cardBytes());
    final book = (await h.engine.importLorebook(jsonEncode(_book()), fileName: 'source.json')).book;
    final regex = (await h.engine.importRegexScripts(jsonEncode(_rule('A')))).scripts.single;
    final cases = [
      (TavernImportKind.character, card.id, '${h.directory.path}/characters/${card.id}/import-report.json'),
      (TavernImportKind.lorebook, book.id, '${h.directory.path}/lorebooks/${book.id}.json'),
      (TavernImportKind.regex, regex.id, '${h.directory.path}/regex-library.json'),
    ];
    h.at = h.at.add(const Duration(days: 1));
    for (final entry in cases) {
      final beforeBytes = await File(entry.$3).readAsBytes();
      final before = (await h.engine.readImportReport(entry.$1, entry.$2))!.toJson();
      final obstruction = await Directory('${entry.$3}.writing').create();
      try {
        final failure = entry.$1 == TavernImportKind.lorebook
            ? isA<TavernAuthoringException>()
                  .having((error) => error.code, 'code', 'resource_write_failed')
                  .having((error) => error.receipt?.committed, 'committed', isFalse)
                  .having((error) => error.cause, 'cause', isA<FileSystemException>())
            : isA<FileSystemException>();
        await expectLater(h.engine.recheckImport(entry.$1, entry.$2), throwsA(failure));
        expect(await File(entry.$3).readAsBytes(), beforeBytes);
        expect((await h.engine.readImportReport(entry.$1, entry.$2))!.toJson(), before);
      } finally {
        await obstruction.delete();
      }
    }
    expect((await h.engine.listLorebooks()).single.stWorldName, 'source');
    expect((await h.engine.listRegexScripts()).single.enabled, isTrue);
  });

  test('regex batch publication failure leaves no new script or report', () async {
    final h = await _open();
    final old = (await h.engine.importRegexScripts(jsonEncode(_rule('A')))).scripts.single;
    final file = File('${h.directory.path}/regex-library.json');
    final before = await file.readAsBytes();
    final obstruction = await Directory('${file.path}.writing').create();
    try {
      await expectLater(
        h.engine.importRegexScripts(jsonEncode([_rule('B'), _rule('C')])),
        throwsA(isA<FileSystemException>()),
      );
      expect(await file.readAsBytes(), before);
      expect((await h.engine.listRegexScripts()).map((value) => value.id), [old.id]);
    } finally {
      await obstruction.delete();
    }
  });

  test('deleting each asset also removes its report and missing reads stay null', () async {
    final h = await _open();
    final card = await h.engine.importCard(_cardBytes());
    final preset = (await h.engine.importPreset('{}')).preset;
    final book = (await h.engine.importLorebook(jsonEncode(_book()))).book;
    final regex = (await h.engine.importRegexScripts(jsonEncode(_rule('A')))).scripts.single;
    await h.engine.deleteCharacter(card.id);
    await h.engine.deletePreset(preset.id);
    await h.engine.deleteLorebook(book.id);
    await h.engine.deleteRegex(regex.id);
    for (final entry in <TavernImportKind, String>{
      TavernImportKind.character: card.id,
      TavernImportKind.preset: preset.id,
      TavernImportKind.lorebook: book.id,
      TavernImportKind.regex: regex.id,
    }.entries) {
      expect(await h.engine.readImportReport(entry.key, entry.value), isNull);
    }
    await expectLater(h.engine.recheckImport(TavernImportKind.character, card.id), throwsA(isA<TavernImportError>()));
    await expectLater(h.engine.recheckImport(TavernImportKind.preset, preset.id), throwsStateError);
    await expectLater(h.engine.recheckImport(TavernImportKind.lorebook, book.id), throwsA(isA<TavernImportError>()));
    await expectLater(h.engine.recheckImport(TavernImportKind.regex, regex.id), throwsA(isA<TavernImportError>()));
  });

  test('character inspection failure publishes no staged character', () async {
    final directory = await Directory.systemTemp.createTemp('t22-character-failed-inspect-');
    addTearDown(() => directory.delete(recursive: true));
    final library = CharacterLibrary(directory);
    await expectLater(
      library.importCard(_cardBytes(), inspect: (_) async => throw StateError('inspection failed')),
      throwsStateError,
    );
    expect(await library.list(), isEmpty);
    expect(await Directory('${directory.path}/characters').list().toList(), isEmpty);
  });

  test('character recheck and subsequent edit use one publication order', () async {
    final directory = await Directory.systemTemp.createTemp('t22-character-report-order-');
    addTearDown(() => directory.delete(recursive: true));
    final library = CharacterLibrary(directory);
    final record = await library.importCard(_cardBytes(), inspect: (card) async => _basicCardReport(card));
    final started = Completer<void>();
    final release = Completer<void>();
    final checking = library.recheckImport(record.id, (card) async {
      started.complete();
      await release.future;
      expect(card.data['first_mes'], 'Hello');
      return _basicCardReport(card);
    });
    await started.future;
    var edited = false;
    final editing = library.updateFields(record.id, {'first_mes': 'new'}).then((value) {
      edited = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(edited, isFalse);
    release.complete();
    final checked = await checking;
    await editing;
    final report = (await library.readImportReport(record.id))!;
    expect(report.fingerprint, checked.fingerprint);
    expect(report.stale, isTrue);
    expect((await library.readFields(record.id))!['first_mes'], 'new');
  });
}

Map<String, Object?> _rule(String pattern) => {
  'id': 'same',
  'scriptName': 'rule',
  'findRegex': pattern,
  'replaceString': 'X',
  'trimStrings': <String>[],
  'placement': [2],
  'disabled': false,
  'markdownOnly': true,
  'promptOnly': false,
  'substituteRegex': 0,
};

Map<String, Object?> _book({Map<String, Object?> extra = const {}}) => {
  'name': 'display title',
  'entries': {
    'actual-key': {
      'uid': 7,
      'key': ['key'],
      'content': 'content',
      'position': 0,
      ...extra,
    },
  },
};

Map<String, Object?> _cardJson([Map<String, Object?> fields = const {}]) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'data': {
    'name': 'Guide',
    'description': '',
    'personality': '',
    'scenario': '',
    'first_mes': 'Hello',
    'mes_example': '',
    'creator_notes': '',
    'system_prompt': '',
    'post_history_instructions': '',
    'alternate_greetings': <String>[],
    'tags': <String>[],
    'creator': '',
    'character_version': '',
    'extensions': <String, Object?>{},
    ...fields,
  },
};
Uint8List _cardBytes([Map<String, Object?> fields = const {}]) =>
    Uint8List.fromList(utf8.encode(jsonEncode(_cardJson(fields))));

TavernImportReport _basicCardReport(TavernCard card) => TavernImportReport(
  kind: TavernImportKind.character,
  checkedAt: DateTime.utc(2026, 11, 10),
  verdict: TavernImportVerdict.usable,
  counts: const {'characters': 1},
  findings: const [],
  fingerprint: importFingerprint(TavernImportKind.character, card.json, embeddedAssetPaths: card.assets.keys),
);

Future<_Harness> _open() async {
  final h = _Harness(await Directory.systemTemp.createTemp('t22-import-report-'));
  await h.open();
  addTearDown(() async {
    await h.engine.close();
    await h.directory.delete(recursive: true);
  });
  return h;
}

class _Harness {
  _Harness(this.directory);
  final Directory directory;
  final model = _NoModel();
  DateTime at = DateTime.utc(2026, 11, 10);
  late TavernEngine engine;
  Future<void> open() async {
    engine = await TavernEngine.openDirectory(directory, modelClient: model, clock: () => at);
  }

  Future<void> reopen() async {
    await engine.close();
    await open();
  }
}

class _NoModel extends TavernModelClient {
  int calls = 0;
  @override
  Stream<ModelDelta> generate({
    required TavernModelConfig config,
    required Map<String, Object?> body,
    required ModelCancellation cancellation,
    void Function(int attempt)? onRequestStarted,
  }) async* {
    calls++;
    throw StateError('Import inspection must never invoke the model.');
  }
}
