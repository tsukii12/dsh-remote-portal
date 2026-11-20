// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'metal_geometry.dart';
import 'metal_glow.dart';
import 'metal_material.dart';
import 'metal_shader.dart';

/// 徽标中间那块干净的白底（原作的 `core`）：椭圆径向渐变。
@immutable
class MetalBadgeCore {
  const MetalBadgeCore({this.r = 46, this.blur = 100, this.a = 0.94, this.size = 49});

  /// Solid radius, % of the ellipse.
  final double r;

  /// Ramp width, %.
  final double blur;

  /// Opacity.
  final double a;

  /// Ellipse size, % of the box.
  final double size;

  @override
  bool operator ==(Object other) =>
      other is MetalBadgeCore && other.r == r && other.blur == blur && other.a == a && other.size == size;

  @override
  int get hashCode => Object.hash(r, blur, a, size);
}

/// 「新」「New」金属小徽标（metal-fx v2 的 `<MetalBadge>`，Figma 1458:40880 原样）：白色胶囊，
/// 金属盖在上面，文字下面留一块干净的白芯，所以金属只在边上；内侧有白色柔光和细亮边，
/// 边上有游走的高光。尺寸按 Figma（45×25、字号 12.222）乘 [scale]，字长了会变宽。
class MetalBadge extends StatefulWidget {
  const MetalBadge({
    super.key,
    this.text = 'New',
    this.preset,
    this.material,
    this.brightness,
    this.strength = 1,
    this.scale = 1,
    this.metalOpacity = 0.8,
    this.shaderScale = 1.6,
    this.core = const MetalBadgeCore(),
    this.gradient = 0,
    this.glow = 0.41,
    this.textColor = const Color(0xFF323232),
    this.halo = true,
    this.sweep = const MetalSweep(),
    this.paused = false,
  });

  final String text;

  /// 原作配色；null 时用跟主题的石墨银。
  final MetalPreset? preset;
  final MetalMaterial? material;
  final Brightness? brightness;

  /// 0..1，乘在金属和高光上。
  final double strength;

  /// 乘在 Figma 尺寸上。
  final double scale;

  /// 金属盖在白底上的量（0..1），再乘 [strength]。
  final double metalOpacity;
  final double shaderScale;
  final MetalBadgeCore core;

  /// 从上到下的白色渐层（0..1）。
  final double gradient;

  /// 内侧白色柔光的强度（0..1）。
  final double glow;
  final Color textColor;

  /// 边上游走的高光（原作徽标是开的）。
  final bool halo;

  /// 自己扫过的光；null 关掉。
  final MetalSweep? sweep;
  final bool paused;

  static const _width = 45.0, _height = 25.0, _radius = 55.556, _textWidth = 26.667, _fontSize = 12.222;

  @override
  State<MetalBadge> createState() => _MetalBadgeState();
}

typedef _BadgeStyle = ({
  MetalMaterial material,
  bool dark,
  double strength,
  double metalOpacity,
  double shaderScale,
  double radius,
  bool halo,
  MetalSweep? sweep,
  double dpr,
});

class _MetalBadgeState extends MetalState<MetalBadge> {
  final _glow = MetalGlowState();
  final _sweep = MetalSweepTracker();
  final _fillPaint = Paint()..color = const Color(0xFFFFFFFF);
  MetalGlowFrame? _glowFrame;
  double? _steppedAt;
  Object? _steppedKey;

  @override
  bool get paused => widget.paused;

  void _advance(_BadgeStyle st, Size size, MetalSampler sampler) {
    if (!st.halo) return;
    final key = (size, st);
    if (_steppedAt == wallMs && _steppedKey == key) return;
    _steppedAt = wallMs;
    _steppedKey = key;
    _glow.configure(size, st.radius, MetalShapeKind.pill);
    final strength = st.strength * st.metalOpacity;
    if (reduced || (paused && _glowFrame == null)) {
      _glowFrame = _glow.still(sampler, strength: strength, dark: st.dark);
    } else if (!paused) {
      final light = st.sweep == null ? null : _sweep.step(clockMs, st.sweep!, size, st.radius, MetalShapeKind.pill);
      _glowFrame = _glow.tick(clockMs, sampler, strength: strength, dark: st.dark, light: light);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = widget.brightness ?? theme.brightness;
    final k = widget.scale;
    final textStyle = DefaultTextStyle.of(context).style.merge(
      TextStyle(
        fontSize: MetalBadge._fontSize * k,
        fontWeight: FontWeight.w600,
        height: 1.4,
        letterSpacing: 0,
        color: widget.textColor,
      ),
    );
    final scaler = MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
    final label = TextPainter(
      text: TextSpan(text: widget.text, style: textStyle),
      textDirection: Directionality.of(context),
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    final padX = (MetalBadge._width - MetalBadge._textWidth) / 2 * k;
    final width = math.max(MetalBadge._width * k, label.width + 2 * padX);
    final height = math.max(MetalBadge._height * k, label.height + 6 * k);
    label.dispose();
    final style = (
      material: widget.material ?? MetalMaterial.resolve(widget.preset, theme.colorScheme.primary, brightness),
      dark: brightness == Brightness.dark,
      strength: widget.strength.clamp(0.0, 1.0),
      metalOpacity: widget.metalOpacity,
      shaderScale: widget.shaderScale,
      radius: math.min(MetalBadge._radius * k, height / 2),
      halo: widget.halo,
      sweep: widget.sweep,
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
    return SizedBox(
      width: width,
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: RepaintBoundary(child: CustomPaint(painter: _BadgeMetalPainter(this, style))),
          ),
          Positioned.fill(
            child: CustomPaint(
              painter: _BadgeOverlayPainter(
                radius: style.radius,
                scale: k,
                dark: style.dark,
                core: widget.core,
                gradient: widget.gradient,
                glow: widget.glow,
              ),
            ),
          ),
          Center(
            child: Text(widget.text, style: textStyle, textScaler: scaler, maxLines: 1, softWrap: false),
          ),
        ],
      ),
    );
  }
}

/// The white pill, the metal over it and the halo along its edge.
class _BadgeMetalPainter extends CustomPainter {
  _BadgeMetalPainter(this.state, this.style) : super(repaint: state.repaint);

  final _MetalBadgeState state;
  final _BadgeStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final st = style, s = state;
    final box = Offset.zero & size;
    final pill = RRect.fromRectAndRadius(box, Radius.circular(st.radius));
    final mapping = MetalSheetMapping(size, st.shaderScale);
    final time = s.seconds;
    canvas
      ..drawRRect(pill, s._fillPaint)
      ..drawRRect(
        pill,
        s.shading.paint(
          st.material,
          mapping,
          size,
          time,
          st.strength * st.metalOpacity * st.material.shaderOpacity,
          st.dpr,
        ),
      );
    if (!st.halo) return;
    (double, double, double) sampler(Offset p) {
      final (u, v) = mapping.uv(p);
      return st.material.sample(u, v, time);
    }

    s._advance(st, size, sampler);
    final frame = s._glowFrame;
    if (frame == null) return;
    final ratio = MetalGeometry.rrPerim(size.width, size.height, st.radius) / MetalGeometry.rrPerim(140, 40, 20);
    MetalGlowPainter.paintRing(
      canvas,
      frame,
      box: box,
      band: MetalGeometry.band(size, st.radius, 1, null),
      surround: Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(box.inflate(MetalGlowPainter.overflow(ratio)))
        ..addRRect(pill),
      ratio: ratio,
      dpr: st.dpr,
      dark: st.dark,
      small: false,
    );
  }

  @override
  bool shouldRepaint(_BadgeMetalPainter oldDelegate) => oldDelegate.style != style;
}

/// What sits above the metal and under the label: the `::after` edge rim, the
/// clean white core, the top wash, the two inset white glows, the 0.833 px
/// hairline and the top rim. Static.
class _BadgeOverlayPainter extends CustomPainter {
  const _BadgeOverlayPainter({
    required this.radius,
    required this.scale,
    required this.dark,
    required this.core,
    required this.gradient,
    required this.glow,
  });

  final double radius;
  final double scale;
  final bool dark;
  final MetalBadgeCore core;
  final double gradient;
  final double glow;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    final pill = RRect.fromRectAndRadius(box, Radius.circular(radius));
    final k = scale;
    canvas.drawDRRect(pill, pill.deflate(1), Paint()..color = dark ? const Color(0x1AFFFFFF) : const Color(0x0F000000));
    canvas
      ..save()
      ..clipRRect(pill);

    // Clean white core: CSS `radial-gradient(ellipse size% size%, white r%,
    // transparent (r+blur)%)` at the core's opacity.
    final rx = size.width * core.size / 100, ry = size.height * core.size / 100;
    canvas
      ..save()
      ..translate(size.width / 2, size.height / 2)
      ..scale(rx, ry)
      ..drawCircle(
        Offset.zero,
        1,
        Paint()
          ..shader = RadialGradient(
            colors: [
              Color.from(alpha: core.a, red: 1, green: 1, blue: 1),
              const Color(0x00FFFFFF),
            ],
            stops: [core.r / 100, math.min(1.0, (core.r + core.blur) / 100)],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1)),
      )
      ..restore();

    if (gradient > 0) {
      canvas.drawRect(
        box,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color.from(alpha: gradient, red: 1, green: 1, blue: 1),
              const Color(0x00FFFFFF),
            ],
          ).createShader(box),
      );
    }

    // Inset shadows: two soft white inner glows (0 0 8.333 px), the 0.833 px
    // hairline at 50 % and the top rim (0 0.833 0) at 78 %.
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(box.inflate(30 * k))
      ..addRRect(pill);
    final inner = Paint()
      ..color = Color.from(alpha: glow, red: 1, green: 1, blue: 1)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8.333 * k / 2);
    canvas
      ..drawPath(outside, inner)
      ..drawPath(outside, inner)
      ..drawDRRect(pill, pill.deflate(0.833 * k), Paint()..color = const Color(0x80FFFFFF))
      ..drawPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(box.inflate(2))
          ..addRRect(pill.shift(Offset(0, 0.833 * k))),
        Paint()..color = const Color(0xC7FFFFFF),
      )
      ..restore();
  }

  @override
  bool shouldRepaint(_BadgeOverlayPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.scale != scale ||
      oldDelegate.dark != dark ||
      oldDelegate.core != core ||
      oldDelegate.gradient != gradient ||
      oldDelegate.glow != glow;
}
