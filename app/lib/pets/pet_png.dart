part of 'pet_pack_validator.dart';

/// Header probe retained for callers; import validation always checks the
/// complete PNG, including CRCs, bounded IDAT and an actual pixel decode.
(int, int)? pngSize(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 24) return null;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != signature[i]) return null;
  }
  if (String.fromCharCodes(bytes.sublist(12, 16)) != 'IHDR') return null;
  final data = ByteData.sublistView(bytes);
  return (data.getUint32(16), data.getUint32(20));
}

/// Whether a sheet passes the same complete, bounded check used on import.
/// Retained for existing callers; there is only one PNG validation path.
bool pngIntact(Uint8List bytes) {
  try {
    _validatePng(bytes, 'sheet');
    return true;
  } on Object {
    return false;
  }
}

(int, int) _validatePng(Uint8List bytes, String path) {
  _require(bytes.length <= petSheetByteCap, 'sheet-size', path);
  final size = pngSize(bytes);
  _require(size != null && bytes.length >= 33, 'png-header', path);
  final (w, h) = size!;
  _require(
    w > 0 && h > 0 && w <= petSheetSideCap && h <= petSheetSideCap && w * h * 4 <= petSheetDecodedCap,
    'sheet-decoded-size',
    path,
  );
  final data = ByteData.sublistView(bytes);
  _require(data.getUint32(8) == 13, 'png-header', path);
  final depth = bytes[24], color = bytes[25], interlace = bytes[28];
  const depths = {
    0: [1, 2, 4, 8, 16],
    2: [8, 16],
    3: [1, 2, 4, 8],
    4: [8, 16],
    6: [8, 16],
  };
  const channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4};
  _require(depths[color]?.contains(depth) ?? false, 'png-format', path);
  _require(bytes[26] == 0 && bytes[27] == 0 && interlace <= 1, 'png-format', path);
  final idat = BytesBuilder(copy: false);
  // The shared rules define a pixel decode of rendering chunks only. Every
  // original chunk's CRC and compressed metadata are still checked first;
  // unrelated ancillary handling must not differ between Pillow and Dart.
  final rendering = BytesBuilder(copy: false)..add(Uint8List.sublistView(bytes, 0, 8));
  var at = 8, paletteEntries = 0, metadataBytes = 0;
  var ended = false, sawIdat = false, idatEnded = false, sawTransparency = false;
  while (at < bytes.length) {
    _require(at + 12 <= bytes.length, 'png-chunk', path);
    final length = data.getUint32(at);
    _require(length <= bytes.length - at - 12, 'png-chunk', path);
    final kind = String.fromCharCodes(Uint8List.sublistView(bytes, at + 4, at + 8));
    _require(kind.codeUnits.every((c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122)), 'png-chunk-type', path);
    _require(
      getCrc32(Uint8List.sublistView(bytes, at + 4, at + 8 + length)) == data.getUint32(at + 8 + length),
      'png-crc',
      path,
    );
    _require(!const {'acTL', 'fcTL', 'fdAT'}.contains(kind), 'png-animated', path);
    _require(kind != 'IHDR' || at == 8, 'png-duplicate-header', path);
    _require(
      bytes[at + 4] & 32 != 0 || const {'IHDR', 'PLTE', 'IDAT', 'IEND'}.contains(kind),
      'png-critical-chunk',
      path,
    );
    if (const {'iCCP', 'zTXt', 'iTXt', 'tEXt'}.contains(kind)) {
      metadataBytes += _pngMetadataSize(
        kind,
        Uint8List.sublistView(bytes, at + 8, at + 8 + length),
        petPngMetadataTotalCap - metadataBytes,
        path,
      );
    }
    if (kind == 'PLTE') {
      _require(
        !sawIdat &&
            !sawTransparency &&
            paletteEntries == 0 &&
            color != 0 &&
            color != 4 &&
            length > 0 &&
            length <= 768 &&
            length % 3 == 0,
        'png-palette',
        path,
      );
      paletteEntries = length ~/ 3;
      if (color == 3) _require(paletteEntries <= 1 << depth, 'png-palette', path);
    }
    if (kind == 'tRNS') {
      _require(
        !sawIdat &&
            !sawTransparency &&
            ((color == 0 && length == 2) ||
                (color == 2 && length == 6) ||
                (color == 3 && paletteEntries > 0 && length > 0 && length <= paletteEntries)),
        'png-transparency',
        path,
      );
      sawTransparency = true;
    }
    if (kind == 'IDAT') {
      _require(!idatEnded && (color != 3 || paletteEntries > 0), 'png-idat-order', path);
      sawIdat = true;
      idat.add(Uint8List.sublistView(bytes, at + 8, at + 8 + length));
    } else if (sawIdat) {
      idatEnded = true;
    }
    if (const {'IHDR', 'PLTE', 'tRNS', 'IDAT', 'IEND'}.contains(kind)) {
      rendering.add(Uint8List.sublistView(bytes, at, at + length + 12));
    }
    at += length + 12;
    if (kind == 'IEND') {
      _require(length == 0 && at == bytes.length, 'png-trailing', path);
      ended = true;
      break;
    }
  }
  _require(ended && sawIdat, 'png-truncated', path);
  final bitsPerPixel = channels[color]! * depth;
  final rows = <(int, int)>[]; // row byte count, pass height
  if (interlace == 0) {
    rows.add(((w * bitsPerPixel + 7) ~/ 8, h));
  } else {
    for (final pass in const [
      (0, 0, 8, 8),
      (4, 0, 8, 8),
      (0, 4, 4, 8),
      (2, 0, 4, 4),
      (0, 2, 2, 4),
      (1, 0, 2, 2),
      (0, 1, 1, 2),
    ]) {
      final (x, y, dx, dy) = pass;
      final pw = w <= x ? 0 : (w - x + dx - 1) ~/ dx;
      final ph = h <= y ? 0 : (h - y + dy - 1) ~/ dy;
      if (pw > 0 && ph > 0) rows.add(((pw * bitsPerPixel + 7) ~/ 8, ph));
    }
  }
  final expected = rows.fold<int>(0, (sum, row) => sum + (row.$1 + 1) * row.$2);
  final compressed = idat.takeBytes();
  final inflated = _pngZlib(compressed, expected, 'png', path, reserveFull: true);
  _require(inflated.length == expected, 'png-member-size', path);
  var rowStart = 0;
  for (final (stride, count) in rows) {
    for (var row = 0; row < count; row++) {
      _require(inflated[rowStart] <= 4, 'png-filter', path);
      rowStart += stride + 1;
    }
  }
  try {
    final decoded = image.PngDecoder().decode(rendering.takeBytes());
    _require(
      decoded != null && decoded.width == w && decoded.height == h && decoded.numFrames == 1,
      'png-decode',
      path,
    );
  } on PetValidationException {
    rethrow;
  } on Object {
    throw PetValidationException('png-decode', path);
  }
  return (w, h);
}

Uint8List _pngZlib(Uint8List compressed, int cap, String kind, String path, {bool reserveFull = false}) {
  _require(
    compressed.length >= 6 &&
        compressed[0] & 15 == 8 &&
        compressed[0] >> 4 <= 7 &&
        (compressed[0] * 256 + compressed[1]) % 31 == 0 &&
        compressed[1] & 32 == 0,
    '$kind-zlib-header',
    path,
  );
  final inflated = _inflateAtMost(
    Uint8List.sublistView(compressed, 2, compressed.length - 4),
    cap,
    kind,
    path,
    reserveFull: reserveFull,
  );
  _require(
    _adler32(inflated) == ByteData.sublistView(compressed).getUint32(compressed.length - 4),
    '$kind-adler',
    path,
  );
  return inflated;
}

int _pngMetadataSize(String kind, Uint8List data, int remaining, String path) {
  final keywordEnd = data.indexOf(0);
  _require(keywordEnd >= 1 && keywordEnd <= 79, 'png-metadata', path);
  var start = keywordEnd + 1;
  var compressed = false;
  if (kind == 'iCCP' || kind == 'zTXt') {
    _require(start < data.length && data[start] == 0, 'png-metadata', path);
    start++;
    compressed = true;
  } else if (kind == 'iTXt') {
    _require(start + 2 <= data.length && data[start] <= 1 && data[start + 1] == 0, 'png-metadata', path);
    compressed = data[start] == 1;
    start += 2;
    final languageEnd = data.indexOf(0, start);
    _require(languageEnd >= start, 'png-metadata', path);
    final translatedEnd = data.indexOf(0, languageEnd + 1);
    _require(translatedEnd > languageEnd, 'png-metadata', path);
    start = translatedEnd + 1;
  }
  final text = Uint8List.sublistView(data, start);
  if (!compressed) {
    _require(text.length <= remaining, 'png-metadata-total-size', path);
    return text.length;
  }
  final cap = remaining < petPngMetadataChunkCap ? remaining : petPngMetadataChunkCap;
  return _pngZlib(text, cap, 'png-metadata', path).length;
}

int _adler32(Uint8List bytes) {
  var a = 1, b = 0;
  for (var start = 0; start < bytes.length; start += 5552) {
    final stop = start + 5552 < bytes.length ? start + 5552 : bytes.length;
    for (var i = start; i < stop; i++) {
      a += bytes[i];
      b += a;
    }
    a %= 65521;
    b %= 65521;
  }
  return (b << 16) | a;
}
