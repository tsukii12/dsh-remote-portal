/// Common schema-1 import validation. Parsing follows [PetPack.parse]; local
/// imports additionally preserve the current Android-compatible strict gate.
/// Market normalization must produce a pack accepted by that same gate.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:image/image.dart' as image;

import 'pet_name_alias.dart';
import 'pet_pack.dart';
import 'pet_pack_rules.g.dart';
import 'pet_unicode_data.g.dart' show petUnicodeWhitespace;

export 'pet_pack_rules.g.dart';

part 'pet_archive.dart';
part 'pet_json.dart';
part 'pet_png.dart';

enum PetValidationProfile { local, market }

class PetValidationException implements Exception {
  const PetValidationException(this.code, [this.path]);
  final String code;
  final String? path;

  @override
  String toString() => 'PetValidationException($code${path == null ? '' : ': $path'})';
}

void _require(bool condition, String code, [String? path]) {
  if (!condition) throw PetValidationException(code, path);
}

class ValidatedPetPack {
  const ValidatedPetPack({required this.json, required this.pack, required this.sheets, this.dropped = const []});
  final Map<String, Object?> json;
  final PetPack pack;
  final Map<String, Uint8List> sheets;
  final List<String> dropped;
}

bool _safeSheetName(String name) =>
    name.isNotEmpty &&
    name.length <= petSheetNameCap &&
    // The common 120-code-unit limit does not bound UTF-8 path components.
    // Normalized sheets are written by this App, including market imports.
    utf8.encode(name).length <= 255 &&
    !name.startsWith('.') &&
    !name.contains('/') &&
    !name.contains('\\') &&
    !name.contains('\u0000') &&
    name.toLowerCase().endsWith('.png');

class PetPackValidator {
  PetPackValidator._();

  static ValidatedPetPack validateArchive(
    Uint8List bytes, {
    PetValidationProfile profile = PetValidationProfile.local,
  }) => validatePetArchive(PetArchive.read(bytes), profile: profile);

  /// Reuse an archive already inspected for pack.json / Codex pet.json.
  static ValidatedPetPack validatePetArchive(
    PetArchive archive, {
    PetValidationProfile profile = PetValidationProfile.local,
  }) {
    final candidates = archive.manifestPaths('pack.json');
    _require(candidates.length == 1, 'archive-pack-count');
    final name = candidates.single;
    final prefix = name.substring(0, name.length - 'pack.json'.length);
    final json = decodePetJson(archive.readFile(name, maxBytes: petJsonCap));
    _require(json is Map<String, Object?>, 'pack-json-object');
    final parsed = _parse(json as Map<String, Object?>, checkOverlay: profile == PetValidationProfile.local);
    final names = _sheetNames(parsed);
    final sheets = <String, Uint8List>{};
    var total = 0;
    for (final sheet in names) {
      _require(archive.fileNames.contains('$prefix$sheet'), 'sheet-missing', sheet);
      final data = archive.readFile(
        '$prefix$sheet',
        maxBytes: petSheetByteCap < petTotalSheetByteCap - total ? petSheetByteCap : petTotalSheetByteCap - total,
      );
      total += data.length;
      sheets[sheet] = data;
    }
    final validated = validateParts(json, sheets, profile: profile);
    final kept = {name, for (final sheet in names) '$prefix$sheet'};
    return ValidatedPetPack(
      json: validated.json,
      pack: validated.pack,
      sheets: validated.sheets,
      dropped: List.unmodifiable(archive.fileNames.difference(kept).toList()..sort()),
    );
  }

  static ValidatedPetPack validateParts(
    Map<String, Object?> json,
    Map<String, Uint8List> sheets, {
    PetValidationProfile profile = PetValidationProfile.local,
  }) {
    _checkJsonValue(json, 0);
    _require(utf8.encode(jsonEncode(json)).length <= petJsonCap, 'pack-size');
    final pack = _parse(json, checkOverlay: profile == PetValidationProfile.local);
    final names = _sheetNames(pack);
    final kept = <String, Uint8List>{};
    var total = 0;
    for (final name in names) {
      final bytes = sheets[name];
      _require(bytes != null, 'sheet-missing', name);
      total += bytes!.length;
      _require(total <= petTotalSheetByteCap, 'sheet-total-size');
      final (w, h) = _validatePng(bytes, name);
      for (final animation in pack.animations.values.where((a) => a.sheet == name)) {
        var last = 0;
        for (final frame in animation.frames) {
          if (frame.i > last) last = frame.i;
        }
        // Divide first. Multiplying arbitrary parsed int64 values can wrap on
        // the Dart VM; this is mathematically the same bound without overflow.
        _require(
          animation.cols <= w ~/ animation.frameWidth && last ~/ animation.cols < h ~/ animation.frameHeight,
          'sheet-frame-bounds',
          animation.name,
        );
      }
      kept[name] = bytes;
    }
    final output = profile == PetValidationProfile.market ? _marketManifest(json, pack) : json;
    _require(utf8.encode(jsonEncode(output)).length <= petJsonCap, 'pack-normalized-size');
    return ValidatedPetPack(
      json: output,
      pack: profile == PetValidationProfile.market ? _parse(output, checkOverlay: true) : pack,
      sheets: Map.unmodifiable(kept),
      dropped: List.unmodifiable(sheets.keys.where((n) => !names.contains(n)).toList()..sort()),
    );
  }

  static PetPack _parse(Map<String, Object?> json, {bool checkOverlay = false}) {
    try {
      final pack = PetPack.parse(json);
      if (checkOverlay) {
        if (overlayPackProblem(json) case final problem?) {
          throw PetValidationException('pack-overlay', problem);
        }
      }
      return pack;
    } on FormatException catch (error) {
      throw PetValidationException('pack-schema', error.message);
    } on UnsupportedError {
      throw const PetValidationException('json-number');
    }
  }

  static Set<String> _sheetNames(PetPack pack) {
    final names = {for (final animation in pack.animations.values) animation.sheet};
    _require(names.length <= petSheetCountCap, 'sheet-count');
    final aliases = <String>{};
    for (final name in names) {
      _require(_safeSheetName(name), 'sheet-name', name);
      _require(aliases.add(petNameAlias(name)), 'sheet-alias', name);
    }
    return names;
  }
}

Map<String, Object?> _marketManifest(Map<String, Object?> input, PetPack pack) {
  for (final key in ['author', 'license', 'source']) {
    _require(
      input[key] is String && (input[key] as String).runes.any((cp) => !petUnicodeWhitespace.contains(cp)),
      'metadata-$key',
    );
  }
  final json = jsonDecode(jsonEncode(input)) as Map<String, Object?>;
  _require(pack.scale > 0 && pack.scale <= 2147483647, 'market-scale');
  json['scale'] = pack.scale;
  json['pixelArt'] = pack.pixelArt;
  if (pack.reactions.isNotEmpty) {
    // Numbered names keep the normalized pack readable by older apps, which
    // read only the plain first name of a reaction.
    json['reactions'] = {
      for (final entry in pack.reactions.entries)
        for (final (index, name) in entry.value.indexed)
          (index == 0 ? entry.key : '${entry.key}${index + 1}'): name,
    };
  }
  final canvas = json['canvas'] as Map<String, Object?>;
  for (final axis in ['w', 'h']) {
    final value = canvas[axis] as num;
    _require(value > 0 && value <= petSheetSideCap && value == value.toInt(), 'market-canvas-integer');
    canvas[axis] = value.toInt();
  }
  double f32(num n) {
    final value = (Float32List(1)..[0] = n.toDouble())[0];
    _require(value.isFinite, 'market-float32');
    return value;
  }

  final animations = json['animations'] as Map<String, Object?>;
  for (final a in pack.animations.values) {
    // Android stores the authored width/height as Float32 fields. Rect.width
    // can lose these bits through (x + w) - x for large x and small w.
    final target = animations[a.name] as Map<String, Object?>;
    final box = target['box'] as Map<String, Object?>;
    _require(
      a.frameWidth == f32(f32(box['w'] as num) * f32(pack.scale)).truncate() &&
          a.frameHeight == f32(f32(box['h'] as num) * f32(pack.scale)).truncate(),
      'market-cell-box-scale',
      a.name,
    );
    for (final frame in a.frames) {
      _require(frame.i <= 2147483647 && frame.ms <= 2147483647, 'market-frame-int32', a.name);
    }
    target.addAll({
      'frameW': a.frameWidth,
      'frameH': a.frameHeight,
      'cols': a.cols,
      'frames': [
        for (final f in a.frames) {'i': f.i, 'ms': f.ms},
      ],
    });
  }
  Map<String, Object?> object(Object? value) => value is Map<String, Object?> ? value : <String, Object?>{};
  List<Object?> array(Object? value) => value is List<Object?> ? value : <Object?>[];
  int rounded(Object? value, int fallback) => value is num ? value.toDouble().round() : fallback;
  for (final tiers in object(json['tiers']).values) {
    for (final tier in array(tiers)) {
      final t = object(tier);
      final value = rounded(t['min'], 1);
      _require(value >= -2147483648 && value <= 2147483647, 'market-tier-int32');
      t['min'] = value;
    }
  }
  final timings = object(json['timings']);
  for (final key in ['minDisplay', 'autoReturn', 'playMs']) {
    if (timings.containsKey(key)) {
      timings[key] = {
        for (final e in object(timings[key]).entries)
          if (e.value is num && (e.value as num) > 0) e.key: rounded(e.value, 0),
      };
    }
  }
  if (timings['wakeMs'] is num) timings['wakeMs'] = rounded(timings['wakeMs'], 0);
  final pool = json['idlePool'];
  for (final item in pool is List ? pool : array(object(pool)['anims'])) {
    final p = object(item);
    p['ms'] = rounded(p['ms'], 0);
  }
  return json;
}

/// What the overlay's parser (PetPack.kt) turns away although
/// PetPack.parse takes it, as an import validation detail;
/// null when both read [json] alike. It reads integers where the app rounds
/// (`scale`, `canvas`, a cell's size, `cols`, each frame's `i` and `ms`), so
/// those must be whole; it drops no malformed frame; and each cell must be
/// exactly its box × scale, in Kotlin's Float arithmetic. A missing `scale`
/// is fine: the install writes the app's reading of it (1) out.
String? overlayPackProblem(Map<String, Object?> json) {
  bool whole(Object? v, {int min = 0, int max = 1 << 30}) =>
      v is num && v.isFinite && v == v.roundToDouble() && v >= min && v <= max;
  if (_depth(json) > 60) return 'pack.json: nested too deep';
  final scale = json['scale'] ?? 1;
  if (!whole(scale, min: 1, max: petSheetSideCap)) return 'pack.json: scale';
  final canvas = json['canvas'];
  if (canvas is! Map || !whole(canvas['w'], min: 1) || !whole(canvas['h'], min: 1)) return 'pack.json: canvas';
  final animations = json['animations'];
  if (animations is! Map) return 'pack.json: animations';
  for (final MapEntry(:key, :value) in animations.entries) {
    if (value is! Map) return 'pack.json: animation $key';
    final fw = value['frameW'];
    final fh = value['frameH'];
    if (!whole(fw, min: 1, max: petSheetSideCap) ||
        !whole(fh, min: 1, max: petSheetSideCap) ||
        !whole(value['cols'], min: 1, max: petSheetSideCap)) {
      return 'pack.json: frames of $key';
    }
    final box = value['box'];
    if (box is! Map || box['w'] is! num || box['h'] is! num) return 'pack.json: animation $key';
    if (_kotlinCell(box['w'] as num, scale as num) != fw || _kotlinCell(box['h'] as num, scale) != fh) {
      return 'pack.json: frameW, frameH of $key ≠ box × scale';
    }
    final frames = value['frames'];
    if (frames is! List) return 'pack.json: frames of $key';
    for (final f in frames) {
      if (f is! Map || !whole(f['i']) || !whole(f['ms'], min: 1)) return 'pack.json: frames of $key';
    }
  }
  return null;
}

/// `(box × scale).toInt()` as PetPack.kt computes it: the box as a Float,
/// times the scale in Float, truncated.
int _kotlinCell(num box, num scale) {
  final f = Float32List(1)..[0] = box.toDouble();
  f[0] = f[0] * scale.toInt();
  return f[0].isFinite ? f[0].truncate() : -1;
}

/// How deep [value] nests (the overlay's JSON reader stops at 64).
int _depth(Object? value) => switch (value) {
  final Map<Object?, Object?> m => 1 + m.values.map(_depth).fold(0, math.max),
  final List<Object?> l => 1 + l.map(_depth).fold(0, math.max),
  _ => 0,
};
