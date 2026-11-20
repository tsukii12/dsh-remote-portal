// A small baseline JPEG encoder (ITU T.81), so pictures in a shared
// conversation can be shrunk without a native plugin. Flutter decodes and
// scales images (dart:ui) but only encodes PNG.
//
// Baseline, Huffman tables from Annex K.3, quantisation tables from Annex K.1
// scaled the IJG way, 4:2:0 chroma, the AAN floating-point DCT. Pure Dart:
// runs in an isolate and in tests.

import 'dart:math' as math;
import 'dart:typed_data';

/// Encodes [rgba] ([width] × [height], 4 bytes a pixel, alpha premultiplied)
/// as a JPEG of [quality] 1–100. Transparent parts land on white.
Uint8List encodeJpeg(Uint8List rgba, int width, int height, {int quality = 82}) {
  if (width <= 0 || height <= 0 || rgba.length < width * height * 4) {
    throw ArgumentError('bad image');
  }
  return _JpegEncoder(quality.clamp(1, 100)).encode(rgba, width, height);
}

const _zigzag = [
  0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
  35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
  58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
];

const _lumaQ = [
  16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, //
  14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99,
];

const _chromaQ = [
  17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, //
  24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
];

// Annex K.3 tables: code counts per length 1..16, then the values.
const _dcLumaBits = [0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0];
const _dcLumaVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const _dcChromaBits = [0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0];
const _dcChromaVals = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
const _acLumaBits = [0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d];
const _acLumaVals = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07, //
  0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
  0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
  0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
  0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
  0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
  0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
  0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
  0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];
const _acChromaBits = [0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77];
const _acChromaVals = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71, //
  0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
  0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
  0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
  0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
  0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
  0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
  0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
  0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
  0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
  0xf9, 0xfa,
];

/// A Huffman table: code and length by symbol.
class _Huffman {
  _Huffman(List<int> bits, List<int> values) {
    var code = 0;
    var k = 0;
    for (var length = 1; length <= 16; length++) {
      for (var i = 0; i < bits[length - 1]; i++) {
        final symbol = values[k++];
        codes[symbol] = code;
        lengths[symbol] = length;
        code++;
      }
      code <<= 1;
    }
  }

  final codes = Int32List(256);
  final lengths = Int32List(256);
}

class _BitWriter {
  final _out = BytesBuilder(copy: false);
  final _chunk = Uint8List(1 << 16);
  var _at = 0;
  var _buffer = 0;
  var _count = 0;

  void byte(int b) {
    if (_at == _chunk.length) _flushChunk();
    _chunk[_at++] = b;
  }

  void word(int w) {
    byte((w >> 8) & 0xff);
    byte(w & 0xff);
  }

  void bytes(List<int> list) {
    for (final b in list) {
      byte(b);
    }
  }

  void bits(int code, int length) {
    _buffer = (_buffer << length) | (code & ((1 << length) - 1));
    _count += length;
    while (_count >= 8) {
      final b = (_buffer >> (_count - 8)) & 0xff;
      byte(b);
      if (b == 0xff) byte(0);
      _count -= 8;
    }
    _buffer &= (1 << _count) - 1;
  }

  /// Pads the last byte with ones.
  void align() {
    if (_count > 0) bits((1 << (8 - _count)) - 1, 8 - _count);
  }

  void _flushChunk() {
    _out.add(Uint8List.fromList(_chunk.sublist(0, _at)));
    _at = 0;
  }

  Uint8List take() {
    _flushChunk();
    return _out.takeBytes();
  }
}

class _JpegEncoder {
  _JpegEncoder(int quality) {
    final scale = quality < 50 ? 5000 ~/ quality : 200 - quality * 2;
    for (var i = 0; i < 64; i++) {
      _lq[i] = ((_lumaQ[i] * scale + 50) ~/ 100).clamp(1, 255);
      _cq[i] = ((_chromaQ[i] * scale + 50) ~/ 100).clamp(1, 255);
    }
    // AAN scale factors folded into the divisors (natural order).
    const aan = [1.0, 1.387039845, 1.306562965, 1.175875602, 1.0, 0.785694958, 0.541196100, 0.275899379];
    for (var row = 0; row < 8; row++) {
      for (var col = 0; col < 8; col++) {
        final i = row * 8 + col;
        _lDiv[i] = 1 / (_lq[i] * aan[row] * aan[col] * 8);
        _cDiv[i] = 1 / (_cq[i] * aan[row] * aan[col] * 8);
      }
    }
  }

  final _lq = Int32List(64);
  final _cq = Int32List(64);
  final _lDiv = Float64List(64);
  final _cDiv = Float64List(64);
  final _dcL = _Huffman(_dcLumaBits, _dcLumaVals);
  final _dcC = _Huffman(_dcChromaBits, _dcChromaVals);
  final _acL = _Huffman(_acLumaBits, _acLumaVals);
  final _acC = _Huffman(_acChromaBits, _acChromaVals);
  final _w = _BitWriter();
  final _block = Float64List(64);
  final _q = Int32List(64);

  Uint8List encode(Uint8List rgba, int width, int height) {
    _headers(width, height);
    // Planes padded to whole 16×16 MCUs (edges repeated).
    final pw = (width + 15) & ~15;
    final ph = (height + 15) & ~15;
    final y = Float64List(pw * ph);
    final cbFull = Float64List(pw * ph);
    final crFull = Float64List(pw * ph);
    for (var row = 0; row < ph; row++) {
      final sy = math.min(row, height - 1);
      for (var col = 0; col < pw; col++) {
        final sx = math.min(col, width - 1);
        final p = (sy * width + sx) * 4;
        // Premultiplied over white: c + (255 - a).
        final a = rgba[p + 3];
        final r = rgba[p] + 255 - a;
        final g = rgba[p + 1] + 255 - a;
        final b = rgba[p + 2] + 255 - a;
        final i = row * pw + col;
        y[i] = 0.299 * r + 0.587 * g + 0.114 * b - 128;
        cbFull[i] = -0.168735892 * r - 0.331264108 * g + 0.5 * b;
        crFull[i] = 0.5 * r - 0.418687589 * g - 0.081312411 * b;
      }
    }
    final cw = pw ~/ 2;
    final ch = ph ~/ 2;
    final cb = Float64List(cw * ch);
    final cr = Float64List(cw * ch);
    for (var row = 0; row < ch; row++) {
      for (var col = 0; col < cw; col++) {
        final a = (row * 2) * pw + col * 2;
        final b = a + pw;
        cb[row * cw + col] = (cbFull[a] + cbFull[a + 1] + cbFull[b] + cbFull[b + 1]) / 4;
        cr[row * cw + col] = (crFull[a] + crFull[a + 1] + crFull[b] + crFull[b + 1]) / 4;
      }
    }
    var dcY = 0, dcCb = 0, dcCr = 0;
    for (var my = 0; my < ph; my += 16) {
      for (var mx = 0; mx < pw; mx += 16) {
        dcY = _unit(y, pw, mx, my, dcY, _lDiv, _dcL, _acL);
        dcY = _unit(y, pw, mx + 8, my, dcY, _lDiv, _dcL, _acL);
        dcY = _unit(y, pw, mx, my + 8, dcY, _lDiv, _dcL, _acL);
        dcY = _unit(y, pw, mx + 8, my + 8, dcY, _lDiv, _dcL, _acL);
        dcCb = _unit(cb, cw, mx ~/ 2, my ~/ 2, dcCb, _cDiv, _dcC, _acC);
        dcCr = _unit(cr, cw, mx ~/ 2, my ~/ 2, dcCr, _cDiv, _dcC, _acC);
      }
    }
    _w.align();
    _w.word(0xFFD9);
    return _w.take();
  }

  void _headers(int width, int height) {
    final w = _w;
    w.word(0xFFD8);
    // APP0 JFIF.
    w.word(0xFFE0);
    w.word(16);
    w.bytes(const [0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0]);
    // DQT, zigzag order.
    w.word(0xFFDB);
    w.word(2 + 65 * 2);
    w.byte(0);
    for (var i = 0; i < 64; i++) {
      w.byte(_lq[_zigzag[i]]);
    }
    w.byte(1);
    for (var i = 0; i < 64; i++) {
      w.byte(_cq[_zigzag[i]]);
    }
    // SOF0: 3 components, Y 2×2, Cb / Cr 1×1.
    w.word(0xFFC0);
    w.word(17);
    w.byte(8);
    w.word(height);
    w.word(width);
    w.byte(3);
    w.bytes(const [1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1]);
    // DHT.
    void table(int cls, List<int> bits, List<int> values) {
      w.word(0xFFC4);
      w.word(2 + 1 + 16 + values.length);
      w.byte(cls);
      w.bytes(bits);
      w.bytes(values);
    }

    table(0x00, _dcLumaBits, _dcLumaVals);
    table(0x10, _acLumaBits, _acLumaVals);
    table(0x01, _dcChromaBits, _dcChromaVals);
    table(0x11, _acChromaBits, _acChromaVals);
    // SOS.
    w.word(0xFFDA);
    w.word(12);
    w.byte(3);
    w.bytes(const [1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]);
  }

  /// One 8×8 block at ([x], [y]) of [plane] ([stride] wide); returns its DC.
  int _unit(Float64List plane, int stride, int x, int y, int prevDc, Float64List div, _Huffman dc, _Huffman ac) {
    final b = _block;
    for (var row = 0; row < 8; row++) {
      final o = (y + row) * stride + x;
      for (var col = 0; col < 8; col++) {
        b[row * 8 + col] = plane[o + col];
      }
    }
    _fdct(b);
    final q = _q;
    for (var i = 0; i < 64; i++) {
      final n = _zigzag[i];
      final v = b[n] * div[n];
      q[i] = v < 0 ? -((-v) + 0.5).floor() : (v + 0.5).floor();
    }
    // DC difference.
    final diff = q[0] - prevDc;
    final size = _bitSize(diff);
    _w.bits(dc.codes[size], dc.lengths[size]);
    if (size > 0) _w.bits(diff < 0 ? diff + (1 << size) - 1 : diff, size);
    // AC run lengths.
    var run = 0;
    var last = 63;
    while (last > 0 && q[last] == 0) {
      last--;
    }
    for (var i = 1; i <= last; i++) {
      final v = q[i];
      if (v == 0) {
        run++;
        continue;
      }
      while (run > 15) {
        _w.bits(ac.codes[0xF0], ac.lengths[0xF0]);
        run -= 16;
      }
      final s = _bitSize(v);
      final symbol = (run << 4) | s;
      _w.bits(ac.codes[symbol], ac.lengths[symbol]);
      _w.bits(v < 0 ? v + (1 << s) - 1 : v, s);
      run = 0;
    }
    if (last < 63) _w.bits(ac.codes[0], ac.lengths[0]);
    return q[0];
  }

  static int _bitSize(int v) {
    var a = v < 0 ? -v : v;
    var n = 0;
    while (a > 0) {
      n++;
      a >>= 1;
    }
    return n;
  }

  /// In-place AAN forward DCT (rows, then columns); outputs scaled by the
  /// factors folded into the divisors.
  static void _fdct(Float64List d) {
    for (var pass = 0; pass < 2; pass++) {
      for (var i = 0; i < 8; i++) {
        final step = pass == 0 ? 1 : 8;
        final base = pass == 0 ? i * 8 : i;
        final p0 = base, p1 = base + step, p2 = base + 2 * step, p3 = base + 3 * step;
        final p4 = base + 4 * step, p5 = base + 5 * step, p6 = base + 6 * step, p7 = base + 7 * step;
        final tmp0 = d[p0] + d[p7];
        final tmp7 = d[p0] - d[p7];
        final tmp1 = d[p1] + d[p6];
        final tmp6 = d[p1] - d[p6];
        final tmp2 = d[p2] + d[p5];
        final tmp5 = d[p2] - d[p5];
        final tmp3 = d[p3] + d[p4];
        final tmp4 = d[p3] - d[p4];

        var tmp10 = tmp0 + tmp3;
        final tmp13 = tmp0 - tmp3;
        var tmp11 = tmp1 + tmp2;
        var tmp12 = tmp1 - tmp2;

        d[p0] = tmp10 + tmp11;
        d[p4] = tmp10 - tmp11;
        final z1 = (tmp12 + tmp13) * 0.707106781;
        d[p2] = tmp13 + z1;
        d[p6] = tmp13 - z1;

        tmp10 = tmp4 + tmp5;
        tmp11 = tmp5 + tmp6;
        tmp12 = tmp6 + tmp7;
        final z5 = (tmp10 - tmp12) * 0.382683433;
        final z2 = 0.541196100 * tmp10 + z5;
        final z4 = 1.306562965 * tmp12 + z5;
        final z3 = tmp11 * 0.707106781;
        final z11 = tmp7 + z3;
        final z13 = tmp7 - z3;
        d[p5] = z13 + z2;
        d[p3] = z13 - z2;
        d[p1] = z11 + z4;
        d[p7] = z11 - z4;
      }
    }
  }
}
