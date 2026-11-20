import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('a raw old-format seed survives reopen and exposes its conversion without importing a card', () async {
    final h = await ScriptFixture.open();
    const raw =
        '\ufeff{ "spec":"chara_card_v2", "spec_version":"2.0", "unknown":{"nil":null}, '
        '"data":{"name":"Seed","description":"Unexpanded {{char}}","extensions":{"vendor":false}} }';
    final original = Uint8List.fromList(utf8.encode(raw));
    final supplied = Uint8List.fromList(original);
    final creating = h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.character, bytes: supplied, fileName: 'old.json'),
    );
    supplied.fillRange(0, supplied.length, 0);
    final draft = await creating;
    final source = draft.sources.single;
    expect(source.origin, TavernAuthoringSourceOrigin.seed);
    expect(source.authorityRevision, isNull);
    expect(source.applySupported, isFalse);
    expect(source.base, jsonDecode(raw.substring(1)));
    expect(scriptMap(source.base['data']).containsKey('personality'), isFalse);
    expect(draft.changes.single.id, 'seed-upgrade-v3');
    expect(draft.changes.single.path, '');
    final untouched = await h.engine.previewAuthoringDraft(draft.id, draftRevision: draft.draftRevision, changeIds: []);
    expect(untouched.candidates[source.physicalResourceId], source.base);
    final converted = await h.engine.previewAuthoringDraft(
      draft.id,
      draftRevision: draft.draftRevision,
      changeIds: ['seed-upgrade-v3'],
    );
    expect(converted.candidates[source.physicalResourceId]!['spec'], 'chara_card_v3');
    expect(converted.diffs.single.before, source.base);
    expect(await Directory('${h.root.path}/characters/${source.target.id}').exists(), isFalse);
    expect(await h.engine.watchCharacters().first, isEmpty);
    await expectLater(
      h.engine.rebaseAuthoringDraft(draft.id, draftRevision: draft.draftRevision, changes: draft.changes),
      throwsA(_error('unsupported_seed')),
    );
    await h.reopen();
    expect((await h.engine.readAuthoringDraft(draft.id))!.sources.single.base, source.base);
    h.inspect((db) {
      final saved = scriptMap(
        jsonDecode(
          db.select('SELECT data_json FROM authoring_drafts WHERE id = ?', [draft.id]).single['data_json']! as String,
        ),
      );
      expect(scriptMap((saved['sources']! as List<Object?>).single)['rawText'], raw);
      expect(
        db.select('SELECT bytes FROM authoring_seed_blobs WHERE draft_id = ? AND path = ?', [
          draft.id,
          'original.json',
        ]).single['bytes'],
        original,
      );
    });
    h.expectNoGeneration();
  });

  test('captured CHARX media and selected raw JSON create one replayable new target', () async {
    final h = await ScriptFixture.open();
    final raw = _card(
      'Seed',
      assets: [
        {'type': 'x_custom', 'uri': 'embeded://notes.txt'},
      ],
    );
    final original = _charx(raw);
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.character, bytes: original, fileName: 'saved.charx'),
    );
    final draft = await h.engine.editAuthoringDraft(
      seed.id,
      draftRevision: seed.draftRevision,
      changes: [_set(seed, 'name', '/data/name', 'Selected')],
    );
    await h.reopen();
    final first = await _save(h.engine, draft, 'captured-card', TavernAuthoringMediaSelection.seedCaptured);
    expect(first.committed, isTrue);
    final id = first.newTarget!.id;
    final targetDirectory = Directory('${h.root.path}/characters/$id');
    final expected = scriptMap(jsonDecode(jsonEncode(raw)));
    scriptMap(expected['data'])['name'] = 'Selected';
    expect(await _json(File('${targetDirectory.path}/card.json')), expected);
    expect(await File('${targetDirectory.path}/original.charx').readAsBytes(), original);
    expect(await File('${targetDirectory.path}/resources/notes.txt').readAsString(), 'seed notes');
    expect(await File('${targetDirectory.path}/resources/unknown-app.bin').readAsBytes(), utf8.encode('\u0000opaque'));
    expect(first.copiedMedia.toSet(), {'original.charx', 'resources/notes.txt', 'resources/unknown-app.bin'});
    expect(first.issues, isEmpty);
    expect((await h.engine.readImportReport(TavernImportKind.character, id))!.stale, isFalse);
    expect((await h.engine.readAuthoringDraft(draft.id))!.sources.single.base, raw);
    await h.engine.deleteAuthoringDraft(draft.id, draftRevision: draft.draftRevision);
    expect(h.inspect((db) => db.select('SELECT * FROM authoring_seed_blobs WHERE draft_id = ?', [draft.id])), isEmpty);
    await h.reopen();
    final replay = await _save(
      h.engine,
      draft,
      'captured-card',
      TavernAuthoringMediaSelection.seedCaptured,
      domainId: first.outcome.domainId,
    );
    expect(replay.newTarget!.id, id);
    expect(replay.authorityRevision, first.authorityRevision);
    expect(replay.copiedMedia, first.copiedMedia);
    expect(await h.engine.listAuthoringRevisions(first.newTarget!.physicalResourceId), hasLength(1));
    await expectLater(
      _save(h.engine, draft, 'captured-card', TavernAuthoringMediaSelection.none, domainId: first.outcome.domainId),
      throwsA(_error('operation_conflict')),
    );

    final work = await Directory.systemTemp.createTemp('dsh-seed-restore-');
    addTearDown(() async {
      if (await work.exists()) {
        await work.delete(recursive: true);
      }
    });
    final archive = File('${work.path}/saved.zip');
    await h.engine.backup(archive.path);
    final restoredDirectory = Directory('${work.path}/restored');
    await restoreTavernDirectory(archive.path, restoredDirectory.path);
    final restored = await TavernEngine.openDirectory(restoredDirectory);
    addTearDown(restored.close);
    expect(
      (await _save(
        restored,
        draft,
        'captured-card',
        TavernAuthoringMediaSelection.seedCaptured,
        domainId: first.outcome.domainId,
      )).newTarget!.id,
      id,
    );
    await expectLater(
      _save(
        restored,
        draft,
        'new-old-domain',
        TavernAuthoringMediaSelection.seedCaptured,
        domainId: first.outcome.domainId,
      ),
      throwsA(_error('authority_conflict')),
    );
    h.expectNoGeneration();
  });

  test('no-media Save As from a PNG keeps references but stores the candidate as its JSON original', () async {
    final h = await ScriptFixture.open();
    final original = await File('test/fixtures/card-both.png').readAsBytes();
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.character, bytes: original, fileName: 'source.png'),
    );
    final saved = await _save(h.engine, seed, 'png-without-media', TavernAuthoringMediaSelection.none);
    expect(saved.committed, isTrue);
    final directory = Directory('${h.root.path}/characters/${saved.newTarget!.id}');
    final actual = await _json(File('${directory.path}/card.json'));
    expect(actual, seed.sources.single.base);
    expect(await _json(File('${directory.path}/original.json')), actual);
    expect(await File('${directory.path}/original.png').exists(), isFalse);
    expect(await File('${directory.path}/source.png').exists(), isFalse);
    expect((await _json(File('${directory.path}/library.json')))['sourceFormat'], 'json');
    expect(saved.copiedMedia, isEmpty);
    expect(saved.issues.any((issue) => issue.type == 'media_not_copied' && issue.message == 'ccdefault:'), isTrue);
    expect(
      h.inspect(
        (db) => db.select('SELECT bytes FROM authoring_seed_blobs WHERE draft_id = ? AND path = ?', [
          seed.id,
          'original.png',
        ]).single['bytes'],
      ),
      original,
    );
    h.expectNoGeneration();
  });

  test('current-source media is read after queued source CAS and does not pretend to be historical media', () async {
    final h = await ScriptFixture.open();
    final original = _charx(
      _card(
        'Existing',
        assets: [
          {'type': 'x_custom', 'uri': 'embeded://notes.txt'},
        ],
      ),
    );
    final imported = await h.engine.importCard(original, fileName: 'current.charx');
    final directory = Directory('${h.root.path}/characters/${imported.id}');
    final identity = File('${directory.path}/library.json');
    await identity.writeAsString('\ufeff${await identity.readAsString()}');
    final target = TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: imported.id);
    final draft = await h.engine.createAuthoringDraft([target]);
    await File('${directory.path}/resources/notes.txt').writeAsString('current bytes');
    await File('${directory.path}/resources/not-in-manifest.txt').writeAsString('must not be copied');
    final saved = await _save(h.engine, draft, 'current-card', TavernAuthoringMediaSelection.currentSource);
    final destination = Directory('${h.root.path}/characters/${saved.newTarget!.id}');
    expect(await File('${destination.path}/resources/notes.txt').readAsString(), 'current bytes');
    expect(await File('${destination.path}/resources/not-in-manifest.txt').exists(), isFalse);
    expect(await File('${destination.path}/original.charx').readAsBytes(), original);
    expect(saved.copiedMedia, contains('resources/notes.txt'));
    expect(await File('${directory.path}/resources/notes.txt').readAsString(), 'current bytes');
    final ordinary = (await h.engine.listAuthoringRevisions(target.physicalResourceId)).first;
    await expectLater(
      _save(h.engine, draft, ordinary.operationId, TavernAuthoringMediaSelection.none, domainId: ordinary.domainId),
      throwsA(_error('operation_conflict')),
    );
    await h.engine.updateCharacterFields(imported.id, {'description': 'Changed after capture'});
    await expectLater(
      _save(h.engine, draft, 'stale-source', TavernAuthoringMediaSelection.currentSource),
      throwsA(_error('authority_conflict')),
    );
    expect(await h.engine.readAuthoringOperation('stale-source', domainId: saved.outcome.domainId), isNull);
    h.expectNoGeneration();
  });

  test('unfinished lorebook seeds can be corrected and saved without normalizing their envelope', () async {
    final h = await ScriptFixture.open();
    const raw = '\ufeff{"format":"dshgo-lorebook","version":1,"vendor":{"keep":null},"book":{"entries":42}}';
    final seed = await h.engine.createAuthoringSeed(
      TavernAuthoringSeedInput(kind: TavernAuthoringTargetKind.lorebook, bytes: Uint8List.fromList(utf8.encode(raw))),
    );
    expect(seed.changes, isEmpty);
    expect(await h.engine.listLorebooks(), isEmpty);
    await expectLater(
      _save(h.engine, seed, 'unfinished-book', TavernAuthoringMediaSelection.none),
      throwsA(_error('invalid_change')),
    );
    final draft = await h.engine.editAuthoringDraft(
      seed.id,
      draftRevision: seed.draftRevision,
      changes: [_set(seed, 'entries', '/book/entries', <String, Object?>{})],
    );
    final saved = await _save(h.engine, draft, 'finished-book', TavernAuthoringMediaSelection.seedCaptured);
    expect(saved.committed, isTrue);
    final expected = scriptMap(jsonDecode(raw.substring(1)));
    scriptMap(expected['book'])['entries'] = <String, Object?>{};
    expect(await _json(File('${h.root.path}/lorebooks/${saved.newTarget!.id}.json')), expected);
    expect((await h.engine.listLorebooks()).single.id, saved.newTarget!.id);
    expect(saved.copiedMedia, isEmpty);
    expect(saved.issues, isEmpty);
    expect((await h.engine.readAuthoringDraft(seed.id))!.sources.single.base, jsonDecode(raw.substring(1)));
    h.expectNoGeneration();
  });

  test(
    'a Save As rename remains adopted when its durable marker fails and replay never allocates a second card',
    () async {
      final h = await ScriptFixture.open();
      final seed = await h.engine.createAuthoringSeed(
        TavernAuthoringSeedInput(
          kind: TavernAuthoringTargetKind.character,
          bytes: Uint8List.fromList(utf8.encode(jsonEncode(_card('Adopted')))),
        ),
      );
      h.inspect(
        (db) => db.execute("""
      CREATE TRIGGER seed_marker_abort BEFORE UPDATE OF state ON authoring_operations
      WHEN NEW.operation_id = 'seed-marker' AND NEW.state = 'adopted'
      BEGIN SELECT RAISE(ABORT, 'seed marker fixture'); END
    """),
        writable: true,
      );
      addTearDown(() => h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS seed_marker_abort'), writable: true));
      final first = await _save(h.engine, seed, 'seed-marker', TavernAuthoringMediaSelection.none);
      expect(first.committed, isTrue);
      expect(first.outcome.historyPending, isTrue);
      expect(first.outcome.adoptedRevision, isNull);
      final id = first.newTarget!.id;
      expect((await h.engine.character(id))!.name, 'Adopted');
      expect(await _json(File('${h.root.path}/characters/$id/card.json')), seed.sources.single.base);
      final prepared = h.inspect(
        (db) => Map<String, Object?>.from(
          db.select('SELECT * FROM authoring_operations WHERE operation_id = ?', ['seed-marker']).single,
        ),
      );
      expect(prepared['physical_resource_id'], 'character:$id');
      expect(scriptMap(jsonDecode(prepared['before_json']! as String))['present'], isFalse);
      expect(scriptMap(jsonDecode(prepared['request_json']! as String))['saveAsResult'], isA<Map<String, Object?>>());
      h.inspect((db) => db.execute('DROP TRIGGER seed_marker_abort'), writable: true);
      final replay = await _save(
        h.engine,
        seed,
        'seed-marker',
        TavernAuthoringMediaSelection.none,
        domainId: first.outcome.domainId,
      );
      expect(replay.newTarget!.id, id);
      expect(replay.outcome.state, TavernAuthoringOperationState.published);
      expect(replay.outcome.historyPending, isFalse);
      expect(await h.engine.listAuthoringRevisions('character:$id'), hasLength(1));
      final directories = (await Directory('${h.root.path}/characters').list().toList()).whereType<Directory>().where(
        (entry) => entry.uri.pathSegments.where((part) => part.isNotEmpty).last.startsWith('card-'),
      );
      expect(directories, hasLength(1));
      h.expectNoGeneration();
    },
  );
}

Map<String, Object?> _card(String name, {List<Map<String, Object?>>? assets}) => {
  'spec': 'chara_card_v3',
  'spec_version': '3.0',
  'unknown_root': {'retained': null},
  'data': {
    'name': name,
    'assets': ?assets,
    'extensions': {'vendor': false},
  },
};

Uint8List _charx(Map<String, Object?> raw) => Uint8List.fromList(
  ZipEncoder().encode(
    Archive()
      ..addFile(ArchiveFile.string('card.json', jsonEncode(raw)))
      ..addFile(ArchiveFile.string('notes.txt', 'seed notes'))
      ..addFile(ArchiveFile.string('unknown-app.bin', '\u0000opaque')),
  ),
);

TavernAuthoringChange _set(TavernAuthoringDraft draft, String id, String path, Object? value) => TavernAuthoringChange(
  id: id,
  physicalResourceId: draft.sources.single.physicalResourceId,
  path: path,
  operation: TavernAuthoringChangeKind.set,
  value: value,
);

Future<TavernAuthoringSaveAsReceipt> _save(
  Tavern engine,
  TavernAuthoringDraft draft,
  String operationId,
  TavernAuthoringMediaSelection media, {
  String? domainId,
}) => engine.saveAuthoringAsNew(
  draft.id,
  draftRevision: draft.draftRevision,
  physicalResourceId: draft.sources.single.physicalResourceId,
  changeIds: draft.changes.map((change) => change.id).toList(),
  operationId: operationId,
  media: media,
  domainId: domainId,
);

TypeMatcher<TavernAuthoringException> _error(String code) =>
    isA<TavernAuthoringException>().having((error) => error.code, 'code', code);

Future<Map<String, Object?>> _json(File file) async => scriptMap(jsonDecode(await file.readAsString()));
