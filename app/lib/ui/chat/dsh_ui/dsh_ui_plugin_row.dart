// One row of view-v2 cells with weighted widths and equal visible heights.
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lays out each cell at its weighted width and natural height, then lays the
/// cells marked [stretch] out again with a *minimum* height equal to the
/// tallest cell. Neither pass makes the height tight, so a cell whose content
/// later grows or shrinks still relayouts the whole row from natural heights.
///
/// This replaces `IntrinsicHeight` (no speculative intrinsic pass, and nested
/// `LayoutBuilder`s are fine) and `Table` (its second, tight pass made a cell a
/// relayout boundary, so a cell that grew afterwards kept the old row height).
///
/// The element structure is the same for every column count, so a cell that
/// stays in place keeps its State when a narrow host wraps the row.
class DshUiEqualRow extends MultiChildRenderObjectWidget {
  const DshUiEqualRow({
    super.key,
    required this.flex,
    required this.stretch,
    this.gap = 0,
    this.align = CrossAxisAlignment.start,
    required super.children,
  }) : assert(flex.length == children.length && stretch.length == children.length);

  /// Positive integer weight per child.
  final List<int> flex;

  /// Whether a child is drawn at the row's full height.
  final List<bool> stretch;
  final double gap;

  /// Vertical placement of the cells that are not stretched.
  final CrossAxisAlignment align;

  @override
  RenderDshUiEqualRow createRenderObject(BuildContext context) => RenderDshUiEqualRow(
    flex: flex,
    stretch: stretch,
    gap: gap,
    align: align,
    textDirection: Directionality.of(context),
  );

  @override
  void updateRenderObject(BuildContext context, RenderDshUiEqualRow renderObject) {
    renderObject
      ..flex = flex
      ..stretch = stretch
      ..gap = gap
      ..align = align
      ..textDirection = Directionality.of(context);
  }
}

class _EqualRowParentData extends ContainerBoxParentData<RenderBox> {}

class RenderDshUiEqualRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _EqualRowParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, _EqualRowParentData> {
  RenderDshUiEqualRow({
    required this._flex,
    required this._stretch,
    required this._gap,
    required this._align,
    required this._textDirection,
  });

  List<int> _flex;
  set flex(List<int> value) {
    if (listEquals(value, _flex)) return;
    _flex = value;
    markNeedsLayout();
  }

  List<bool> _stretch;
  set stretch(List<bool> value) {
    if (listEquals(value, _stretch)) return;
    _stretch = value;
    markNeedsLayout();
  }

  double _gap;
  set gap(double value) {
    if (value == _gap) return;
    _gap = value;
    markNeedsLayout();
  }

  CrossAxisAlignment _align;
  set align(CrossAxisAlignment value) {
    if (value == _align) return;
    _align = value;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection value) {
    if (value == _textDirection) return;
    _textDirection = value;
    markNeedsLayout();
  }

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _EqualRowParentData) child.parentData = _EqualRowParentData();
  }

  int _weight(int i) => i < _flex.length ? math.max(1, _flex[i]) : 1;
  bool _stretches(int i) => i < _stretch.length && _stretch[i];

  /// The same arithmetic as a Row of Expanded children separated by fixed
  /// gaps, so rows without stretched cells keep their former pixels.
  List<double> _widths(double maxWidth) {
    final count = childCount;
    if (count == 0) return const [];
    final total = [for (var i = 0; i < count; i++) _weight(i)].fold(0, (a, b) => a + b);
    final free = math.max(0.0, maxWidth - _gap * (count - 1));
    final perFlex = free / total;
    return [for (var i = 0; i < count; i++) perFlex * _weight(i)];
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    var sum = 0.0;
    var child = firstChild;
    while (child != null) {
      sum += child.getMinIntrinsicWidth(height);
      child = childAfter(child);
    }
    return sum + _gap * math.max(0, childCount - 1);
  }

  @override
  double computeMaxIntrinsicWidth(double height) {
    var sum = 0.0;
    var child = firstChild;
    while (child != null) {
      sum += child.getMaxIntrinsicWidth(height);
      child = childAfter(child);
    }
    return sum + _gap * math.max(0, childCount - 1);
  }

  double _intrinsicHeight(double width, double Function(RenderBox child, double width) measure) {
    if (!width.isFinite) return 0;
    final widths = _widths(width);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      height = math.max(height, measure(child, widths[i++]));
      child = childAfter(child);
    }
    return height;
  }

  @override
  double computeMinIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (child, w) => child.getMinIntrinsicHeight(w));

  @override
  double computeMaxIntrinsicHeight(double width) =>
      _intrinsicHeight(width, (child, w) => child.getMaxIntrinsicHeight(w));

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    if (!constraints.hasBoundedWidth) return constraints.smallest;
    final widths = _widths(constraints.maxWidth);
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      final size = child.getDryLayout(
        BoxConstraints(minWidth: widths[i], maxWidth: widths[i], maxHeight: constraints.maxHeight),
      );
      height = math.max(height, size.height);
      i++;
      child = childAfter(child);
    }
    return constraints.constrain(Size(constraints.maxWidth, height));
  }

  @override
  void performLayout() {
    final constraints = this.constraints;
    if (!constraints.hasBoundedWidth) {
      // Not reachable from a plugin view (its width is always bounded). Lay
      // the cells out side by side at their natural width instead of failing.
      var x = 0.0;
      var height = 0.0;
      var child = firstChild;
      while (child != null) {
        child.layout(BoxConstraints(maxHeight: constraints.maxHeight), parentUsesSize: true);
        (child.parentData! as _EqualRowParentData).offset = Offset(x, 0);
        x += child.size.width + _gap;
        height = math.max(height, child.size.height);
        child = childAfter(child);
      }
      size = constraints.constrain(Size(math.max(0, x - _gap), height));
      return;
    }
    final widths = _widths(constraints.maxWidth);
    // Pass 1: natural heights.
    var height = 0.0;
    var child = firstChild;
    var i = 0;
    while (child != null) {
      child.layout(
        BoxConstraints(minWidth: widths[i], maxWidth: widths[i], maxHeight: constraints.maxHeight),
        parentUsesSize: true,
      );
      height = math.max(height, child.size.height);
      i++;
      child = childAfter(child);
    }
    height = constraints.constrainHeight(height);
    // Pass 2: only shorter stretched cells, with a minimum (not a tight)
    // height whenever the parent leaves room above it.
    child = firstChild;
    i = 0;
    while (child != null) {
      if (_stretches(i) && child.size.height < height) {
        child.layout(
          BoxConstraints(
            minWidth: widths[i],
            maxWidth: widths[i],
            minHeight: height,
            maxHeight: math.max(height, constraints.maxHeight),
          ),
          parentUsesSize: true,
        );
      }
      i++;
      child = childAfter(child);
    }
    final rtl = _textDirection == TextDirection.rtl;
    var x = 0.0;
    child = firstChild;
    i = 0;
    while (child != null) {
      final h = child.size.height;
      final y = _stretches(i)
          ? 0.0
          : switch (_align) {
              CrossAxisAlignment.center => (height - h) / 2,
              CrossAxisAlignment.end => height - h,
              _ => 0.0,
            };
      final left = rtl ? constraints.maxWidth - x - widths[i] : x;
      (child.parentData! as _EqualRowParentData).offset = Offset(left, y);
      x += widths[i] + _gap;
      i++;
      child = childAfter(child);
    }
    size = constraints.constrain(Size(constraints.maxWidth, height));
  }

  @override
  void paint(PaintingContext context, Offset offset) => defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}

/// Shields a stretched cell's content from the extra minimum height: the cell
/// fills the row, its content keeps the same constraints in both passes and
/// sits at the top. Width constraints pass through unchanged. Without it a
/// `LayoutBuilder` inside would see two different constraints per layout.
class DshUiCellFill extends SingleChildRenderObjectWidget {
  const DshUiCellFill({super.key, required super.child});
  @override
  RenderObject createRenderObject(BuildContext context) => _RenderCellFill();
}

class _RenderCellFill extends RenderShiftedBox {
  _RenderCellFill() : super(null);

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return constraints.constrain(child.getDryLayout(constraints.copyWith(minHeight: 0)));
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(constraints.copyWith(minHeight: 0), parentUsesSize: true);
    (child.parentData! as BoxParentData).offset = Offset.zero;
    size = constraints.constrain(child.size);
  }
}
