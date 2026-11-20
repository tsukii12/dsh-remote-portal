// The smallest ZIP writer the diagnostics bundle needs
// (deflated or stored entries, UTF-8 names, no ZIP64, no encryption).

import 'dart:convert' show utf8;
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

/// One file of a [buildZip] archive.
class ZipEntry {
  const ZipEntry(this.name, this.bytes);

  /// Path inside the archive (`/`-separated, no leading slash).
  final String name;
  final List<int> bytes;
}

/// A ZIP archive of [entries], each deflated unless that would not shrink
/// it. [modified] is every entry's time stamp (local time, 2-second steps).
Uint8List buildZip(List<ZipEntry> entries, {required DateTime modified}) {
  final out = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final time = _dosTime(modified);
  final date = _dosDate(modified);
  for (final entry in entries) {
    final name = utf8.encode(entry.name);
    final data = entry.bytes is Uint8List ? entry.bytes as Uint8List : Uint8List.fromList(entry.bytes);
    final crc = crc32(data);
    final deflated = data.isEmpty ? data : Uint8List.fromList(ZLibEncoder(raw: true, level: 6).convert(data));
    final stored = deflated.length >= data.length;
    final payload = stored ? data : deflated;
    final method = stored ? 0 : 8;
    final offset = out.length;

    out.add(
      _header(0x04034b50, [
        (20, 2), // version needed
        (_utf8Flag, 2),
        (method, 2),
        (time, 2),
        (date, 2),
        (crc, 4),
        (payload.length, 4),
        (data.length, 4),
        (name.length, 2),
        (0, 2), // extra
      ]),
    );
    out
      ..add(name)
      ..add(payload);

    central.add(
      _header(0x02014b50, [
        (20, 2), // version made by
        (20, 2), // version needed
        (_utf8Flag, 2),
        (method, 2),
        (time, 2),
        (date, 2),
        (crc, 4),
        (payload.length, 4),
        (data.length, 4),
        (name.length, 2),
        (0, 2), // extra
        (0, 2), // comment
        (0, 2), // disk
        (0, 2), // internal attributes
        (0, 4), // external attributes
        (offset, 4),
      ]),
    );
    central.add(name);
  }
  final directoryOffset = out.length;
  final directory = central.takeBytes();
  out
    ..add(directory)
    ..add(
      _header(0x06054b50, [
        (0, 2), // this disk
        (0, 2), // directory disk
        (entries.length, 2),
        (entries.length, 2),
        (directory.length, 4),
        (directoryOffset, 4),
        (0, 2), // comment
      ]),
    );
  return out.takeBytes();
}

/// Names are UTF-8 (general purpose bit 11).
const _utf8Flag = 0x0800;

Uint8List _header(int signature, List<(int, int)> fields) {
  final size = 4 + fields.fold<int>(0, (sum, f) => sum + f.$2);
  final data = ByteData(size)..setUint32(0, signature, Endian.little);
  var at = 4;
  for (final (value, width) in fields) {
    if (width == 2) {
      data.setUint16(at, value, Endian.little);
    } else {
      data.setUint32(at, value, Endian.little);
    }
    at += width;
  }
  return data.buffer.asUint8List();
}

int _dosTime(DateTime t) => (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);

int _dosDate(DateTime t) => ((t.year - 1980).clamp(0, 127) << 9) | (t.month << 5) | t.day;

final Uint32List _crcTable = () {
  final table = Uint32List(256);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    table[n] = c;
  }
  return table;
}();

/// CRC-32 (IEEE 802.3), as ZIP stores it.
int crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc = _crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
