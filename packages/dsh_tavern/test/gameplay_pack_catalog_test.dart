import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/gameplay_pack_codec.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('catalog preserves original bytes, opaque identities and saved diagnostics across reopen', () async {
    final h = await ScriptFixture.open();
    const packId = '\uFEFFcatalog';
    const version = '\uFEFFfirst';
    const ruleId = '\uFEFFrules';
    const rulePath = 'regex/rules.json';
    final rule = <String, Object?>{
      'scriptName': 'Retained invalid pattern',
      'findRegex': '/[/g',
      'replaceString': '',
      'placement': [2],
      'foreign': {'keep': null},
    };
    final card = <String, Object?>{
      'spec': 'chara_card_v3',
      'spec_version': '3.9',
      'data': {
        'name': 'Catalog only',
        'extensions': {
          'foreign': [1, null],
        },
      },
      'unknownRoot': true,
    };
    final manifest =
        _manifest(
            packId: packId,
            version: version,
            resources: [
              {'localId': ruleId, 'kind': 'regex', 'path': rulePath},
              {'localId': 'cast', 'kind': 'castCard', 'path': 'cast.json'},
              {'localId': 'asset', 'kind': 'asset', 'path': 'assets/blob.bin'},
            ],
          )
          ..['foreign'] = {
            'keep': [false, null, '原文'],
          };
    final formattedManifest = const JsonEncoder.withIndent('  ').convert(manifest).replaceAll('\n', '\r\n');
    final manifestRaw = '\uFEFF$formattedManifest\r\n';
    final files = <String, Uint8List>{
      rulePath: _jsonBytes(rule),
      'cast.json': _jsonBytes(card),
      'assets/blob.bin': Uint8List.fromList([0, 255, 17]),
      'unlisted.bin': Uint8List.fromList([128, 0, 254]),
    };
    final original = _zip(manifestRaw, files);
    final imported = await h.engine.importGameplayPack(original);
    expect(imported.reused, isFalse);
    expect(imported.version.externalPackId, packId);
    expect(imported.ref.packVersion, version);
    expect(imported.version.manifestRaw, manifestRaw);
    expect(imported.version.manifest, manifest);
    final diagnostic = scriptMap((_resourceInspection(imported, ruleId)['regexDiagnostics']! as List<Object?>).single);
    expect(diagnostic['status'], 'incompatible');
    expect(diagnostic['path'], r'$.findRegex');
    final savedInspection = scriptMap(jsonDecode(jsonEncode(imported.inspection)));
    final asset = (await h.engine.readGameplayPackResource(imported.ref, 'asset'))!;
    expect(asset.bytes, [0, 255, 17]);
    asset.bytes[0] = 99;
    imported.version.manifest['foreign'] = 'local mutation';
    imported.inspection.clear();
    expect(await h.engine.readGameplayPackResource(imported.ref, 'not-declared'), isNull);
    expect(
      await h.engine.watchCharacters().first,
      isEmpty,
      reason: 'A catalog cast declaration must not import a live character.',
    );
    h.expectNoGeneration();

    await h.reopen();
    final saved = (await h.engine.readGameplayPack(imported.ref))!;
    expect(saved.externalPackId, packId);
    expect(saved.ref.packVersion, version);
    expect(saved.manifestRaw, manifestRaw);
    expect(saved.manifest, manifest);
    expect(saved.inspection, savedInspection);
    final savedRule = (await h.engine.readGameplayPackResource(imported.ref, ruleId))!;
    expect(savedRule.localId, ruleId);
    expect(savedRule.path, rulePath);
    expect(savedRule.bytes, orderedEquals(files[rulePath]!));
    expect((await h.engine.readGameplayPackResource(imported.ref, 'asset'))!.bytes, [0, 255, 17]);
    expect((await h.engine.readGameplayPackResource(imported.ref, 'cast'))!.bytes, orderedEquals(files['cast.json']!));
    expect(await h.engine.exportInstalledGameplayPack(imported.ref), orderedEquals(original));
    final repacked = _zip(manifestRaw, files, reverse: true);
    expect(repacked, isNot(orderedEquals(original)));
    final reused = await h.engine.importGameplayPack(repacked);
    expect(reused.reused, isTrue);
    expect(reused.ref.toJson(), imported.ref.toJson());
    expect(reused.digest, imported.digest);
    expect(reused.inspection, savedInspection);
    expect(await h.engine.exportInstalledGameplayPack(imported.ref), orderedEquals(original));
    final archive = ZipDecoder().decodeBytes(await h.engine.exportInstalledGameplayPack(imported.ref), verify: true);
    expect(
      archive.files.singleWhere((file) => file.name == 'unlisted.bin').readBytes(),
      orderedEquals(files['unlisted.bin']!),
    );
    expect((await h.engine.listGameplayPacks()).single.ref.toJson(), imported.ref.toJson());
    h.expectNoGeneration();
  });

  test('stable mappings follow actual lorebook survivors and original regex positions', () async {
    final h = await ScriptFixture.open();
    final book = <String, Object?>{
      'entries': [
        {
          'id': 7,
          'keys': ['old'],
          'content': 'shadowed',
          'enabled': true,
        },
        {
          'id': 7,
          'keys': ['new'],
          'content': 'winner',
          'enabled': true,
        },
        {
          'id': 'paused',
          'keys': ['later'],
          'content': 'retained disabled',
          'enabled': false,
        },
      ],
    };
    final rules = <Object?>[
      42,
      {'findRegex': false, 'replaceString': ''},
      {
        'findRegex': '/x/g',
        'replaceString': 'y',
        'placement': [2],
        'disabled': true,
      },
    ];
    final bookResource = <String, Object?>{
      'localId': 'book',
      'kind': 'lorebook',
      'path': 'book.json',
      'entries': [
        {'localId': 'winner', 'pointer': '/entries/0'},
        {'localId': 'paused', 'pointer': '/entries/2'},
      ],
    };
    final regexResource = <String, Object?>{
      'localId': 'rules',
      'kind': 'regex',
      'path': 'rules.json',
      'entries': [
        {'localId': 'invalid', 'pointer': '/1'},
        {'localId': 'disabled', 'pointer': '/2'},
      ],
    };
    final manifest = _manifest(packId: 'mapped', resources: [bookResource, regexResource]);
    final files = {'book.json': _jsonBytes(book), 'rules.json': _jsonBytes(rules)};
    await expectLater(h.engine.importGameplayPack(_zip(jsonEncode(manifest), files)), throwsA(isA<FormatException>()));
    expect(await h.engine.listGameplayPacks(includeRemoved: true), isEmpty);
    bookResource['entries'] = [
      {'localId': 'winner', 'pointer': '/entries/1'},
      {'localId': 'paused', 'pointer': '/entries/2'},
    ];
    final broken = Map<String, Uint8List>.of(files)..['rules.json'] = Uint8List.fromList(utf8.encode('{broken'));
    await expectLater(h.engine.importGameplayPack(_zip(jsonEncode(manifest), broken)), throwsA(isA<FormatException>()));
    expect(await h.engine.listGameplayPacks(includeRemoved: true), isEmpty);
    final imported = await h.engine.importGameplayPack(_zip(jsonEncode(manifest), files));
    expect((await h.engine.readGameplayPackResource(imported.ref, 'book'))!.bytes, orderedEquals(files['book.json']!));
    final inspected = _resourceInspection(imported, 'rules');
    final diagnostics = (inspected['regexDiagnostics']! as List<Object?>).map(scriptMap).toList();
    expect(diagnostics.map((value) => value['path']), [r'$[0]', r'$[1]', r'$[2].findRegex']);
    expect(diagnostics[0]['code'], 'invalid-rule');
    expect(diagnostics[1]['code'], 'invalid-script');
    expect((inspected['reports']! as List<Object?>).map(scriptMap).map((value) => value['pointer']), ['/1', '/2']);
    expect(
      (await h.engine.readGameplayPackResource(imported.ref, 'rules'))!.bytes,
      orderedEquals(files['rules.json']!),
    );
    h.expectNoGeneration();
  });

  test('removal uses domain CAS and full replay while reimport cannot revive a tombstone', () async {
    final h = await ScriptFixture.open();
    final bytes = _zip(jsonEncode(_manifest(packId: 'removed')), const {});
    final imported = await h.engine.importGameplayPack(bytes);
    final before = imported.version.availability;
    const operationId = '\uFEFFremove';
    final removed = await h.engine.removeGameplayPackVersion(imported.ref, expected: before, operationId: operationId);
    expect(removed.changed, isTrue);
    expect(removed.availability.revision, before.revision + 1);
    expect(
      (await h.engine.removeGameplayPackVersion(imported.ref, expected: before, operationId: operationId)).toJson(),
      removed.toJson(),
    );
    await expectLater(
      h.engine.removeGameplayPackVersion(imported.ref, expected: removed.availability, operationId: operationId),
      throwsA(_gameplayError('operation_conflict')),
    );
    await expectLater(
      h.engine.removeGameplayPackVersion(imported.ref, expected: before, operationId: 'stale'),
      throwsA(_gameplayError('revision_conflict')),
    );
    final noChange = await h.engine.removeGameplayPackVersion(
      imported.ref,
      expected: removed.availability,
      operationId: 'already-removed',
    );
    expect(noChange.changed, isFalse);
    expect(noChange.availability.toJson(), removed.availability.toJson());
    final reused = await h.engine.importGameplayPack(bytes);
    expect(reused.reused, isTrue);
    expect(reused.ref.toJson(), imported.ref.toJson());
    expect(reused.version.removed, isTrue);
    expect(reused.version.availability.toJson(), removed.availability.toJson());
    expect(await h.engine.listGameplayPacks(), isEmpty);
    expect((await h.engine.listGameplayPacks(includeRemoved: true)).single.removed, isTrue);
    expect(await h.engine.exportInstalledGameplayPack(imported.ref), orderedEquals(bytes));

    await h.reopen(
      whileClosed: () async {
        final rootPath = h.root.path;
        final store = ChatStore.open('$rootPath/tavern.sqlite3');
        try {
          store.rotateAuthoringDomain();
        } finally {
          await store.close();
        }
      },
    );
    final current = (await h.engine.readGameplayPack(imported.ref))!;
    expect(current.availability.domainId, isNot(before.domainId));
    expect(current.removed, isTrue);
    expect(
      (await h.engine.removeGameplayPackVersion(imported.ref, expected: before, operationId: operationId)).toJson(),
      removed.toJson(),
    );
    await expectLater(
      h.engine.removeGameplayPackVersion(imported.ref, expected: before, operationId: 'unrecorded-old-domain'),
      throwsA(_gameplayError('revision_conflict')),
    );
    final next = await h.engine.importGameplayPack(
      _zip(jsonEncode(_manifest(packId: 'removed', version: 'next')), const {}),
    );
    expect(next.ref.installedPackId, imported.ref.installedPackId);
    expect(next.version.removed, isFalse);
    h.expectNoGeneration();
  });

  test('real outer COMMIT adopts the original result before publication can fail', () async {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    final pack = decodeGameplayPack(_zip(jsonEncode(_manifest(packId: 'commit')), const {}));
    final inspection = <String, Object?>{
      'dshgo': inspectDshgoExtension(null, present: false).toJson(),
      'resources': <Object?>[],
    };
    TavernPackImportResult? adopted;
    db.execute("""
      CREATE TEMP TRIGGER reject_pack BEFORE INSERT ON gameplay_pack_versions
      BEGIN SELECT RAISE(ABORT, 'before COMMIT'); END;
    """);
    expect(
      () => store.importGameplayPackData(
        pack,
        inspection: inspection,
        onCommitted: (result) {
          adopted = result;
        },
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(adopted, isNull);
    expect(store.listGameplayPackVersions(includeRemoved: true), isEmpty);
    db.execute('DROP TRIGGER reject_pack');
    final publication = StateError('Real COMMIT observer failure.');
    store.committedObserver = (_, _) {
      throw publication;
    };
    try {
      expect(
        () => store.importGameplayPackData(
          pack,
          inspection: inspection,
          onCommitted: (result) {
            adopted = result;
          },
        ),
        throwsA(same(publication)),
      );
    } finally {
      store.committedObserver = null;
    }
    final first = adopted!;
    expect(first.reused, isFalse);
    expect(store.readGameplayPackVersion(first.ref)!.inspection, inspection);
    expect(store.readGameplayPackArchive(first.ref), orderedEquals(pack.originalZip));
    final reused = store.importGameplayPackData(pack, inspection: {'mustNotReplace': true});
    expect(reused.reused, isTrue);
    expect(reused.inspection, inspection);

    TavernPackRemovalReceipt? removal;
    store.committedObserver = (_, _) {
      throw publication;
    };
    try {
      expect(
        () => store.removeGameplayPackVersionData(
          first.ref,
          expected: first.version.availability,
          operationId: 'remove-after-commit',
          onCommitted: (result) {
            removal = result;
          },
        ),
        throwsA(same(publication)),
      );
    } finally {
      store.committedObserver = null;
    }
    expect(removal, isNotNull);
    expect(store.readGameplayPackVersion(first.ref)!.removed, isTrue);
    expect(
      store
          .removeGameplayPackVersionData(
            first.ref,
            expected: first.version.availability,
            operationId: 'remove-after-commit',
          )
          .toJson(),
      removal!.toJson(),
    );
  });

  test('reuse skips a new inspection clock and admitted import drains through reentrant close', () async {
    final root = await Directory.systemTemp.createTemp('dsh-pack-close-');
    TavernEngine? engine;
    Future<void>? closing;
    var failClock = false;
    var armed = false;
    var keyReads = 0;
    final at = DateTime.utc(2026, 11, 14);
    final rule = _jsonBytes({
      'findRegex': '/x/g',
      'replaceString': 'y',
      'placement': [2],
    });
    final resource = <String, Object?>{'localId': 'r', 'kind': 'regex', 'path': 'r.json'};
    final config = TavernModelConfig(
      baseUrl: 'https://catalog.invalid/v1',
      model: 'unused',
      deepseek: false,
      thinking: false,
      apiKey: () async {
        keyReads++;
        throw StateError('Catalog work must not request a model.');
      },
    );
    DateTime clock() {
      if (failClock) {
        throw StateError('A reused version must retain its original inspection.');
      }
      if (armed) {
        armed = false;
        closing = engine!.close();
        closing!.ignore();
      }
      return at;
    }

    try {
      final opened = await TavernEngine.openDirectory(root, config: config, clock: clock);
      engine = opened;
      final manifest = jsonEncode(_manifest(packId: 'closing', resources: [resource]));
      final original = _zip(manifest, {'r.json': rule});
      final imported = await opened.importGameplayPack(original);
      failClock = true;
      try {
        final reused = await opened.importGameplayPack(_zip(manifest, {'r.json': rule}, reverse: true));
        expect(reused.reused, isTrue);
        expect(reused.inspection, imported.inspection);
        await expectLater(
          opened.importGameplayPack(
            _zip(manifest, {
              'r.json': _jsonBytes({
                'findRegex': '/other/g',
                'replaceString': '',
                'placement': [2],
              }),
            }),
          ),
          throwsA(_gameplayError('version_conflict')),
        );
      } finally {
        failClock = false;
      }
      final supplied = _zip(jsonEncode(_manifest(packId: 'closing', version: 'next', resources: [resource])), {
        'r.json': rule,
      });
      final captured = Uint8List.fromList(supplied);
      armed = true;
      final importing = opened.importGameplayPack(supplied);
      supplied.fillRange(0, supplied.length, 0);
      final completed = await importing;
      expect(closing, isNotNull);
      await closing;
      final reopened = await TavernEngine.openDirectory(root, config: config, clock: clock);
      engine = reopened;
      expect((await reopened.readGameplayPack(completed.ref))!.ref.toJson(), completed.ref.toJson());
      expect(await reopened.exportInstalledGameplayPack(completed.ref), orderedEquals(captured));
      expect(keyReads, 0);
    } finally {
      armed = false;
      failClock = false;
      await engine?.close();
      await closing;
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    }
    expect(await root.exists(), isFalse);
  });
}

Map<String, Object?> _manifest({
  required String packId,
  String version = '1',
  List<Map<String, Object?>> resources = const [],
}) => {'formatVersion': 1, 'packId': packId, 'packVersion': version, 'resources': resources};

Uint8List _jsonBytes(Object? value) => Uint8List.fromList(utf8.encode(jsonEncode(value)));

Uint8List _zip(String manifestRaw, Map<String, Uint8List> files, {bool reverse = false}) {
  final archive = Archive();
  final entries = [MapEntry('pack.json', Uint8List.fromList(utf8.encode(manifestRaw))), ...files.entries];
  for (final entry in reverse ? entries.reversed : entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Map<String, Object?> _resourceInspection(TavernPackImportResult result, String localId) =>
    (result.inspection['resources']! as List<Object?>)
        .map(scriptMap)
        .singleWhere((value) => value['localId'] == localId);

TypeMatcher<TavernGameplayException> _gameplayError(String code) =>
    isA<TavernGameplayException>().having((error) => error.code, 'code', code);
