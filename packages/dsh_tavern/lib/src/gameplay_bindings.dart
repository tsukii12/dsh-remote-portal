import 'gameplay.dart';
import 'gameplay_packs.dart';

/// A persisted scope identity. Global has no targetId; character/chat retain
/// their actual opaque target ID even when the target is later removed.
final class TavernPackScopeTarget {
  const TavernPackScopeTarget({required this.kind, this.targetId});

  final TavernGameplayScope kind;
  final String? targetId;

  Map<String, Object?> toJson() => {'kind': kind.name, 'targetId': targetId};
}

/// A reference to the original durable cast-import journal. The domain remains
/// the operation's historical domain after a whole-root restore.
final class TavernCastImportRef {
  const TavernCastImportRef({required this.domainId, required this.operationId});

  final String domainId;
  final String operationId;

  Map<String, Object?> toJson() => {'domainId': domainId, 'operationId': operationId};
}

/// One binding instance. Selecting a version does not change binding identity
/// or onceEpoch. sourceMap is allocated by storage, never supplied by an edit.
final class TavernPackBinding {
  const TavernPackBinding({
    required this.bindingId,
    required this.bindingRevision,
    required this.packRef,
    required this.enabled,
    required this.removed,
    required this.order,
    required this.onceEpoch,
    required this.aliases,
    required this.sourceMap,
    this.castImports = const {},
  });

  final String bindingId;
  final int bindingRevision;
  final TavernPackVersionRef packRef;
  final bool enabled;
  final bool removed;
  final int order;
  final int onceEpoch;
  final Map<String, String> aliases;

  /// Local cast IDs point to actual adopted imports; selecting a version never
  /// replaces their characters or implicitly imports another character.
  final Map<String, TavernCastImportRef> castImports;

  /// WI entry rows may carry wiPolicyEpoch and wiPolicy. Missing keys mean
  /// no policy has been established; an empty wiPolicy is a real baseline.
  /// A retained policy for an older epoch is not the current epoch's baseline.
  final List<Map<String, Object?>> sourceMap;

  Map<String, Object?> toJson() => {
    'bindingId': bindingId,
    'bindingRevision': bindingRevision,
    'packRef': packRef.toJson(),
    'enabled': enabled,
    'removed': removed,
    'order': order,
    'onceEpoch': onceEpoch,
    'aliases': aliases,
    'castImports': {for (final entry in castImports.entries) entry.key: entry.value.toJson()},
    'sourceMap': sourceMap,
  };
}

/// A detached ordered scope, including disabled and removed bindings.
/// An absent scope has revision zero; reading it does not insert a row.
final class TavernPackScopeSnapshot {
  const TavernPackScopeSnapshot({
    required this.scope,
    required this.token,
    required this.bindings,
    this.issues = const [],
  });

  final TavernPackScopeTarget scope;
  final TavernGameplayRevision token;
  final List<TavernPackBinding> bindings;
  final List<Map<String, Object?>> issues;

  Map<String, Object?> toJson() => {
    'scope': scope.toJson(),
    'token': token.toJson(),
    'bindings': [for (final binding in bindings) binding.toJson()],
    'issues': issues,
  };
}

/// The original adopted result of one scope operation.
/// A no-change request still records its receipt after checking the token.
final class TavernPackBindingReceipt {
  const TavernPackBindingReceipt({
    required this.operationId,
    required this.snapshot,
    required this.createdBindings,
    required this.changed,
    this.resourceChanges = const [],
  });

  final String operationId;
  final TavernPackScopeSnapshot snapshot;
  final Map<String, String> createdBindings;
  final bool changed;

  /// Adopted manifest resource/entry mapping changes, not an execution list.
  /// Rows identify bindingId, kind, resourceLocalId, optional entryLocalId and
  /// stableId, with change = added/removed/identity_changed/delay_changed and
  /// beforeEpoch/afterEpoch. A new binding has no beforeEpoch.
  /// Added rows use newIdentity to distinguish new and returning mappings.
  /// delay_changed uses the real loader's before/after declaration maps,
  /// preserving absence and explicit null. Reset also lists absent known IDs.
  /// This original operation result is never recalculated during replay.
  final List<Map<String, Object?>> resourceChanges;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'snapshot': snapshot.toJson(),
    'createdBindings': createdBindings,
    'changed': changed,
    'resourceChanges': resourceChanges,
  };
}

/// Edits are applied in order to one scope; the final result is committed by
/// one domain/revision CAS. Alias and cast-import maps replace their complete
/// previous maps.
sealed class TavernPackBindingEdit {
  const TavernPackBindingEdit();

  factory TavernPackBindingEdit.create({
    required String clientKey,
    required TavernPackVersionRef packRef,
    bool enabled = true,
    Map<String, String> aliases = const {},
    Map<String, TavernCastImportRef> castImports = const {},
  }) => TavernPackBindingCreate(
    clientKey: clientKey,
    packRef: packRef,
    enabled: enabled,
    aliases: aliases,
    castImports: castImports,
  );

  factory TavernPackBindingEdit.selectVersion({required String bindingId, required String packVersion}) =>
      TavernPackBindingSelectVersion(bindingId: bindingId, packVersion: packVersion);

  factory TavernPackBindingEdit.setEnabled({required String bindingId, required bool enabled}) =>
      TavernPackBindingSetEnabled(bindingId: bindingId, enabled: enabled);

  factory TavernPackBindingEdit.reorder({required List<String> bindingIds}) =>
      TavernPackBindingReorder(bindingIds: bindingIds);

  factory TavernPackBindingEdit.remove({required String bindingId}) => TavernPackBindingRemove(bindingId: bindingId);

  factory TavernPackBindingEdit.resetOnce({required String bindingId}) =>
      TavernPackBindingResetOnce(bindingId: bindingId);

  factory TavernPackBindingEdit.setAliases({required String bindingId, required Map<String, String> aliases}) =>
      TavernPackBindingSetAliases(bindingId: bindingId, aliases: aliases);

  factory TavernPackBindingEdit.setCastImports({
    required String bindingId,
    required Map<String, TavernCastImportRef> imports,
  }) => TavernPackBindingSetCastImports(bindingId: bindingId, imports: imports);

  Map<String, Object?> toJson();
}

final class TavernPackBindingCreate extends TavernPackBindingEdit {
  const TavernPackBindingCreate({
    required this.clientKey,
    required this.packRef,
    this.enabled = true,
    this.aliases = const {},
    this.castImports = const {},
  });

  final String clientKey;
  final TavernPackVersionRef packRef;
  final bool enabled;
  final Map<String, String> aliases;
  final Map<String, TavernCastImportRef> castImports;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'create', 'clientKey': clientKey, 'packRef': packRef.toJson(),
    'enabled': enabled, 'aliases': aliases,
    // Preserve the exact pre-cast request shape for historical create replays.
    if (castImports.isNotEmpty)
      'castImports': {for (final entry in castImports.entries) entry.key: entry.value.toJson()},
  };
}

final class TavernPackBindingSelectVersion extends TavernPackBindingEdit {
  const TavernPackBindingSelectVersion({required this.bindingId, required this.packVersion});

  final String bindingId;
  final String packVersion;

  @override
  Map<String, Object?> toJson() => {'kind': 'selectVersion', 'bindingId': bindingId, 'packVersion': packVersion};
}

final class TavernPackBindingSetEnabled extends TavernPackBindingEdit {
  const TavernPackBindingSetEnabled({required this.bindingId, required this.enabled});

  final String bindingId;
  final bool enabled;

  @override
  Map<String, Object?> toJson() => {'kind': 'setEnabled', 'bindingId': bindingId, 'enabled': enabled};
}

final class TavernPackBindingReorder extends TavernPackBindingEdit {
  const TavernPackBindingReorder({required this.bindingIds});

  final List<String> bindingIds;

  @override
  Map<String, Object?> toJson() => {'kind': 'reorder', 'bindingIds': bindingIds};
}

final class TavernPackBindingRemove extends TavernPackBindingEdit {
  const TavernPackBindingRemove({required this.bindingId});

  final String bindingId;

  @override
  Map<String, Object?> toJson() => {'kind': 'remove', 'bindingId': bindingId};
}

final class TavernPackBindingResetOnce extends TavernPackBindingEdit {
  const TavernPackBindingResetOnce({required this.bindingId});

  final String bindingId;

  @override
  Map<String, Object?> toJson() => {'kind': 'resetOnce', 'bindingId': bindingId};
}

final class TavernPackBindingSetAliases extends TavernPackBindingEdit {
  const TavernPackBindingSetAliases({required this.bindingId, required this.aliases});

  final String bindingId;
  final Map<String, String> aliases;

  @override
  Map<String, Object?> toJson() => {'kind': 'setAliases', 'bindingId': bindingId, 'aliases': aliases};
}

final class TavernPackBindingSetCastImports extends TavernPackBindingEdit {
  const TavernPackBindingSetCastImports({required this.bindingId, required this.imports});

  final String bindingId;
  final Map<String, TavernCastImportRef> imports;

  @override
  Map<String, Object?> toJson() => {
    'kind': 'setCastImports',
    'bindingId': bindingId,
    'imports': {for (final entry in imports.entries) entry.key: entry.value.toJson()},
  };
}
