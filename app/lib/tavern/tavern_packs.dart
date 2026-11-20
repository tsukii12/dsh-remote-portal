// 玩法包 (Pro's stage 3, STAGE3-APP-INTEGRATION): the installed versions,
// the bindings of a scope, and how their diagnostics and failures read.

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import 'tavern_provider.dart';

/// Installed versions, newest import last as the engine lists them; with
/// the withdrawn ones when asked.
final tavernPacksProvider = FutureProvider.autoDispose.family<List<TavernPackVersion>, bool>(
  (ref, includeRemoved) => ref.watch(tavernProvider).listGameplayPacks(includeRemoved: includeRemoved),
);

/// A scope as a provider key: global has no target.
typedef TavernPackScopeKey = ({TavernGameplayScope kind, String? targetId});

TavernPackScopeTarget tavernPackScopeTarget(TavernPackScopeKey key) =>
    TavernPackScopeTarget(kind: key.kind, targetId: key.targetId);

final tavernPackScopeProvider = FutureProvider.autoDispose.family<TavernPackScopeSnapshot, TavernPackScopeKey>(
  (ref, key) => ref.watch(tavernProvider).readGameplayBindings(tavernPackScopeTarget(key)),
);

bool tavernPackSameRef(TavernPackVersionRef a, TavernPackVersionRef b) =>
    a.installedPackId == b.installedPackId && a.packVersion == b.packVersion;

/// What a pack is called: its manifest's name when it has one, else its id.
String tavernPackTitle(TavernPackVersion version) => switch (version.manifest['name']) {
  final String name when name.trim().isNotEmpty => name,
  _ => version.externalPackId,
};

/// The declared resources (localId, kind, path), in manifest order.
List<Map<String, Object?>> tavernPackResources(TavernPackVersion version) => [
  for (final r in version.manifest['resources'] as List<Object?>? ?? const []) r! as Map<String, Object?>,
];

/// One character a pack can make: a manifest cast member, or a castCard
/// resource. The two id spaces stay apart.
typedef TavernPackCast = ({String localId, String name, bool resource});

List<TavernPackCast> tavernPackCast(TavernPackVersion version) {
  final dshgo = version.manifest['dshgo'];
  final cast = dshgo is Map<String, Object?> ? dshgo['cast'] : null;
  return [
    if (cast is List<Object?>)
      for (final member in cast.whereType<Map<String, Object?>>())
        if (member['id'] case final String id)
          (
            localId: id,
            name: switch (member) {
              {'card': {'name': final String name}} || {'name': final String name} => name,
              _ => id,
            },
            resource: false,
          ),
    for (final r in tavernPackResources(version))
      if (r['kind'] == 'castCard') (localId: r['localId']! as String, name: r['localId']! as String, resource: true),
  ];
}

TavernCastSource tavernPackCastSource(TavernPackVersionRef ref, TavernPackCast cast) =>
    cast.resource ? TavernCastSource.packResource(packRef: ref) : TavernCastSource.pack(packRef: ref);

/// The diagnostics of one installed resource as the import saved them: each
/// report's findings (with the pointer of what it checked), then the regex
/// diagnostics.
List<Map<String, Object?>> tavernPackResourceIssues(TavernPackVersion version, String localId) {
  for (final row in version.inspection['resources'] as List<Object?>? ?? const []) {
    if (row is Map<String, Object?> && row['localId'] == localId) {
      return [
        for (final r in (row['reports'] as List<Object?>? ?? const []).cast<Map<String, Object?>>())
          for (final f
              in ((r['report']! as Map<String, Object?>)['findings']! as List<Object?>).cast<Map<String, Object?>>())
            {'pointer': r['pointer'], ...f},
        ...(row['regexDiagnostics'] as List<Object?>? ?? const []).cast<Map<String, Object?>>(),
      ];
    }
  }
  return const [];
}

/// One diagnostic as a line. Their fields differ by checker, so this takes
/// what is there: what it is, what it says, where.
String tavernPackIssueLine(Map<String, Object?> issue) {
  final what = issue['code'] ?? issue['type'] ?? issue['status'] ?? issue['kind'];
  final where = issue['sourcePath'] ?? issue['path'];
  return [
    if (issue['pointer'] case final String pointer when pointer.isNotEmpty && pointer != where) pointer,
    ?what?.toString(),
    ?issue['message']?.toString(),
    ?where?.toString(),
  ].join(' · ');
}

/// Whether a diagnostic row stops something (export issues say so).
bool tavernPackIssueBlocking(Map<String, Object?> issue) => issue['blocking'] == true;

/// What a failed pack operation tells the person (STAGE3 §8): the known
/// codes in words, anything else as the engine said it.
String tavernPackErrorText(L10n l10n, Object error) => switch (error) {
  TavernGameplayCommittedException() => l10n.tavernPackCommitted,
  TavernGameplayException(:final code, :final message) => switch (code) {
    'version_conflict' => l10n.tavernPackVersionConflict,
    'revision_conflict' => l10n.tavernPackRevisionConflict,
    'operation_conflict' => l10n.tavernPackOperationConflict,
    'version_not_found' => l10n.tavernPackVersionNotFound,
    'version_unavailable' || 'version_removed' => l10n.tavernPackVersionRemoved,
    'timer_policy_conflict' => l10n.tavernPackTimerConflict,
    'target_not_found' || 'binding_not_found' => l10n.tavernPackTargetGone,
    'authority_conflict' => l10n.tavernPackAuthorityConflict,
    'cast_import_not_found' || 'cast_import_not_adopted' || 'cast_import_mismatch' => l10n.tavernPackCastUnproven,
    'cast_source_version_mismatch' => l10n.tavernPackCastOtherVersion,
    'export_preview_conflict' => l10n.tavernPackExportChanged,
    _ => '$message ($code)',
  },
  _ => '$error'.split('\n').first,
};
