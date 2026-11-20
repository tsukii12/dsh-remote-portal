part of 'pet_pack_validator.dart';

class _PetArchiveEntry {
  const _PetArchiveEntry(this.header, this.rawName, this.name);
  final ZipFileHeader header;
  final Uint8List rawName;
  final String name;
}

/// A ZIP directory inspected without extracting paths or decompressing entries.
/// Headers are visited individually, before duplicate names can be collapsed.
class PetArchive {
  PetArchive._(this._bytes, this._entries, this._centralStart, this._offsets);
  final Uint8List _bytes;
  final Map<String, _PetArchiveEntry> _entries;
  final int _centralStart;
  final List<int> _offsets;

  Set<String> get fileNames => Set.unmodifiable(_entries.keys);

  /// An exact root name, or that name in one enclosing top folder.
  List<String> manifestPaths(String basename) =>
      _entries.keys.where((n) => n == basename || (n.endsWith('/$basename') && n.split('/').length == 2)).toList();

  static PetArchive read(Uint8List bytes) {
    _require(bytes.length <= petArchiveByteCap, 'archive-size');
    try {
      final directory = ZipDirectory();
      final entries = <String, _PetArchiveEntry>{};
      final members = <_PetArchiveEntry>[];
      final aliases = <String>{};
      final offsets = <int>[];
      final data = ByteData.sublistView(bytes);
      var count = 0, expanded = 0, cursor = -1;
      for (final header in directory.headers(InputMemoryStream(bytes), files: false, verify: true)) {
        // The iterator allocates at most one header before this gate; never a
        // list sized by a possibly forged declared member count.
        _require(
          ++count <= petArchiveEntryCap && directory.totalCentralDirectoryEntries <= petArchiveEntryCap,
          'archive-entries',
        );
        _require(
          directory.numberOfThisDisk == 0 &&
              directory.diskWithTheStartOfTheCentralDirectory == 0 &&
              header.diskNumberStart == 0,
          'archive-multidisk',
        );
        if (cursor < 0) cursor = directory.centralDirectoryOffset;
        _require(cursor >= 0 && cursor + 46 <= bytes.length, 'archive-directory');
        final nameLength = data.getUint16(cursor + 28, Endian.little);
        final extraLength = data.getUint16(cursor + 30, Endian.little);
        final commentLength = data.getUint16(cursor + 32, Endian.little);
        _require(
          cursor + 46 + nameLength + extraLength + commentLength <=
              directory.centralDirectoryOffset + directory.centralDirectorySize,
          'archive-directory',
        );
        final rawName = Uint8List.sublistView(bytes, cursor + 46, cursor + 46 + nameLength);
        // Python zipfile (market CI) uses UTF-8 flag / CP437 and does not apply
        // the optional Unicode Path extra field. Match that exact choice.
        final name = header.generalPurposeBitFlag & 0x800 != 0
            ? '${_hasUtf8Bom(rawName) ? '\uFEFF' : ''}${utf8.decode(rawName)}'
            : _cp437(rawName);
        cursor += 46 + nameLength + extraLength + commentLength;
        final parts = name.replaceFirst(RegExp(r'/+$'), '').split('/');
        _require(
          name.isNotEmpty &&
              !name.startsWith('/') &&
              !name.contains('\\') &&
              !name.contains('\u0000') &&
              parts.every((p) => p.isNotEmpty && p != '.' && p != '..' && !p.contains(':')),
          'archive-path',
          name,
        );
        _require(aliases.add(petNameAlias(name)), 'archive-duplicate', name);
        final isDirectory = name.endsWith('/');
        final kind = (header.externalFileAttributes >> 16) & 0xf000;
        _require(kind == 0 || kind == (isDirectory ? 0x4000 : 0x8000), 'archive-type', name);
        _require(
          header.generalPurposeBitFlag & 1 == 0 && (header.compressionMethod == 0 || header.compressionMethod == 8),
          'archive-encoding',
          name,
        );
        _require(
          header.uncompressedSize >= 0 && header.uncompressedSize <= petArchiveExpandedCap - expanded,
          'archive-expanded-size',
          name,
        );
        expanded += header.uncompressedSize;
        offsets.add(header.localHeaderOffset);
        final entry = _PetArchiveEntry(header, rawName, name);
        members.add(entry);
        if (!isDirectory) entries[name] = entry;
      }
      _require(directory.filePosition >= 0, 'archive-invalid');
      _require(count == directory.totalCentralDirectoryEntries, 'archive-directory');
      _require(count <= petArchiveEntryCap, 'archive-entries');
      offsets.sort();
      final archive = PetArchive._(bytes, entries, directory.centralDirectoryOffset, offsets);
      // Even a dropped extra (or a directory) may claim another member's local
      // header as its payload. Validate every declared interval before returning;
      // actual decompression and CRC checks remain bounded, on-demand reads.
      for (final entry in members) {
        archive._memberStart(entry);
      }
      return archive;
    } on PetValidationException {
      rethrow;
    } on Object {
      throw const PetValidationException('archive-invalid');
    }
  }

  int _memberStart(_PetArchiveEntry entry) {
    final header = entry.header, path = entry.name;
    final offset = header.localHeaderOffset;
    _require(offset >= 0 && offset <= _bytes.length - 30, 'archive-header', path);
    final data = ByteData.sublistView(_bytes);
    _require(data.getUint32(offset, Endian.little) == 0x04034b50, 'archive-header', path);
    final flags = data.getUint16(offset + 6, Endian.little);
    _require(
      flags & 0x61 == 0 &&
          flags == header.generalPurposeBitFlag &&
          data.getUint16(offset + 8, Endian.little) == header.compressionMethod,
      'archive-encoding',
      path,
    );
    final nameLength = data.getUint16(offset + 26, Endian.little);
    final extraLength = data.getUint16(offset + 28, Endian.little);
    final start = offset + 30 + nameLength + extraLength;
    _require(start <= _centralStart && nameLength == entry.rawName.length, 'archive-member-range', path);
    for (var i = 0; i < nameLength; i++) {
      _require(_bytes[offset + 30 + i] == entry.rawName[i], 'archive-local-name', path);
    }
    final next = _offsets.firstWhere((p) => p > offset, orElse: () => _centralStart);
    _require(
      _offsets.where((p) => p == offset).length == 1 &&
          header.compressedSize >= 0 &&
          header.compressedSize <= next - start &&
          start + header.compressedSize <= _centralStart,
      'archive-member-range',
      path,
    );
    return start;
  }

  /// Reads only this member, with a hard output budget applied before each
  /// inflate write. Declared lengths, actual EOF, trailing data and CRC agree.
  Uint8List readFile(String path, {required int maxBytes}) {
    final entry = _entries[path];
    _require(entry != null, 'archive-member-missing', path);
    final header = entry!.header;
    _require(maxBytes >= 0 && header.uncompressedSize <= maxBytes, 'archive-member-size', path);
    try {
      final start = _memberStart(entry);
      final compressed = Uint8List.sublistView(_bytes, start, start + header.compressedSize);
      final Uint8List result;
      if (header.compressionMethod == 0) {
        _require(compressed.length == header.uncompressedSize, 'archive-member-size', path);
        result = compressed;
      } else {
        result = _inflateBounded(compressed, header.uncompressedSize, 'archive', path);
      }
      _require(getCrc32(result) == header.crc32, 'archive-member-crc', path);
      return result;
    } on PetValidationException {
      rethrow;
    } on Object {
      throw PetValidationException('archive-member-invalid', path);
    }
  }
}

// CP437 bytes 128..255. ASCII/control bytes map to their Unicode code points,
// as Python's codec does; these are not the DOS graphical control glyphs.
String _cp437(Uint8List bytes) {
  const high =
      'ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜ¢£¥₧ƒáíóúñÑªº¿⌐¬½¼¡«»░▒▓│┤╡╢╖╕╣║╗╝╜╛┐└┴┬├─┼╞╟╚╔╩╦╠═╬╧╨╤╥╙╘╒╓╫╪┘┌█▄▌▐▀αßΓπΣσµτΦΘΩδ∞φε∩≡±≥≤⌠⌡÷≈°∙·√ⁿ²■ ';
  return String.fromCharCodes([for (final b in bytes) b < 128 ? b : high.codeUnitAt(b - 128)]);
}

Uint8List _inflateBounded(Uint8List bytes, int expected, String kind, String path) {
  final result = _inflateAtMost(bytes, expected, kind, path, reserveFull: true);
  _require(result.length == expected, '$kind-member-size', path);
  return result;
}

Uint8List _inflateAtMost(Uint8List bytes, int cap, String kind, String path, {bool reserveFull = false}) {
  final input = InputMemoryStream(bytes);
  final output = _PetBoundedOutput(cap, '$kind-member-size', path, initialSize: reserveFull ? cap : 0);
  try {
    final inflater = Inflate.stream(input, output: output, throwOnError: true);
    _require(inflater.isFinished, '$kind-deflate-truncated', path);
    _require(input.isEOS, '$kind-deflate-trailing', path);
    return output.getBytes();
  } on PetValidationException {
    rethrow;
  } on Object {
    throw PetValidationException('$kind-deflate-invalid', path);
  }
}

// It must extend OutputMemoryStream: archive's Inflate otherwise substitutes
// an unbounded internal memory buffer before draining into the supplied sink.
class _PetBoundedOutput extends OutputMemoryStream {
  _PetBoundedOutput(this.cap, this.code, this.path, {required int initialSize})
    : _capacity = initialSize,
      super(size: initialSize);
  final int cap;
  final String code, path;
  int _capacity;
  void _room(int count) {
    _require(count >= 0 && count <= cap - length, code, path);
    final wanted = length + count;
    if (wanted > _capacity) {
      var next = _capacity == 0 ? 128 : _capacity * 2;
      if (next < wanted) next = wanted;
      if (next > cap) next = cap;
      // Reserve explicitly so OutputMemoryStream's private geometric growth
      // never allocates past our cap. Empty metadata allocates no payload.
      super.reserve(next);
      _capacity = next;
    }
  }

  @override
  void reserve(int total) {
    _require(total >= 0 && total <= cap, code, path);
    super.reserve(total);
    if (total > _capacity) _capacity = total;
  }

  @override
  void writeByte(int value) {
    _room(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _room(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _room(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _room(count);
    super.writeBackReference(distance, count);
  }
}
