import 'dart:typed_data';

import 'package:image/image.dart' as image;

import '../authoring.dart';
import '../authoring_render.dart';

/// The result DTO already owns immutable bytes. Validate only at this host
/// boundary: a matching signature alone is not successful image decoding.
void validateAuthoringImage(TavernAuthoringRenderResult result, TavernAuthoringHostBinding binding) {
  final bytes = result.bytes;
  final width = result.pixelWidth, height = result.pixelHeight;
  if (bytes == null ||
      bytes.isEmpty ||
      bytes.length > binding.maxImageBytes ||
      width == null ||
      height == null ||
      width < 1 ||
      height < 1 ||
      width > binding.maxPixelWidth ||
      height > binding.maxPixelHeight ||
      !binding.formats.contains(result.mimeType)) {
    _invalidImage();
  }
  final signature = switch (result.mimeType) {
    'image/png' => const [137, 80, 78, 71, 13, 10, 26, 10],
    'image/jpeg' => const [255, 216, 255],
    _ => const <int>[],
  };
  if (signature.isEmpty || !_startsWith(bytes, signature)) {
    _invalidImage();
  }
  final image.Image? decoded;
  try {
    decoded = image.decodeImage(bytes);
  } on Exception {
    _invalidImage();
  } on RangeError {
    _invalidImage();
  }
  if (decoded == null ||
      decoded.width != width ||
      decoded.height != height ||
      decoded.width > binding.maxPixelWidth ||
      decoded.height > binding.maxPixelHeight) {
    _invalidImage();
  }
}

bool _startsWith(Uint8List bytes, List<int> signature) {
  if (bytes.length < signature.length) {
    return false;
  }
  for (var index = 0; index < signature.length; index++) {
    if (bytes[index] != signature[index]) {
      return false;
    }
  }
  return true;
}

Never _invalidImage() => throw const TavernAuthoringException(
  'invalid_render_image',
  'The renderer did not return a supported image with matching dimensions within its declared limits.',
);
