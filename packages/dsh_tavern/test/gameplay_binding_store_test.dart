import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:dsh_tavern/src/io/gameplay_pack_codec.dart';
import 'package:dsh_tavern/src/store/chat_store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  test('scope CAS preserves binding identities, mappings and epochs through edits and domain rotation', () {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    const localId = '\uFEFFasset';
    final first = _install(store, version: '\uFEFFone', assets: [localId]);
    final second = _install(store, version: 'two', assets: [localId, 'later']);
    final initial = store.readGameplayScopeData(scope);
    expect(initial.token.revision, 0);
    expect(initial.bindings, isEmpty);
    expect(db.select('SELECT * FROM gameplay_scopes'), isEmpty);
    final empty = store.updateGameplayBindingsData(
      scope,
      expected: initial.token,
      operationId: 'empty-scope',
      edits: const [],
    );
    expect(empty.changed, isFalse);
    expect(empty.snapshot.token.toJson(), initial.token.toJson());
    expect(db.select('SELECT * FROM gameplay_scopes'), isEmpty);
    expect(db.select("SELECT 1 FROM gameplay_operations WHERE operation_id = 'empty-scope'"), hasLength(1));
    final createEdits = <TavernPackBindingEdit>[
      TavernPackBindingCreate(clientKey: '\uFEFFa', packRef: first.ref),
      TavernPackBindingCreate(clientKey: 'b', packRef: first.ref),
    ];
    final created = store.updateGameplayBindingsData(
      scope,
      expected: initial.token,
      operationId: '\uFEFFcreate',
      edits: createEdits,
    );
    final a = created.createdBindings['\uFEFFa']!;
    final b = created.createdBindings['b']!;
    expect(created.changed, isTrue);
    expect(created.snapshot.token.revision, 1);
    expect(created.snapshot.bindings.map((value) => value.bindingRevision), [1, 1]);
    expect(created.snapshot.bindings.map((value) => value.onceEpoch), [1, 1]);
    expect(created.snapshot.bindings.first.packRef.packVersion, '\uFEFFone');
    final sourceA = created.snapshot.bindings.first.sourceMap.single;
    final sourceB = created.snapshot.bindings.last.sourceMap.single;
    expect(sourceA['resourceLocalId'], localId);
    expect(sourceA.containsKey('entryLocalId'), isFalse);
    expect(sourceA['stableId'], isNot(sourceB['stableId']));
    expect(db.select('SELECT scope, target FROM gameplay_scopes').single, {'scope': 'global', 'target': ''});
    expect(db.select('SELECT entry_local_id FROM gameplay_source_ids').map((row) => row['entry_local_id']), ['', '']);
    expect(
      store
          .updateGameplayBindingsData(scope, expected: initial.token, operationId: '\uFEFFcreate', edits: createEdits)
          .toJson(),
      created.toJson(),
    );
    expect(
      () =>
          store.updateGameplayBindingsData(scope, expected: initial.token, operationId: 'stale-empty', edits: const []),
      throwsA(_error('revision_conflict')),
    );

    final edited = store.updateGameplayBindingsData(
      scope,
      expected: created.snapshot.token,
      operationId: 'upgrade-and-order',
      edits: [
        TavernPackBindingSelectVersion(bindingId: a, packVersion: second.ref.packVersion),
        TavernPackBindingSetAliases(bindingId: a, aliases: {'friend': b, '\uFEFFfriend': b}),
        TavernPackBindingReorder(bindingIds: [b, a]),
      ],
    );
    expect(edited.snapshot.bindings.map((value) => value.bindingId), [b, a]);
    expect(edited.snapshot.bindings.map((value) => value.bindingRevision), [2, 2]);
    expect(edited.snapshot.bindings.map((value) => value.onceEpoch), [1, 1]);
    expect(_binding(edited.snapshot, a).sourceMap.first, sourceA);
    expect(_binding(edited.snapshot, a).sourceMap.map((source) => source['resourceLocalId']), [localId, 'later']);
    final replay = store.updateGameplayBindingsData(
      scope,
      expected: created.snapshot.token,
      operationId: 'upgrade-and-order',
      edits: [
        TavernPackBindingSelectVersion(bindingId: a, packVersion: second.ref.packVersion),
        TavernPackBindingSetAliases(bindingId: a, aliases: {'\uFEFFfriend': b, 'friend': b}),
        TavernPackBindingReorder(bindingIds: [b, a]),
      ],
    );
    expect(
      replay.toJson(),
      edited.toJson(),
      reason: 'Map key order is not a different operation; edit and reorder list order still are.',
    );

    final removed = store.updateGameplayBindingsData(
      scope,
      expected: edited.snapshot.token,
      operationId: 'remove',
      edits: [TavernPackBindingRemove(bindingId: a)],
    );
    expect(removed.snapshot.bindings.map((value) => value.bindingId), [b, a]);
    expect(_binding(removed.snapshot, a).removed, isTrue);
    expect(_binding(removed.snapshot, a).enabled, isFalse);
    expect(_binding(removed.snapshot, a).onceEpoch, 1);
    final revived = store.updateGameplayBindingsData(
      scope,
      expected: removed.snapshot.token,
      operationId: 'revive-and-reset',
      edits: [
        TavernPackBindingSelectVersion(bindingId: a, packVersion: first.ref.packVersion),
        TavernPackBindingSetEnabled(bindingId: a, enabled: true),
        TavernPackBindingResetOnce(bindingId: a),
      ],
    );
    final restored = _binding(revived.snapshot, a);
    expect(restored.bindingId, a);
    expect(restored.bindingRevision, 4);
    expect(restored.onceEpoch, 2);
    expect(restored.removed, isFalse);
    expect(restored.enabled, isTrue);
    expect(
      restored.sourceMap,
      _binding(edited.snapshot, a).sourceMap,
      reason: 'A version without later does not delete its stable mapping.',
    );
    final noChange = store.updateGameplayBindingsData(
      scope,
      expected: revived.snapshot.token,
      operationId: 'same',
      edits: [
        TavernPackBindingSetEnabled(bindingId: a, enabled: true),
        TavernPackBindingSetAliases(bindingId: a, aliases: {'\uFEFFfriend': b, 'friend': b}),
        TavernPackBindingReorder(bindingIds: [b, a]),
      ],
    );
    expect(noChange.changed, isFalse);
    expect(noChange.snapshot.token.toJson(), revived.snapshot.token.toJson());
    expect(noChange.snapshot.bindings.map((value) => value.bindingRevision), [2, 4]);
    expect(store.readGameplayScopeData(scope).toJson(), noChange.snapshot.toJson());

    store.rotateAuthoringDomain();
    final current = store.readGameplayScopeData(scope);
    expect(current.token.domainId, isNot(noChange.snapshot.token.domainId));
    expect(current.token.revision, noChange.snapshot.token.revision);
    expect(
      store
          .updateGameplayBindingsData(scope, expected: initial.token, operationId: '\uFEFFcreate', edits: createEdits)
          .toJson(),
      created.toJson(),
    );
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: noChange.snapshot.token,
        operationId: 'old-domain',
        edits: const [],
      ),
      throwsA(_error('revision_conflict')),
    );
    final fresh = store.updateGameplayBindingsData(
      scope,
      expected: current.token,
      operationId: 'new-domain-no-change',
      edits: const [],
    );
    expect(fresh.changed, isFalse);
    expect(fresh.snapshot.token.toJson(), current.token.toJson());
  });

  test('scope validation and receipt SQL are atomic while outer COMMIT survives publication failure', () {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.character, targetId: 'offline-character');
    final pack = _install(store, assets: ['asset']);
    final initial = store.readGameplayScopeData(scope);
    TavernPackBindingReceipt? adopted;
    final edits = [TavernPackBindingCreate(clientKey: 'base', packRef: pack.ref)];
    db.execute("""
      CREATE TEMP TRIGGER reject_scope_receipt BEFORE INSERT ON gameplay_operations
      WHEN NEW.kind = 'update_scope'
      BEGIN SELECT RAISE(ABORT, 'receipt failure'); END;
    """);
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: initial.token,
        operationId: 'adopt',
        edits: edits,
        onCommitted: (result) {
          adopted = result;
        },
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(adopted, isNull);
    for (final table in const ['gameplay_scopes', 'gameplay_bindings', 'gameplay_source_ids', 'gameplay_operations']) {
      expect(db.select('SELECT * FROM $table'), isEmpty);
    }
    expect(store.readGameplayPackVersion(pack.ref), isNotNull);
    db.execute('DROP TRIGGER reject_scope_receipt');
    final publication = StateError('scope publication failed after COMMIT');
    store.committedObserver = (_, _) {
      throw publication;
    };
    try {
      expect(
        () => store.updateGameplayBindingsData(
          scope,
          expected: initial.token,
          operationId: 'adopt',
          edits: edits,
          onCommitted: (result) {
            adopted = result;
          },
        ),
        throwsA(same(publication)),
      );
    } finally {
      store.committedObserver = null;
    }
    final saved = adopted!;
    expect(saved.changed, isTrue);
    expect(store.readGameplayScopeData(scope).toJson(), saved.snapshot.toJson());
    expect(
      store.updateGameplayBindingsData(scope, expected: initial.token, operationId: 'adopt', edits: edits).toJson(),
      saved.toJson(),
    );
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: initial.token,
        operationId: 'adopt',
        edits: [const TavernPackBindingRemove(bindingId: 'missing')],
      ),
      throwsA(_error('operation_conflict')),
    );

    final book = _install(store, packId: 'book', book: true);
    final disabled = store.updateGameplayBindingsData(
      scope,
      expected: saved.snapshot.token,
      operationId: 'disabled',
      edits: [TavernPackBindingCreate(clientKey: 'book', packRef: book.ref, enabled: false)],
    );
    final bookBinding = disabled.createdBindings['book']!;
    expect(_binding(disabled.snapshot, bookBinding).sourceMap, hasLength(2));
    expect(_binding(store.readGameplayScopeData(scope), bookBinding).sourceMap.last['entryLocalId'], '\uFEFFentry');
    final unchanged = store.updateGameplayBindingsData(
      scope,
      expected: disabled.snapshot.token,
      operationId: 'final-disabled',
      edits: [
        TavernPackBindingSetEnabled(bindingId: bookBinding, enabled: true),
        TavernPackBindingSetEnabled(bindingId: bookBinding, enabled: false),
      ],
    );
    expect(unchanged.changed, isFalse);
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: unchanged.snapshot.token,
        operationId: 'twice',
        edits: [
          TavernPackBindingResetOnce(bindingId: bookBinding),
          TavernPackBindingResetOnce(bindingId: bookBinding),
        ],
      ),
      throwsA(_error('invalid_binding_edit')),
    );
    expect(store.readGameplayScopeData(scope).toJson(), unchanged.snapshot.toJson());
    expect(db.select("SELECT 1 FROM gameplay_operations WHERE operation_id = 'twice'"), isEmpty);
    store.removeGameplayPackVersionData(book.ref, expected: book.version.availability, operationId: 'withdraw-book');
    final withdrawn = store.readGameplayScopeData(scope);
    expect(withdrawn.issues.single['code'], 'version_unavailable');
    final retracted = store.updateGameplayBindingsData(
      scope,
      expected: withdrawn.token,
      operationId: 'retracted-enable',
      edits: [
        TavernPackBindingSetEnabled(bindingId: bookBinding, enabled: true),
        TavernPackBindingSetEnabled(bindingId: bookBinding, enabled: false),
      ],
    );
    expect(retracted.changed, isFalse);
    expect(retracted.snapshot.toJson(), withdrawn.toJson());
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: withdrawn.token,
        operationId: 'unavailable-enable',
        edits: [TavernPackBindingSetEnabled(bindingId: bookBinding, enabled: true)],
      ),
      throwsA(_error('version_unavailable')),
    );
  });

  test('effective configuration rows join the real caller transaction and cannot change under an existing ID', () {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    final chat = store.createChat(characterId: 'configuration-character', title: 'before');
    final vector = <Object?>[
      {'kind': 'card', 'characterId': 'configuration-character'},
    ];
    final definitions = <String, Object?>{
      'state': {
        'schema': {'type': 'number'},
        'init': 1,
      },
    };
    final sources = <Object?>[
      {
        'path': '/state',
        'source': {'kind': 'card', 'characterId': 'configuration-character'},
      },
    ];
    expect(store.readGameplayEffectiveConfigData('config'), isNull);
    expect(
      () => store.ensureGameplayEffectiveConfigData(
        'config',
        sourceVector: vector,
        effectiveDefinitions: definitions,
        sourceMap: sources,
      ),
      throwsStateError,
    );
    expect(db.select('SELECT * FROM gameplay_effective_configs'), isEmpty);

    var adopted = false;
    store.transaction(
      () {
        store.updateChat(chat, title: 'adopted');
        store.ensureGameplayEffectiveConfigData(
          'config',
          sourceVector: vector,
          effectiveDefinitions: definitions,
          sourceMap: sources,
        );
        final before = _totalChanges(db);
        store.ensureGameplayEffectiveConfigData(
          'config',
          sourceVector: vector,
          effectiveDefinitions: {
            'state': {
              'init': 1,
              'schema': {'type': 'number'},
            },
          },
          sourceMap: sources,
        );
        expect(_totalChanges(db), before);
        expect(db.autocommit, isFalse);
        expect(store.readGameplayEffectiveConfigData('config')!['effectiveDefinitions'], definitions);
      },
      onCommitted: () {
        adopted = true;
      },
    );
    expect(adopted, isTrue);
    final saved = store.readGameplayEffectiveConfigData('config')!;
    expect(saved, {'sourceVector': vector, 'effectiveDefinitions': definitions, 'sourceMap': sources});
    final detached = store.readGameplayEffectiveConfigData('config')!;
    (detached['sourceVector']! as List<Object?>).clear();
    expect(store.readGameplayEffectiveConfigData('config'), saved);

    expect(
      () => store.transaction(() {
        store.updateChat(chat, title: 'must roll back');
        store.ensureGameplayEffectiveConfigData(
          'config',
          sourceVector: vector,
          effectiveDefinitions: {'state': null},
          sourceMap: sources,
        );
      }),
      throwsStateError,
    );
    expect(store.chat(chat).title, 'adopted');
    expect(store.readGameplayEffectiveConfigData('config'), saved);
    expect(db.select('SELECT * FROM gameplay_effective_configs'), hasLength(1));
    expect(db.autocommit, isTrue);
  });
  test('WI policy adoption preserves missing entries, final epochs, durable diffs and finite simulation seeds', () {
    final db = sqlite3.openInMemory();
    final store = ChatStore.fromDatabase(db);
    addTearDown(store.close);
    store.initializeAuthoringAuthority();
    const scope = TavernPackScopeTarget(kind: TavernGameplayScope.global);
    const mainEntry = <String, Object?>{
      'uid': 7,
      'key': ['key'],
      'content': 'original',
      'sticky': 2,
      'cooldown': 4,
      'delay': 1,
    };
    const emptyEntry = <String, Object?>{'uid': 8, 'key': [], 'content': 'no timer'};
    const mappings = <Map<String, Object?>>[
      {'localId': 'main', 'pointer': '/entries/a~1b~0'},
      {'localId': 'empty', 'pointer': '/entries/empty'},
    ];
    final one = _installPolicyBook(store, 'one', {'a/b~': mainEntry, 'empty': emptyEntry}, mappings);
    final content = _installPolicyBook(store, 'content', {
      'a/b~': {...mainEntry, 'content': 'new content', 'delay': 2},
      'empty': emptyEntry,
    }, mappings);
    final changed = _installPolicyBook(
      store,
      'changed',
      {
        'a/b~': {...mainEntry, 'sticky': 3},
        'empty': emptyEntry,
        'later': {'uid': 9, 'key': [], 'content': 'later', 'cooldown': null},
      },
      [
        ...mappings,
        {'localId': 'later', 'pointer': '/entries/later'},
      ],
    );
    final missing = _installPolicyBook(store, 'missing', {'empty': emptyEntry}, [mappings.last]);

    // A schema-14 disabled binding has only these original source columns.
    // The new nullable policy columns are deliberately not populated here.
    const bindingId = 'pre-policy-binding';
    store.transaction(() {
      db.execute("INSERT INTO gameplay_scopes (scope, target, revision) VALUES ('global', '', 1)");
      db.execute(
        """
        INSERT INTO gameplay_bindings
          (binding_id, scope, target, revision, installed_pack_id, pack_version,
           enabled, removed, sort_order, once_epoch, aliases_json)
        VALUES (?, 'global', '', 1, ?, ?, 0, 0, 0, 1, '{}')
      """,
        [bindingId, one.ref.installedPackId, one.ref.packVersion],
      );
      for (final entryId in const ['', 'main', 'empty']) {
        db.execute(
          """
          INSERT INTO gameplay_source_ids
            (binding_id, kind, resource_local_id, entry_local_id, stable_id)
          VALUES (?, 'lorebook', 'book', ?, ?)
        """,
          [bindingId, entryId, 'stored-book-$entryId'],
        );
      }
    });
    final totalBeforeRead = _totalChanges(db);
    final original = store.readGameplayScopeData(scope);
    expect(_totalChanges(db), totalBeforeRead);
    expect(original.bindings.single.sourceMap.every((row) => !row.containsKey('wiPolicy')), isTrue);
    final empty = store.updateGameplayBindingsData(
      scope,
      expected: original.token,
      operationId: 'no-policy-backfill',
      edits: const [],
    );
    expect(empty.changed, isFalse);
    expect(empty.resourceChanges, isEmpty);
    expect(empty.snapshot.toJson(), original.toJson());
    expect(
      db
          .select('SELECT wi_policy_epoch, wi_policy_json FROM gameplay_source_ids')
          .every((row) => row['wi_policy_epoch'] == null && row['wi_policy_json'] == null),
      isTrue,
    );

    final establishEdits = [TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: one.ref.packVersion)];
    db.execute("""
      CREATE TEMP TRIGGER reject_policy_receipt BEFORE INSERT ON gameplay_operations
      WHEN NEW.operation_id = 'establish-policy'
      BEGIN SELECT RAISE(ABORT, 'policy receipt failure'); END;
    """);
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: original.token,
        operationId: 'establish-policy',
        edits: establishEdits,
      ),
      throwsA(isA<SqliteException>()),
    );
    expect(store.readGameplayScopeData(scope).toJson(), original.toJson());
    db.execute('DROP TRIGGER reject_policy_receipt');
    final established = store.updateGameplayBindingsData(
      scope,
      expected: original.token,
      operationId: 'establish-policy',
      edits: establishEdits,
    );
    expect(established.changed, isTrue);
    expect(established.snapshot.token.revision, original.token.revision + 1);
    expect(established.snapshot.bindings.single.bindingRevision, 2);
    expect(established.snapshot.bindings.single.enabled, isFalse);
    expect(established.resourceChanges, isEmpty);
    Map<String, Object?> source(TavernPackScopeSnapshot snapshot, String id) =>
        snapshot.bindings.single.sourceMap.singleWhere((row) => row['entryLocalId'] == id);
    final mainStableId = source(established.snapshot, 'main')['stableId'];
    expect(source(established.snapshot, 'main')['wiPolicyEpoch'], 1);
    expect(source(established.snapshot, 'main')['wiPolicy'], {'sticky': 2, 'cooldown': 4});
    expect(source(established.snapshot, 'empty')['wiPolicy'], <String, Object?>{});
    expect(
      source(store.readGameplayScopeData(scope), 'main'),
      source(established.snapshot, 'main'),
      reason: 'Policy UPDATE must reach the existing SQL source row, not only the receipt.',
    );
    final enabled = store.updateGameplayBindingsData(
      scope,
      expected: established.snapshot.token,
      operationId: 'enable-policy-book',
      edits: [const TavernPackBindingSetEnabled(bindingId: bindingId, enabled: true)],
    );
    expect(enabled.snapshot.bindings.single.enabled, isTrue);

    final contentEdits = [TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: content.ref.packVersion)];
    final upgraded = store.updateGameplayBindingsData(
      scope,
      expected: enabled.snapshot.token,
      operationId: 'content-and-delay',
      edits: contentEdits,
    );
    expect(upgraded.snapshot.bindings.single.onceEpoch, 1);
    expect(source(upgraded.snapshot, 'main')['stableId'], mainStableId);
    expect(source(upgraded.snapshot, 'main')['wiPolicy'], {'sticky': 2, 'cooldown': 4});
    expect(upgraded.resourceChanges, [
      <String, Object?>{
        'bindingId': bindingId,
        'kind': 'lorebook',
        'resourceLocalId': 'book',
        'entryLocalId': 'main',
        'stableId': mainStableId,
        'change': 'delay_changed',
        'beforeEpoch': 1,
        'afterEpoch': 1,
        'before': {'delay': 1},
        'after': {'delay': 2},
      },
    ]);
    final incompatible = [TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: changed.ref.packVersion)];
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: upgraded.snapshot.token,
        operationId: 'reject-policy',
        edits: incompatible,
      ),
      throwsA(
        _error('timer_policy_conflict').having((error) => error.details, 'details', {
          'bindingId': bindingId,
          'resourceLocalId': 'book',
          'entryLocalId': 'main',
          'onceEpoch': 1,
          'before': {'sticky': 2, 'cooldown': 4},
          'after': {'sticky': 3, 'cooldown': 4},
        }),
      ),
    );
    expect(store.readGameplayScopeData(scope).toJson(), upgraded.snapshot.toJson());
    expect(db.select("SELECT 1 FROM gameplay_operations WHERE operation_id = 'reject-policy'"), isEmpty);

    final absent = store.updateGameplayBindingsData(
      scope,
      expected: upgraded.snapshot.token,
      operationId: 'entry-absent',
      edits: [TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: missing.ref.packVersion)],
    );
    expect(source(absent.snapshot, 'main'), source(upgraded.snapshot, 'main'));
    expect(absent.resourceChanges.single['change'], 'removed');
    expect(absent.resourceChanges.single['stableId'], mainStableId);
    expect(
      () => store.updateGameplayBindingsData(
        scope,
        expected: absent.snapshot.token,
        operationId: 'reject-returning-policy',
        edits: incompatible,
      ),
      throwsA(_error('timer_policy_conflict')),
    );
    expect(store.readGameplayScopeData(scope).toJson(), absent.snapshot.toJson());
    final resetAbsent = store.updateGameplayBindingsData(
      scope,
      expected: absent.snapshot.token,
      operationId: 'reset-while-absent',
      edits: [const TavernPackBindingResetOnce(bindingId: bindingId)],
    );
    expect(resetAbsent.snapshot.bindings.single.onceEpoch, 2);
    expect(source(resetAbsent.snapshot, 'main')['wiPolicyEpoch'], 1);
    expect(source(resetAbsent.snapshot, 'empty')['wiPolicyEpoch'], 2);
    expect(
      resetAbsent.resourceChanges.map((row) => row['stableId']).toSet(),
      absent.snapshot.bindings.single.sourceMap.map((row) => row['stableId']).toSet(),
    );
    expect(
      resetAbsent.resourceChanges.every(
        (row) => row['change'] == 'identity_changed' && row['beforeEpoch'] == 1 && row['afterEpoch'] == 2,
      ),
      isTrue,
    );
    final returned = store.updateGameplayBindingsData(
      scope,
      expected: resetAbsent.snapshot.token,
      operationId: 'return-under-new-epoch',
      edits: incompatible,
    );
    expect(source(returned.snapshot, 'main')['stableId'], mainStableId);
    expect(source(returned.snapshot, 'main')['wiPolicyEpoch'], 2);
    expect(source(returned.snapshot, 'main')['wiPolicy'], {'sticky': 3, 'cooldown': 4});
    expect(returned.resourceChanges.singleWhere((row) => row['entryLocalId'] == 'main')['newIdentity'], isFalse);
    expect(returned.resourceChanges.singleWhere((row) => row['entryLocalId'] == 'later')['newIdentity'], isTrue);
    final finalBatch = store.updateGameplayBindingsData(
      scope,
      expected: returned.snapshot.token,
      operationId: 'select-before-reset',
      edits: [
        TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: content.ref.packVersion),
        const TavernPackBindingResetOnce(bindingId: bindingId),
      ],
    );
    expect(finalBatch.snapshot.bindings.single.onceEpoch, 3);
    expect(source(finalBatch.snapshot, 'main')['wiPolicyEpoch'], 3);
    expect(source(finalBatch.snapshot, 'main')['wiPolicy'], {'sticky': 2, 'cooldown': 4});
    expect(source(finalBatch.snapshot, 'later')['wiPolicyEpoch'], 2);
    expect(
      finalBatch.resourceChanges.any((row) => row['change'] == 'identity_changed' && row['entryLocalId'] == 'later'),
      isTrue,
    );
    expect(
      store
          .updateGameplayBindingsData(
            scope,
            expected: enabled.snapshot.token,
            operationId: 'content-and-delay',
            edits: contentEdits,
          )
          .toJson(),
      upgraded.toJson(),
      reason: 'Replay returns the original diff, not a diff against the now-selected version.',
    );
    expect(
      store
          .updateGameplayBindingsData(
            scope,
            expected: original.token,
            operationId: 'establish-policy',
            edits: establishEdits,
          )
          .toJson(),
      established.toJson(),
    );

    final captured = store.readGameplaySimulationData(
      store.readGameplaySnapshot(
        characterId: 'sample-character',
        readBindings: true,
        readContext: false,
        readResources: false,
      ),
      configIds: const [],
    );
    final temporaryDb = sqlite3.openInMemory();
    final temporary = ChatStore.fromDatabase(temporaryDb);
    addTearDown(temporary.close);
    temporary.initializeAuthoringAuthority();
    temporary.transaction(() {
      temporary.bootstrapGameplaySimulationData(captured);
    });
    final seeded = temporary.readGameplayScopeData(scope);
    expect(seeded.token.domainId, isNot(finalBatch.snapshot.token.domainId));
    expect(seeded.token.revision, finalBatch.snapshot.token.revision);
    expect(seeded.bindings.single.toJson(), finalBatch.snapshot.bindings.single.toJson());
    expect(temporaryDb.select('SELECT * FROM gameplay_pack_versions'), hasLength(1));
    expect(temporaryDb.select('SELECT * FROM gameplay_operations'), isEmpty);
    expect(
      temporaryDb.select('SELECT wi_policy_epoch, wi_policy_json FROM gameplay_source_ids ORDER BY rowid'),
      db.select('SELECT wi_policy_epoch, wi_policy_json FROM gameplay_source_ids ORDER BY rowid'),
    );
    expect(store.readGameplayScopeData(scope).toJson(), finalBatch.snapshot.toJson());
  });
}

TavernPackBinding _binding(TavernPackScopeSnapshot snapshot, String id) =>
    snapshot.bindings.singleWhere((value) => value.bindingId == id);

TavernPackImportResult _install(
  ChatStore store, {
  String packId = 'scope-pack',
  String version = 'one',
  List<String> assets = const [],
  bool book = false,
}) {
  final resources = <Map<String, Object?>>[
    for (var index = 0; index < assets.length; index++)
      {'localId': assets[index], 'kind': 'asset', 'path': 'assets/$index.bin'},
    if (book)
      {
        'localId': 'book',
        'kind': 'lorebook',
        'path': 'book.json',
        'entries': [
          {'localId': '\uFEFFentry', 'pointer': '/entries/0'},
        ],
      },
  ];
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': packId,
    'packVersion': version,
    'resources': resources,
  };
  final files = <String, Uint8List>{
    'pack.json': Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
    for (var index = 0; index < assets.length; index++) 'assets/$index.bin': Uint8List.fromList([index, 255]),
    if (book)
      'book.json': Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'entries': [
              {
                'id': 0,
                'keys': ['key'],
                'content': 'book',
                'enabled': true,
              },
            ],
          }),
        ),
      ),
  };
  final archive = Archive();
  for (final file in files.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  final decoded = decodeGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)));
  return store.importGameplayPackData(
    decoded,
    inspection: const {
      'dshgo': {'present': false},
      'resources': <Object?>[],
    },
  );
}

TavernPackImportResult _installPolicyBook(
  ChatStore store,
  String version,
  Map<String, Object?> entries,
  List<Map<String, Object?>> mappings,
) {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'packId': 'policy-book',
    'packVersion': version,
    'resources': [
      {'localId': 'book', 'kind': 'lorebook', 'path': 'book.json', 'entries': mappings},
    ],
  };
  final files = <String, Uint8List>{
    'pack.json': Uint8List.fromList(utf8.encode(jsonEncode(manifest))),
    'book.json': Uint8List.fromList(utf8.encode('\uFEFF\uFEFF${jsonEncode({'entries': entries})}')),
    'unlisted.bin': Uint8List.fromList([0, 127, 255]),
  };
  final archive = Archive();
  for (final file in files.entries) {
    archive.addFile(ArchiveFile(file.key, file.value.length, file.value));
  }
  final decoded = decodeGameplayPack(Uint8List.fromList(ZipEncoder().encode(archive)));
  return store.importGameplayPackData(
    decoded,
    inspection: const {
      'dshgo': {'present': false},
      'resources': <Object?>[],
    },
  );
}

TypeMatcher<TavernGameplayException> _error(String code) =>
    isA<TavernGameplayException>().having((error) => error.code, 'code', code);

int _totalChanges(Database db) => db.select('SELECT total_changes() AS count').single['count']! as int;
