import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Decode enough detail for BoxFit.cover at the physical display size.
/// A cropped axis can exceed the display box; fitting both axes would blur the crop.
/// Full-screen viewers keep their original provider so zoom still has full detail.
ImageProvider imageForDisplay(
  ImageProvider image, {
  required double width,
  required double height,
  required double pixelRatio,
}) {
  int pixels(double size) => !size.isFinite || size <= 0 || !pixelRatio.isFinite || pixelRatio <= 0
      ? 1
      : (size * pixelRatio).clamp(1, 4096).ceil();
  return _CoverImage(image, pixels(width), pixels(height));
}

class _CoverImageKey {
  const _CoverImageKey(this.source, this.width, this.height);
  final Object source;
  final int width;
  final int height;

  @override
  bool operator ==(Object other) =>
      other is _CoverImageKey && other.source == source && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(source, width, height);
}

class _CoverImage extends ImageProvider<_CoverImageKey> {
  const _CoverImage(this.image, this.width, this.height);

  final ImageProvider image;
  final int width;
  final int height;

  @override
  Future<_CoverImageKey> obtainKey(ImageConfiguration configuration) =>
      image.obtainKey(configuration).then((key) => _CoverImageKey(key, width, height));

  @override
  ImageStreamCompleter loadImage(_CoverImageKey key, ImageDecoderCallback decode) {
    final completer = image.loadImage(key.source, (buffer, {getTargetSize}) {
      assert(getTargetSize == null, 'imageForDisplay expects an original, unresized image provider.');
      return decode(
        buffer,
        getTargetSize: (int sourceWidth, int sourceHeight) {
          // Keep native resolution when cover cannot shrink both axes. Passing
          // neither dimension avoids the codec's floating-point single-axis math.
          if (width >= sourceWidth || height >= sourceHeight) return const ui.TargetImageSize();

          // Both dimensions come from one rational cover scale. Round the other
          // axis up by less than one pixel; exact ratios stay exact. This keeps
          // the cover lower bound without stretching to an unrelated box ratio.
          if (width * sourceHeight >= height * sourceWidth) {
            return ui.TargetImageSize(width: width, height: (sourceHeight * width + sourceWidth - 1) ~/ sourceWidth);
          }
          return ui.TargetImageSize(width: (sourceWidth * height + sourceHeight - 1) ~/ sourceHeight, height: height);
        },
      );
    });
    completer.addEphemeralErrorListener((error, stack) {
      // The source provider can only evict its own key, not this wrapper's entry.
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
    });
    return completer;
  }

  @override
  bool operator ==(Object other) =>
      other is _CoverImage && other.image == image && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(image, width, height);
}
