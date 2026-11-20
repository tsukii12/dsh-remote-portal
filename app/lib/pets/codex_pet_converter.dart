// Codex CLI's pet.json (openai/codex 33b3f80a, pets/model.rs) and the
// OpenAI Work Pets 0.1.6 fixed v2 atlas. Their control/state machines differ:
// this adapter retains the source tracks but binds them to DSH's states.

import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;

import 'pet_pack_validator.dart';
import 'pet_unicode_data.g.dart' show petUnicodeWhitespace;

class CodexPetConversion {
  const CodexPetConversion(this.validated, this.spriteVersionNumber, this.warnings);

  final ValidatedPetPack validated;
  final int spriteVersionNumber;

  /// Stable codes, also saved in pack.json's codexImport.warnings.
  final List<String> warnings;
}

/// Converts a ZIP's pet.json and local PNG/WebP to a validated schema-1 pack.
/// No paths are extracted and no resources are downloaded. PNG bytes are kept;
/// static WebP is decoded and encoded as one PNG with the same pixel grid.
abstract final class CodexPetConverter {
  static CodexPetConversion convertArchive(
    Uint8List zip, {
    PetValidationProfile profile = PetValidationProfile.local,
  }) => convert(PetArchive.read(zip), profile: profile);

  static CodexPetConversion convert(PetArchive archive, {PetValidationProfile profile = PetValidationProfile.local}) {
    final candidates = archive.manifestPaths('pet.json');
    if (candidates.length != 1) {
      throw const PetValidationException('codex-manifest');
    }
    final manifestName = candidates.single;
    final prefix = manifestName.substring(0, manifestName.length - 'pet.json'.length);
    final metadata = decodePetJson(archive.readFile(manifestName, maxBytes: petJsonCap));
    if (metadata is! Map<String, Object?>) throw const PetValidationException('codex-metadata');

    final versionValue = metadata.containsKey('spriteVersionNumber') ? metadata['spriteVersionNumber'] : 1;
    if (versionValue is! int || (versionValue != 1 && versionValue != 2)) {
      throw const PetValidationException('codex-version', 'spriteVersionNumber');
    }
    final version = versionValue;
    final sourceName = _text(metadata, 'spritesheetPath');
    // Whitespace only selects the CLI default. An authored filename is exact,
    // including a leading BOM or space retained by the ZIP name decoder.
    final source = sourceName == null || sourceName.trim().isEmpty ? 'spritesheet.webp' : sourceName;
    if (source.isEmpty ||
        source.length > petSheetNameCap ||
        source.startsWith('.') ||
        source.contains('/') ||
        source.contains('\\') ||
        source.contains('\u0000') ||
        !(source.toLowerCase().endsWith('.png') || source.toLowerCase().endsWith('.webp'))) {
      throw const PetValidationException('codex-sheet-name', 'spritesheetPath');
    }
    final sourcePath = '$prefix$source';
    if (!archive.fileNames.contains(sourcePath)) throw PetValidationException('sheet-missing', sourcePath);
    final bytes = archive.readFile(sourcePath, maxBytes: petSheetByteCap);
    final height = version == 1 ? 1872 : 2288;
    final grid = _grid(metadata['frame'], version, height);
    final isWebp = source.toLowerCase().endsWith('.webp');
    final png = isWebp ? _webpToPng(bytes, height) : bytes;
    if (pngSize(png) != (1536, height)) throw const PetValidationException('codex-atlas-size');
    final sheet = isWebp ? '${source.substring(0, source.length - 5)}.png' : source;

    final warnings = <String>[
      'dsh-state-loops-replace-codex-settle-to-idle',
      'roam-left-mirrors-right-track',
      'drag-direction-uses-right-track',
      'sleep-uses-first-idle-frame',
      if (version == 2) 'look-directions-not-bound',
      if (isWebp) 'webp-transcoded-to-png',
    ];
    final tracks = _defaultTracks();
    if (metadata.containsKey('animations') && metadata['animations'] == null) {
      throw const PetValidationException('codex-animations');
    }
    _overrides(metadata['animations'], tracks, warnings, version);
    for (final entry in tracks.entries) {
      if (entry.value.frames.any((frame) => frame.$1 >= grid.cols * grid.rows)) {
        throw PetValidationException('codex-frame-index', entry.key);
      }
    }
    final idText = _text(metadata, 'id')?.trim();
    final id = idText == null || idText.isEmpty ? 'codex-${sha256.convert(bytes).toString().substring(0, 16)}' : idText;
    final displayName = _text(metadata, 'displayName')?.trim();
    final description = _text(metadata, 'description');
    final attribution = <String, Object?>{};
    for (final key in ['author', 'license', 'source']) {
      final value = _text(metadata, key);
      if (value != null) attribution[key] = value;
      if (value == null || value.runes.every((cp) => petUnicodeWhitespace.contains(cp))) {
        warnings.add('missing-$key');
      }
    }
    final animationJson = <String, Object?>{
      for (final entry in tracks.entries)
        entry.key: {
          'sheet': sheet,
          'frameW': grid.width,
          'frameH': grid.height,
          'cols': grid.cols,
          'box': {'x': 0, 'y': 0, 'w': grid.width, 'h': grid.height},
          'loop': entry.value.loop,
          'frames': [
            for (final frame in entry.value.frames) {'i': frame.$1, 'ms': frame.$2},
          ],
        },
    };
    // A private name cannot collide with any author-defined track.
    var sleepName = 'dsh-sleep';
    while (tracks.containsKey(sleepName)) {
      sleepName = '$sleepName-';
    }
    animationJson[sleepName] = {
      'sheet': sheet,
      'frameW': grid.width,
      'frameH': grid.height,
      'cols': grid.cols,
      'box': {'x': 0, 'y': 0, 'w': grid.width, 'h': grid.height},
      'loop': true,
      'frames': [
        {'i': tracks['idle']!.frames.first.$1, 'ms': 1000},
      ],
    };
    final json = <String, Object?>{
      'schema': 1,
      'id': id,
      'name': displayName == null || displayName.isEmpty ? id : displayName,
      ...attribution,
      'description': ?description,
      'pixelArt': false,
      'scale': 1,
      'canvas': {'w': grid.width, 'h': grid.height},
      'anchor': {'x': grid.width ~/ 2, 'baseline': grid.height},
      'contentBox': {'x': 0, 'y': 0, 'w': grid.width, 'h': grid.height},
      'animations': animationJson,
      'states': {
        'idle': ['idle'],
        'thinking': ['waiting'],
        'working': ['running'],
        'juggling': ['running'],
        'notification': ['waiting'],
        'attention': ['review'],
        'error': ['failed'],
        'sweeping': ['running'],
        'carrying': ['running'],
        'sleeping': [sleepName],
        'waking': ['jumping'],
      },
      'reactions': {'tapLeft': 'waving', 'tapRight': 'waving', 'tickle': 'jumping', 'drag': 'running-right'},
      'roam': {'anim': 'running-right', 'faces': 'right'},
      // Prevent Kotlin's default two-loop reaction duration from diverging
      // from Flutter's default one-loop duration.
      'timings': {
        'playMs': {for (final entry in tracks.entries) entry.key: entry.value.duration},
      },
      'codexImport': {
        'profile': version == 1 ? 'codex-cli-v1' : 'work-fixed-v2',
        'spriteVersionNumber': version,
        'sourceSheet': source,
        'sourceSha256': sha256.convert(bytes).toString(),
        'warnings': warnings,
      },
    };
    final checked = PetPackValidator.validateParts(json, {sheet: png}, profile: profile);
    final validated = ValidatedPetPack(
      json: checked.json,
      pack: checked.pack,
      sheets: checked.sheets,
      dropped: List.unmodifiable(archive.fileNames.difference({manifestName, sourcePath}).toList()..sort()),
    );
    return CodexPetConversion(validated, version, List.unmodifiable(warnings));
  }
}

String? _text(Map<String, Object?> metadata, String key) {
  final value = metadata[key];
  if (value == null) return null;
  if (value is! String) throw PetValidationException('codex-metadata', key);
  return value;
}

({int width, int height, int cols, int rows}) _grid(Object? raw, int version, int atlasHeight) {
  final standard = (width: 192, height: 208, cols: 8, rows: version == 1 ? 9 : 11);
  if (raw == null) return standard;
  if (raw is! Map) throw const PetValidationException('codex-frame', 'frame');
  final values = [
    for (final key in ['width', 'height', 'columns', 'rows']) raw[key],
  ];
  if (values.any((value) => value is! int || value <= 0 || value > 4096)) {
    throw const PetValidationException('codex-frame', 'frame');
  }
  final grid = (width: values[0] as int, height: values[1] as int, cols: values[2] as int, rows: values[3] as int);
  if (grid.width * grid.cols != 1536 || grid.height * grid.rows != atlasHeight || grid.cols * grid.rows > 256) {
    throw const PetValidationException('codex-frame', 'frame');
  }
  if (version == 2 && grid != standard) throw const PetValidationException('codex-frame-version', 'frame');
  return grid;
}

class _Track {
  const _Track(this.frames, {this.loop = true});
  final List<(int, int)> frames;
  final bool loop;
  int get duration => frames.fold(0, (sum, frame) => sum + frame.$2);
}

Map<String, _Track> _defaultTracks() {
  _Track row(int row, int count, int ms, int lastMs) =>
      _Track([for (var col = 0; col < count; col++) (row * 8 + col, col == count - 1 ? lastMs : ms)]);
  final tracks = <String, _Track>{
    'idle': const _Track([(0, 1680), (1, 660), (2, 660), (3, 840), (4, 840), (5, 1920)]),
    'running-right': row(1, 8, 120, 220),
    'running-left': row(2, 8, 120, 220),
    'waving': row(3, 4, 140, 280),
    'jumping': row(4, 5, 140, 280),
    'failed': row(5, 8, 140, 240),
    'waiting': row(6, 6, 150, 260),
    'running': row(7, 6, 120, 220),
    'review': row(8, 6, 150, 280),
  };
  for (final alias in {
    'move_right': 'running-right',
    'move_left': 'running-left',
    'wave': 'waving',
    'bounce': 'jumping',
    'sad': 'failed',
  }.entries) {
    tracks[alias.key] = tracks[alias.value]!;
  }
  return tracks;
}

void _overrides(Object? raw, Map<String, _Track> tracks, List<String> warnings, int version) {
  if (raw == null) return;
  if (raw is! Map<String, Object?>) throw const PetValidationException('codex-animations');
  if (version == 2 && raw.isNotEmpty) throw const PetValidationException('codex-animations-version');
  final names = {...tracks.keys, ...raw.keys};
  const bound = {'idle', 'running-right', 'waving', 'jumping', 'failed', 'waiting', 'running', 'review'};
  for (final entry in raw.entries) {
    final value = entry.value;
    if (value is! Map<String, Object?> || value['frames'] is! List) {
      throw PetValidationException('codex-animation', entry.key);
    }
    final frames = value['frames'] as List;
    final fps = value['fps'] ?? 8;
    final loop = value['loop'] ?? true;
    final fallback = value.containsKey('fallback') ? value['fallback'] : '';
    if (frames.isEmpty ||
        frames.any((v) => v is! int || v < 0 || v >= 256) ||
        fps is! num ||
        !fps.isFinite ||
        fps <= 0 ||
        fps > 60 ||
        loop is! bool ||
        fallback is! String) {
      throw PetValidationException('codex-animation', entry.key);
    }
    if (fallback.isNotEmpty && !names.contains(fallback)) {
      throw PetValidationException('codex-fallback-reference', entry.key);
    }
    if (!loop && fallback.isNotEmpty && fallback != 'idle') {
      throw PetValidationException('codex-fallback-unsupported', entry.key);
    }
    final milliseconds = 1000 / fps;
    if (!milliseconds.isFinite || milliseconds > 0x7fffffff || milliseconds.round() * frames.length > 0x7fffffff) {
      throw PetValidationException('codex-animation-duration', entry.key);
    }
    final ms = milliseconds.round();
    if (milliseconds != ms && !warnings.contains('fps-rounded-to-milliseconds')) {
      warnings.add('fps-rounded-to-milliseconds');
    }
    if (!loop && !warnings.contains('one-shot-return-controlled-by-dsh')) {
      warnings.add('one-shot-return-controlled-by-dsh');
    }
    if (!bound.contains(entry.key) && !warnings.contains('custom-tracks-not-bound')) {
      warnings.add('custom-tracks-not-bound');
    }
    tracks[entry.key] = _Track([for (final index in frames) (index as int, ms)], loop: loop);
  }
}

Uint8List _webpToPng(Uint8List bytes, int height) {
  // image.startDecode parses headers without decoding pixels. Also check the
  // complete RIFF envelope ourselves: do not silently accept trailing bytes,
  // two bitstreams, malformed lengths, or animation chunks behind a flag.
  if (bytes.length < 20) throw const PetValidationException('codex-webp-header');
  final data = ByteData.sublistView(bytes);
  String tag(int at) => String.fromCharCodes(bytes.sublist(at, at + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WEBP' || data.getUint32(4, Endian.little) != bytes.length - 8) {
    throw const PetValidationException('codex-webp-header');
  }
  var at = 12;
  var bitstreams = 0;
  final seen = <String>{};
  while (at < bytes.length) {
    if (bytes.length - at < 8) throw const PetValidationException('codex-webp-chunk');
    final type = tag(at);
    final size = data.getUint32(at + 4, Endian.little);
    final start = at + 8;
    final end = start + size + (size & 1);
    if (end > bytes.length || (size.isOdd && bytes[end - 1] != 0)) {
      throw const PetValidationException('codex-webp-chunk');
    }
    if (type == 'ANIM' || type == 'ANMF') throw const PetValidationException('codex-webp-animated');
    if (const {'VP8X', 'VP8 ', 'VP8L', 'ALPH', 'ICCP', 'EXIF', 'XMP '}.contains(type) && !seen.add(type)) {
      throw const PetValidationException('codex-webp-chunk');
    }
    if (type == 'VP8X') {
      if (at != 12 || size != 10) throw const PetValidationException('codex-webp-chunk');
      if (bytes[start] & 2 != 0) throw const PetValidationException('codex-webp-animated');
      if (bytes[start] & 0xc1 != 0 || bytes[start + 1] != 0 || bytes[start + 2] != 0 || bytes[start + 3] != 0) {
        throw const PetValidationException('codex-webp-header');
      }
      int u24(int offset) => bytes[offset] | bytes[offset + 1] << 8 | bytes[offset + 2] << 16;
      if ((u24(start + 4) + 1, u24(start + 7) + 1) != (1536, height)) {
        throw const PetValidationException('codex-atlas-size');
      }
    }
    if (type == 'VP8 ' || type == 'VP8L') bitstreams++;
    at = end;
  }
  if (bitstreams != 1) throw const PetValidationException('codex-webp-chunk');
  try {
    final decoder = image.WebPDecoder()..maxPixels = petSheetDecodedCap ~/ 4;
    final info = decoder.startDecode(bytes);
    if (info == null) throw const PetValidationException('codex-webp-decode');
    if (info.hasAnimation || info.numFrames > 1) throw const PetValidationException('codex-webp-animated');
    if ((info.width, info.height) != (1536, height)) throw const PetValidationException('codex-atlas-size');
    final decoded = decoder.decodeFrame(0);
    if (decoded == null || (decoded.width, decoded.height) != (1536, height) || decoded.numFrames != 1) {
      throw const PetValidationException('codex-webp-decode');
    }
    final encoded = image.encodePng(decoded, level: 6, singleFrame: true);
    if (encoded.length > petSheetByteCap) throw const PetValidationException('sheet-size');
    return encoded;
  } on PetValidationException {
    rethrow;
  } catch (_) {
    throw const PetValidationException('codex-webp-decode');
  }
}
