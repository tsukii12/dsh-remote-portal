// The parameter header generation mode puts on the first line of an ordinary
// chat message — grammar v1, docs/design/media-generation.md §4.6:
//
//   〔生成图像 · 3:4 · 2 张 · 质量=2k · Seedream 5.0〈ark/doubao-seedream-5-0-pro〉〕
//   画一只在窗台上打盹的橘猫
//
//   〔生成视频 · 16:9 · 5 秒 · 720p · Seedance 2.0〈ark/doubao-seedance-2-0〉〕
//   镜头缓慢推近，猫抬头看向窗外
//
// The host's dsh-media plugin reads the same grammar (its src/header.js); both
// ends run app/test/media/fixtures/header_grammar_v1.json case by case. The
// checks below go in the spec's order (§4.6.3) so both give the same error
// code for the same input. The words are wire format, not UI copy: an English
// app writes the same header; only what the bubble shows is translated.

import 'dart:convert';

/// What a header asks for.
enum GenerateKind { image, video }

/// Why a message that starts like a header isn't one (§4.6.3).
abstract final class GenerateHeaderCode {
  static const invalidMessage = 'invalid_message';
  static const missingPrompt = 'missing_prompt';
  static const invalidHeader = 'invalid_header';
  static const invalidOrder = 'invalid_order';
  static const invalidAspect = 'invalid_aspect';
  static const invalidCount = 'invalid_count';
  static const invalidSeconds = 'invalid_seconds';
  static const invalidQuality = 'invalid_quality';
  static const invalidModel = 'invalid_model';
  static const tooLong = 'too_long';
}

class GenerateHeaderException implements Exception {
  const GenerateHeaderException(this.code);

  /// One of [GenerateHeaderCode].
  final String code;

  @override
  String toString() => 'GenerateHeaderException($code)';
}

Never _fail(String code) => throw GenerateHeaderException(code);

/// The model field: its catalogue name, and the 〈service/model〉 marker that
/// says which one when the name alone could mean several (§4.6.5).
class GenerateModelTag {
  const GenerateModelTag(this.label, {this.service, this.id});

  final String label;

  /// `value.services[].id` of the plugin's settings.
  final String? service;

  /// The catalogue's `models[].id`.
  final String? id;

  bool get marked => service != null && id != null;

  /// [label] can stand as a model in a header: it passes the label rules and
  /// reads back as a model, not as an aspect or a resolution.
  static bool expressible(String label) {
    try {
      final text = GenerateHeader.formatWire({
        'kind': 'image',
        'prompt': '.',
        'model': {'label': label},
      });
      return GenerateHeader.read(text)?.header?.model?.label == label;
    } on GenerateHeaderException {
      return false;
    }
  }

  static final _service = RegExp(r'^[a-z][a-z0-9_]{0,31}$');
  static final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,159}$');

  /// [service] and [id] fit the marker.
  static bool markable(String service, String id) => _service.hasMatch(service) && _id.hasMatch(id);

  Map<String, Object?> get wire => {'label': label, 'serviceId': ?service, 'id': ?id};

  @override
  bool operator ==(Object other) =>
      other is GenerateModelTag && other.label == label && other.service == service && other.id == id;

  @override
  int get hashCode => Object.hash(label, service, id);

  @override
  String toString() => marked ? '$label〈$service/$id〉' : label;
}

/// A message read as a generation request: valid ([header], [description]) or
/// not ([error]).
class GenerateRead {
  const GenerateRead.valid(GenerateHeader this.header, String this.description) : error = null;
  const GenerateRead.invalid(String this.error) : header = null, description = null;

  final GenerateHeader? header;

  /// Everything after the header line, as it was.
  final String? description;

  /// One of [GenerateHeaderCode].
  final String? error;
}

/// The parameters a header carries; a null field is left to the host.
class GenerateHeader {
  const GenerateHeader({
    required this.kind,
    this.aspect,
    this.count,
    this.seconds,
    this.quality,
    this.resolution,
    this.model,
  });

  final GenerateKind kind;

  /// `3:4`.
  final String? aspect;

  /// Pictures (image), 1–4.
  final int? count;

  /// Length (video), 1–60.
  final int? seconds;

  /// The catalogue's own quality value (image): `2k`, `high`.
  final String? quality;

  /// `720p` (video).
  final String? resolution;

  final GenerateModelTag? model;

  static const open = '〔';
  static const close = '〕';
  static const separator = ' · ';
  static const imageWord = '生成图像';
  static const videoWord = '生成视频';
  static const qualityPrefix = '质量=';
  static const countUnit = ' 张';
  static const secondsUnit = ' 秒';
  static const maxHeaderBytes = 1024;
  static const maxDescriptionBytes = 4096;
  static const maxLabelBytes = 160;

  // ── Reading ──────────────────────────────────────────────────────────────

  /// [text] as a generation message: null when it is an ordinary one (§4.6.2),
  /// else valid or the first error.
  static GenerateRead? read(String text) {
    final kind = _kindAt(text);
    if (kind == null) return null;
    try {
      final newline = text.indexOf('\n');
      if (newline < 0) _fail(GenerateHeaderCode.missingPrompt);
      var line = text.substring(0, newline);
      if (line.endsWith('\r')) line = line.substring(0, line.length - 1);
      final description = text.substring(newline + 1);
      if (_blank(description)) _fail(GenerateHeaderCode.missingPrompt);
      if (_utf8Length(line) > maxHeaderBytes || _utf8Length(description) > maxDescriptionBytes) {
        _fail(GenerateHeaderCode.tooLong);
      }
      return GenerateRead.valid(_line(line), description);
    } on GenerateHeaderException catch (e) {
      return GenerateRead.invalid(e.code);
    }
  }

  /// [text]'s header and description when it is a valid generation message;
  /// null for anything else (shown as typed).
  static ({GenerateHeader header, String description})? parse(String text) {
    final read = GenerateHeader.read(text);
    final header = read?.header;
    if (header == null) return null;
    return (header: header, description: read!.description!);
  }

  /// The kind [text] starts with, when the kind word ends at a token boundary
  /// (`〕`, `·`, whitespace or the end): 〔生成图像的方法〕 is ordinary text.
  static GenerateKind? _kindAt(String text) {
    for (final (word, kind) in const [(imageWord, GenerateKind.image), (videoWord, GenerateKind.video)]) {
      final prefix = '$open$word';
      if (!text.startsWith(prefix)) continue;
      if (text.length == prefix.length) return kind;
      final next = text.codeUnitAt(prefix.length);
      return next == 0x3015 || next == 0x00B7 || _isSpace(next) ? kind : null;
    }
    return null;
  }

  static final _aspectShape = RegExp(r'^[+-]?\d+(?:\.\d+)?:[+-]?\d+(?:\.\d+)?$');
  static final _aspect = RegExp(r'^[1-9]\d?:[1-9]\d?$');
  static final _countShape = RegExp(r'^[+-]?\d+(?:\.\d+)?\s*张$');
  static final _count = RegExp(r'^[1-4] 张$');
  static final _secondsShape = RegExp(r'^[+-]?\d+(?:\.\d+)?\s*秒$');
  static final _seconds = RegExp(r'^[1-9]\d? 秒$');
  static final _quality = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]{0,31}$');
  static final _resolutionShape = RegExp(r'^[+-]?\d+(?:\.\d+)?[pPkK]$');
  static final _resolution = RegExp(r'^[1-9]\d{2,3}p$');
  static final _modelToken = RegExp(r'^([^〈〉]+?)(?:〈([a-z][a-z0-9_]{0,31})/([A-Za-z0-9][A-Za-z0-9_.:/-]{0,159})〉)?$');
  static final _labelForbidden = RegExp(r'[〔〕·\x00-\x1f\x7f-\x9f]');
  static final _labelLooksLikeField = RegExp(r'^\d+(?::\d+|\s*(?:张|秒|p|k))$', caseSensitive: false);
  static final _structural = RegExp('[〔〕·]');

  /// The header line (§4.6.3 steps 5–7).
  static GenerateHeader _line(String line) {
    if (!line.endsWith(close) || line.contains('\r') || line.contains('\n')) _fail(GenerateHeaderCode.invalidHeader);
    final tokens = line.substring(open.length, line.length - close.length).split(separator);
    final kind = switch (tokens.first) {
      imageWord => GenerateKind.image,
      videoWord => GenerateKind.video,
      _ => null,
    };
    if (kind == null || tokens.length > 5 || tokens.any((t) => t.isEmpty || !_trimmed(t) || _structural.hasMatch(t))) {
      _fail(GenerateHeaderCode.invalidHeader);
    }
    final image = kind == GenerateKind.image;
    String? aspect;
    int? count;
    int? seconds;
    String? quality;
    String? resolution;
    GenerateModelTag? model;
    var previous = 0;
    for (final token in tokens.skip(1)) {
      final int rank;
      if (_aspectShape.hasMatch(token)) {
        if (!_aspect.hasMatch(token)) _fail(GenerateHeaderCode.invalidAspect);
        rank = 1;
        aspect = token;
      } else if (_countShape.hasMatch(token)) {
        if (!image || !_count.hasMatch(token)) _fail(GenerateHeaderCode.invalidCount);
        rank = 2;
        count = int.parse(token.substring(0, token.length - countUnit.length));
      } else if (_secondsShape.hasMatch(token)) {
        if (image || !_seconds.hasMatch(token)) _fail(GenerateHeaderCode.invalidSeconds);
        final value = int.parse(token.substring(0, token.length - secondsUnit.length));
        if (value > 60) _fail(GenerateHeaderCode.invalidSeconds);
        rank = 2;
        seconds = value;
      } else if (token.startsWith(qualityPrefix)) {
        final value = token.substring(qualityPrefix.length);
        if (!image || !_quality.hasMatch(value)) _fail(GenerateHeaderCode.invalidQuality);
        rank = 3;
        quality = value;
      } else if (_resolutionShape.hasMatch(token)) {
        if (image || !_resolution.hasMatch(token)) _fail(GenerateHeaderCode.invalidQuality);
        rank = 3;
        resolution = token;
      } else {
        rank = 4;
        model = _model(token);
      }
      if (rank <= previous) _fail(GenerateHeaderCode.invalidOrder);
      previous = rank;
    }
    return GenerateHeader(
      kind: kind,
      aspect: aspect,
      count: count,
      seconds: seconds,
      quality: quality,
      resolution: resolution,
      model: model,
    );
  }

  static GenerateModelTag _model(String token) {
    final match = _modelToken.firstMatch(token);
    final label = match?[1];
    if (label == null ||
        !_trimmed(label) ||
        _utf8Length(label) > maxLabelBytes ||
        _labelForbidden.hasMatch(label) ||
        _labelLooksLikeField.hasMatch(label) ||
        label.startsWith(qualityPrefix)) {
      _fail(GenerateHeaderCode.invalidModel);
    }
    return GenerateModelTag(label, service: match![2], id: match[3]);
  }

  // ── Writing ──────────────────────────────────────────────────────────────

  /// The golden's (the plugin parser's) shape of this header with
  /// [description]: `kind`, `prompt`, then only the fields there are; a
  /// video's resolution goes as `quality`.
  Map<String, Object?> wire(String description) => {
    'kind': kind.name,
    'prompt': description,
    'aspect': ?aspect,
    if (kind == GenerateKind.image) 'n': ?count,
    if (kind == GenerateKind.video) 'seconds': ?seconds,
    'quality': ?(kind == GenerateKind.image ? quality : resolution),
    'model': ?model?.wire,
  };

  /// The message to send: this header, LF, [description] as it is. Throws
  /// [GenerateHeaderException] when a value can't be carried (§4.6.4).
  String message(String description) => formatWire(wire(description));

  /// [message], or why not.
  ({String? text, String? code}) tryMessage(String description) {
    try {
      return (text: message(description), code: null);
    } on GenerateHeaderException catch (e) {
      return (text: null, code: e.code);
    }
  }

  static const _wireKeys = {'kind', 'prompt', 'aspect', 'n', 'seconds', 'quality', 'model'};
  static const _modelKeys = {'label', 'serviceId', 'id'};

  /// Writes [value] (the golden's shape) as a message, checking every field
  /// first and the result after: it must read back as exactly [value].
  static String formatWire(Map<String, Object?> value) {
    final kindName = value['kind'];
    final prompt = value['prompt'];
    if (value.keys.any((k) => !_wireKeys.contains(k)) ||
        (kindName != 'image' && kindName != 'video') ||
        prompt is! String) {
      _fail(GenerateHeaderCode.invalidMessage);
    }
    final image = kindName == 'image';
    if ((image && value.containsKey('seconds')) || (!image && value.containsKey('n'))) {
      _fail(GenerateHeaderCode.invalidOrder);
    }
    final parts = [if (image) imageWord else videoWord];
    if (value.containsKey('aspect')) {
      final aspect = value['aspect'];
      if (aspect is! String || !_aspect.hasMatch(aspect)) _fail(GenerateHeaderCode.invalidAspect);
      parts.add(aspect);
    }
    if (value.containsKey('n')) {
      final n = _wholeNumber(value['n']);
      if (n == null || n < 1 || n > 4) _fail(GenerateHeaderCode.invalidCount);
      parts.add('$n$countUnit');
    }
    if (value.containsKey('seconds')) {
      final s = _wholeNumber(value['seconds']);
      if (s == null || s < 1 || s > 60) _fail(GenerateHeaderCode.invalidSeconds);
      parts.add('$s$secondsUnit');
    }
    if (value.containsKey('quality')) {
      final quality = value['quality'];
      if (quality is! String || !(image ? _quality : _resolution).hasMatch(quality)) {
        _fail(GenerateHeaderCode.invalidQuality);
      }
      parts.add(image ? '$qualityPrefix$quality' : quality);
    }
    if (value.containsKey('model')) {
      final model = value['model'];
      if (model is! Map || model.keys.any((k) => !_modelKeys.contains(k)) || model['label'] is! String) {
        _fail(GenerateHeaderCode.invalidModel);
      }
      final label = model['label'] as String;
      final alone = _model(label);
      if (alone.service != null || alone.label != label) _fail(GenerateHeaderCode.invalidModel);
      final hasService = model.containsKey('serviceId');
      final hasId = model.containsKey('id');
      final service = model['serviceId'];
      final id = model['id'];
      if (hasService != hasId ||
          (hasService && (service is! String || id is! String || !GenerateModelTag.markable(service, id)))) {
        _fail(GenerateHeaderCode.invalidModel);
      }
      parts.add(hasService ? '$label〈$service/$id〉' : label);
    }
    final text = '$open${parts.join(separator)}$close\n$prompt';
    final read = GenerateHeader.read(text);
    if (read == null) _fail(GenerateHeaderCode.invalidHeader);
    if (read.error case final code?) _fail(code);
    final again = read.header!.wire(read.description!);
    for (final key in const ['kind', 'prompt', 'aspect', 'n', 'seconds', 'quality']) {
      if (!_sameScalar(again[key], value[key])) _fail(GenerateHeaderCode.invalidHeader);
    }
    final parsedModel = again['model'] as Map<String, Object?>?;
    final givenModel = value['model'] as Map?;
    if ((parsedModel == null) != (givenModel == null)) _fail(GenerateHeaderCode.invalidModel);
    if (givenModel != null) {
      for (final key in _modelKeys) {
        if (parsedModel![key] != givenModel[key]) _fail(GenerateHeaderCode.invalidModel);
      }
    }
    return text;
  }

  /// A JSON number that is a safe integer (`2` and `2.0` alike).
  static int? _wholeNumber(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.roundToDouble() && value.abs() <= 9007199254740991) {
      return value.toInt();
    }
    return null;
  }

  static bool _sameScalar(Object? a, Object? b) => a is num && b is num ? a == b : a == b;

  // ── Titles ───────────────────────────────────────────────────────────────

  /// A conversation title that starts with a request's header (§4.6.6): its
  /// kind and what follows the header ('' when the title was cut inside the
  /// header or nothing follows). DSH's fallback title is the first message,
  /// whitespace runs folded to one space, cut short. Null for any other
  /// title, which shows as it is.
  static ({GenerateKind kind, String rest})? splitTitle(String title) {
    for (final (word, kind) in const [(imageWord, GenerateKind.image), (videoWord, GenerateKind.video)]) {
      final prefix = '$open$word';
      if (!title.startsWith(prefix)) continue;
      final after = title.substring(prefix.length);
      final end = title.indexOf(close);
      // Cut inside the header.
      if (after.isEmpty || after == ' ·' || (after.startsWith(separator) && end < 0)) return (kind: kind, rest: '');
      if (!after.startsWith(separator) && !after.startsWith(close)) return null;
      final line = title.substring(0, end + close.length);
      try {
        if (_utf8Length(line) > maxHeaderBytes) return null;
        if (_line(line).kind != kind) return null;
      } on GenerateHeaderException {
        return null;
      }
      final rest = title.substring(line.length);
      if (rest.isEmpty) return (kind: kind, rest: '');
      if (!rest.startsWith(' ')) return null;
      return (kind: kind, rest: rest.substring(1));
    }
    return null;
  }

  // ── Characters ───────────────────────────────────────────────────────────

  /// Whitespace as JavaScript's `trim` sees it (§4.6.1); not Dart's, which
  /// also takes U+0085.
  static bool _isSpace(int unit) =>
      (unit >= 0x09 && unit <= 0x0D) ||
      unit == 0x20 ||
      unit == 0xA0 ||
      unit == 0x1680 ||
      (unit >= 0x2000 && unit <= 0x200A) ||
      unit == 0x2028 ||
      unit == 0x2029 ||
      unit == 0x202F ||
      unit == 0x205F ||
      unit == 0x3000 ||
      unit == 0xFEFF;

  static bool _blank(String text) => text.codeUnits.every(_isSpace);

  static bool _trimmed(String text) =>
      text.isNotEmpty && !_isSpace(text.codeUnitAt(0)) && !_isSpace(text.codeUnitAt(text.length - 1));

  /// UTF-8 bytes of [text]; a lone surrogate is [GenerateHeaderCode.invalidMessage].
  static int _utf8Length(String text) {
    var length = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        final next = i + 1 < text.length ? text.codeUnitAt(i + 1) : 0;
        if (next < 0xDC00 || next > 0xDFFF) _fail(GenerateHeaderCode.invalidMessage);
        length += 4;
        i++;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        _fail(GenerateHeaderCode.invalidMessage);
      } else {
        length += unit <= 0x7F ? 1 : (unit <= 0x7FF ? 2 : 3);
      }
    }
    return length;
  }

  /// UTF-8 bytes of [text] for callers checking a description before writing
  /// it; null when it holds a lone surrogate.
  static int? utf8Bytes(String text) {
    try {
      return _utf8Length(text);
    } on GenerateHeaderException {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is GenerateHeader &&
      other.kind == kind &&
      other.aspect == aspect &&
      other.count == count &&
      other.seconds == seconds &&
      other.quality == quality &&
      other.resolution == resolution &&
      other.model == model;

  @override
  int get hashCode => Object.hash(kind, aspect, count, seconds, quality, resolution, model);

  @override
  String toString() => jsonEncode(wire(''));
}
