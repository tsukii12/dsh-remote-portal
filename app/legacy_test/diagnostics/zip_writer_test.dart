// The diagnostics ZIP, read back with an independent reader
// (`support/zip_reader.dart`).

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dsh_app/diagnostics/zip_writer.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/zip_reader.dart';

void main() {
  test('crc32 matches the standard check value', () {
    expect(crc32(ascii.encode('123456789')), 0xCBF43926);
    expect(crc32(const []), 0);
  });

  test('entries read back byte for byte, names in UTF-8', () {
    final random = Random(7);
    final noise = Uint8List.fromList([for (var i = 0; i < 4096; i++) random.nextInt(256)]);
    final text = utf8.encode('${'[gateway] listening on 127.0.0.1:3080\n' * 200}引擎就绪\n');
    final zip = buildZip([
      ZipEntry('summary.json', utf8.encode('{"app": "1.0.0+1"}\n')),
      ZipEntry('engine.log', text),
      ZipEntry('日志/崩溃.txt', utf8.encode('没有崩溃')),
      ZipEntry('noise.bin', noise),
      const ZipEntry('empty.log', []),
    ], modified: DateTime(2026, 10, 24, 15, 30, 13));
    final entries = readZip(zip);
    expect(entries.map((e) => e.name), ['summary.json', 'engine.log', '日志/崩溃.txt', 'noise.bin', 'empty.log']);
    expect(utf8.decode(entries[1].data), utf8.decode(text));
    expect(utf8.decode(entries[2].data), '没有崩溃');
    expect(entries[3].data, noise);
    expect(entries[4].data, isEmpty);
    // Repetitive text is deflated; noise that would grow is stored.
    expect(entries[1].method, 8);
    expect(entries[3].method, 0);
    expect(entries[4].method, 0);
    for (final e in entries) {
      expect(e.flags & 0x0800, 0x0800, reason: 'UTF-8 names');
      // 2026-10-24 15:30:12 in DOS form (two-second steps).
      expect(e.date, ((2026 - 1980) << 9) | (10 << 5) | 24);
      expect(e.time, (15 << 11) | (30 << 5) | 6);
    }
  });

  test('an empty archive is just the end record', () {
    final zip = buildZip(const [], modified: DateTime(2026));
    expect(zip.length, 22);
    expect(readZip(zip), isEmpty);
  });
}
