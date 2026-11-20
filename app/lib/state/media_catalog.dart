// What a host can generate with (docs/design/media-generation.md §4.3,
// §4.6.5; the dsh-media plugin's MEDIA-CATALOG-CONTRACT): its model catalogue
// crossed with the services really configured there.
//
// The catalogue is metadata, not a setting: settings/describe carries it on
// the plugin's `services` field, `meta.extra["dsh-go/media/catalog"]`, under
// whatever namespace the host gave the plugin. A catalogue that is missing,
// damaged or of an unknown version gives no generation mode (ordinary chat
// still works); there is no built-in model table to fall back on. A model is
// on offer only through a service that is switched on, whose key the host
// says is there, that lists it — and only when the parameter header can name
// it exactly (§4.6.1).
//
// Pure: no providers here, so the engine settings can ask which keys to read.

import 'package:dsh_client/dsh_client.dart';

import '../ui/chat/media/generate_header.dart';

/// The metadata key the catalogue sits under.
const mediaCatalogMetaKey = 'dsh-go/media/catalog';

/// The catalogue contract this app reads.
const mediaCatalogContract = 'dsh-go/media/catalog';
const mediaCatalogVersion = 1;

enum MediaCatalogStatus {
  /// Settings not read yet.
  loading,

  /// No namespace carries a catalogue.
  missing,

  /// A catalogue of another version or contract.
  unsupported,

  /// A catalogue this app can't read.
  broken,

  /// Read; [MediaCatalog.entries] says what can generate (maybe nothing yet).
  ready,
}

/// A model's price as the catalogue gives it.
class MediaPrice {
  const MediaPrice({required this.perSecond, required this.amount, this.currency = 'CNY'});

  final bool perSecond;
  final double amount;
  final String currency;
}

/// One model of the catalogue (§4.3), with only the values a header can
/// carry.
class MediaModel {
  const MediaModel({
    required this.id,
    required this.label,
    required this.kind,
    this.profile,
    this.ratios = const [],
    this.qualities = const [],
    this.maxN = 1,
    this.durations = const [],
    this.resolutions = const [],
    this.maxRefs = 0,
    this.firstFrame = false,
    this.lastFrame = false,
    this.edit = false,
    this.price,
  });

  final String id;
  final String label;
  final GenerateKind kind;

  /// The request protocol a service must speak to serve it.
  final String? profile;

  /// `1:1`, `3:2`… Empty: the aspect is the host's to choose.
  final List<String> ratios;

  /// The catalogue's own values: `1k`, `2k`, `high`… (image).
  final List<String> qualities;

  /// Pictures at once, 1–4, already within every limit.
  final int maxN;

  /// Seconds the model allows (video).
  final List<int> durations;

  /// `720p`, `1080p` (video).
  final List<String> resolutions;
  final int maxRefs;
  final bool firstFrame;
  final bool lastFrame;
  final bool edit;
  final MediaPrice? price;

  MediaModel _limitedTo(int? limit) => limit == null || limit >= maxN
      ? this
      : MediaModel(
          id: id,
          label: label,
          kind: kind,
          profile: profile,
          ratios: ratios,
          qualities: qualities,
          maxN: limit < 1 ? 1 : limit,
          durations: durations,
          resolutions: resolutions,
          maxRefs: maxRefs,
          firstFrame: firstFrame,
          lastFrame: lastFrame,
          edit: edit,
          price: price,
        );
}

/// One provider template the plugin publishes in its catalogue
/// (`meta.extra["dsh-go/media/catalog"].presets[]`, plugin 0.3.0+): the
/// values a new service starts with, so the settings page never asks for a
/// protocol id, an API root or a model list. Older catalogues carry none and
/// [fallbackMediaPresets] keeps the page usable.
class MediaPreset {
  const MediaPreset({
    required this.id,
    required this.label,
    this.labelEn = '',
    required this.provider,
    required this.profile,
    required this.baseUrl,
    this.responseFormat = '',
    required this.models,
    required this.kind,
    required this.keyGroup,
  });

  final String id;

  /// Chinese label as the plugin gives it.
  final String label;

  /// English label; empty uses [label].
  final String labelEn;
  final String provider;
  final String profile;
  final String baseUrl;

  /// '', 'url' or 'b64_json'.
  final String responseFormat;
  final List<String> models;
  final GenerateKind kind;

  /// Presets of one provider share keys (image + video of Ark need one key).
  final String keyGroup;

  String title(bool english) => english && labelEn.isNotEmpty ? labelEn : label;

  /// The catalogue models this preset can offer, in the plugin's order.
  List<MediaModel> catalogModels(MediaCatalog catalog) => [
    for (final id in models)
      if (catalog.modelOf(id) case final model? when model.profile == profile && model.kind == kind) model,
  ];
}

/// One configured service of the plugin (`value.services[]`).
class MediaService {
  const MediaService({required this.id, this.label = '', this.provider});

  final String id;
  final String label;
  final String? provider;

  /// What the model page groups under.
  String get title => label.isNotEmpty ? label : id;
}

/// Which model a mode means: where it is (namespace, service, model id) and
/// its name. Without [service] and [id] it is only a name the app could not
/// pin to one choice; the person picks again.
class MediaModelRef {
  const MediaModelRef({this.namespace, this.service, this.id, required this.label});

  static MediaModelRef? fromJson(Object? json) {
    if (json is! Map) return null;
    String? read(String key) => json[key] is String && (json[key] as String).isNotEmpty ? json[key] as String : null;
    final label = json['label'];
    if (label is! String) return null;
    return MediaModelRef(namespace: read('ns'), service: read('service'), id: read('id'), label: label);
  }

  final String? namespace;
  final String? service;
  final String? id;
  final String label;

  bool get pinned => service != null && id != null;

  /// The header's model field.
  GenerateModelTag get tag => GenerateModelTag(label, service: pinned ? service : null, id: pinned ? id : null);

  Map<String, Object?> toJson() => {'ns': ?namespace, 'service': ?service, 'id': ?id, 'label': label};

  @override
  bool operator ==(Object other) =>
      other is MediaModelRef &&
      other.namespace == namespace &&
      other.service == service &&
      other.id == id &&
      other.label == label;

  @override
  int get hashCode => Object.hash(namespace, service, id, label);

  @override
  String toString() => '$namespace/$service/$id ($label)';
}

/// One choice: a model through one service of one plugin namespace.
class MediaEntry {
  const MediaEntry({required this.namespace, required this.service, required this.model});

  final String namespace;
  final MediaService service;
  final MediaModel model;

  GenerateKind get kind => model.kind;

  MediaModelRef get ref => MediaModelRef(namespace: namespace, service: service.id, id: model.id, label: model.label);

  /// Unique across the catalogue.
  String get key => '$namespace\u0000${service.id}\u0000${model.id}';
}

/// One default the plugin names (`value.defaults`): the general pair, or the
/// image/video pair added in plugin 0.3.0.
class MediaDefault {
  const MediaDefault({required this.namespace, required this.service, required this.model, this.kind});

  final String namespace;
  final String service;
  final String model;

  /// Null for the legacy general default (`serviceId`/`modelId`).
  final GenerateKind? kind;
}

/// What the current host offers.
class MediaCatalog {
  const MediaCatalog({
    this.status = MediaCatalogStatus.ready,
    this.entries = const [],
    this.models = const {},
    this.defaults = const [],
  });

  static const loading = MediaCatalog(status: MediaCatalogStatus.loading);
  static const missing = MediaCatalog(status: MediaCatalogStatus.missing);

  final MediaCatalogStatus status;

  /// In the host's order: namespace, then service, then the service's list.
  final List<MediaEntry> entries;

  /// Every model the catalogue declares, by id, whether or not a service
  /// currently serves it (a disabled service or a missing key still lets the
  /// settings page name its models).
  final Map<String, MediaModel> models;

  /// Each namespace's `value.defaults`, in the host's order.
  final List<MediaDefault> defaults;

  MediaModel? modelOf(String id) => models[id];

  /// A catalogue this app can read: generation mode is possible here.
  bool get usable => status == MediaCatalogStatus.ready;

  /// Something to generate with right now.
  bool get configured => usable && entries.isNotEmpty;

  /// The kinds with at least one choice, image first.
  List<GenerateKind> get kinds => [
    for (final kind in GenerateKind.values)
      if (entries.any((e) => e.kind == kind)) kind,
  ];

  List<MediaEntry> of(GenerateKind kind) => [
    for (final e in entries)
      if (e.kind == kind) e,
  ];

  /// The one choice [ref] pins, of [kind]; null when it pins none (a bare
  /// name, a service since switched off).
  MediaEntry? resolve(MediaModelRef? ref, GenerateKind kind) {
    if (ref == null || !ref.pinned) return null;
    final found = [
      for (final e in of(kind))
        if (e.service.id == ref.service &&
            e.model.id == ref.id &&
            (ref.namespace == null || e.namespace == ref.namespace))
          e,
    ];
    return found.length == 1 ? found.single : null;
  }

  /// A header's model as a mode's (§4.6.5): by its marker, else by a name only
  /// one choice of [kind] has. Anything else stays an unpinned name.
  MediaModelRef refOfTag(GenerateModelTag tag, GenerateKind kind) {
    final found = [
      for (final e in of(kind))
        if (tag.marked ? e.service.id == tag.service && e.model.id == tag.id : e.model.label == tag.label) e,
    ];
    return found.length == 1 ? found.single.ref : MediaModelRef(label: tag.label);
  }

  /// A card's request as a mode's model: the tool result names the provider
  /// and the model, not the service, so it pins only when one choice fits.
  MediaModelRef? refOfRequest(MediaRequestInfo request, GenerateKind kind) {
    final id = request.model;
    final label = request.label;
    if (id == null && label == null) return null;
    final found = [
      for (final e in of(kind))
        if (id != null
            ? e.model.id == id && (request.provider == null || e.service.provider == request.provider)
            : e.model.label == label)
          e,
    ];
    return found.length == 1 ? found.single.ref : MediaModelRef(label: label ?? id!);
  }

  /// What a fresh mode of [kind] starts on, with the same order the plugin
  /// uses: the kind's service even when only its model went away, then the
  /// legacy service, then the first choice. Within that service: the kind's
  /// model, the legacy model, then the service's first model.
  MediaEntry? defaultFor(GenerateKind kind) {
    final choices = of(kind);
    if (choices.isEmpty) return null;
    MediaDefault? firstWhere(Iterable<MediaDefault> values, bool Function(MediaDefault) test) {
      for (final value in values) {
        if (test(value)) return value;
      }
      return null;
    }

    final kindDefault = firstWhere(defaults, (d) => d.kind == kind && d.service.isNotEmpty);
    final legacy = firstWhere(defaults, (d) => d.kind == null && d.service.isNotEmpty);
    MediaEntry? serviceEntry(MediaDefault? d) =>
        d == null ? null : choices.where((e) => e.namespace == d.namespace && e.service.id == d.service).firstOrNull;
    final selected = serviceEntry(kindDefault) ?? serviceEntry(legacy) ?? choices.first;
    final forService = [
      for (final e in choices)
        if (e.namespace == selected.namespace && e.service.id == selected.service.id) e,
    ];
    String? modelId;
    if (kindDefault != null && kindDefault.namespace == selected.namespace && kindDefault.model.isNotEmpty) {
      modelId = kindDefault.model;
    }
    if (modelId == null || !forService.any((e) => e.model.id == modelId)) {
      modelId = legacy != null && legacy.namespace == selected.namespace && legacy.model.isNotEmpty
          ? legacy.model
          : null;
    }
    return forService.where((e) => e.model.id == modelId).firstOrNull ?? forService.first;
  }
}

// ── Reading settings/describe ────────────────────────────────────────────────

/// The catalogue [view] carries, as sent; null when it carries none.
Object? mediaCatalogMetaOf(SettingsNamespaceView view) {
  final services = view.schema.fields?['services'];
  if (services == null) return null;
  // On the field itself (a transform): its effective array may not carry it.
  for (final node in [services, services.effective]) {
    final extra = node.meta.extra;
    if (extra is Map && extra.containsKey(mediaCatalogMetaKey)) return extra[mediaCatalogMetaKey];
  }
  return null;
}

/// Namespaces that carry a catalogue, in the host's order.
List<String> mediaNamespacesOf(Map<String, SettingsNamespaceView> namespaces) => [
  for (final view in namespaces.values)
    if (mediaCatalogMetaOf(view) != null) view.ns,
];

/// The provider templates [view]'s catalogue publishes, validated; the
/// app's own list when the plugin predates `presets` (0.2.x) or publishes
/// none this app can read. The plugin's list wins wholesale: a partially
/// readable newer list is still the host's answer.
List<MediaPreset> mediaPresetsOf(SettingsNamespaceView view) {
  final raw = mediaCatalogMetaOf(view);
  final list = raw is Map ? raw['presets'] : null;
  if (list is! List) return fallbackMediaPresets;
  final out = <MediaPreset>[];
  final ids = <String>{};
  for (final row in list) {
    final preset = _presetFrom(row);
    if (preset != null && ids.add(preset.id)) out.add(preset);
  }
  // An absent list means an older catalogue (use the app's list); an empty
  // list is the plugin saying it publishes none, and is honoured.
  return List.unmodifiable(out);
}

/// The provider templates of a plugin that predates `presets`; their model
/// ids are the ones the 0.2.x catalogue verified. The settings page filters
/// them through the live catalogue, so an id a newer catalogue dropped
/// simply doesn't appear.
const fallbackMediaPresets = <MediaPreset>[
  MediaPreset(
    id: 'ark-image',
    label: '火山方舟 · 图片',
    labelEn: 'Volcengine Ark · Image',
    provider: 'ark',
    profile: 'ark-image',
    baseUrl: 'https://ark.cn-beijing.volces.com',
    models: ['doubao-seedream-5-0-pro-260628'],
    kind: GenerateKind.image,
    keyGroup: 'ark',
  ),
  MediaPreset(
    id: 'ark-video',
    label: '火山方舟 · 视频',
    labelEn: 'Volcengine Ark · Video',
    provider: 'ark',
    profile: 'ark-video',
    baseUrl: 'https://ark.cn-beijing.volces.com',
    models: ['doubao-seedance-2-5-260628'],
    kind: GenerateKind.video,
    keyGroup: 'ark',
  ),
  MediaPreset(
    id: 'aliyun-image',
    label: '阿里云百炼 · 图片',
    labelEn: 'Alibaba Model Studio · Image',
    provider: 'aliyun',
    profile: 'ali-wan-image',
    baseUrl: 'https://dashscope.aliyuncs.com',
    models: ['wan2.7-image'],
    kind: GenerateKind.image,
    keyGroup: 'aliyun',
  ),
  MediaPreset(
    id: 'aliyun-video',
    label: '阿里云百炼 · 视频',
    labelEn: 'Alibaba Model Studio · Video',
    provider: 'aliyun',
    profile: 'ali-video',
    baseUrl: 'https://dashscope.aliyuncs.com',
    models: ['wan2.7-t2v-2026-06-12', 'wan2.7-i2v-2026-04-25'],
    kind: GenerateKind.video,
    keyGroup: 'aliyun',
  ),
  MediaPreset(
    id: 'siliconflow-image',
    label: '硅基流动 · 图片',
    labelEn: 'SiliconFlow · Image',
    provider: 'siliconflow',
    profile: 'silicon-image',
    baseUrl: 'https://api.siliconflow.cn',
    models: ['Qwen/Qwen-Image', 'Qwen/Qwen-Image-Edit-2509'],
    kind: GenerateKind.image,
    keyGroup: 'siliconflow',
  ),
  MediaPreset(
    id: 'siliconflow-video',
    label: '硅基流动 · 视频',
    labelEn: 'SiliconFlow · Video',
    provider: 'siliconflow',
    profile: 'silicon-video',
    baseUrl: 'https://api.siliconflow.cn',
    models: ['Wan-AI/Wan2.2-T2V-A14B', 'Wan-AI/Wan2.2-I2V-A14B'],
    kind: GenerateKind.video,
    keyGroup: 'siliconflow',
  ),
  MediaPreset(
    id: 'openai-image',
    label: 'OpenAI · 图片',
    labelEn: 'OpenAI · Image',
    provider: 'openai',
    profile: 'openai-gpt-image',
    baseUrl: 'https://api.openai.com/v1',
    models: ['gpt-image-2', 'gpt-image-2.5-sunburst', 'gpt-image-2.5-flare'],
    kind: GenerateKind.image,
    keyGroup: 'openai',
  ),
  MediaPreset(
    id: 'gemini-image',
    label: 'Gemini · 图片',
    labelEn: 'Gemini · Image',
    provider: 'gemini',
    profile: 'openai-compatible',
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    responseFormat: 'b64_json',
    models: ['gemini-2.5-flash-image'],
    kind: GenerateKind.image,
    keyGroup: 'gemini',
  ),
];

final _presetId = RegExp(r'^[a-z][a-z0-9-]{0,31}$');
final _responseFormat = RegExp(r'^(|url|b64_json)$');
final _control = RegExp(r'[\u0000-\u001f]');

MediaPreset? _presetFrom(Object? raw) {
  if (raw is! Map) return null;
  final id = raw['id'];
  final label = raw['label'];
  final labelEn = raw['labelEn'];
  final provider = raw['provider'];
  final profile = raw['profile'];
  final baseUrl = raw['baseUrl'];
  final responseFormat = raw['responseFormat'] ?? '';
  final models = raw['models'];
  final kind = switch (raw['kind']) {
    'image' => GenerateKind.image,
    'video' => GenerateKind.video,
    _ => null,
  };
  if (id is! String || !_presetId.hasMatch(id) || label is! String || label.isEmpty || label.length > 80) return null;
  if (labelEn != null && (labelEn is! String || labelEn.isEmpty || labelEn.length > 80)) return null;
  if (provider is! String || provider.isEmpty || provider.length > 80 || _control.hasMatch(provider)) return null;
  if (profile is! String || profile.isEmpty || profile.length > 80) return null;
  if (baseUrl is! String) return null;
  final url = Uri.tryParse(baseUrl);
  if (url == null ||
      url.scheme != 'https' ||
      url.host.isEmpty ||
      url.userInfo.isNotEmpty ||
      url.hasQuery ||
      url.hasFragment) {
    return null;
  }
  if (responseFormat is! String || !_responseFormat.hasMatch(responseFormat)) return null;
  if (models is! List || models.isEmpty || models.length > 16) return null;
  final ids = <String>{};
  for (final model in models) {
    if (model is! String || model.isEmpty || model.length > 160 || !ids.add(model)) return null;
  }
  if (kind == null) return null;
  final keyGroup = raw['keyGroup'];
  final group = keyGroup is String && _presetId.hasMatch(keyGroup) ? keyGroup : id.split('-').first;
  return MediaPreset(
    id: id,
    label: label,
    labelEn: labelEn is String ? labelEn : '',
    provider: provider,
    profile: profile,
    baseUrl: baseUrl,
    responseFormat: responseFormat,
    models: List.unmodifiable(ids),
    kind: kind,
    keyGroup: group,
  );
}

/// The credential references the plugin's services name: the engine
/// settings read them with the rest, so [mediaCatalogFrom] knows which keys
/// are there.
Set<String> mediaKeyRefsOf(Map<String, SettingsNamespaceView> namespaces) => {
  for (final view in namespaces.values)
    if (mediaCatalogMetaOf(view) != null)
      for (final service in _list(view.value['services']))
        if (service is Map && service['keyRef'] is String && (service['keyRef'] as String).isNotEmpty)
          service['keyRef'] as String,
};

/// [namespaces] (null: not read yet) as what can generate, given which
/// [credentials] the host says are set.
MediaCatalog mediaCatalogFrom(
  Map<String, SettingsNamespaceView>? namespaces, {
  Map<String, CredentialStatus> credentials = const {},
}) {
  if (namespaces == null) return MediaCatalog.loading;
  final read = <(SettingsNamespaceView, _Catalog)>[];
  var found = false;
  var unsupported = false;
  for (final view in namespaces.values) {
    final raw = mediaCatalogMetaOf(view);
    if (raw == null) continue;
    found = true;
    try {
      read.add((view, _Catalog.parse(raw)));
    } on _Unsupported {
      unsupported = true;
    } on _Broken {
      // Counted below: found, but nothing read.
    }
  }
  if (!found) return MediaCatalog.missing;
  if (read.isEmpty) {
    return MediaCatalog(status: unsupported ? MediaCatalogStatus.unsupported : MediaCatalogStatus.broken);
  }

  final entries = <MediaEntry>[];
  final models = <String, MediaModel>{};
  final defaults = <MediaDefault>[];
  for (final (view, catalog) in read) {
    entries.addAll(catalog.entriesFor(view, credentials));
    for (final model in catalog.models.values) {
      models.putIfAbsent(model.id, () => model);
    }
    final d = view.value['defaults'];
    if (d is Map) {
      String read(Object? value) => value is String ? value : '';
      void add(String service, String model, GenerateKind? kind) {
        if (service.isEmpty && model.isEmpty) return;
        defaults.add(MediaDefault(namespace: view.ns, service: service, model: model, kind: kind));
      }

      add(read(d['serviceId']), read(d['modelId']), null);
      add(read(d['imageServiceId']), read(d['imageModelId']), GenerateKind.image);
      add(read(d['videoServiceId']), read(d['videoModelId']), GenerateKind.video);
    }
  }
  // v1's header names no namespace: a service and model two namespaces share
  // can't be told apart, so neither is offered (§4.6.5).
  final seen = <String, int>{};
  for (final e in entries) {
    final key = '${e.service.id}\u0000${e.model.id}';
    seen[key] = (seen[key] ?? 0) + 1;
  }
  return MediaCatalog(
    entries: List.unmodifiable([
      for (final e in entries)
        if (seen['${e.service.id}\u0000${e.model.id}'] == 1) e,
    ]),
    models: Map.unmodifiable(models),
    defaults: List.unmodifiable(defaults),
  );
}

class _Broken implements Exception {}

class _Unsupported implements Exception {}

List<Object?> _list(Object? value) => value is List ? value : const [];

final _serviceId = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
final _aspect = RegExp(r'^[1-9]\d?:[1-9]\d?$');
final _quality = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$');
final _resolution = RegExp(r'^[1-9]\d{2,3}p$');

/// One namespace's catalogue, checked.
class _Catalog {
  _Catalog(this.models, this.kinds, this.maxN);

  /// By id; unknown kinds already dropped.
  final Map<String, MediaModel> models;

  /// Kinds `capabilities` doesn't turn off.
  final Set<GenerateKind> kinds;

  /// `limits.maxN`.
  final int? maxN;

  static _Catalog parse(Object? raw) {
    if (raw is! Map) throw _Broken();
    final v = raw['v'];
    if (v is! int) throw _Broken();
    if (v != mediaCatalogVersion) throw _Unsupported();
    final contract = raw['contract'];
    if (contract != null && contract != mediaCatalogContract) throw _Unsupported();
    final list = raw['models'];
    if (list is! List) throw _Broken();
    final caps = raw['capabilities'];
    if (caps != null && caps is! Map) throw _Broken();
    final limits = raw['limits'];
    if (limits != null && limits is! Map) throw _Broken();
    final limit = limits is Map ? limits['maxN'] : null;
    if (limit != null && limit is! int) throw _Broken();

    final ids = <String>{};
    final models = <String, MediaModel>{};
    for (final m in list) {
      if (m is! Map) throw _Broken();
      final id = m['id'];
      final label = m['label'];
      final kind = m['kind'];
      if (id is! String || id.isEmpty || !ids.add(id) || label is! String || label.isEmpty || kind is! String) {
        throw _Broken();
      }
      final known = switch (kind) {
        'image' => GenerateKind.image,
        'video' => GenerateKind.video,
        _ => null,
      };
      // A kind of a later version: left for a later app.
      if (known == null) continue;
      models[id] = _model(m, id, label, known);
    }
    bool off(String name) => caps is Map && caps.containsKey(name) && caps[name] != true;
    return _Catalog(models, {
      if (!off('image')) GenerateKind.image,
      if (!off('video')) GenerateKind.video,
    }, limit as int?);
  }

  static MediaModel _model(Map<Object?, Object?> m, String id, String label, GenerateKind kind) {
    List<String> strings(String key, RegExp keep) {
      final v = m[key];
      if (v == null) return const [];
      if (v is! List || v.any((e) => e is! String)) throw _Broken();
      // Values the header can't carry are not offered (§4.6.4).
      return List.unmodifiable({
        for (final e in v.cast<String>())
          if (keep.hasMatch(e)) e,
      });
    }

    int? integer(String key) {
      final v = m[key];
      if (v == null) return null;
      if (v is! int) throw _Broken();
      return v;
    }

    bool flag(Object? v) {
      if (v == null) return false;
      if (v is! bool) throw _Broken();
      return v;
    }

    final durations = m['durations'];
    if (durations != null && (durations is! List || durations.any((e) => e is! num))) throw _Broken();
    final frames = m['frames'];
    if (frames != null && frames is! Map) throw _Broken();
    final profile = m['profile'];
    if (profile != null && profile is! String) throw _Broken();
    final maxN = integer('maxN') ?? 1;
    return MediaModel(
      id: id,
      label: label,
      kind: kind,
      profile: profile as String?,
      ratios: strings('ratios', _aspect),
      qualities: strings('qualities', _quality),
      maxN: maxN.clamp(1, 4),
      durations: List.unmodifiable({
        for (final e in _list(durations).cast<num>())
          if (e == e.roundToDouble() && e >= 1 && e <= 60) e.toInt(),
      }),
      resolutions: strings('resolutions', _resolution),
      maxRefs: (integer('maxRefs') ?? 0).clamp(0, 99),
      firstFrame: frames is Map && flag(frames['first']),
      lastFrame: frames is Map && flag(frames['last']),
      edit: flag(m['edit']),
      price: _price(m['price']),
    );
  }

  static MediaPrice? _price(Object? json) {
    if (json is! Map) return null;
    final amount = json['amount'];
    if (amount is! num || amount < 0) return null;
    final currency = json['currency'];
    return MediaPrice(
      perSecond: json['unit'] == 'second',
      amount: amount.toDouble(),
      currency: currency is String ? currency : 'CNY',
    );
  }

  /// The choices [view]'s services make of this catalogue.
  List<MediaEntry> entriesFor(SettingsNamespaceView view, Map<String, CredentialStatus> credentials) {
    final services = _list(view.value['services']);
    final count = <String, int>{};
    for (final s in services) {
      if (s is Map && s['id'] is String) count[s['id'] as String] = (count[s['id'] as String] ?? 0) + 1;
    }
    final hostLimit = switch (view.value['limits']) {
      final Map limits when limits['maxImages'] is int => limits['maxImages'] as int,
      _ => null,
    };
    final out = <MediaEntry>[];
    for (final s in services) {
      if (s is! Map) continue;
      final id = s['id'];
      final keyRef = s['keyRef'];
      if (id is! String || !_serviceId.hasMatch(id) || count[id] != 1) continue;
      if (s['enabled'] != true) continue;
      if (keyRef is! String || credentials[keyRef]?.configured != true) continue;
      final listed = switch (s['models']) {
        final String text => text.split(','),
        final List list => [
          for (final e in list)
            if (e is String) e,
        ],
        _ => const <String>[],
      };
      final service = MediaService(
        id: id,
        label: s['label'] is String ? (s['label'] as String).trim() : '',
        provider: s['provider'] is String ? s['provider'] as String : null,
      );
      final profile = s['profile'] is String ? s['profile'] as String : null;
      final taken = <String>{};
      for (final raw in listed) {
        final modelId = raw.trim();
        final model = models[modelId];
        if (model == null || !taken.add(modelId) || !kinds.contains(model.kind)) continue;
        if (model.profile != null && profile != null && model.profile != profile) continue;
        // Only what a header can name exactly (§4.6.5).
        if (!GenerateModelTag.markable(id, model.id) || !GenerateModelTag.expressible(model.label)) continue;
        final limits = [?maxN, ?hostLimit];
        final limited = limits.isEmpty ? model : model._limitedTo(limits.reduce((a, b) => a < b ? a : b));
        out.add(MediaEntry(namespace: view.ns, service: service, model: limited));
      }
    }
    return out;
  }
}
