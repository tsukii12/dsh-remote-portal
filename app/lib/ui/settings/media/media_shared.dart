// Shared bits of the curated 「图像与视频」 pages (media-generation §5.8): how a
// service row is written back, how a service reads in one line, what the
// catalogue's state means to the page, and the inline save failure.

import 'package:flutter/material.dart';

import '../../../l10n/l10n.dart';
import '../../../state/engine_settings_state.dart';
import '../../../state/media_catalog.dart';
import '../../../state/media_generation.dart' show GenerateKind;
import '../../../state/media_settings.dart';
import '../../theme/theme.dart';

/// The plugin's own `validateServices` bound: `settings/mutate` refuses a 9th.
const mediaServiceLimit = 8;

/// [services] as the plugin's `value.services` rows.
List<Map<String, Object?>> mediaServiceRows(Iterable<MediaServiceConfig> services) => [
  for (final service in services) service.toJson(),
];

/// Writes [service] over the row of its id (a no-op reads as saved).
Future<bool> mediaWriteService(
  SettingsEditor editor,
  FieldRef field,
  List<MediaServiceConfig> services,
  MediaServiceConfig service,
) {
  final current = mediaServiceById(services, service.id);
  if (current != null && jsonEquals(current.toJson(), service.toJson())) return Future.value(true);
  return editor.set(field, mediaServiceRows(withMediaService(services, service)));
}

/// One service's models in the row's second line: catalogue names, ids for
/// models the catalogue no longer lists.
String mediaServiceModelsSummary(MediaServiceConfig service, MediaCatalog catalog) {
  if (service.models.isEmpty) return appL10n.mediaSettingsNoModels;
  return [for (final id in service.models) catalog.modelOf(id)?.label ?? id].join(' · ');
}

/// The pair [kind]'s default names when both halves are set.
(String, String)? mediaDefaultPair(Object? defaults, GenerateKind kind) {
  if (defaults is! Map) return null;
  final prefix = kind == GenerateKind.image ? 'image' : 'video';
  final service = defaults['${prefix}ServiceId'];
  final model = defaults['${prefix}ModelId'];
  if (service is String && service.isNotEmpty && model is String && model.isNotEmpty) return (service, model);
  return null;
}

/// The legacy general pair (`serviceId`/`modelId`) when both halves are set.
(String, String)? mediaDefaultPairLegacy(Object? defaults) {
  if (defaults is! Map) return null;
  final service = defaults['serviceId'];
  final model = defaults['modelId'];
  if (service is String && service.isNotEmpty && model is String && model.isNotEmpty) return (service, model);
  return null;
}

/// [defaults] with every pair that names [serviceId] cleared (the image, video
/// and legacy general pairs); null when none of them pointed at it.
Map<String, Object?>? mediaDefaultsClearedFor(Object? defaults, String serviceId) {
  if (defaults is! Map) return null;
  Map<String, Object?>? next;
  for (final kind in const <GenerateKind?>[GenerateKind.image, GenerateKind.video, null]) {
    final prefix = switch (kind) {
      GenerateKind.image => 'image',
      GenerateKind.video => 'video',
      null => null,
    };
    final service = defaults[prefix == null ? 'serviceId' : '${prefix}ServiceId'];
    if (service == serviceId) next = mediaDefaultsWith(next ?? defaults, kind: kind);
  }
  return next;
}

/// The catalogue can name models: services can be added, defaults picked.
bool mediaCatalogReady(MediaCatalog catalog) => catalog.status == MediaCatalogStatus.ready && catalog.models.isNotEmpty;

/// What the page says when the catalogue cannot fill presets or defaults;
/// null while it is still being read or when it is ready with models.
String? mediaCatalogNote(MediaCatalog catalog, L10n l10n) => switch (catalog.status) {
  MediaCatalogStatus.loading => null,
  MediaCatalogStatus.ready => catalog.models.isEmpty ? l10n.mediaSettingsCatalogEmpty : null,
  MediaCatalogStatus.missing => l10n.mediaSettingsCatalogMissing,
  MediaCatalogStatus.unsupported || MediaCatalogStatus.broken => l10n.mediaSettingsCatalogBroken,
};

/// A field write's failure, in one readable line under the cards.
class MediaInlineError extends StatelessWidget {
  const MediaInlineError(this.message, {super.key});

  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
    child: Text(
      message,
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: DshColors.of(context).danger, height: 1.5),
    ),
  );
}
