part of 'engine.dart';

extension _GameplayBindingOperations on TavernEngine {
  Future<TavernPackScopeSnapshot> _readGameplayBindings(TavernPackScopeTarget scope) => _authoringOperation(() async {
    final snapshot = _store.readGameplayScopeData(scope);
    if (scope.kind != TavernGameplayScope.character || await _record(scope.targetId!) != null) {
      return snapshot;
    }
    // Character existence belongs to the file owner, not the SQL scope.
    // Keep the binding identity and report the observed missing target.
    return TavernPackScopeSnapshot(
      scope: snapshot.scope,
      token: snapshot.token,
      bindings: snapshot.bindings,
      issues: [
        ...snapshot.issues,
        {'code': 'target_not_found', 'scope': scope.toJson()},
      ],
    );
  });

  Future<TavernPackBindingReceipt> _updateGameplayBindings(
    TavernPackScopeTarget scope, {
    required TavernGameplayRevision expected,
    required String operationId,
    required List<TavernPackBindingEdit> edits,
  }) => _authoringOperation(() async {
    final captured = _captureGameplayBindingEdits(edits);
    return _commitGameplay(
      (onCommitted) => _store.updateGameplayBindingsData(
        scope,
        expected: expected,
        operationId: operationId,
        edits: captured,
        onCommitted: onCommitted,
      ),
    );
  });
}

/// Only the four collection-bearing variants need a detached collection.
/// Scalars and version refs already have immutable typed fields.
List<TavernPackBindingEdit> _captureGameplayBindingEdits(List<TavernPackBindingEdit> edits) => [
  for (final edit in edits)
    switch (edit) {
      TavernPackBindingCreate() => TavernPackBindingCreate(
        clientKey: edit.clientKey,
        packRef: edit.packRef,
        enabled: edit.enabled,
        aliases: Map<String, String>.of(edit.aliases),
        castImports: Map<String, TavernCastImportRef>.of(edit.castImports),
      ),
      TavernPackBindingReorder() => TavernPackBindingReorder(bindingIds: List<String>.of(edit.bindingIds)),
      TavernPackBindingSetAliases() => TavernPackBindingSetAliases(
        bindingId: edit.bindingId,
        aliases: Map<String, String>.of(edit.aliases),
      ),
      TavernPackBindingSetCastImports() => TavernPackBindingSetCastImports(
        bindingId: edit.bindingId,
        imports: Map<String, TavernCastImportRef>.of(edit.imports),
      ),
      _ => edit,
    },
];
