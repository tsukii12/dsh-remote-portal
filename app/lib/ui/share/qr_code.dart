// A small QR Code encoder (byte mode, ISO/IEC 18004) and its painter, for the
// links on share cards and community groups. The structure follows the public
// description of the standard (and the layout of Project Nayuki's reference
// encoder); the module matrices are checked against libqrencode in
// test/share/qr_code_test.dart.
//
// Hand-written instead of a package: share cards only ever encode short URLs,
// ~300 lines cover it with no new dependency in the shared pubspec.
//
// A short link can carry the app's tile in its centre (QrCodeView.logo): the
// code moves to level H and leaves a plate of light modules for the tile, sized
// per version in QrCode.logoPlates. test/share/qr_logo_test.dart checks every
// plate against the function patterns and the error-correction budget.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../shell/brand_mark.dart';

/// Error correction level. M (~15 % recoverable) is the default for links.
enum QrEcc {
  low(1),
  medium(0),
  quartile(3),
  high(2);

  const QrEcc(this.formatBits);

  /// The two bits of the format information.
  final int formatBits;
}

/// An encoded QR Code: a square of dark / light modules, without quiet zone.
class QrCode {
  QrCode._(this.version, this.ecc, this.mask, this._modules);

  /// Encodes [text] (UTF-8, byte mode) in the smallest version from
  /// [minVersion] up that holds it at [ecc]. [mask] forces one of the eight
  /// masks (tests); by default the one with the lowest penalty is used.
  factory QrCode.encode(String text, {QrEcc ecc = QrEcc.medium, int? mask, int minVersion = 1}) {
    final data = utf8.encode(text);
    final version = versionFor(data.length, ecc, minVersion: minVersion);
    if (version == null) throw ArgumentError('Text too long for a QR Code');
    return _build(version, ecc, data, version < 10 ? 8 : 16, mask);
  }

  /// [text] at level H with room for a centred logo ([logoPlate]): the
  /// smallest version from [logoMinVersion] to [logoMaxVersion] that holds it
  /// (up to 58 bytes), or null when it needs more.
  static QrCode? withLogo(String text) {
    final data = utf8.encode(text);
    final version = versionFor(data.length, QrEcc.high, minVersion: logoMinVersion, maxVersion: logoMaxVersion);
    return version == null ? null : _build(version, QrEcc.high, data, 8, null);
  }

  /// The smallest version in [minVersion]–[maxVersion] that holds [bytes]
  /// bytes at [ecc]; null when none does.
  static int? versionFor(int bytes, QrEcc ecc, {int minVersion = 1, int maxVersion = 40}) {
    for (var version = minVersion; version <= maxVersion; version++) {
      final countBits = version < 10 ? 8 : 16;
      if (bytes >= 1 << countBits) continue;
      if (4 + countBits + bytes * 8 <= _dataCodewords(version, ecc) * 8) return version;
    }
    return null;
  }

  // ── A centred logo ─────────────────────────────────────────────────────────

  /// Side of the plate a centred logo clears, in modules, by version (level H
  /// only).
  ///
  /// The plate is the logo, about 22 % of the code's width, with one light
  /// module round it: an odd number of whole modules, so it centres on the
  /// middle module. Each keeps clear of every function pattern and covers at
  /// most a third of what level H corrects, leaving every block at least a
  /// third of its own correction for blur, glare and downscaling
  /// (test/share/qr_logo_test.dart):
  ///
  /// | version | side | plate | logo      | codewords touched, worst block |
  /// |---------|------|-------|-----------|--------------------------------|
  /// | 4       | 33   | 9     | 7 (21 %)  | 5 of the 8 it corrects         |
  /// | 5       | 37   | 9     | 7 (19 %)  | 4 of 11                        |
  /// | 6       | 41   | 11    | 9 (22 %)  | 6 of 14                        |
  ///
  /// Versions 1–3 leave no room for a mark worth drawing (short text is
  /// encoded at version 4 instead); 7–13 put an alignment pattern on the very
  /// centre; 14 and up stay plain, too dense to give modules up to a logo.
  static const logoPlates = {4: 9, 5: 9, 6: 11};
  static const logoMinVersion = 4;
  static const logoMaxVersion = 6;

  /// Where a centred logo may go on this code; null below level H or outside
  /// [logoPlates].
  QrLogoPlate? get logoPlate {
    final side = ecc == QrEcc.high ? logoPlates[version] : null;
    return side == null ? null : QrLogoPlate._((size - side) ~/ 2, side);
  }

  /// 1–40; the side is `4 * version + 17` modules.
  final int version;
  final QrEcc ecc;

  /// The mask applied (0–7).
  final int mask;
  final List<List<bool>> _modules;

  int get size => _modules.length;

  /// Whether the module at column [x], row [y] is dark.
  bool isDark(int x, int y) => _modules[y][x];

  static QrCode _build(int version, QrEcc ecc, List<int> data, int countBits, int? forcedMask) {
    // Bit stream: mode 0100, count, bytes, terminator, byte padding, pad codewords.
    final capacity = _dataCodewords(version, ecc) * 8;
    final bits = _BitBuffer()
      ..append(4, 4)
      ..append(data.length, countBits);
    for (final b in data) {
      bits.append(b, 8);
    }
    bits.append(0, (capacity - bits.length).clamp(0, 4));
    bits.append(0, (8 - bits.length % 8) % 8);
    for (var pad = 0xEC; bits.length < capacity; pad ^= 0xEC ^ 0x11) {
      bits.append(pad, 8);
    }
    final codewords = _interleave(version, ecc, bits.bytes());

    final grid = _Grid(version);
    grid.drawFunctionPatterns(ecc);
    grid.drawCodewords(codewords);

    var mask = forcedMask ?? -1;
    if (mask < 0) {
      var best = 1 << 30;
      for (var m = 0; m < 8; m++) {
        grid.applyMask(m);
        grid.drawFormatBits(ecc, m);
        final penalty = grid.penalty();
        if (penalty < best) {
          best = penalty;
          mask = m;
        }
        grid.applyMask(m); // XOR again undoes it
      }
    }
    grid.applyMask(mask);
    grid.drawFormatBits(ecc, mask);
    return QrCode._(version, ecc, mask, grid.modules);
  }

  // ── Capacity tables (index 0 unused) ──────────────────────────────────────

  // dart format off
  static const _eccPerBlock = <QrEcc, List<int>>{
    QrEcc.low:      [-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    QrEcc.medium:   [-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
    QrEcc.quartile: [-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
    QrEcc.high:     [-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
  };

  static const _blocks = <QrEcc, List<int>>{
    QrEcc.low:      [-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
    QrEcc.medium:   [-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
    QrEcc.quartile: [-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
    QrEcc.high:     [-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
  };
  // dart format on

  /// Modules left for data + ECC after the function patterns.
  static int _rawModules(int version) {
    var result = (16 * version + 128) * version + 64;
    if (version >= 2) {
      final align = version ~/ 7 + 2;
      result -= (25 * align - 10) * align - 55;
      if (version >= 7) result -= 36;
    }
    return result;
  }

  static int _dataCodewords(int version, QrEcc ecc) =>
      _rawModules(version) ~/ 8 - _eccPerBlock[ecc]![version] * _blocks[ecc]![version];

  /// Splits [data] into blocks, appends each block's Reed–Solomon ECC and
  /// interleaves them column by column.
  static Uint8List _interleave(int version, QrEcc ecc, List<int> data) {
    final blockCount = _blocks[ecc]![version];
    final eccLen = _eccPerBlock[ecc]![version];
    final raw = _rawModules(version) ~/ 8;
    final shortBlocks = blockCount - raw % blockCount;
    final shortLen = raw ~/ blockCount;
    final divisor = _rsDivisor(eccLen);
    final blocks = <List<int>>[];
    var k = 0;
    for (var i = 0; i < blockCount; i++) {
      final take = shortLen - eccLen + (i < shortBlocks ? 0 : 1);
      final block = data.sublist(k, k + take);
      k += take;
      final ecc = _rsRemainder(block, divisor);
      blocks.add([...block, if (i < shortBlocks) 0, ...ecc]);
    }
    final out = Uint8List(raw);
    var n = 0;
    for (var i = 0; i < blocks.first.length; i++) {
      for (var j = 0; j < blocks.length; j++) {
        // The short blocks' placeholder byte is not transmitted.
        if (i != shortLen - eccLen || j >= shortBlocks) out[n++] = blocks[j][i];
      }
    }
    return out;
  }

  static List<int> _rsDivisor(int degree) {
    final result = List<int>.filled(degree, 0)..[degree - 1] = 1;
    var root = 1;
    for (var i = 0; i < degree; i++) {
      for (var j = 0; j < degree; j++) {
        result[j] = _gfMul(result[j], root);
        if (j + 1 < degree) result[j] ^= result[j + 1];
      }
      root = _gfMul(root, 0x02);
    }
    return result;
  }

  static List<int> _rsRemainder(List<int> data, List<int> divisor) {
    final result = List<int>.filled(divisor.length, 0);
    for (final b in data) {
      final factor = b ^ result[0];
      result
        ..setRange(0, result.length - 1, result, 1)
        ..[result.length - 1] = 0;
      for (var i = 0; i < divisor.length; i++) {
        result[i] ^= _gfMul(divisor[i], factor);
      }
    }
    return result;
  }

  /// Multiplication in GF(2^8) modulo x^8 + x^4 + x^3 + x^2 + 1.
  static int _gfMul(int x, int y) {
    var z = 0;
    for (var i = 7; i >= 0; i--) {
      z = (z << 1) ^ ((z >> 7) * 0x11D);
      z ^= ((y >> i) & 1) * x;
    }
    return z & 0xFF;
  }
}

/// The square of modules a centred logo leaves light: [side] modules from
/// column and row [start]. The logo sits one module in from each edge.
@immutable
class QrLogoPlate {
  const QrLogoPlate._(this.start, this.side);

  final int start;
  final int side;

  /// First column and row of the logo.
  int get logoStart => start + 1;

  /// Side of the logo, in modules.
  int get logoSide => side - 2;

  bool contains(int x, int y) => x >= start && x < start + side && y >= start && y < start + side;
}

class _BitBuffer {
  final _bits = <bool>[];

  int get length => _bits.length;

  void append(int value, int count) {
    for (var i = count - 1; i >= 0; i--) {
      _bits.add((value >> i) & 1 == 1);
    }
  }

  List<int> bytes() {
    final out = List<int>.filled(_bits.length ~/ 8, 0);
    for (var i = 0; i < _bits.length; i++) {
      if (_bits[i]) out[i >> 3] |= 0x80 >> (i & 7);
    }
    return out;
  }
}

/// The module matrix while it is being drawn.
class _Grid {
  _Grid(this.version)
    : size = version * 4 + 17,
      modules = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false)),
      function = List.generate(version * 4 + 17, (_) => List.filled(version * 4 + 17, false));

  final int version;
  final int size;
  final List<List<bool>> modules;
  final List<List<bool>> function;

  void _set(int x, int y, bool dark) {
    modules[y][x] = dark;
    function[y][x] = true;
  }

  void drawFunctionPatterns(QrEcc ecc) {
    for (var i = 0; i < size; i++) {
      _set(6, i, i.isEven);
      _set(i, 6, i.isEven);
    }
    _finder(3, 3);
    _finder(size - 4, 3);
    _finder(3, size - 4);
    final align = _alignmentPositions();
    final last = align.length - 1;
    for (var i = 0; i < align.length; i++) {
      for (var j = 0; j < align.length; j++) {
        if ((i == 0 && j == 0) || (i == 0 && j == last) || (i == last && j == 0)) continue;
        _alignment(align[i], align[j]);
      }
    }
    drawFormatBits(ecc, 0); // reserves the area; redrawn with the real mask
    _versionBits();
  }

  void _finder(int cx, int cy) {
    for (var dy = -4; dy <= 4; dy++) {
      for (var dx = -4; dx <= 4; dx++) {
        final x = cx + dx, y = cy + dy;
        if (x < 0 || x >= size || y < 0 || y >= size) continue;
        final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        _set(x, y, dist != 2 && dist != 4);
      }
    }
  }

  void _alignment(int cx, int cy) {
    for (var dy = -2; dy <= 2; dy++) {
      for (var dx = -2; dx <= 2; dx++) {
        final dist = dx.abs() > dy.abs() ? dx.abs() : dy.abs();
        _set(cx + dx, cy + dy, dist != 1);
      }
    }
  }

  List<int> _alignmentPositions() {
    if (version == 1) return const [];
    final count = version ~/ 7 + 2;
    final step = (version * 8 + count * 3 + 5) ~/ (count * 4 - 4) * 2;
    final result = <int>[];
    for (var i = 0, pos = size - 7; i < count - 1; i++, pos -= step) {
      result.insert(0, pos);
    }
    return [6, ...result];
  }

  void drawFormatBits(QrEcc ecc, int mask) {
    final data = ecc.formatBits << 3 | mask;
    var rem = data;
    for (var i = 0; i < 10; i++) {
      rem = (rem << 1) ^ ((rem >> 9) * 0x537);
    }
    final bits = (data << 10 | rem) ^ 0x5412;
    bool bit(int i) => (bits >> i) & 1 == 1;
    for (var i = 0; i <= 5; i++) {
      _set(8, i, bit(i));
    }
    _set(8, 7, bit(6));
    _set(8, 8, bit(7));
    _set(7, 8, bit(8));
    for (var i = 9; i < 15; i++) {
      _set(14 - i, 8, bit(i));
    }
    for (var i = 0; i < 8; i++) {
      _set(size - 1 - i, 8, bit(i));
    }
    for (var i = 8; i < 15; i++) {
      _set(8, size - 15 + i, bit(i));
    }
    _set(8, size - 8, true); // the dark module
  }

  void _versionBits() {
    if (version < 7) return;
    var rem = version;
    for (var i = 0; i < 12; i++) {
      rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
    }
    final bits = version << 12 | rem;
    for (var i = 0; i < 18; i++) {
      final dark = (bits >> i) & 1 == 1;
      final a = size - 11 + i % 3, b = i ~/ 3;
      _set(a, b, dark);
      _set(b, a, dark);
    }
  }

  /// Places the codewords in the two-column zigzag, skipping function modules.
  void drawCodewords(List<int> data) {
    var i = 0;
    for (var right = size - 1; right >= 1; right -= 2) {
      if (right == 6) right = 5;
      for (var vert = 0; vert < size; vert++) {
        for (var j = 0; j < 2; j++) {
          final x = right - j;
          final upward = (right + 1) & 2 == 0;
          final y = upward ? size - 1 - vert : vert;
          if (!function[y][x] && i < data.length * 8) {
            modules[y][x] = (data[i >> 3] >> (7 - (i & 7))) & 1 == 1;
            i++;
          }
        }
      }
    }
  }

  /// XORs [mask] over the non-function modules (applying twice undoes it).
  void applyMask(int mask) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final invert = switch (mask) {
          0 => (x + y) % 2 == 0,
          1 => y % 2 == 0,
          2 => x % 3 == 0,
          3 => (x + y) % 3 == 0,
          4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
          5 => x * y % 2 + x * y % 3 == 0,
          6 => (x * y % 2 + x * y % 3) % 2 == 0,
          _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
        };
        if (invert && !function[y][x]) modules[y][x] = !modules[y][x];
      }
    }
  }

  /// The standard's mask penalty (runs, 2×2 blocks, finder look-alikes, balance).
  int penalty() {
    var result = 0;
    for (var pass = 0; pass < 2; pass++) {
      for (var a = 0; a < size; a++) {
        var runColor = false;
        var run = 0;
        final history = List<int>.filled(7, 0);
        for (var b = 0; b < size; b++) {
          final dark = pass == 0 ? modules[a][b] : modules[b][a];
          if (dark == runColor) {
            run++;
            if (run == 5) {
              result += 3;
            } else if (run > 5) {
              result++;
            }
          } else {
            _addHistory(run, history);
            if (!runColor) result += _finderLike(history) * 40;
            runColor = dark;
            run = 1;
          }
        }
        result += _terminate(runColor, run, history) * 40;
      }
    }
    for (var y = 0; y < size - 1; y++) {
      for (var x = 0; x < size - 1; x++) {
        final c = modules[y][x];
        if (c == modules[y][x + 1] && c == modules[y + 1][x] && c == modules[y + 1][x + 1]) result += 3;
      }
    }
    var dark = 0;
    for (final row in modules) {
      for (final m in row) {
        if (m) dark++;
      }
    }
    final total = size * size;
    final k = ((dark * 20 - total * 10).abs() + total - 1) ~/ total - 1;
    return result + k * 10;
  }

  void _addHistory(int run, List<int> history) {
    if (history[0] == 0) run += size; // light border before the first run
    for (var i = history.length - 1; i > 0; i--) {
      history[i] = history[i - 1];
    }
    history[0] = run;
  }

  int _finderLike(List<int> h) {
    final n = h[1];
    final core = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
    return (core && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (core && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
  }

  int _terminate(bool runColor, int run, List<int> history) {
    if (runColor) {
      _addHistory(run, history);
      run = 0;
    }
    run += size; // light border after the last run
    _addHistory(run, history);
    return _finderLike(history);
  }
}

/// Paints a [QrCode]: dark modules in [color] on a [background] square with
/// a [quietZone] of light modules around it (4 per the standard; 2 still
/// scans in every common reader and keeps small codes larger).
///
/// With [logo], the app's tile sits in the centre on a plate of [background]
/// (see [QrCode.logoPlates]).
class QrCodeView extends StatelessWidget {
  const QrCodeView({
    super.key,
    required this.data,
    this.size = 96,
    this.color = const Color(0xFF111318),
    this.background = const Color(0xFFFFFFFF),
    this.quietZone = 2,
    this.ecc = QrEcc.medium,
    this.logo = false,
    this.semanticLabel,
  });

  final String data;
  final double size;
  final Color color;
  final Color background;
  final int quietZone;
  final QrEcc ecc;

  /// Centre the app's tile on the code when [data] is short enough to carry
  /// it at level H ([QrCode.withLogo]) with modules no finer than
  /// [logoMinModule]; otherwise the code is drawn plain at [ecc].
  final bool logo;

  final String? semanticLabel;

  /// The tile in the centre, when there is one.
  static const logoKey = ValueKey('qr-logo');

  /// The finest module, in logical pixels, a code with a logo is drawn at.
  ///
  /// Level H needs a version or two more than M, so its modules are finer.
  /// Measured on share-card codes in halved exports with zxing-cpp: 1.36 a
  /// module (version 6 at 64) misread, logo or not; 1.49 and up held. The
  /// card's 72 takes every logo version (6 is 1.53).
  static const logoMinModule = 1.45;

  static final _cache = <(String, QrEcc, bool), QrCode?>{};

  static QrCode? _cached(String data, QrEcc ecc, bool logo, QrCode? Function() make) {
    if (_cache.length > 32) _cache.clear();
    return _cache.putIfAbsent((data, ecc, logo), make);
  }

  /// The code drawn for [data] in a [size] square with [quietZone] modules
  /// round it, and the plate its logo clears: with a logo when [logo] asks for
  /// one, [data] fits ([QrCode.withLogo]) and its modules stay at least
  /// [logoMinModule] wide; else plain at [ecc], with no plate.
  static (QrCode, QrLogoPlate?) codeFor(
    String data,
    QrEcc ecc, {
    bool logo = false,
    double size = double.infinity,
    int quietZone = 2,
  }) {
    if (logo) {
      final code = _cached(data, QrEcc.high, true, () => QrCode.withLogo(data));
      if (code != null && size / (code.size + quietZone * 2) >= logoMinModule) return (code, code.logoPlate);
    }
    return (_cached(data, ecc, false, () => QrCode.encode(data, ecc: ecc))!, null);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final (code, plate) = codeFor(data, ecc, logo: logo, size: size, quietZone: quietZone);
    final cell = size / (code.size + quietZone * 2);
    final modules = CustomPaint(
      size: Size.square(size),
      painter: _QrPainter(code, color, background, quietZone, plate),
    );
    return Semantics(
      image: true,
      label: semanticLabel ?? l10n.viewQrCode,
      child: SizedBox.square(
        dimension: size,
        child: plate == null
            ? modules
            : Stack(
                children: [
                  modules,
                  // On whole modules, so the plate's light ring is one module on
                  // every side and the tile's centre is the code's.
                  Positioned(
                    left: (quietZone + plate.logoStart) * cell,
                    top: (quietZone + plate.logoStart) * cell,
                    width: plate.logoSide * cell,
                    height: plate.logoSide * cell,
                    child: ExcludeSemantics(
                      child: BrandMark(key: logoKey, size: plate.logoSide * cell, tile: true),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.code, this.color, this.background, this.quietZone, this.plate);

  final QrCode code;
  final Color color;
  final Color background;
  final int quietZone;

  /// Left light under the logo.
  final QrLogoPlate? plate;

  bool _dark(int x, int y) => code.isDark(x, y) && !(plate?.contains(x, y) ?? false);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = background);
    final cells = code.size + quietZone * 2;
    final cell = size.shortestSide / cells;
    final path = Path();
    for (var y = 0; y < code.size; y++) {
      var x = 0;
      while (x < code.size) {
        if (!_dark(x, y)) {
          x++;
          continue;
        }
        // One rectangle per horizontal run: no hairline seams between modules.
        var end = x;
        while (end < code.size && _dark(end, y)) {
          end++;
        }
        path.addRect(Rect.fromLTWH((x + quietZone) * cell, (y + quietZone) * cell, (end - x) * cell, cell));
        x = end;
      }
    }
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_QrPainter old) =>
      old.code != code ||
      old.color != color ||
      old.background != background ||
      old.quietZone != quietZone ||
      old.plate?.side != plate?.side;
}
