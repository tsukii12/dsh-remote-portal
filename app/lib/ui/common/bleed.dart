import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// 让一行的**点按高亮**比它的内容宽出 [horizontal],内容本身仍贴着所在列的
/// 左右边缘。
///
/// 聊天里的工具行、思考行、操作图标都要和正文左缘对齐;可它们的水波纹需要
/// 一点内边距才不显得局促。整行平移(`Transform.translate`)会让右端跟着缩进去,
/// 所以反过来:子组件按「列宽 + 2×[horizontal]」布局,
/// 画在 `-horizontal` 处,自己只报告列宽 —— 内容的左右两端都和正文对齐,
/// 高亮向两侧各溢出 [horizontal],溢出部分照样能点。
///
/// 子组件里通常是 `InkWell` + `Padding(horizontal: horizontal)`。
class Bleed extends SingleChildRenderObjectWidget {
  const Bleed({super.key, this.horizontal = 6, super.child});

  final double horizontal;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBleed(horizontal);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderBleed).bleed = horizontal;
  }
}

class _RenderBleed extends RenderShiftedBox {
  _RenderBleed(this._bleed) : super(null);

  double _bleed;
  set bleed(double value) {
    if (value == _bleed) return;
    _bleed = value;
    markNeedsLayout();
  }

  BoxConstraints _inner(BoxConstraints c) => BoxConstraints(
    minWidth: c.minWidth + 2 * _bleed,
    maxWidth: c.maxWidth.isFinite ? c.maxWidth + 2 * _bleed : c.maxWidth,
    minHeight: c.minHeight,
    maxHeight: c.maxHeight,
  );

  Size _outer(BoxConstraints c, Size child) => c.constrain(Size(math.max(0, child.width - 2 * _bleed), child.height));

  @override
  double computeMinIntrinsicWidth(double height) =>
      math.max(0, (child?.getMinIntrinsicWidth(height) ?? 0) - 2 * _bleed);

  @override
  double computeMaxIntrinsicWidth(double height) =>
      math.max(0, (child?.getMaxIntrinsicWidth(height) ?? 0) - 2 * _bleed);

  @override
  double computeMinIntrinsicHeight(double width) => child?.getMinIntrinsicHeight(width + 2 * _bleed) ?? 0;

  @override
  double computeMaxIntrinsicHeight(double width) => child?.getMaxIntrinsicHeight(width + 2 * _bleed) ?? 0;

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final child = this.child;
    if (child == null) return constraints.smallest;
    return _outer(constraints, child.getDryLayout(_inner(constraints)));
  }

  @override
  double? computeDryBaseline(BoxConstraints constraints, TextBaseline baseline) =>
      child?.getDryBaseline(_inner(constraints), baseline);

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(_inner(constraints), parentUsesSize: true);
    size = _outer(constraints, child.size);
    (child.parentData! as BoxParentData).offset = Offset(-_bleed, 0);
  }

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    final inside =
        position.dy >= 0 && position.dy < size.height && position.dx >= -_bleed && position.dx < size.width + _bleed;
    if (!inside) return false;
    if (hitTestChildren(result, position: position) || hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}
