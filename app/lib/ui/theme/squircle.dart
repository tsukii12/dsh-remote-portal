// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'package:flutter/widgets.dart';

/// 连续曲率圆角(超椭圆)。
///
/// 普通圆角在直线与圆弧的接缝处曲率突变,放大能看到"折角";连续曲率圆角让
/// 曲率平滑过渡,这就是 iOS 圆角看着更柔的原因。
///
/// 用引擎原生的 `RoundedSuperellipseBorder`:
/// - 曲线与 iOS 连续圆角同款,而不是近似的 n=5 超椭圆;
/// - Impeller 有专门的快路径,描边与抗锯齿由引擎处理;
/// - 支持 `lerp`:`AnimatedContainer` / `ShapeBorderTween` 的形状动画不跳变;
/// - 描边按 `strokeAlign` 正确内缩。
typedef SquircleBorder = RoundedSuperellipseBorder;

/// 常用连续圆角的快捷构造。
abstract final class Squircle {
  /// 四角同半径的连续圆角边框。
  static RoundedSuperellipseBorder border(double radius, {BorderSide side = BorderSide.none}) =>
      RoundedSuperellipseBorder(borderRadius: BorderRadius.all(Radius.circular(radius)), side: side);

  /// 按连续圆角裁剪子树(图片、代码井、玻璃内容)。
  static Widget clip({required double radius, required Widget child, Clip clipBehavior = Clip.antiAlias}) =>
      ClipRSuperellipse(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        clipBehavior: clipBehavior,
        child: child,
      );
}
