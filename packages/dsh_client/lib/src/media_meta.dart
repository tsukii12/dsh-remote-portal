/// Generated pictures and videos on a tool result: `meta["dsh-go/media"]`,
/// written by the host's media plugin through `presentationMeta` (contract v1,
/// docs/design/media-generation.md §2.5 ①). No bytes: the items name files in
/// the host's workspace, read through `workspaceFiles/*` like any artifact.
library;

import 'json.dart';

/// The tool-result meta key the media plugin writes.
const mediaMetaKey = 'dsh-go/media';

/// `kind` of a request.
enum MediaKind {
  image,
  video;

  static MediaKind? parse(Object? value) => switch (value) {
    'image' => MediaKind.image,
    'video' => MediaKind.video,
    _ => null,
  };
}

/// `status`: pictures are usually [done] at once; a video runs as a host job.
enum MediaStatus {
  running,
  done,
  failed;

  static MediaStatus parse(Object? value) => switch (value) {
    'running' => MediaStatus.running,
    'failed' => MediaStatus.failed,
    _ => MediaStatus.done,
  };
}

/// One generated file.
class MediaItem {
  const MediaItem({
    required this.path,
    this.mime,
    this.width,
    this.height,
    this.bytes,
    this.duration,
    this.poster,
    this.codec,
  });

  static MediaItem? fromJson(Object? json) {
    final map = asMap(json);
    final path = asString(map?['path']);
    if (map == null || path == null || path.isEmpty) return null;
    final width = asInt(map['width']);
    final height = asInt(map['height']);
    return MediaItem(
      path: path,
      mime: asString(map['mime']),
      width: width != null && width > 0 ? width : null,
      height: height != null && height > 0 ? height : null,
      bytes: asInt(map['bytes']),
      duration: asNum(map['duration'])?.toDouble(),
      poster: asString(map['poster']),
      codec: asString(map['codec']),
    );
  }

  /// Absolute path on the host.
  final String path;
  final String? mime;
  final int? width;
  final int? height;
  final int? bytes;

  /// Seconds (video).
  final double? duration;

  /// A still of a video, when the plugin made one.
  final String? poster;

  /// `h264`, `hevc`… (video): whether the phone can play it in place.
  final String? codec;

  /// Width / height, when both are known.
  double? get aspect => width != null && height != null ? width! / height! : null;

  bool get isVideo => mime?.startsWith('video/') ?? false;

  /// The file name (`cat-1.png`).
  String get name {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return slash < 0 ? path : path.substring(slash + 1);
  }
}

/// What was asked for (`request`).
class MediaRequestInfo {
  const MediaRequestInfo({
    this.provider,
    this.model,
    this.label,
    this.aspect,
    this.n,
    this.quality,
    this.seconds,
    this.resolution,
    this.refs,
  });

  static MediaRequestInfo fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    return MediaRequestInfo(
      provider: asString(map['provider']),
      model: asString(map['model']),
      label: asString(map['label']),
      aspect: asString(map['aspect']),
      n: asInt(map['n']),
      quality: asString(map['quality']),
      seconds: asNum(map['seconds'])?.toDouble(),
      resolution: asString(map['resolution']) ?? asString(map['res']),
      refs: asInt(map['refs']),
    );
  }

  final String? provider;
  final String? model;

  /// The model as people know it (`Seedream 5.0`).
  final String? label;

  /// `1:1`, `3:4`, `16:9`…
  final String? aspect;
  final int? n;

  /// `1k` / `2k` / `4k`, or the provider's own word.
  final String? quality;
  final double? seconds;

  /// `720p`, `1080p` (video).
  final String? resolution;

  /// Reference pictures sent along.
  final int? refs;

  /// The model's name to show: [label], else the id.
  String? get modelName => label ?? model;

  /// `3:4` as width / height.
  double? get ratio {
    final value = aspect;
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final w = double.tryParse(parts[0].trim());
    final h = double.tryParse(parts[1].trim());
    return w == null || h == null || w <= 0 || h <= 0 ? null : w / h;
  }
}

/// An estimate of what it cost (`cost`); only there when the price is known.
class MediaCost {
  const MediaCost(this.estimate, this.currency);

  static MediaCost? fromJson(Object? json) {
    final map = asMap(json);
    final estimate = asNum(map?['estimate'])?.toDouble();
    if (estimate == null || estimate < 0) return null;
    return MediaCost(estimate, asString(map?['currency']) ?? 'CNY');
  }

  final double estimate;
  final String currency;
}

/// Where the file's own marks stand (`provenance`).
class MediaProvenance {
  const MediaProvenance({this.visibleMark, this.c2pa, this.implicitLabel});

  static MediaProvenance? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return MediaProvenance(
      visibleMark: asBool(map['visibleMark']),
      c2pa: asBool(map['c2pa']),
      implicitLabel: asBool(map['implicitLabel']),
    );
  }

  final bool? visibleMark;
  final bool? c2pa;
  final bool? implicitLabel;
}

/// Why it failed (`error`, with `status: failed`).
class MediaFailure {
  const MediaFailure(this.code, this.text);

  static MediaFailure? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    return MediaFailure(asString(map['code']) ?? 'unknown', asString(map['text']));
  }

  /// `policy`, `auth`, `balance`, `quota`, `unavailable`, `expired`…
  final String code;
  final String? text;
}

/// `meta["dsh-go/media"]`, v1.
class MediaMeta {
  const MediaMeta({
    this.version = 1,
    this.rid,
    required this.kind,
    this.status = MediaStatus.done,
    this.job,
    this.items = const [],
    this.request = const MediaRequestInfo(),
    this.prompt,
    this.revisedPrompt,
    this.cost,
    this.provenance,
    this.error,
  });

  /// The media entry of a tool result's meta; null when there is none or it
  /// can't be read (no kind, nothing to show and nothing running).
  static MediaMeta? fromToolMeta(Object? meta) {
    final map = asMap(meta);
    if (map == null || !map.containsKey(mediaMetaKey)) return null;
    return fromJson(map[mediaMetaKey]);
  }

  static MediaMeta? fromJson(Object? json) {
    final map = asMap(json);
    if (map == null) return null;
    final version = asInt(map['v']) ?? 1;
    if (version < 1) return null;
    final items = [for (final raw in asListOrEmpty(map['items'])) ?MediaItem.fromJson(raw)];
    final status = MediaStatus.parse(map['status']);
    final kind =
        MediaKind.parse(map['kind']) ??
        (items.isNotEmpty ? (items.first.isVideo ? MediaKind.video : MediaKind.image) : null);
    if (kind == null) return null;
    if (items.isEmpty && status == MediaStatus.done) return null;
    return MediaMeta(
      version: version,
      rid: asString(map['rid']),
      kind: kind,
      status: status,
      job: asString(map['job']),
      items: List.unmodifiable(items),
      request: MediaRequestInfo.fromJson(map['request']),
      prompt: asString(map['prompt']),
      revisedPrompt: asString(map['revisedPrompt']),
      cost: MediaCost.fromJson(map['cost']),
      provenance: MediaProvenance.fromJson(map['provenance']),
      error: MediaFailure.fromJson(map['error']),
    );
  }

  final int version;

  /// One request's id (a video's card updates in place by it).
  final String? rid;
  final MediaKind kind;
  final MediaStatus status;

  /// The host job of a video (`job/list`, `job/kill`).
  final String? job;
  final List<MediaItem> items;
  final MediaRequestInfo request;

  /// The description as written.
  final String? prompt;

  /// The description the model or provider rewrote it into.
  final String? revisedPrompt;

  /// Absent when the price isn't reliable: then nothing is shown.
  final MediaCost? cost;
  final MediaProvenance? provenance;
  final MediaFailure? error;

  /// What 「复制提示词」 copies: the rewrite when there is one.
  String? get promptToCopy => revisedPrompt ?? prompt;

  /// The paths of the items (and their posters), for de-duplicating images
  /// the reply also names.
  Iterable<String> get paths sync* {
    for (final item in items) {
      yield item.path;
      if (item.poster case final poster?) yield poster;
    }
  }
}
