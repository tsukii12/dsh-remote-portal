import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'motion.dart';

/// 按压光晕:从指尖亮起的一团柔光,松手淡掉。灵动档的主题默认水波(见 `app_theme.dart`)。
///
/// 只在按压时画一个径向渐变,比系统默认的 InkSparkle(逐像素噪点着色器)便宜,
/// 没有离屏层,也不模糊。
class AppInkGlow extends InteractiveInkFeature {
  AppInkGlow({
    required MaterialInkController controller,
    required super.referenceBox,
    required Offset position,
    required super.color,
    required this._textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    this._customBorder,
    double? radius,
    super.onRemoved,
  }) : _position = position,
       _clip = containedInkWell ? (rectCallback ?? () => Offset.zero & referenceBox.size) : rectCallback,
       _borderRadius = borderRadius ?? BorderRadius.zero,
       _target = radius ?? _reach(referenceBox, position, containedInkWell, rectCallback),
       super(controller: controller) {
    _grow = AnimationController(vsync: controller.vsync, duration: _growDuration)
      ..addListener(controller.markNeedsPaint)
      ..forward();
    _fade = AnimationController(vsync: controller.vsync, duration: _fadeInDuration)
      ..addListener(controller.markNeedsPaint)
      ..addStatusListener(_fadeStatus)
      ..forward();
    controller.addInkFeature(this);
  }

  static const InteractiveInkFeatureFactory splashFactory = _AppInkGlowFactory();

  static const _growDuration = Duration(milliseconds: 420);
  static const _fadeInDuration = Duration(milliseconds: 90);
  static const _confirmFade = Duration(milliseconds: 260);
  static const _cancelFade = Duration(milliseconds: 160);

  /// 指尖处比主题给的水波色亮这么多:渐变往外淡,平均下来和原来差不多。
  static const _coreBoost = 1.9;

  final Offset _position;
  final TextDirection _textDirection;
  final RectCallback? _clip;
  final BorderRadius _borderRadius;
  final ShapeBorder? _customBorder;
  final double _target;

  late final AnimationController _grow;
  late final AnimationController _fade;

  /// 手指已经抬起或被滚动抢走,淡入结束后接着淡出的时长。
  Duration? _pendingFade;

  static double _reach(RenderBox box, Offset position, bool contained, RectCallback? rectCallback) {
    final rect = rectCallback?.call() ?? Offset.zero & box.size;
    final corners = [rect.topLeft, rect.topRight, rect.bottomLeft, rect.bottomRight];
    final far = corners.map((corner) => (corner - position).distance).reduce(math.max);
    // 只照亮按到的那一片,大块卡片不至于整张亮起来。
    return contained ? math.min(far, 220.0) : Material.defaultSplashRadius;
  }

  void _fadeStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _pendingFade != null) {
      _startFade(_pendingFade!);
    } else if (status == AnimationStatus.dismissed) {
      dispose();
    }
  }

  void _startFade(Duration duration) {
    _pendingFade = null;
    _fade.reverseDuration = duration;
    _fade.reverse();
  }

  void _release(Duration duration) {
    if (_fade.status == AnimationStatus.reverse) return;
    if (_fade.isAnimating) {
      _pendingFade = duration;
    } else {
      _startFade(duration);
    }
  }

  @override
  void confirm() => _release(_confirmFade);

  @override
  void cancel() => _release(_cancelFade);

  @override
  void dispose() {
    _grow.dispose();
    _fade.dispose();
    super.dispose();
  }

  @override
  void paintFeature(Canvas canvas, Matrix4 transform) {
    final opacity = _fade.value;
    if (opacity <= 0) return;
    final radius = _target * (0.35 + 0.65 * Curves.easeOutCubic.transform(_grow.value));
    final core = color.withValues(alpha: math.min(1, color.a * _coreBoost) * opacity);
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        _position,
        radius,
        [core, core.withValues(alpha: core.a * 0.55), core.withValues(alpha: 0)],
        const [0, 0.5, 1],
      );
    paintInkCircle(
      canvas: canvas,
      transform: transform,
      paint: paint,
      center: _position,
      textDirection: _textDirection,
      radius: radius,
      customBorder: _customBorder,
      borderRadius: _borderRadius,
      clipCallback: _clip,
    );
  }
}

class _AppInkGlowFactory extends InteractiveInkFeatureFactory {
  const _AppInkGlowFactory();

  @override
  InteractiveInkFeature create({
    required MaterialInkController controller,
    required RenderBox referenceBox,
    required Offset position,
    required Color color,
    required TextDirection textDirection,
    bool containedInkWell = false,
    RectCallback? rectCallback,
    BorderRadius? borderRadius,
    ShapeBorder? customBorder,
    double? radius,
    VoidCallback? onRemoved,
  }) => AppInkGlow(
    controller: controller,
    referenceBox: referenceBox,
    position: position,
    color: color,
    textDirection: textDirection,
    containedInkWell: containedInkWell,
    rectCallback: rectCallback,
    borderRadius: borderRadius,
    customBorder: customBorder,
    radius: radius,
    onRemoved: onRemoved,
  );
}

/// 给原本不要水波的行([NoSplash]):灵动档换成光晕,标准档还是没有。
InteractiveInkFeatureFactory rowSplash(BuildContext context) =>
    AppMotion.fluid(context) ? AppInkGlow.splashFactory : NoSplash.splashFactory;
