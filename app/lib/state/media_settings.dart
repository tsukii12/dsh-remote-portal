// The 「图像与视频」 settings page's edits of the media plugin's namespace
// (media-generation §5.8): `value.services[]` in the plugin's own shape, the
// default model per kind, and the credential reference a new service starts
// with. Pure except for the small map conversions, so the page's rules are
// unit-tested without a host.
//
// A service's key is any environment-style credential name the host has
// (`DSH_MEDIA_ARK_API_KEY` here). The page creates one per provider group and
// reuses it for that provider's other services, so pictures and video of the
// same provider never ask for the key twice. The plugin's older fixed slots
// still work and appear as ordinary references.

import 'package:flutter/foundation.dart';

import '../ui/chat/media/generate_header.dart' show GenerateKind;
import 'media_catalog.dart';

/// One row of the plugin's `value.services`.
@immutable
class MediaServiceConfig {
  const MediaServiceConfig({
    required this.id,
    this.label = '',
    this.enabled = false,
    required this.provider,
    required this.baseUrl,
    required this.profile,
    this.responseFormat = '',
    this.models = const [],
    required this.keyRef,
  });

  /// A row as settings/describe gives it; null when it could not be the
  /// plugin's own service shape (the host validates before serving it, so
  /// this is only for damaged or foreign rows).
  static MediaServiceConfig? tryFrom(Object? json) {
    if (json is! Map) return null;
    String? string(String key) => json[key] is String ? json[key] as String : null;
    final id = string('id');
    final provider = string('provider');
    final baseUrl = string('baseUrl');
    final profile = string('profile');
    final keyRef = string('keyRef');
    if (id == null || id.isEmpty || provider == null || baseUrl == null || profile == null || keyRef == null) {
      return null;
    }
    final models = switch (json['models']) {
      final String value => [
        for (final part in value.split(','))
          if (part.trim().isNotEmpty) part.trim(),
      ],
      final List<Object?> value => [
        for (final part in value)
          if (part is String && part.trim().isNotEmpty) part.trim(),
      ],
      _ => const <String>[],
    };
    return MediaServiceConfig(
      id: id,
      label: string('label') ?? '',
      enabled: json['enabled'] == true,
      provider: provider,
      baseUrl: baseUrl,
      profile: profile,
      responseFormat: string('responseFormat') ?? '',
      models: List.unmodifiable(models),
      keyRef: keyRef,
    );
  }

  final String id;
  final String label;
  final bool enabled;
  final String provider;
  final String baseUrl;
  final String profile;

  /// '', 'url' or 'b64_json' (openai-compatible services only).
  final String responseFormat;
  final List<String> models;
  final String keyRef;

  String get title => label.isNotEmpty
      ? label
      : provider.isNotEmpty
      ? provider
      : id;

  String get modelsValue => models.join(', ');

  MediaServiceConfig copyWith({
    String? id,
    String? label,
    bool? enabled,
    String? provider,
    String? baseUrl,
    String? profile,
    String? responseFormat,
    List<String>? models,
    String? keyRef,
  }) => MediaServiceConfig(
    id: id ?? this.id,
    label: label ?? this.label,
    enabled: enabled ?? this.enabled,
    provider: provider ?? this.provider,
    baseUrl: baseUrl ?? this.baseUrl,
    profile: profile ?? this.profile,
    responseFormat: responseFormat ?? this.responseFormat,
    models: models ?? this.models,
    keyRef: keyRef ?? this.keyRef,
  );

  MediaServiceConfig withModel(String modelId, {required bool on}) {
    final next = [...models]..removeWhere((id) => id == modelId);
    if (on) next.add(modelId);
    return copyWith(models: List.unmodifiable(next));
  }

  /// The plugin's row: `models` is the comma-separated string its schema
  /// declares, every other field a plain value.
  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'enabled': enabled,
    'provider': provider,
    'baseUrl': baseUrl,
    'profile': profile,
    'responseFormat': responseFormat,
    'models': modelsValue,
    'keyRef': keyRef,
  };
}

/// The valid service rows of a `value.services` value, in order.
List<MediaServiceConfig> mediaServicesOf(Object? value) => [
  if (value is List)
    for (final row in value) ?MediaServiceConfig.tryFrom(row),
];

/// [services] with [service] replacing the row of its id, or appended.
List<MediaServiceConfig> withMediaService(List<MediaServiceConfig> services, MediaServiceConfig service) {
  final index = services.indexWhere((row) => row.id == service.id);
  if (index < 0) return List.unmodifiable([...services, service]);
  return List.unmodifiable([...services]..[index] = service);
}

/// [services] without [id].
List<MediaServiceConfig> withoutMediaService(List<MediaServiceConfig> services, String id) => List.unmodifiable([
  for (final row in services)
    if (row.id != id) row,
]);

/// The row [id], if present.
MediaServiceConfig? mediaServiceById(Iterable<MediaServiceConfig> services, String id) =>
    services.where((row) => row.id == id).firstOrNull;

/// The provider template [service] came from: same profile and kind, else
/// same profile (a catalogue may serve two kinds on one protocol).
MediaPreset? mediaPresetForService(Iterable<MediaPreset> presets, MediaServiceConfig service) {
  for (final preset in presets) {
    if (preset.profile == service.profile && preset.models.any(service.models.contains)) return preset;
  }
  for (final preset in presets) {
    if (preset.profile == service.profile) return preset;
  }
  return null;
}

/// A display label for a service: the preset's localized name for the
/// provider group, else its own label/provider.
String mediaServiceTitle(MediaServiceConfig service, Iterable<MediaPreset> presets, {required bool english}) {
  final preset = mediaPresetForService(presets, service);
  if (preset != null && preset.label.isNotEmpty) {
    // The stored label is the plugin's Chinese name; a renamed service keeps
    // its own name.
    if (service.label.isEmpty || service.label == preset.label) return preset.title(english);
  }
  return service.title;
}

/// A service the page creates from [preset]: its models are the preset's
/// that the live catalogue still knows on that protocol and kind, else every
/// such model the catalogue has. Null when the catalogue has none: the page
/// leaves the preset out rather than writing a service the plugin refuses.
MediaServiceConfig? mediaServiceFromPreset({
  required MediaPreset preset,
  required MediaCatalog catalog,
  required Iterable<MediaServiceConfig> existing,
  bool reuseKey = true,
}) {
  // Only the preset's own models: `openai-compatible` is shared by several
  // providers, so filling in "every model on this protocol" could point a
  // Gemini preset at an OpenAI model on the wrong API root. A preset whose
  // models the catalogue dropped is not offered.
  final models = preset.catalogModels(catalog);
  if (models.isEmpty) return null;
  final donor = reuseKey ? mediaKeyDonor(existing, preset) : null;
  final id = nextMediaServiceId(preset, existing.map((service) => service.id));
  return MediaServiceConfig(
    id: id,
    label: preset.label,
    enabled: true,
    provider: preset.provider,
    baseUrl: preset.baseUrl,
    profile: preset.profile,
    responseFormat: preset.responseFormat,
    models: List.unmodifiable([for (final model in models.take(16)) model.id]),
    keyRef: donor?.keyRef ?? nextMediaCredentialRef(preset, existing.map((service) => service.keyRef)),
  );
}

/// The service whose key a new service of [preset]'s provider can share
/// (pictures and video of one provider usually bill one account).
MediaServiceConfig? mediaKeyDonor(Iterable<MediaServiceConfig> services, MediaPreset preset) {
  for (final service in services) {
    if (service.provider == preset.provider &&
        service.keyRef.isNotEmpty &&
        !mediaTargetOriginChanged(service.baseUrl, preset.baseUrl)) {
      return service;
    }
  }
  return null;
}

/// Local shape feedback only. The host still decides allowed targets/protocols.
enum MediaUrlIssue { invalid, endpoint, rootRequired }

MediaUrlIssue? mediaBaseUrlIssue(String value, String profile) {
  final text = value.trim();
  final uri = Uri.tryParse(text);
  if (text.isEmpty ||
      text.length > 2048 ||
      RegExp(r'[\s\\\x00-\x1f\x7f]').hasMatch(text) ||
      uri == null ||
      uri.scheme != 'https' ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.hasPort && (uri.port < 1 || uri.port > 65535))) {
    return MediaUrlIssue.invalid;
  }
  final path = uri.path.replaceAll(RegExp(r'/+$'), '').toLowerCase();
  if (RegExp(
    r'/(images/(generations|edits)|chat/completions|responses|contents/generations/tasks|video/(submit|status)|video-synthesis|multimodal-generation/generation)(/|$)',
  ).hasMatch(path)) {
    return MediaUrlIssue.endpoint;
  }
  if (const {
        'ark-image',
        'ark-video',
        'ali-wan-image',
        'ali-video',
        'silicon-image',
        'silicon-video',
      }.contains(profile) &&
      path.isNotEmpty) {
    return MediaUrlIssue.rootRequired;
  }
  return null;
}

/// Origin comparison includes the port; malformed old roots require confirmation.
bool mediaTargetOriginChanged(String before, String after) {
  final a = Uri.tryParse(before.trim());
  final b = Uri.tryParse(after.trim());
  return a == null ||
      b == null ||
      !a.hasAuthority ||
      !b.hasAuthority ||
      !const {'http', 'https'}.contains(a.scheme) ||
      !const {'http', 'https'}.contains(b.scheme) ||
      a.origin != b.origin;
}

/// Create-request preview, not a provider probe. Native paths come from the host;
/// older catalogues without them must not invent an endpoint.
String? mediaRequestPreview(String baseUrl, String profile, Object? catalog) {
  if (mediaBaseUrlIssue(baseUrl, profile) != null) return null;
  final profiles = catalog is Map ? catalog['profiles'] : null;
  final spec = profiles is Map ? profiles[profile] : null;
  if (spec is Map) {
    final path = spec['path'];
    if (path is! String || !path.startsWith('/') || path.startsWith('//') || RegExp(r'[\s?#\\]').hasMatch(path)) {
      return null;
    }
    return '${Uri.parse(baseUrl.trim()).origin}$path';
  }
  if (profile == 'openai-gpt-image' || profile == 'openai-compatible') {
    return '${baseUrl.trim().replaceAll(RegExp(r'/+$'), '')}/images/generations';
  }
  return null;
}

final _serviceId = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
final _credentialRef = RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$');

/// A service id for [preset] not in [used]: `ark_image`, then `ark_image_2`.
String nextMediaServiceId(MediaPreset preset, Iterable<String> used) {
  final taken = used.toSet();
  final base = preset.id.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_+|_+$'), '');
  var candidate = _serviceId.hasMatch(base) ? base : 'media_service';
  if (candidate.length > 24) candidate = candidate.substring(0, 24).replaceAll(RegExp(r'_+$'), '');
  var suffix = 2;
  var id = candidate;
  while (taken.contains(id)) {
    id = '${candidate}_$suffix';
    suffix += 1;
  }
  return id;
}

/// A credential name for [preset]'s provider group not in [used]:
/// `DSH_MEDIA_ARK_API_KEY`, then `DSH_MEDIA_ARK_2_API_KEY`.
String nextMediaCredentialRef(MediaPreset preset, Iterable<String> used) {
  final taken = used.toSet();
  final group = preset.keyGroup.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]+'), '_');
  final stem = 'DSH_MEDIA_${group.isEmpty ? 'SERVICE' : group}';
  var ref = '${stem}_API_KEY';
  var suffix = 2;
  while (taken.contains(ref) || !_credentialRef.hasMatch(ref)) {
    ref = '${stem}_${suffix}_API_KEY';
    suffix += 1;
  }
  return ref;
}

/// `value.defaults` with one kind's pair replaced (or the legacy general pair
/// when [kind] is null). Other namespaces' fields and the other kinds stay.
Map<String, Object?> mediaDefaultsWith(Object? current, {GenerateKind? kind, String? serviceId, String? modelId}) {
  final map = <String, Object?>{
    if (current is Map)
      for (final MapEntry(:key, :value) in current.entries)
        if (key is String) key: value,
  };
  final prefix = switch (kind) {
    GenerateKind.image => 'image',
    GenerateKind.video => 'video',
    null => null,
  };
  map[prefix == null ? 'serviceId' : '${prefix}ServiceId'] = serviceId ?? '';
  map[prefix == null ? 'modelId' : '${prefix}ModelId'] = modelId ?? '';
  return map;
}
