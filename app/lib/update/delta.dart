import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Builds a release's APK from the installed one and a `DSHDLT01` patch
/// (docs/release.md). Big-endian throughout:
///
/// ```text
/// header  "DSHDLT01" · SHA-256 of the base APK (32 bytes) · SHA-256 of the target (32) · target length (u64)
/// ops     0x01 COPY  base offset (u64) · length (u64)    that many bytes of the base APK
///         0x02 DATA  length (u64) · that many bytes       literal bytes
///         0x00 END
/// ```
///
/// The patch is read front to back and the base by offset, both through
/// 64 KiB buffers, and the output is hashed as it is written: memory stays
/// flat whatever the APK's size.
class DeltaPatch {
  DeltaPatch._(this._base, this._patch, this._out, this._targetLength);

  static const magic = 'DSHDLT01';

  static const _headerLength = 8 + 32 + 32 + 8;
  static const _end = 0x00;
  static const _copy = 0x01;
  static const _data = 0x02;

  final RandomAccessFile _base;
  final RandomAccessFile _patch;
  final RandomAccessFile _out;
  final int _targetLength;

  final _baseBuffer = Uint8List(1 << 16);
  final _patchBuffer = Uint8List(1 << 16);
  var _patchStart = 0;
  var _patchEnd = 0;
  var _written = 0;
  final _digest = _DigestSink();
  late final _hash = sha256.startChunkedConversion(_digest);

  /// Writes to [out] what [patch] builds from [base]. Throws a
  /// [FormatException] when the patch isn't one from [baseSha256] to
  /// [targetSha256] ([targetSize] bytes, when known), is cut short or
  /// malformed, or builds anything but exactly that target; [out] is gone
  /// then. Synchronous: [applyDeltaPatch] runs it off the UI isolate.
  static void apply({
    required File base,
    required File patch,
    required File out,
    required String baseSha256,
    required String targetSha256,
    int? targetSize,
  }) {
    final opened = <RandomAccessFile>[];
    RandomAccessFile open(File file, [FileMode mode = FileMode.read]) {
      final handle = file.openSync(mode: mode);
      opened.add(handle);
      return handle;
    }

    var built = false;
    try {
      final input = open(patch);
      final header = input.readSync(_headerLength);
      if (header.length < _headerLength || String.fromCharCodes(header, 0, 8) != magic) {
        throw const FormatException('not a DSHDLT01 patch');
      }
      if (_hex(header, 8) != baseSha256) throw const FormatException('the patch is for another base APK');
      if (_hex(header, 40) != targetSha256) throw const FormatException('the patch builds another APK');
      final length = _size(ByteData.sublistView(header, 72).getUint64(0));
      if (targetSize != null && length != targetSize) throw const FormatException('the patch builds another length');
      DeltaPatch._(open(base), input, open(out, FileMode.write), length)._run(targetSha256);
      built = true;
    } finally {
      for (final handle in opened) {
        handle.closeSync();
      }
      if (!built && out.existsSync()) out.deleteSync();
    }
  }

  void _run(String targetSha256) {
    while (true) {
      switch (_byte()) {
        case _end:
          _hash.close();
          if (_written != _targetLength || _digest.value.toString() != targetSha256) {
            throw const FormatException('the patch did not build the target');
          }
          return;
        case _copy:
          final offset = _readU64();
          final length = _bounded(_readU64());
          _base.setPositionSync(offset);
          for (var left = length; left > 0;) {
            final n = _base.readIntoSync(_baseBuffer, 0, math.min(left, _baseBuffer.length));
            if (n == 0) throw const FormatException('COPY past the end of the base APK');
            _emit(_baseBuffer, 0, n);
            left -= n;
          }
        case _data:
          for (var left = _bounded(_readU64()); left > 0;) {
            _fill();
            final n = math.min(left, _patchEnd - _patchStart);
            _emit(_patchBuffer, _patchStart, n);
            _patchStart += n;
            left -= n;
          }
        case final op:
          throw FormatException('unknown patch op $op');
      }
    }
  }

  /// [length] more bytes still fit in the target.
  int _bounded(int length) {
    if (length > _targetLength - _written) throw const FormatException('the patch builds past the target length');
    return length;
  }

  void _emit(Uint8List bytes, int start, int length) {
    _out.writeFromSync(bytes, start, start + length);
    _hash.add(Uint8List.sublistView(bytes, start, start + length));
    _written += length;
  }

  /// At least one unread byte of the patch in [_patchBuffer].
  void _fill() {
    if (_patchStart < _patchEnd) return;
    _patchStart = 0;
    _patchEnd = _patch.readIntoSync(_patchBuffer);
    if (_patchEnd == 0) throw const FormatException('the patch is cut short');
  }

  int _byte() {
    _fill();
    return _patchBuffer[_patchStart++];
  }

  int _readU64() {
    var value = 0;
    for (var i = 0; i < 8; i++) {
      value = value << 8 | _byte();
    }
    return _size(value);
  }

  /// An offset or a length. No file is 2^63 bytes: one that wraps negative is
  /// a broken patch.
  static int _size(int value) => value < 0 ? throw const FormatException('the patch has a size out of range') : value;

  static String _hex(Uint8List bytes, int start) => Digest(Uint8List.sublistView(bytes, start, start + 32)).toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// [DeltaPatch.apply] off the UI isolate: it reads and writes a whole APK.
Future<void> applyDeltaPatch({
  required File base,
  required File patch,
  required File out,
  required String baseSha256,
  required String targetSha256,
  int? targetSize,
}) {
  final (basePath, patchPath, outPath) = (base.path, patch.path, out.path);
  return Isolate.run(
    () => DeltaPatch.apply(
      base: File(basePath),
      patch: File(patchPath),
      out: File(outPath),
      baseSha256: baseSha256,
      targetSha256: targetSha256,
      targetSize: targetSize,
    ),
  );
}
