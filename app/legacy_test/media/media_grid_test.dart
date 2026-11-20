// The media grid's geometry (media-generation §5.1), measured: column widths
// 288 (320dp phone), 358 (390dp) and the 688 reading column; n = 1–4; square,
// portrait and wide batches; the height cap H = min(480, 0.6 × window).

import 'package:dsh_app/ui/chat/media/media_grid.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const _eps = 0.01;

void _expectGaps(MediaGridLayout layout) {
  final cells = layout.cells;
  for (var i = 0; i < cells.length; i++) {
    final a = cells[i];
    double? below;
    double? right;
    for (var j = 0; j < cells.length; j++) {
      if (i == j) continue;
      final b = cells[j];
      expect(a.overlaps(b.deflate(0.01)), isFalse, reason: 'cells $i and $j overlap');
      final sameColumn = a.left < b.right - _eps && b.left < a.right - _eps;
      final sameRow = a.top < b.bottom - _eps && b.top < a.bottom - _eps;
      if (sameColumn && b.top >= a.bottom - _eps) {
        final gap = b.top - a.bottom;
        below = below == null || gap < below ? gap : below;
      }
      if (sameRow && b.left >= a.right - _eps) {
        final gap = b.left - a.right;
        right = right == null || gap < right ? gap : right;
      }
    }
    // The nearest neighbour below and to the right is exactly 4 away.
    if (below != null) expect(below, moreOrLessEquals(MediaGridMetrics.gap, epsilon: _eps));
    if (right != null) expect(right, moreOrLessEquals(MediaGridMetrics.gap, epsilon: _eps));
  }
}

void main() {
  test('H is 480, or 0.6 of a short window', () {
    expect(MediaGridMetrics.maxHeightFor(844), 480);
    expect(MediaGridMetrics.maxHeightFor(412), moreOrLessEquals(247.2, epsilon: _eps));
  });

  group('one', () {
    test('a square fills the column', () {
      final l = layoutMediaGrid(count: 1, aspect: 1, width: 288, maxHeight: 480);
      expect(l.size, const Size(288, 288));
      expect(l.cells.single.topLeft, Offset.zero);
      expect(l.radiusOf(0), BorderRadius.circular(20));
    });

    test('a portrait gets narrower, never wider than H × aspect', () {
      final l = layoutMediaGrid(count: 1, aspect: 9 / 16, width: 288, maxHeight: 480);
      expect(l.size.height, moreOrLessEquals(480, epsilon: _eps));
      expect(l.size.width, moreOrLessEquals(270, epsilon: _eps));
    });

    test('on a phone on its side the whole card fits', () {
      final h = MediaGridMetrics.maxHeightFor(412);
      final l = layoutMediaGrid(count: 1, aspect: 1, width: 688, maxHeight: h);
      expect(l.size.height, moreOrLessEquals(h, epsilon: _eps));
      expect(l.size.width, moreOrLessEquals(h, epsilon: _eps));
    });

    test('a wide one is the column wide', () {
      final l = layoutMediaGrid(count: 1, aspect: 16 / 9, width: 288, maxHeight: 480);
      expect(l.size, const Size(288, 162));
    });
  });

  for (final width in [288.0, 358.0, 688.0]) {
    for (final (name, aspect) in [
      ('square', 1.0),
      ('portrait 3:4', 0.75),
      ('portrait 9:16', 9 / 16),
      ('wide 16:9', 16 / 9),
    ]) {
      for (final n in [2, 3, 4]) {
        test('$n $name in $width: inside the column and under H, 4 apart, left-aligned', () {
          final l = layoutMediaGrid(count: n, aspect: aspect, width: width, maxHeight: 480);
          expect(l.cells, hasLength(n));
          expect(l.size.width, lessThanOrEqualTo(width + _eps));
          expect(l.size.height, lessThanOrEqualTo(480 + _eps));
          expect(l.cells.map((c) => c.left).reduce((a, b) => a < b ? a : b), moreOrLessEquals(0, epsilon: _eps));
          _expectGaps(l);
          // Every cell keeps the batch's aspect.
          for (final c in l.cells) {
            expect(c.width / c.height, moreOrLessEquals(aspect, epsilon: 0.001));
          }
          // A group that fits at full width takes all of it.
          if (l.size.height < 480 - _eps) expect(l.size.width, moreOrLessEquals(width, epsilon: _eps));
        });
      }
    }
  }

  test('two square or portrait side by side, two wide stacked', () {
    final side = layoutMediaGrid(count: 2, aspect: 1, width: 288, maxHeight: 480);
    expect(side.cells[0].top, side.cells[1].top);
    expect(side.cells[0].width, moreOrLessEquals(142, epsilon: _eps));
    final stacked = layoutMediaGrid(count: 2, aspect: 1.25, width: 288, maxHeight: 480);
    expect(stacked.cells[0].left, stacked.cells[1].left);
    expect(stacked.cells[1].top, moreOrLessEquals(stacked.cells[0].bottom + 4, epsilon: _eps));
  });

  test('three square: one large left, the two small as tall as it', () {
    final l = layoutMediaGrid(count: 3, aspect: 1, width: 288, maxHeight: 480);
    final [large, top, bottom] = l.cells;
    expect(large.height, moreOrLessEquals(bottom.bottom - top.top, epsilon: _eps));
    expect(top.left, moreOrLessEquals(large.right + 4, epsilon: _eps));
    expect(top.right, moreOrLessEquals(288, epsilon: _eps));
  });

  test('three wide stack', () {
    final l = layoutMediaGrid(count: 3, aspect: 16 / 9, width: 288, maxHeight: 480);
    expect({for (final c in l.cells) c.left}, {0.0});
    expect(l.size.height, lessThanOrEqualTo(480 + _eps));
  });

  test('four 9:16 at 320dp: cells 142 wide, too tall, narrowed to about 272 (the design\'s numbers)', () {
    final full = layoutMediaGrid(count: 4, aspect: 9 / 16, width: 288, maxHeight: double.infinity);
    expect(full.cells.first.width, moreOrLessEquals(142, epsilon: _eps));
    expect(full.size.height, greaterThan(480));
    final l = layoutMediaGrid(count: 4, aspect: 9 / 16, width: 288, maxHeight: 480);
    expect(l.size.height, moreOrLessEquals(480, epsilon: _eps));
    expect(l.size.width, moreOrLessEquals(271.75, epsilon: _eps));
  });

  test('corners: 20 outside, 8 inside', () {
    final l = layoutMediaGrid(count: 4, aspect: 1, width: 288, maxHeight: 480);
    expect(
      l.radiusOf(0),
      const BorderRadius.only(
        topLeft: Radius.circular(20),
        topRight: Radius.circular(8),
        bottomLeft: Radius.circular(8),
        bottomRight: Radius.circular(8),
      ),
    );
    expect(l.radiusOf(3).bottomRight, const Radius.circular(20));
    expect(l.radiusOf(3).topLeft, const Radius.circular(8));
    final three = layoutMediaGrid(count: 3, aspect: 1, width: 288, maxHeight: 480);
    expect(three.radiusOf(0).topLeft, const Radius.circular(20));
    expect(three.radiusOf(0).bottomLeft, const Radius.circular(20));
    expect(three.radiusOf(0).topRight, const Radius.circular(8));
    expect(three.radiusOf(1).topRight, const Radius.circular(20));
    expect(three.radiusOf(2).bottomRight, const Radius.circular(20));
  });
}
