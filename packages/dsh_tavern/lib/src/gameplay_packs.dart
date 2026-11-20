import 'dart:typed_data';

/// Permanent installed identity and one opaque, immutable version name.
final class TavernPackVersionRef {
  const TavernPackVersionRef({required this.installedPackId, required this.packVersion});

  final String installedPackId;
  final String packVersion;

  Map<String, Object?> toJson() => {'installedPackId': installedPackId, 'packVersion': packVersion};
}

/// A catalog or scope revision belongs to the root in which it was captured.
final class TavernGameplayRevision {
  const TavernGameplayRevision({required this.domainId, required this.revision});

  final String domainId;
  final int revision;

  Map<String, Object?> toJson() => {'domainId': domainId, 'revision': revision};
}

/// Detached catalog data. The resource declarations are in manifest.resources.
/// The availability token and tombstone may change; the saved payload does not.
final class TavernPackVersion {
  const TavernPackVersion({
    required this.ref,
    required this.externalPackId,
    required this.digest,
    required this.manifestRaw,
    required this.manifest,
    required this.inspection,
    required this.availability,
    required this.removed,
  });

  final TavernPackVersionRef ref;
  final String externalPackId;
  final String digest;

  /// Complete UTF-8 manifest text, including an initial BOM when present.
  final String manifestRaw;
  final Map<String, Object?> manifest;

  /// The diagnostics saved by the original import, not a fresh reinspection.
  final Map<String, Object?> inspection;
  final TavernGameplayRevision availability;
  final bool removed;
}

/// Importing saves a version but does not bind or execute it.
/// A reused result retains the saved diagnostics and current tombstone.
final class TavernPackImportResult {
  const TavernPackImportResult({required this.version, required this.reused});

  final TavernPackVersion version;
  final bool reused;
  TavernPackVersionRef get ref => version.ref;
  String get digest => version.digest;
  Map<String, Object?> get inspection => version.inspection;
}

/// One declared resource with its exact file bytes.
final class TavernPackResource {
  const TavernPackResource({required this.localId, required this.kind, required this.path, required this.bytes});

  final String localId;
  final String kind;
  final String path;
  final Uint8List bytes;
}

/// The durable result of one availability operation.
/// An already removed version with a fresh token produces changed == false.
final class TavernPackRemovalReceipt {
  const TavernPackRemovalReceipt({
    required this.ref,
    required this.operationId,
    required this.availability,
    required this.changed,
  });

  final TavernPackVersionRef ref;
  final String operationId;
  final TavernGameplayRevision availability;
  final bool changed;

  Map<String, Object?> toJson() => {
    'ref': ref.toJson(),
    'operationId': operationId,
    'availability': availability.toJson(),
    'changed': changed,
  };
}

final class TavernGameplayException implements Exception {
  const TavernGameplayException({required this.code, required this.message, this.details = const {}});

  final String code;
  final String message;
  final Map<String, Object?> details;

  @override
  String toString() => '$code: $message';
}

/// The SQL transaction committed, but a later publication step failed.
/// The result is the original adopted result; retrying is not implied.
final class TavernGameplayCommittedException<T extends Object> implements Exception {
  const TavernGameplayCommittedException({required this.result, required this.cause});

  final T result;
  final Object cause;

  @override
  String toString() => 'Gameplay operation committed before publication failed: $cause';
}
