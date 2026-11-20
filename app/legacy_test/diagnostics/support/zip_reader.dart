// A minimal ZIP reader for the diagnostics tests (central directory → local
// headers → raw inflate → CRC), the way an archive tool extracts.

import 'dart:convert';
import 'dart:io' show ZLibDecoder;
import 'dart:typed_data';

import 'package:dsh_app/diagnostics/zip_writer.dart' show crc32;
import 'package:flutter_test/flutter_test.dart';

/// One entry as a reader sees it.
typedef ReadEntry = ({String name, int method, int flags, int time, int date, Uint8List data});

/// A minimal ZIP reader (no ZIP64): what an archive tool would extract.
List<ReadEntry> readZip(Uint8List bytes) {
  final view = ByteData.sublistView(bytes);
  var eocd = -1;
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  expect(eocd, greaterThanOrEqualTo(0), reason: 'end of central directory');
  final count = view.getUint16(eocd + 10, Endian.little);
  expect(view.getUint16(eocd + 8, Endian.little), count);
  final size = view.getUint32(eocd + 12, Endian.little);
  final offset = view.getUint32(eocd + 16, Endian.little);
  expect(offset + size, eocd, reason: 'directory ends where the end record starts');

  final out = <ReadEntry>[];
  var at = offset;
  for (var i = 0; i < count; i++) {
    expect(view.getUint32(at, Endian.little), 0x02014b50);
    final flags = view.getUint16(at + 8, Endian.little);
    final method = view.getUint16(at + 10, Endian.little);
    final time = view.getUint16(at + 12, Endian.little);
    final date = view.getUint16(at + 14, Endian.little);
    final crc = view.getUint32(at + 16, Endian.little);
    final packed = view.getUint32(at + 20, Endian.little);
    final plain = view.getUint32(at + 24, Endian.little);
    final nameLength = view.getUint16(at + 28, Endian.little);
    final extra = view.getUint16(at + 30, Endian.little);
    final comment = view.getUint16(at + 32, Endian.little);
    final local = view.getUint32(at + 42, Endian.little);
    final name = utf8.decode(bytes.sublist(at + 46, at + 46 + nameLength));

    // The local header repeats the same facts.
    expect(view.getUint32(local, Endian.little), 0x04034b50);
    expect(view.getUint16(local + 8, Endian.little), method);
    expect(view.getUint32(local + 14, Endian.little), crc);
    expect(view.getUint32(local + 18, Endian.little), packed);
    expect(view.getUint32(local + 22, Endian.little), plain);
    final localName = view.getUint16(local + 26, Endian.little);
    final localExtra = view.getUint16(local + 28, Endian.little);
    final start = local + 30 + localName + localExtra;
    final stored = bytes.sublist(start, start + packed);
    final data = method == 8 ? Uint8List.fromList(ZLibDecoder(raw: true).convert(stored)) : stored;
    expect(data.length, plain, reason: name);
    expect(crc32(data), crc, reason: name);
    out.add((name: name, method: method, flags: flags, time: time, date: date, data: data));
    at += 46 + nameLength + extra + comment;
  }
  return out;
}
