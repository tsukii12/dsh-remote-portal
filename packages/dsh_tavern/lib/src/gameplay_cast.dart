import 'authoring.dart';
import 'authoring_seed.dart';
import 'gameplay_packs.dart';

/// These selectors use distinct, explicit local-id namespaces.
enum TavernCastSourceKind { card, packManifest, packResource }

/// A captured existing card, a manifest cast list, or one castCard resource.
/// Importing never chooses a source by display name or array position.
final class TavernCastSource {
  const TavernCastSource.card({required TavernAuthoringSource this.card, this.copyMedia = false})
    : kind = TavernCastSourceKind.card,
      packRef = null,
      assetResourceIds = const [];

  /// localCastId at import identifies manifest.dshgo.cast[].id.
  const TavernCastSource.pack({required TavernPackVersionRef this.packRef, this.assetResourceIds = const []})
    : kind = TavernCastSourceKind.packManifest,
      card = null,
      copyMedia = false;

  /// localCastId at import identifies a resource with kind == castCard.
  /// That resource contains a complete CCv3 JSON envelope.
  const TavernCastSource.packResource({required TavernPackVersionRef this.packRef, this.assetResourceIds = const []})
    : kind = TavernCastSourceKind.packResource,
      card = null,
      copyMedia = false;

  final TavernCastSourceKind kind;
  final TavernAuthoringSource? card;
  final bool copyMedia;
  final TavernPackVersionRef? packRef;

  /// Explicit asset resources from this same immutable pack version.
  /// Their stored paths are retained. The import treats this list as a set.
  final List<String> assetResourceIds;

  Map<String, Object?> toJson() {
    final character = card;
    if (character != null) {
      final revision = character.authorityRevision;
      return {
        'kind': kind.name,
        'card': {
          'target': {'kind': character.target.kind.name, 'id': character.target.id},
          'origin': character.origin.name,
          'sourceFormat': character.sourceFormat,
          'base': character.base,
          'mediaRefs': character.mediaRefs,
          'authorityRevision': revision == null ? null : {'domainId': revision.domainId, 'revision': revision.revision},
          'applySupported': character.applySupported,
        },
        'copyMedia': copyMedia,
      };
    }
    return {'kind': kind.name, 'packRef': packRef!.toJson(), 'assetResourceIds': assetResourceIds};
  }
}

/// Provenance of one confirmed adopted character import.
/// A newer pack version never silently replaces this character.
final class TavernCastMapping {
  const TavernCastMapping({
    required this.source,
    required this.localCastId,
    required this.characterId,
    required this.domainId,
    required this.operationId,
  });

  final TavernCastSource source;
  final String localCastId;
  final String characterId;
  final String domainId;
  final String operationId;

  Map<String, Object?> toJson() => {
    'source': source.toJson(),
    'localCastId': localCastId,
    'characterId': characterId,
    'domainId': domainId,
    'operationId': operationId,
  };
}

/// The original prepared-import outcome and its adoption-dependent mapping.
/// A reserved newTarget alone does not establish a successful import.
final class TavernCastImportResult {
  const TavernCastImportResult({required this.receipt, this.mapping});

  final TavernAuthoringSaveAsReceipt receipt;
  final TavernCastMapping? mapping;
}
