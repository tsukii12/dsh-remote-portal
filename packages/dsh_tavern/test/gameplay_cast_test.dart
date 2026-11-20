import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/authoring_authority.dart';
import 'package:dsh_tavern/src/io/import_intake.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('explicit pack selectors preserve originals and media while one intent replays one adopted character', () async {
    final h = await ScriptFixture.open();
    final child = <String, Object?>{
      'name': 'Manifest child',
      'assets': [
        {'type': 'x_custom', 'uri': 'embedded://assets/a.txt'},
        {'type': 'x_custom', 'uri': 'embedded://assets/b.txt'},
      ],
      'extensions': {
        'unknown': {'nil': null, 'value': false},
      },
    };
    const resourceText =
        '\ufeff{ "spec":"chara_card_v3", "spec_version":"3.9", '
        '"foreign":{"kept":null}, "data":{"name":"Resource child","extensions":{"raw":false}} }';
    final archive = _pack(
      'cast-selection',
      {
        'cast': [
          {'id': 'same', 'card': child},
        ],
      },
      resources: [
        {'localId': 'same', 'kind': 'castCard', 'path': 'cast.json'},
        {'localId': 'asset-a', 'kind': 'asset', 'path': 'assets/a.txt'},
        {'localId': 'asset-b', 'kind': 'asset', 'path': 'assets/b.txt'},
      ],
      files: {
        'cast.json': utf8.encode(resourceText),
        'assets/a.txt': utf8.encode('first actual asset'),
        'assets/b.txt': utf8.encode('second actual asset'),
        'unselected.txt': utf8.encode('not implicitly copied'),
      },
    );
    final installed = await h.engine.importGameplayPack(archive);
    await h.engine.removeGameplayPackVersion(
      installed.ref,
      expected: installed.version.availability,
      operationId: 'remove-before-cast',
    );
    expect((await h.engine.readGameplayPack(installed.ref))!.removed, isTrue);

    final manifestSource = TavernCastSource.pack(packRef: installed.ref, assetResourceIds: ['asset-b', 'asset-a']);
    final imported = await h.engine.importDshgoCastMember(manifestSource, 'same', operationId: 'manifest-cast');
    expect(imported.receipt.committed, isTrue);
    final id = imported.mapping!.characterId;
    final directory = Directory('${h.root.path}/characters/$id');
    expect(await _cardJson(h, id), {'spec': 'chara_card_v3', 'spec_version': '3.0', 'data': child});
    expect(await File('${directory.path}/resources/assets/a.txt').readAsString(), 'first actual asset');
    expect(await File('${directory.path}/resources/assets/b.txt').readAsString(), 'second actual asset');
    expect(await File('${directory.path}/resources/unselected.txt').exists(), isFalse);
    expect(imported.receipt.copiedMedia.toSet(), {'original.json', 'resources/assets/a.txt', 'resources/assets/b.txt'});
    expect(imported.receipt.issues, isEmpty);
    expect(imported.mapping!.source.assetResourceIds, ['asset-a', 'asset-b']);

    final resource = await h.engine.importDshgoCastMember(
      TavernCastSource.packResource(packRef: installed.ref),
      'same',
      operationId: 'resource-cast',
    );
    final resourceId = resource.mapping!.characterId;
    expect(resourceId, isNot(id));
    expect(await File('${h.root.path}/characters/$resourceId/card.json').readAsBytes(), utf8.encode(resourceText));
    expect(await File('${h.root.path}/characters/$resourceId/original.json').readAsBytes(), utf8.encode(resourceText));
    expect(resource.mapping!.source.kind, TavernCastSourceKind.packResource);

    final beforeRead = _operations(h);
    final read = await h.engine.readDshgoCastImport(imported.mapping!.domainId, 'manifest-cast');
    expect(read!.mapping!.toJson(), imported.mapping!.toJson());
    expect(_operations(h), beforeRead);
    await h.reopen();
    final replay = await h.engine.importDshgoCastMember(
      TavernCastSource.pack(packRef: installed.ref, assetResourceIds: ['asset-a', 'asset-b']),
      'same',
      operationId: 'manifest-cast',
      domainId: imported.mapping!.domainId,
    );
    expect(replay.mapping!.characterId, id);
    expect(replay.receipt.authorityRevision, imported.receipt.authorityRevision);
    expect(await h.engine.watchCharacters().first, hasLength(2));
    await expectLater(
      h.engine.importDshgoCastMember(
        TavernCastSource.packResource(packRef: installed.ref),
        'same',
        operationId: 'manifest-cast',
        domainId: imported.mapping!.domainId,
      ),
      throwsA(_authoringError('operation_conflict')),
    );
    expect(await h.engine.exportInstalledGameplayPack(installed.ref), archive);
    expect((await h.engine.readGameplayPackResource(installed.ref, 'same'))!.bytes, utf8.encode(resourceText));
    h.expectNoGeneration();
  });

  test('card cast without media keeps its captured source through the final prepared-import CAS', () async {
    final h = await ScriptFixture.open();
    final child = <String, Object?>{
      'name': 'Child',
      'extensions': {'notDefaulted': null},
    };
    final parentId = await h.card(
      'Parent',
      extensions: {
        'dshgo': {
          'cast': [
            {'id': 'child', 'card': child},
          ],
        },
      },
    );
    final draft = await h.engine.createAuthoringDraft([
      TavernAuthoringTarget(kind: TavernAuthoringTargetKind.character, id: parentId),
    ]);
    final card = draft.sources.single;
    final source = TavernCastSource.card(card: card);
    final parentFile = File('${h.root.path}/characters/$parentId/card.json');
    final original = await parentFile.readAsBytes();
    final imported = await h.engine.importDshgoCastMember(source, 'child', operationId: 'card-cast');
    expect(imported.mapping!.source.copyMedia, isFalse);
    expect(imported.receipt.copiedMedia, isEmpty);
    expect(await _cardJson(h, imported.mapping!.characterId), {
      'spec': 'chara_card_v3',
      'spec_version': '3.0',
      'data': child,
    });
    expect(await parentFile.readAsBytes(), original);

    // Use the real existing inspection callback to change the source after
    // decode/portrait work, while the prepared importer still owns its queue.
    await h.close();
    final store = ChatStore.open('${h.root.path}/tavern.sqlite3');
    var inspected = false;
    try {
      final authority = AuthoringAuthority(root: h.root, store: store);
      final before = authority.peek('character:$parentId').snapshot!;
      final library = CharacterLibrary(h.root, authority: authority, now: () => DateTime.utc(2026, 11, 14));
      final envelope = <String, Object?>{'spec': 'chara_card_v3', 'spec_version': '3.0', 'data': child};
      await expectLater(
        library.importAuthoringEnvelope(
          jsonEncode(envelope),
          domainId: authority.domainId,
          operationId: 'late-card-cast',
          parameters: {'method': 'importDshgoCastMember', 'source': source.toJson(), 'localCastId': 'child'},
          media: TavernAuthoringMediaSelection.none,
          mediaRefs: const [],
          sourceFormat: 'json',
          requiredSource: (
            id: parentId,
            expected: AuthoringExpectation(revision: card.authorityRevision!, before: before),
          ),
          inspect: (_) async {
            final changed = scriptMap(jsonDecode(utf8.decode(original)));
            changed['externalChange'] = true;
            await parentFile.writeAsString(jsonEncode(changed), flush: true);
            inspected = true;
            return assessImport(
              kind: TavernImportKind.character,
              document: envelope,
              checkedAt: DateTime.utc(2026, 11, 14),
            );
          },
        ),
        throwsA(_authoringError('authority_conflict')),
      );
      expect(inspected, isTrue);
      expect(store.readAuthoringOperationData(authority.domainId, 'late-card-cast'), isNull);
      expect(authority.peek('character:$parentId').revision, card.authorityRevision!.revision + 1);
    } finally {
      await store.close();
    }
    await h.openEngine();
    expect(await h.engine.watchCharacters().first, hasLength(2));
    final replay = await h.engine.importDshgoCastMember(
      source,
      'child',
      operationId: 'card-cast',
      domainId: imported.mapping!.domainId,
    );
    expect(replay.mapping!.characterId, imported.mapping!.characterId);
    await expectLater(
      h.engine.importDshgoCastMember(source, 'child', operationId: 'stale-card-cast'),
      throwsA(_authoringError('authority_conflict')),
    );
    h.expectNoGeneration();
  });

  test('cast mapping follows actual adoption and a pure journal read does not publish a pending marker', () async {
    final h = await ScriptFixture.open();
    final installed = await h.engine.importGameplayPack(
      _pack('cast-marker', {
        'cast': [
          {
            'id': 'child',
            'card': {
              'name': 'Adopted child',
              'extensions': {'kept': false},
            },
          },
        ],
      }),
    );
    final source = TavernCastSource.pack(packRef: installed.ref);
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER cast_marker_abort BEFORE UPDATE OF state ON authoring_operations
      WHEN NEW.operation_id = 'cast-marker' AND NEW.state = 'adopted'
      BEGIN SELECT RAISE(ABORT, 'cast marker fixture'); END
    """),
      writable: true,
    );
    addTearDown(() => h.inspect((db) => db.execute('DROP TRIGGER IF EXISTS cast_marker_abort'), writable: true));
    final first = await h.engine.importDshgoCastMember(source, 'child', operationId: 'cast-marker');
    expect(first.receipt.committed, isTrue);
    expect(first.receipt.outcome.historyPending, isTrue);
    expect(first.receipt.outcome.adoptedRevision, isNull);
    final mapping = first.mapping!;
    expect((await h.engine.character(mapping.characterId))!.name, 'Adopted child');
    h.inspect((db) => db.execute('DROP TRIGGER cast_marker_abort'), writable: true);

    // The physical rename is known to the live owner, but its stored prepared
    // row is still inconclusive. Reading this API must not reconcile that row.
    final beforeRead = _operations(h);
    final pending = await h.engine.readDshgoCastImport(mapping.domainId, mapping.operationId);
    expect(pending!.receipt.committed, isNull);
    expect(pending.receipt.newTarget!.id, mapping.characterId);
    expect(pending.mapping, isNull);
    expect(_operations(h), beforeRead);

    final replay = await h.engine.importDshgoCastMember(
      source,
      'child',
      operationId: mapping.operationId,
      domainId: mapping.domainId,
    );
    expect(replay.receipt.outcome.state, TavernAuthoringOperationState.published);
    expect(replay.mapping!.characterId, mapping.characterId);
    expect(replay.receipt.outcome.historyPending, isFalse);
    expect(await h.engine.watchCharacters().first, hasLength(1));
    final saved = await h.engine.readDshgoCastImport(mapping.domainId, mapping.operationId);
    expect(saved!.mapping!.toJson(), mapping.toJson());
    await h.reopen();
    expect(
      (await h.engine.readDshgoCastImport(mapping.domainId, mapping.operationId))!.mapping!.toJson(),
      mapping.toJson(),
    );
    expect(await h.engine.listAuthoringRevisions('character:${mapping.characterId}'), hasLength(1));
    h.expectNoGeneration();
  });
}

Uint8List _pack(
  String id,
  Map<String, Object?> dshgo, {
  List<Map<String, Object?>> resources = const [],
  Map<String, List<int>> files = const {},
}) {
  final manifest = {'formatVersion': 1, 'packId': id, 'packVersion': 'one', 'dshgo': dshgo, 'resources': resources};
  final archive = Archive()..addFile(ArchiveFile.string('pack.json', jsonEncode(manifest)));
  for (final entry in files.entries) {
    archive.addFile(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<Map<String, Object?>> _cardJson(ScriptFixture h, String id) async =>
    scriptMap(jsonDecode(await File('${h.root.path}/characters/$id/card.json').readAsString()));

List<Map<String, Object?>> _operations(ScriptFixture h) => h.inspect(
  (db) => [
    for (final row in db.select('SELECT * FROM authoring_operations ORDER BY domain_id, operation_id'))
      Map<String, Object?>.from(row),
  ],
);

TypeMatcher<TavernAuthoringException> _authoringError(String code) =>
    isA<TavernAuthoringException>().having((error) => error.code, 'code', code);
