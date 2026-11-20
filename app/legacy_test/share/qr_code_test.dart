// The QR encoder against libqrencode 4.1.1: same text, level and byte mode
// must give the same module matrix (libqrencode picks its mask with its own
// penalty arithmetic, so the match is checked against all eight masks; the
// mask the encoder picks itself is checked separately).
//
// Fixtures: python3 test/share/fixtures/make_qr_fixtures.py > test/share/fixtures/qr_libqrencode.json

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/share/qr_code.dart';
import 'package:flutter_test/flutter_test.dart';

QrEcc _level(String l) => switch (l) {
  'L' => QrEcc.low,
  'M' => QrEcc.medium,
  'Q' => QrEcc.quartile,
  _ => QrEcc.high,
};

List<String> _rows(QrCode code) => [
  for (var y = 0; y < code.size; y++) [for (var x = 0; x < code.size; x++) code.isDark(x, y) ? '1' : '0'].join(),
];

List<String> _fixtureRows(Map<String, Object?> fixture) {
  final size = fixture['size']! as int;
  return [
    for (final hex in (fixture['rows']! as List).cast<String>())
      BigInt.parse(hex, radix: 16).toRadixString(2).padLeft(hex.length * 4, '0').substring(0, size),
  ];
}

void main() {
  final fixtures = (jsonDecode(File('test/share/fixtures/qr_libqrencode.json').readAsStringSync()) as List)
      .cast<Map<String, Object?>>();

  for (final fixture in fixtures) {
    final text = fixture['text']! as String;
    final level = fixture['level']! as String;
    final label = '${text.length > 24 ? '${text.substring(0, 24)}…' : text} ($level, ${utf8.encode(text).length} B)';

    test('matches libqrencode: $label', () {
      final expected = _fixtureRows(fixture);
      final ecc = _level(level);
      final auto = QrCode.encode(text, ecc: ecc);
      expect(auto.size, expected.length, reason: 'same version');
      final matching = [
        for (var mask = 0; mask < 8; mask++)
          if (_rows(QrCode.encode(text, ecc: ecc, mask: mask)).join('\n') == expected.join('\n')) mask,
      ];
      expect(matching, hasLength(1), reason: 'exactly one mask reproduces libqrencode');
    });
  }

  test('picks the lowest-penalty mask and keeps the finder patterns', () {
    final code = QrCode.encode('https://github.com/ccch1mneyyy/dsh-go');
    expect(code.version, 3);
    expect(code.ecc, QrEcc.medium);
    // Finder corners: dark outer ring, light separator.
    for (final (x, y) in [(0, 0), (code.size - 1, 0), (0, code.size - 1)]) {
      expect(code.isDark(x, y), isTrue);
    }
    expect(code.isDark(7, 7), isFalse);
    expect(code.isDark(8, code.size - 8), isTrue, reason: 'the dark module');
  });

  test('refuses text that does not fit', () {
    expect(() => QrCode.encode('x' * 3000), throwsArgumentError);
  });
}
