// How a batch of generated pictures sits in the reading column
// (docs/design/media-generation.md §5.1): one at its own aspect, two side by
// side (or stacked when wide), three as one large and two small (or stacked),
// four as 2 × 2; 4 apart, the whole group under the height cap H and
// left-aligned with the reply text. Pure geometry, measured in
// `test/media/media_grid_test.dart`.

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The grid's constants.
abstract final class MediaGridMetrics {
  /// Between cells.
  static const gap = 4.0;

  /// The group's outer corners.
  static const outerRadius = 20.0;

  /// Corners inside the group (multi-cell).
  static const innerRadius = 8.0;

  /// The tallest a card gets, whatever the window ([maxHeightFor]).
  static const maxHeight = 480.0;

  /// A share of the window height a card may take (a phone on its side).
  static const windowShare = 0.6;

  /// At or above this width / height a batch counts as wide (stacks).
  static const wide = 1.25;

  /// H = min(480, 0.6 × window height).
  static double maxHeightFor(double windowHeight) => math.min(maxHeight, windowShare * windowHeight);
}

/// Where each cell of a batch goes, from the group's top-left corner.
class MediaGridLayout {
  const MediaGridLayout(this.size, this.cells);

  /// The whole group.
  final Size size;
  final List<Rect> cells;

  /// [cell]'s corners: [MediaGridMetrics.outerRadius] where they touch the
  /// group's own corners, [MediaGridMetrics.innerRadius] inside.
  BorderRadius radiusOf(int cell) {
    final r = cells[cell];
    const eps = 0.5;
    Radius corner(bool outer) => Radius.circular(outer ? MediaGridMetrics.outerRadius : MediaGridMetrics.innerRadius);
    final left = r.left < eps;
    final top = r.top < eps;
    final right = (size.width - r.right).abs() < eps;
    final bottom = (size.height - r.bottom).abs() < eps;
    return BorderRadius.only(
      topLeft: corner(left && top),
      topRight: corner(right && top),
      bottomLeft: corner(left && bottom),
      bottomRight: corner(right && bottom),
    );
  }
}

/// Lays out [count] cells of one [aspect] (width / height; 1 when unknown) in
/// [width], no taller than [maxHeight]: a group too tall at full width gets
/// narrower, keeping its shape and its 4 gaps.
MediaGridLayout layoutMediaGrid({
  required int count,
  required double aspect,
  required double width,
  required double maxHeight,
}) {
  final a = aspect.isFinite && aspect > 0 ? aspect : 1.0;
  final n = math.max(1, count);
  final full = _layout(n, a, width);
  if (full.size.height <= maxHeight + 0.01) return full;
  // Every length is affine in the group's width (cells scale, gaps don't):
  // find the width whose height is maxHeight from two samples.
  final half = _layout(n, a, width / 2);
  final slope = (full.size.height - half.size.height) / (width / 2);
  if (slope <= 0) return full;
  final fitted = width - (full.size.height - maxHeight) / slope;
  return _layout(n, a, math.max(0, fitted));
}

MediaGridLayout _layout(int n, double a, double width) {
  const gap = MediaGridMetrics.gap;
  final wideBatch = a >= MediaGridMetrics.wide;
  List<Rect> cells;
  switch (n) {
    case 1:
      cells = [Rect.fromLTWH(0, 0, width, width / a)];
    case 2 || 3 when wideBatch:
      final h = width / a;
      cells = [for (var i = 0; i < n; i++) Rect.fromLTWH(0, i * (h + gap), width, h)];
    case 2:
      final w = (width - gap) / 2;
      cells = [Rect.fromLTWH(0, 0, w, w / a), Rect.fromLTWH(w + gap, 0, w, w / a)];
    case 3:
      // One large on the left as tall as the two small ones stacked:
      // large / a = 2 · small / a + gap, large + gap + small = width.
      final small = (width - gap - gap * a) / 3;
      final large = width - gap - small;
      cells = [
        Rect.fromLTWH(0, 0, large, large / a),
        Rect.fromLTWH(large + gap, 0, small, small / a),
        Rect.fromLTWH(large + gap, small / a + gap, small, small / a),
      ];
    default:
      // 2 × 2 (more would go on, two to a row).
      final w = (width - gap) / 2;
      final h = w / a;
      cells = [for (var i = 0; i < n; i++) Rect.fromLTWH((i % 2) * (w + gap), (i ~/ 2) * (h + gap), w, h)];
  }
  final size = Size(cells.map((r) => r.right).reduce(math.max), cells.map((r) => r.bottom).reduce(math.max));
  return MediaGridLayout(size, cells);
}

/// The single picture's box (n = 1): `min(width, H × aspect)` wide.
Size singleMediaSize({required double aspect, required double width, required double maxHeight}) =>
    layoutMediaGrid(count: 1, aspect: aspect, width: width, maxHeight: maxHeight).size;
