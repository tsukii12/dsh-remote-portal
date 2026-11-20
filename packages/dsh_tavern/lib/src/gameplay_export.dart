import 'api.dart' show TavernCardFormat;
import 'authoring_seed.dart' show TavernAuthoringMediaSelection;
import 'gameplay.dart';

enum TavernGameplayExportKind { character, pack }

/// One explicitly selected resource of an active binding in a real context.
final class TavernGameplayPackResourceRef {
  const TavernGameplayPackResourceRef({required this.bindingId, required this.localId});
  final String bindingId;
  final String localId;
  Map<String, Object?> toJson() => {'bindingId': bindingId, 'localId': localId};
}

/// An explicit stable mapping in the newly exported resource, never inferred
/// from the position of an entry in a previous version.
final class TavernGameplayExportEntry {
  const TavernGameplayExportEntry({required this.localId, required this.pointer});
  final String localId;
  final String pointer;
  Map<String, Object?> toJson() => {'localId': localId, 'pointer': pointer};
}

/// A declared file of a pack produced from the existing draft materializer.
/// JSON pointers address the complete selected candidate. A media URI names
/// an actual captured local asset (or ccdefault:); it is never fetched.
final class TavernGameplayDraftResource {
  const TavernGameplayDraftResource.json({
    required this.physicalResourceId,
    required String this.pointer,
    required this.localId,
    required this.kind,
    required this.path,
    this.entries = const [],
  }) : assetUri = null,
       media = null;

  const TavernGameplayDraftResource.asset({
    required this.physicalResourceId,
    required String this.assetUri,
    required TavernAuthoringMediaSelection this.media,
    required this.localId,
    required this.path,
    this.kind = 'asset',
  }) : pointer = null,
       entries = const [];

  final String physicalResourceId;
  final String localId;
  final String kind;
  final String path;
  final String? pointer;
  final String? assetUri;
  final TavernAuthoringMediaSelection? media;
  final List<TavernGameplayExportEntry> entries;

  Map<String, Object?> toJson() => {
    'physicalResourceId': physicalResourceId,
    'localId': localId,
    'kind': kind,
    'path': path,
    'pointer': ?pointer,
    'assetUri': ?assetUri,
    'media': ?media?.name,
    'entries': [for (final entry in entries) entry.toJson()],
  };
}

/// A complete export intent. Resource selection is explicit: ambient linked
/// legacy books, managed regex and presets are not silently embedded in a card.
/// The original card JSON and its own embedded resources remain its base.
final class TavernGameplayExportRequest {
  const TavernGameplayExportRequest.character({
    required TavernGameplayContext this.context,
    required TavernCardFormat this.format,
    required this.at,
    required this.packResources,
    required this.copyCardMedia,
  }) : kind = TavernGameplayExportKind.character,
       draftId = null,
       draftRevision = null,
       physicalResourceId = null,
       packId = null,
       packVersion = null,
       changeIds = const [],
       schemaRoots = const [],
       draftResources = const [],
       references = const [],
       manifestFields = const {};

  const TavernGameplayExportRequest.packFromDraft({
    required String this.draftId,
    required int this.draftRevision,
    required String this.physicalResourceId,
    required this.changeIds,
    required String this.packId,
    required String this.packVersion,
    required this.schemaRoots,
    required this.draftResources,
    required this.at,
    this.references = const [],
    this.manifestFields = const {},
  }) : kind = TavernGameplayExportKind.pack,
       context = null,
       format = null,
       packResources = const [],
       copyCardMedia = false;

  final TavernGameplayExportKind kind;

  /// The content date and new-pack ZIP encoder use this exact instant.
  /// The existing CHARX codec retains its container timestamp behavior.
  final DateTime at;
  final TavernGameplayContext? context;
  final TavernCardFormat? format;
  final List<TavernGameplayPackResourceRef> packResources;
  final bool copyCardMedia;
  final String? draftId;
  final int? draftRevision;

  /// The character candidate whose complete dshgo declaration seeds the pack.
  final String? physicalResourceId;
  final List<String> changeIds;
  final String? packId;
  final String? packVersion;

  /// State-value paths. Nodes are taken from the materialized schema.
  final List<String> schemaRoots;
  final List<TavernGameplayDraftResource> draftResources;
  final List<Map<String, Object?>> references;

  /// Additional new manifest fields. Reserved protocol keys cannot be replaced.
  final Map<String, Object?> manifestFields;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'at': at.toUtc().toIso8601String(),
    if (kind == TavernGameplayExportKind.character) ...{
      'context': {'characterId': context!.characterId, 'chatId': context!.chatId},
      'format': format!.name,
      'copyCardMedia': copyCardMedia,
      'packResources': [for (final resource in packResources) resource.toJson()],
    } else ...{
      'draftId': draftId,
      'draftRevision': draftRevision,
      'physicalResourceId': physicalResourceId,
      'changeIds': changeIds,
      'packId': packId,
      'packVersion': packVersion,
      'schemaRoots': schemaRoots,
      'resources': [for (final resource in draftResources) resource.toJson()],
      'references': references,
      'manifestFields': manifestFields,
    },
  };
}

/// The prospective input to the existing card/pack codec, with the source
/// declarations and every exported identity/resource mapping. An issue with
/// blocking == true prevents the corresponding export call from returning bytes.
/// Existing CardCodec portrait/container normalization still applies.
final class TavernGameplayExportPreview {
  const TavernGameplayExportPreview({
    required this.previewId,
    required this.sources,
    required this.mergedRaw,
    required this.idMappings,
    required this.resourceMappings,
    required this.issues,
  });

  final String previewId;
  final List<Map<String, Object?>> sources;
  final Map<String, Object?> mergedRaw;
  final List<Map<String, Object?>> idMappings;
  final List<Map<String, Object?>> resourceMappings;
  final List<Map<String, Object?>> issues;
}
