// The centred logo on a QR code (QrCode.logoPlates), checked against the
// standard rather than against the encoder:
//
// - the plate never covers a finder (with its separator), timing, alignment,
//   format or version module, and sits exactly on the centre;
// - the codewords under it stay within budget: at most a third of what level
//   H corrects, counted in modules, and every block keeps at least a third of
//   its own correction for blur, glare and downscaling.
//
// Function patterns and codeword positions come from ISO/IEC 18004 (Annex E,
// Table 9, the zigzag placement of 7.7.3), worked out here independently; the
// model is proven by reading the text back out of codes the encoder made.
//
// The logo itself: drawn on whole modules, its centre the code's.

import 'dart:convert';

import 'package:dsh_app/ui/share/qr_code.dart';
import 'package:dsh_app/ui/shell/brand_mark.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Annex E: alignment pattern centres (rows and columns) by version.
const _alignment = <int, List<int>>{
  1: [],
  2: [6, 18],
  3: [6, 22],
  4: [6, 26],
  5: [6, 30],
  6: [6, 34],
  7: [6, 22, 38],
  8: [6, 24, 42],
  9: [6, 26, 46],
  10: [6, 28, 50],
  11: [6, 30, 54],
  12: [6, 32, 58],
  13: [6, 34, 62],
};

/// Table 9, level H: groups of (blocks, codewords per block, data codewords per block).
const _blocksH = <int, List<(int, int, int)>>{
  4: [(4, 25, 9)],
  5: [(2, 33, 11), (2, 34, 12)],
  6: [(4, 43, 15)],
};

int _side(int version) => 4 * version + 17;

/// What a module at ([x], [y]) is part of, or null for a data module.
String? _function(int version, int x, int y) {
  final n = _side(version);
  bool inSquare(int x0, int y0, int side) => x >= x0 && x < x0 + side && y >= y0 && y < y0 + side;
  // Finders with their one-module separators.
  if (inSquare(0, 0, 8) || inSquare(n - 8, 0, 8) || inSquare(0, n - 8, 8)) return 'finder';
  if (x == 6 || y == 6) return 'timing';
  final centres = _alignment[version]!;
  for (final cx in centres) {
    for (final cy in centres) {
      final onFinder = (cx == 6 && cy == 6) || (cx == 6 && cy == centres.last) || (cx == centres.last && cy == 6);
      if (!onFinder && (x - cx).abs() <= 2 && (y - cy).abs() <= 2) return 'alignment';
    }
  }
  if ((x == 8 && (y <= 8 || y >= n - 8)) || (y == 8 && (x <= 8 || x >= n - 8))) return 'format';
  if (version >= 7 && ((x >= n - 11 && x < n - 8 && y < 6) || (y >= n - 11 && y < n - 8 && x < 6))) return 'version';
  return null;
}

/// The codeword index each data module carries (7.7.3: two-column zigzag from
/// the bottom right, skipping the timing column); -1 for function and
/// remainder modules.
List<List<int>> _codewordMap(int version) {
  final n = _side(version);
  final map = List.generate(n, (_) => List.filled(n, -1));
  final total = _blocksH[version]!.fold(0, (sum, g) => sum + g.$1 * g.$2);
  var bit = 0;
  var upward = true;
  for (var right = n - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    for (var i = 0; i < n; i++) {
      final y = upward ? n - 1 - i : i;
      for (final x in [right, right - 1]) {
        if (_function(version, x, y) != null) continue;
        if (bit < total * 8) map[y][x] = bit ~/ 8;
        bit++;
      }
    }
    upward = !upward;
  }
  return map;
}

/// The block each codeword of the interleaved stream belongs to (8.6: data
/// codewords column by column across the blocks, then the error correction).
List<int> _blockOf(int version) {
  final blocks = [
    for (final (count, total, data) in _blocksH[version]!)
      for (var i = 0; i < count; i++) (total, data),
  ];
  final out = <int>[];
  final longest = blocks.map((b) => b.$2).reduce((a, b) => a > b ? a : b);
  for (var i = 0; i < longest; i++) {
    for (var j = 0; j < blocks.length; j++) {
      if (i < blocks[j].$2) out.add(j);
    }
  }
  for (var i = 0; i < blocks.first.$1 - blocks.first.$2; i++) {
    for (var j = 0; j < blocks.length; j++) {
      out.add(j);
    }
  }
  return out;
}

bool _masked(int mask, int x, int y) => switch (mask) {
  0 => (x + y) % 2 == 0,
  1 => y % 2 == 0,
  2 => x % 3 == 0,
  3 => (x + y) % 3 == 0,
  4 => (x ~/ 3 + y ~/ 2) % 2 == 0,
  5 => x * y % 2 + x * y % 3 == 0,
  6 => (x * y % 2 + x * y % 3) % 2 == 0,
  _ => ((x + y) % 2 + x * y % 3) % 2 == 0,
};

/// The text of a byte-mode level-H [code], read back through the model above.
String _readBack(QrCode code) {
  final version = code.version;
  final map = _codewordMap(version);
  final blockOf = _blockOf(version);
  // Codewords in stream order, each from its eight modules in placement order
  // (most significant bit first), the mask taken off.
  final ordered = List.filled(blockOf.length, 0);
  final seen = List.filled(blockOf.length, 0);
  for (final (x, y) in _placementOrder(version)) {
    final i = map[y][x];
    if (i < 0) continue;
    final dark = code.isDark(x, y) != _masked(code.mask, x, y);
    ordered[i] |= (dark ? 1 : 0) << (7 - seen[i]++);
  }
  expect(seen.every((b) => b == 8), isTrue, reason: 'every codeword gets eight modules');
  // De-interleave the data codewords.
  final groups = [
    for (final (count, _, _) in _blocksH[version]!)
      for (var i = 0; i < count; i++) <int>[],
  ];
  final dataLengths = [
    for (final (count, _, data) in _blocksH[version]!)
      for (var i = 0; i < count; i++) data,
  ];
  final dataTotal = dataLengths.reduce((a, b) => a + b);
  for (var i = 0; i < dataTotal; i++) {
    groups[blockOf[i]].add(ordered[i]);
  }
  final data = [for (final g in groups) ...g];
  // Mode 0100, an 8-bit count (versions 1–9), then the bytes.
  int bitAt(int i) => data[i >> 3] >> (7 - (i & 7)) & 1;
  int read(int from, int count) => [for (var i = 0; i < count; i++) bitAt(from + i)].fold(0, (v, b) => v << 1 | b);
  expect(read(0, 4), 4, reason: 'byte mode');
  final length = read(4, 8);
  return utf8.decode([for (var i = 0; i < length; i++) read(12 + i * 8, 8)]);
}

/// Data modules in placement order.
Iterable<(int, int)> _placementOrder(int version) sync* {
  final n = _side(version);
  var upward = true;
  for (var right = n - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    for (var i = 0; i < n; i++) {
      final y = upward ? n - 1 - i : i;
      for (final x in [right, right - 1]) {
        if (_function(version, x, y) == null) yield (x, y);
      }
    }
    upward = !upward;
  }
}

void main() {
  test('the model reads real level-H codes back, at every logo version and mask', () {
    for (final text in [
      'https://qm.qq.com/q/example',
      'https://github.com/ccch1mneyyy/dsh-go',
      'https://weixin.qq.com/r/${'x' * 30}',
    ]) {
      for (var mask = 0; mask < 8; mask++) {
        final code = QrCode.encode(text, ecc: QrEcc.high, mask: mask, minVersion: QrCode.logoMinVersion);
        expect(QrCode.logoPlates, contains(code.version));
        expect(_readBack(code), text, reason: 'v${code.version} mask $mask');
      }
    }
  });

  for (final MapEntry(key: version, value: side) in QrCode.logoPlates.entries) {
    test('version $version: a $side-module plate on the centre, clear of every pattern, within budget', () {
      final n = _side(version);
      final code = QrCode.encode('x', ecc: QrEcc.high, minVersion: version);
      expect(code.version, version);
      final plate = code.logoPlate!;
      expect(plate.side, side);
      expect(side.isOdd, isTrue, reason: 'centres on the middle module');
      expect(plate.start * 2 + side, n, reason: 'as many modules left of it as right of it');
      expect(plate.logoStart, plate.start + 1, reason: 'one light module round the logo');
      expect(plate.logoSide, side - 2);
      expect(plate.logoSide / n, inInclusiveRange(0.18, 0.23), reason: 'about 22 % of the code');

      final cells = [
        for (var y = plate.start; y < plate.start + side; y++)
          for (var x = plate.start; x < plate.start + side; x++) (x, y),
      ];
      for (final (x, y) in cells) {
        expect(_function(version, x, y), isNull, reason: '($x, $y) is not a function module');
        expect(plate.contains(x, y), isTrue);
      }
      // One step out is not the plate.
      expect(plate.contains(plate.start - 1, plate.start), isFalse);
      expect(plate.contains(plate.start + side, plate.start), isFalse);

      // Budget: what level H corrects is half its error-correction codewords per block.
      final groups = [
        for (final (count, total, data) in _blocksH[version]!)
          for (var i = 0; i < count; i++) (total - data) ~/ 2,
      ];
      final correctable = groups.reduce((a, b) => a + b);
      expect(cells.length, lessThanOrEqualTo(correctable * 8 ~/ 3), reason: 'a third of what H corrects, in modules');
      final map = _codewordMap(version);
      final blockOf = _blockOf(version);
      final touched = {for (final (x, y) in cells) map[y][x]}..remove(-1);
      final perBlock = List.filled(groups.length, 0);
      for (final c in touched) {
        perBlock[blockOf[c]]++;
      }
      for (var b = 0; b < groups.length; b++) {
        expect(perBlock[b] * 3, lessThanOrEqualTo(groups[b] * 2), reason: 'block $b keeps a third of its correction');
      }
      // ignore: avoid_print
      print(
        'v$version ($n×$n): plate $side, logo ${plate.logoSide} '
        '(${(plate.logoSide / n * 100).toStringAsFixed(1)} %), ${cells.length} modules '
        '(${(cells.length / (correctable * 8) * 100).toStringAsFixed(0)} % of what H corrects), '
        'codewords touched per block $perBlock of ${groups.first}',
      );
    });
  }

  test('versions 1–3 are too small and 7–13 have an alignment pattern on the centre', () {
    for (var version = 7; version <= 13; version++) {
      final mid = _side(version) ~/ 2;
      expect(_function(version, mid, mid), 'alignment', reason: 'v$version');
    }
    expect(QrCode.logoPlates.keys, [4, 5, 6]);
    expect(QrCode.logoMinVersion, 4);
    expect(QrCode.logoMaxVersion, 6);
  });

  test('withLogo: level H, versions 4–6, up to 58 bytes', () {
    expect(QrCode.withLogo('a')!.version, 4, reason: 'short text is raised to version 4');
    expect(QrCode.withLogo('https://github.com/ccch1mneyyy/dsh-go')!.version, 5);
    expect(QrCode.withLogo('x' * 58)!.version, 6);
    expect(QrCode.withLogo('x' * 58)!.ecc, QrEcc.high);
    expect(QrCode.withLogo('x' * 59), isNull);
    expect(QrCode.encode('https://github.com/ccch1mneyyy/dsh-go').logoPlate, isNull, reason: 'level M');
    expect(QrCode.encode('x' * 70, ecc: QrEcc.high).logoPlate, isNull, reason: 'version 7');
  });

  group('QrCodeView', () {
    Future<void> pump(WidgetTester tester, QrCodeView view) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(child: view),
        ),
      );
    }

    for (final (size, quietZone) in [(64.0, 3), (208.0, 1), (248.0, 2)]) {
      testWidgets('the tile on the centre, one module of plate round it ($size, quiet zone $quietZone)', (
        tester,
      ) async {
        const data = 'https://github.com/ccch1mneyyy/dsh-go';
        await pump(tester, QrCodeView(data: data, size: size, quietZone: quietZone, logo: true));
        final (code, plate) = QrCodeView.codeFor(data, QrEcc.medium, logo: true, size: size, quietZone: quietZone);
        expect(code.ecc, QrEcc.high);
        final view = tester.getRect(find.byType(QrCodeView));
        final logo = tester.getRect(find.byKey(QrCodeView.logoKey));
        final cell = size / (code.size + 2 * quietZone);
        expect(logo.center.dx, moreOrLessEquals(view.center.dx, epsilon: 1e-9));
        expect(logo.center.dy, moreOrLessEquals(view.center.dy, epsilon: 1e-9));
        expect(logo.width, moreOrLessEquals(plate!.logoSide * cell, epsilon: 1e-9));
        expect(logo.height, logo.width);
        // The plate's edge (where modules start again) is one module out on every side.
        final edge = (quietZone + plate.start) * cell;
        for (final gap in [
          logo.left - view.left,
          view.right - logo.right,
          logo.top - view.top,
          view.bottom - logo.bottom,
        ]) {
          expect(gap, moreOrLessEquals(edge + cell, epsilon: 1e-9));
        }
        expect(tester.widget<BrandMark>(find.byKey(QrCodeView.logoKey)).tile, isTrue);
      });
    }

    testWidgets('a link too long for a logo is drawn plain at its own level', (tester) async {
      final data = 'https://go.dshtui.com/share/#p=${'A' * 300}';
      await pump(tester, QrCodeView(data: data, size: 248, logo: true));
      expect(find.byKey(QrCodeView.logoKey), findsNothing);
      final (code, plate) = QrCodeView.codeFor(data, QrEcc.medium, logo: true, size: 248);
      expect(code.ecc, QrEcc.medium);
      expect(plate, isNull);
    });

    testWidgets('a code that would be too fine with a logo is drawn plain', (tester) async {
      // 58 bytes: version 6 at H, 1.36 per module on the share card's 64.
      final data = 'https://github.com/ccch1mneyyy/dsh-go/releases/tag/v0.9.15';
      await pump(tester, QrCodeView(data: data, size: 64, quietZone: 3, logo: true));
      expect(find.byKey(QrCodeView.logoKey), findsNothing);
      expect(QrCodeView.codeFor(data, QrEcc.medium, logo: true, size: 64, quietZone: 3).$1.ecc, QrEcc.medium);
      // The same link on the community sheet's 208 carries it.
      await pump(tester, QrCodeView(data: data, size: 208, quietZone: 1, logo: true));
      expect(find.byKey(QrCodeView.logoKey), findsOneWidget);
    });

    testWidgets('no logo unless asked', (tester) async {
      await pump(tester, const QrCodeView(data: 'https://github.com/ccch1mneyyy/dsh-go'));
      expect(find.byKey(QrCodeView.logoKey), findsNothing);
      expect(find.byType(BrandMark), findsNothing);
    });

    testWidgets('the tile is not announced apart from the code', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(
        tester,
        const QrCodeView(data: 'https://github.com/ccch1mneyyy/dsh-go', logo: true, semanticLabel: 'QR'),
      );
      expect(find.bySemanticsLabel('QR'), findsOneWidget);
      expect(find.bySemanticsLabel('DSH'), findsNothing, reason: "the tile's own label");
      handle.dispose();
    });
  });
}
