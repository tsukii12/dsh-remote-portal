import 'dart:typed_data';

import 'authoring.dart';

/// A local container used to start a draft, without importing a live resource.
final class TavernAuthoringSeedInput {
  const TavernAuthoringSeedInput({required this.kind, required this.bytes, this.fileName});

  final TavernAuthoringTargetKind kind;
  final Uint8List bytes;
  final String? fileName;
}

/// Media is selected explicitly; JSON references are never silently removed.
enum TavernAuthoringMediaSelection {
  /// Use the candidate JSON as the new card's original, without an old container.
  none,

  /// Use the seed's persisted original container and media blobs.
  seedCaptured,

  /// Read an existing card's current media after its saved authority passes CAS.
  currentSource,
}

/// A new-resource result backed by the same durable operation as other writes.
/// Keep [TavernAuthoringReceipt.domainId] with [operationId] for an explicit retry after a
/// whole-root restore; an omitted domain selects only the current domain.
final class TavernAuthoringSaveAsReceipt {
  const TavernAuthoringSaveAsReceipt({
    required this.outcome,
    this.newTarget,
    this.copiedMedia = const [],
    this.issues = const [],
  });

  final TavernAuthoringReceipt outcome;
  final TavernAuthoringTarget? newTarget;

  /// Paths copied into the prepared new card. [outcome] separately records
  /// whether that directory was adopted; lorebooks have no separate media files.
  final List<String> copiedMedia;
  final List<TavernAuthoringIssue> issues;

  String get operationId => outcome.operationId;
  bool? get committed => outcome.committed;
  TavernAuthorityRevision? get authorityRevision => outcome.adoptedRevision == null
      ? null
      : TavernAuthorityRevision(domainId: outcome.domainId, revision: outcome.adoptedRevision!);
}
