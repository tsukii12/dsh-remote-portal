// Pictures for a shared conversation: the long side at most 1600, JPEG (PNG
// where they are see-through), so a conversation file stays small enough to
// send in a chat app.

import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import '../state/attachments.dart' show inlineImageType;
import 'jpeg_encoder.dart';

/// Longest side of a shared picture.
const sharedImageMaxSide = 1600;

/// A picture that already fits and is at most this large goes as it is.
const _keepBytes = 360 * 1024;

const _quality = 82;

/// A picture ready for the file.
typedef ShrunkImage = ({Uint8List bytes, String mediaType, int width, int height});

/// [bytes] fitted to [sharedImageMaxSide]: kept when it already fits and is
/// small, else scaled and re-encoded. Null when it can't be decoded.
Future<ShrunkImage?> shrinkImage(Uint8List bytes, {int maxSide = sharedImageMaxSide}) async {
  final type = inlineImageType(bytes);
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? image;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    final w = descriptor.width;
    final h = descriptor.height;
    final long = math.max(w, h);
    if (type != null && type != 'image/gif' && long <= maxSide && bytes.length <= _keepBytes) {
      return (bytes: bytes, mediaType: type, width: w, height: h);
    }
    final scale = long > maxSide ? maxSide / long : 1.0;
    final tw = math.max(1, (w * scale).round());
    final th = math.max(1, (h * scale).round());
    codec = await descriptor.instantiateCodec(targetWidth: tw, targetHeight: th);
    final frame = await codec.getNextFrame();
    image = frame.image;
    final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (raw == null) return null;
    final rgba = raw.buffer.asUint8List(raw.offsetInBytes, raw.lengthInBytes);
    if (_seeThrough(rgba)) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      if (png != null && png.lengthInBytes <= 3 * _keepBytes) {
        return (
          bytes: png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
          mediaType: 'image/png',
          width: tw,
          height: th,
        );
      }
    }
    final jpeg = await Isolate.run(() => encodeJpeg(rgba, tw, th, quality: _quality));
    // A small original that only failed the size test may still be smaller.
    if (type != null && type != 'image/gif' && long <= maxSide && bytes.length <= jpeg.length) {
      return (bytes: bytes, mediaType: type, width: w, height: h);
    }
    return (bytes: jpeg, mediaType: 'image/jpeg', width: tw, height: th);
  } catch (_) {
    return null;
  } finally {
    image?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

/// Any pixel less than opaque.
bool _seeThrough(Uint8List rgba) {
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) return true;
  }
  return false;
}
