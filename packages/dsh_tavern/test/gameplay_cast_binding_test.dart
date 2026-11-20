import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'p2_script_test_support.dart';

void main() {
  test('real cast receipts join scope CAS, old empty replay and version-preserving mappings', () async {
    final h = await ScriptFixture.open();
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    const localCastId = 'card'; // A cast ID is not an alias name.
    final one = await h.engine.importGameplayPack(_pack('one', 'Original cast'));
    final imported = await h.engine.importDshgoCastMember(
      TavernCastSource.pack(packRef: one.ref),
      localCastId,
      operationId: 'import-cast',
    );
    expect(imported.receipt.committed, isTrue);
    final mapping = imported.mapping!;
    final ref = TavernCastImportRef(domainId: mapping.domainId, operationId: mapping.operationId);
    final originalCard = await h.engine.exportCard(mapping.characterId, format: TavernCardFormat.json);
    final initial = await h.engine.readGameplayBindings(scope);
    final created = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'create-empty',
      edits: [TavernPackBindingCreate(clientKey: 'base', packRef: one.ref)],
    );
    final bindingId = created.createdBindings['base']!;
    expect(created.snapshot.bindings.single.castImports, isEmpty);
    h.inspect((db) {
      final row = db
          .select(
            '''
        SELECT request_json, result_json FROM gameplay_operations
        WHERE domain_id = ? AND operation_id = ?''',
            [initial.token.domainId, 'create-empty'],
          )
          .single;
      final request = jsonDecode(row['request_json']! as String) as Map<String, Object?>;
      final edit = (request['edits']! as List<Object?>).single! as Map<String, Object?>;
      expect(edit.containsKey('castImports'), isFalse);
      // A real pre-3F receipt has no castImports member in its binding snapshots.
      final oldReceipt = jsonDecode(row['result_json']! as String) as Map<String, Object?>;
      final snapshot = oldReceipt['snapshot']! as Map<String, Object?>;
      for (final raw in snapshot['bindings']! as List<Object?>) {
        (raw! as Map<String, Object?>).remove('castImports');
      }
      db.execute(
        '''
        UPDATE gameplay_operations SET result_json = ?
        WHERE domain_id = ? AND operation_id = ?''',
        [jsonEncode(oldReceipt), initial.token.domainId, 'create-empty'],
      );
    }, writable: true);
    final oldReplay = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'create-empty',
      edits: [TavernPackBindingCreate(clientKey: 'base', packRef: one.ref, castImports: const {})],
    );
    expect(oldReplay.toJson(), created.toJson());

    final before = _scopeRows(h);
    await expectLater(
      h.engine.updateGameplayBindings(
        scope,
        expected: created.snapshot.token,
        operationId: 'wrong-local-id',
        edits: [
          TavernPackBindingSetCastImports(bindingId: bindingId, imports: {'different': ref}),
        ],
      ),
      throwsA(_error('cast_import_mismatch')),
    );
    expect(_scopeRows(h), before);
    final edits = [
      TavernPackBindingSetCastImports(bindingId: bindingId, imports: {localCastId: ref}),
    ];
    h.inspect(
      (db) => db.execute("""
      CREATE TRIGGER reject_cast_binding_receipt BEFORE INSERT ON gameplay_operations
      WHEN NEW.operation_id = 'set-cast'
      BEGIN SELECT RAISE(ABORT, 'cast receipt failure'); END;
    """),
      writable: true,
    );
    try {
      await expectLater(
        h.engine.updateGameplayBindings(scope, expected: created.snapshot.token, operationId: 'set-cast', edits: edits),
        throwsA(isA<SqliteException>()),
      );
      expect(_scopeRows(h), before);
    } finally {
      h.inspect((db) => db.execute('DROP TRIGGER reject_cast_binding_receipt'), writable: true);
    }
    final adopted = await h.engine.updateGameplayBindings(
      scope,
      expected: created.snapshot.token,
      operationId: 'set-cast',
      edits: edits,
    );
    expect(adopted.changed, isTrue);
    expect(adopted.snapshot.bindings.single.castImports[localCastId]!.toJson(), ref.toJson());
    expect(adopted.snapshot.bindings.single.bindingRevision, created.snapshot.bindings.single.bindingRevision + 1);
    expect(adopted.snapshot.bindings.single.onceEpoch, 1);
    expect(adopted.snapshot.bindings.single.sourceMap, created.snapshot.bindings.single.sourceMap);
    expect(adopted.snapshot.issues, isEmpty);

    final two = await h.engine.importGameplayPack(_pack('two', 'New source, not an import'));
    expect(two.ref.installedPackId, one.ref.installedPackId);
    final upgraded = await h.engine.updateGameplayBindings(
      scope,
      expected: adopted.snapshot.token,
      operationId: 'upgrade-cast-source',
      edits: [TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: two.ref.packVersion)],
    );
    expect(upgraded.snapshot.bindings.single.castImports[localCastId]!.toJson(), ref.toJson());
    expect(upgraded.snapshot.bindings.single.onceEpoch, 1);
    expect(upgraded.snapshot.issues.single, {
      'code': 'cast_source_version_mismatch',
      'bindingId': bindingId,
      'localCastId': localCastId,
      'castImport': ref.toJson(),
      'sourcePackRef': one.ref.toJson(),
      'selectedPackRef': two.ref.toJson(),
      'characterId': mapping.characterId,
    });
    expect(await h.engine.exportCard(mapping.characterId, format: TavernCardFormat.json), originalCard);
    expect(
      h.inspect((db) => db.select('SELECT * FROM chats')),
      isEmpty,
      reason: 'A cast mapping does not create a chat or add a group member.',
    );

    final cleared = await h.engine.updateGameplayBindings(
      scope,
      expected: upgraded.snapshot.token,
      operationId: 'clear-cast',
      edits: [TavernPackBindingSetCastImports(bindingId: bindingId, imports: const {})],
    );
    expect(cleared.changed, isTrue);
    expect(cleared.snapshot.bindings.single.castImports, isEmpty);
    expect(cleared.snapshot.issues, isEmpty);
    final retracted = await h.engine.updateGameplayBindings(
      scope,
      expected: cleared.snapshot.token,
      operationId: 'retract-intermediate-cast',
      edits: [
        TavernPackBindingSetCastImports(
          bindingId: bindingId,
          imports: {localCastId: const TavernCastImportRef(domainId: 'absent', operationId: 'absent')},
        ),
        TavernPackBindingSetCastImports(bindingId: bindingId, imports: const {}),
      ],
    );
    expect(retracted.changed, isFalse);
    expect(retracted.snapshot.toJson(), cleared.snapshot.toJson());
    expect(
      (await h.engine.updateGameplayBindings(
        scope,
        expected: created.snapshot.token,
        operationId: 'set-cast',
        edits: edits,
      )).toJson(),
      adopted.toJson(),
    );
    h.expectNoGeneration();
  });

  test('finite simulation seed retains only referenced real adopted cast evidence and its original domain', () async {
    final h = await ScriptFixture.open();
    final pack = await h.engine.importGameplayPack(_pack('one', 'Captured cast'));
    final imported = await h.engine.importDshgoCastMember(
      TavernCastSource.pack(packRef: pack.ref),
      'card',
      operationId: '\uFEFFkept-cast',
    );
    final unreferenced = await h.engine.importDshgoCastMember(
      TavernCastSource.pack(packRef: pack.ref),
      'card',
      operationId: 'unreferenced-cast',
    );
    expect(imported.receipt.committed, isTrue);
    expect(unreferenced.receipt.committed, isTrue);
    final mapping = imported.mapping!;
    final ref = TavernCastImportRef(domainId: mapping.domainId, operationId: mapping.operationId);
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    final initial = await h.engine.readGameplayBindings(scope);
    final bound = await h.engine.updateGameplayBindings(
      scope,
      expected: initial.token,
      operationId: 'bind-kept-cast',
      edits: [
        TavernPackBindingCreate(clientKey: 'base', packRef: pack.ref, castImports: {'card': ref}),
      ],
    );
    expect(bound.snapshot.issues, isEmpty);
    h.expectNoGeneration();
    await h.close();

    final sourceDb = sqlite3.open('${h.root.path}/tavern.sqlite3');
    final source = ChatStore.fromDatabase(sourceDb);
    addTearDown(source.close);
    source.initializeAuthoringAuthority();
    source.rotateAuthoringDomain();
    final sourceScope = source.readGameplayScopeData(scope);
    expect(sourceScope.token.domainId, isNot(ref.domainId));
    expect(
      sourceScope.issues,
      isEmpty,
      reason: 'Restore-domain rotation does not invalidate original adopted journal evidence.',
    );
    final captured = source.readGameplaySimulationData(
      source.readGameplaySnapshot(
        characterId: mapping.characterId,
        readBindings: true,
        readContext: false,
        readResources: false,
      ),
      configIds: const [],
    );
    expect(captured.castImports.keys, [(ref.domainId, ref.operationId)]);
    final originalRow = captured.castImports.values.single!;
    expect(originalRow['operation_id'], '\uFEFFkept-cast');
    expect(originalRow['domain_id'], ref.domainId);
    expect(originalRow['state'], anyOf('adopted', 'published'));

    final temporaryDb = sqlite3.openInMemory();
    final temporary = ChatStore.fromDatabase(temporaryDb);
    addTearDown(temporary.close);
    temporary.initializeAuthoringAuthority();
    final temporaryDomain = temporary.authoringDomainId;
    expect(temporaryDomain, isNot(sourceScope.token.domainId));
    expect(temporaryDomain, isNot(ref.domainId));
    temporary.transaction(() {
      temporary.bootstrapGameplaySimulationData(captured);
    });
    final copiedRows = temporary.readGameplayCastImportRows([ref]);
    expect(
      copiedRows,
      captured.castImports,
      reason: 'Original JSON, revision, artifact and timestamp columns are copied verbatim.',
    );
    expect(temporary.authoringDomainId, temporaryDomain);
    final seeded = temporary.readGameplayScopeData(scope);
    expect(seeded.bindings.single.toJson(), sourceScope.bindings.single.toJson());
    expect(seeded.issues, isEmpty);
    expect(seeded.token.domainId, temporaryDomain);
    expect(
      temporary.readAuthoringOperationData(unreferenced.mapping!.domainId, unreferenced.mapping!.operationId),
      isNull,
    );
    expect(temporaryDb.select('SELECT * FROM authoring_operations'), hasLength(1));
    expect(temporaryDb.select('SELECT * FROM authoring_resources'), isEmpty);
    expect(temporaryDb.select('SELECT * FROM gameplay_operations'), isEmpty);
    expect(temporary.authoringRootStateData().hasPending, isFalse);
    expect(temporary.authoringRootStateData().protectedArtifacts, isEmpty);

    // Removing the original durable evidence leaves the stored reference
    // unresolved; capture/bootstrap never fabricate a replacement character.
    sourceDb.execute('DELETE FROM authoring_operations WHERE domain_id = ? AND operation_id = ?', [
      ref.domainId,
      ref.operationId,
    ]);
    expect(source.readGameplayCastImportRows([ref]), {(ref.domainId, ref.operationId): null});
    expect(source.readGameplayCastImportRows([ref]), isNot(captured.castImports));
    final missing = source.readGameplaySimulationData(
      source.readGameplaySnapshot(
        characterId: mapping.characterId,
        readBindings: true,
        readContext: false,
        readResources: false,
      ),
      configIds: const [],
    );
    final missingDb = sqlite3.openInMemory();
    final missingTemporary = ChatStore.fromDatabase(missingDb);
    addTearDown(missingTemporary.close);
    missingTemporary.initializeAuthoringAuthority();
    missingTemporary.transaction(() {
      missingTemporary.bootstrapGameplaySimulationData(missing);
    });
    expect(missingTemporary.readGameplayScopeData(scope).issues.single['code'], 'cast_import_not_found');
    expect(missingDb.select('SELECT * FROM authoring_operations'), isEmpty);
    expect(missingTemporary.readGameplayScopeData(scope).bindings.single.castImports['card']!.toJson(), ref.toJson());
  });
}

Map<String, Object?> _scopeRows(ScriptFixture h) => h.inspect(
  (db) => {
    for (final table in const ['gameplay_scopes', 'gameplay_bindings', 'gameplay_source_ids', 'gameplay_operations'])
      table: [for (final row in db.select('SELECT * FROM $table ORDER BY rowid')) Map<String, Object?>.from(row)],
  },
);

TypeMatcher<TavernGameplayException> _error(String code) =>
    isA<TavernGameplayException>().having((error) => error.code, 'code', code);

Uint8List _pack(String version, String castName) {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': 'binding-cast-pack',
    'packVersion': version,
    'dshgo': {
      'v': 1,
      'cast': [
        {
          'id': 'card',
          'card': {
            'name': castName,
            'description': '',
            'personality': '',
            'scenario': '',
            'first_mes': '',
            'mes_example': '',
            'creator_notes': '',
            'system_prompt': '',
            'post_history_instructions': '',
            'alternate_greetings': <String>[],
            'tags': <String>[],
            'creator': '',
            'character_version': '',
            'extensions': <String, Object?>{},
          },
        },
      ],
    },
    'resources': [
      {'localId': 'marker', 'kind': 'asset', 'path': 'marker.bin'},
    ],
  };
  final files = <String, Uint8List>{
    'pack.json': Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
    'marker.bin': Uint8List.fromList([1, 2, 3]),
  };
  final archive = Archive();
  for (final file in files.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
