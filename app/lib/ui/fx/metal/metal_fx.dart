// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'metal_bend.dart';
import 'metal_geometry.dart';
import 'metal_glow.dart';
import 'metal_material.dart';
import 'metal_shader.dart';

/// [MetalFx] 的两种外形：胶囊按钮（1 px 金属环），圆形图标按钮（2 px 环）。
enum MetalFxVariant { button, circle }

/// 液态金属环（metal-fx v2 的 `<MetalFx>`）：把 [child] 包成一个金属描边的按钮，环上有
/// 缓慢游走的高光；按下时环像液体一样被手指压弯，松手弹回。
///
/// 用在一屏唯一的高级行动按钮上（「升级」「开始」这类），一页只放一个金属元素。
/// 尺寸跟着 [child] 走；图标按钮请给 child 定宽高。高光会溢出控件约 50 px，祖先别裁剪。
class MetalFx extends StatefulWidget {
  const MetalFx({
    super.key,
    required this.child,
    this.variant = MetalFxVariant.button,
    this.preset,
    this.material,
    this.brightness,
    this.strength = 1,
    this.shaderScale,
    this.ringWidth,
    this.borderRadius,
    this.innerShadow = false,
    this.glow = true,
    this.glowGain = 1,
    this.paused = false,
    this.sweep = const MetalSweep(),
    this.pressBend = true,
    this.fill,
  });

  final Widget child;
  final MetalFxVariant variant;

  /// 原作配色；null 时用跟主题的石墨银（[MetalMaterial.themed]）。
  final MetalPreset? preset;

  /// 直接给材质参数，优先于 [preset]。
  final MetalMaterial? material;

  /// 用哪一套深浅调校；null 跟主题（原作的 `theme="auto"`）。
  final Brightness? brightness;

  /// 0..1，乘在金属不透明度和高光上。
  final double strength;

  /// 材质缩放；默认按钮 1.6、圆钮 1.3。
  final double? shaderScale;

  /// 环宽，px；默认按钮 1、圆钮 2。
  final double? ringWidth;

  /// 圆角；默认全圆（胶囊）。圆钮总是正圆。
  final double? borderRadius;

  /// 环顶内沿的一道细亮线（Figma 内阴影）。原作的圆钮示例是开的。
  final bool innerShadow;

  /// 游走的高光（原作 `disableGlow` 的反面）。
  final bool glow;

  /// 只乘在高光上的系数，和 [strength] 相乘后截到 0..1。
  final double glowGain;

  /// 停在当前帧。
  final bool paused;

  /// 自己扫过的光（代替桌面上的光标光源）；null 关掉。
  final MetalSweep? sweep;

  /// 按下时环被压弯（代替桌面上的光标弯折）。只听按在 [child] 上的触点，按钮本身就接得住。
  final bool pressBend;

  /// 环里面的底色；默认深色 #272727、浅色白。
  final Color? fill;

  @override
  State<MetalFx> createState() => _MetalFxState();
}

typedef _RingStyle = ({
  MetalMaterial material,
  bool dark,
  bool circle,
  double strength,
  double shaderScale,
  double ring,
  double? borderRadius,
  bool innerShadow,
  bool glow,
  double glowGain,
  MetalSweep? sweep,
  bool bend,
  Color fill,
  double dpr,
});

class _MetalFxState extends MetalState<MetalFx> {
  final _glow = MetalGlowState();
  final _bend = MetalBendModel();
  final _sweep = MetalSweepTracker();
  Offset? _pointer;
  bool _pressed = false;
  MetalGlowFrame? _glowFrame;
  MetalBendField? _field;
  double? _steppedAt;
  Size? _steppedSize;
  _RingStyle? _steppedStyle;
  _RingPaths? _rigid;
  Object? _rigidKey;
  final _fillPaint = Paint();
  final _rimPaint = Paint();
  final _hairlinePaint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1
    ..color = const Color(0x73000000);

  /// The ring's outlines; rebuilt every frame only while bent.
  _RingPaths _paths(Size size, double radius, double ring, double rim, double overflow, MetalDeform? deform) {
    if (deform == null) {
      final key = (size, radius, ring, rim, overflow);
      if (key == _rigidKey) return _rigid!;
      _rigidKey = key;
      return _rigid = _RingPaths(size, radius, ring, rim, overflow, null);
    }
    return _RingPaths(size, radius, ring, rim, overflow, deform);
  }

  @override
  bool get paused => widget.paused;

  @override
  bool get busy => _pointer != null || _bend.busy;

  void _down(PointerDownEvent e) {
    _pointer = e.localPosition;
    _pressed = true;
    syncTicker();
  }

  void _move(PointerMoveEvent e) {
    if (_pointer != null) _pointer = e.localPosition;
  }

  void _up(PointerEvent e) {
    _pointer = null;
    _pressed = false;
  }

  /// Steps the bend, the sweep and the halo once per frame.
  void _advance(_RingStyle st, Size size, double radius, MetalShapeKind kind, MetalSampler sampler) {
    if (_steppedAt == wallMs && _steppedSize == size && _steppedStyle == st) return;
    _steppedAt = wallMs;
    _steppedSize = size;
    _steppedStyle = st;
    _field = st.bend ? _bend.step(wallMs / 1000, _pointer, pressed: _pressed, size: size, radius: radius) : null;
    if (!st.glow) return;
    _glow.configure(size, radius, kind);
    final strength = st.strength * st.glowGain;
    final deform = _field?.deform;
    if (reduced || (paused && _glowFrame == null)) {
      _glowFrame = _glow.still(sampler, strength: strength, dark: st.dark, deform: deform);
    } else if (!paused) {
      final light = st.sweep == null ? null : _sweep.step(clockMs, st.sweep!, size, radius, kind);
      _glowFrame = _glow.tick(clockMs, sampler, strength: strength, dark: st.dark, deform: deform, light: light);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = widget.brightness ?? theme.brightness;
    final dark = brightness == Brightness.dark;
    final circle = widget.variant == MetalFxVariant.circle;
    final style = (
      material: widget.material ?? MetalMaterial.resolve(widget.preset, theme.colorScheme.primary, brightness),
      dark: dark,
      circle: circle,
      strength: widget.strength.clamp(0.0, 1.0),
      shaderScale: widget.shaderScale ?? (circle ? 1.3 : 1.6),
      ring: widget.ringWidth ?? (circle ? 2.0 : 1.0),
      borderRadius: widget.borderRadius,
      innerShadow: widget.innerShadow,
      glow: widget.glow,
      glowGain: math.max(0.0, widget.glowGain),
      sweep: widget.sweep,
      bend: widget.pressBend && !reduced,
      fill: widget.fill ?? (dark ? const Color(0xFF272727) : const Color(0xFFFFFFFF)),
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
    final fg = dark ? const Color(0xFFF8F8F8) : const Color(0xFF1D1D1D);
    Widget child = CustomPaint(
      painter: _RingPainter(this, style),
      child: RepaintBoundary(
        child: DefaultTextStyle.merge(
          style: TextStyle(color: fg),
          child: IconTheme.merge(
            data: IconThemeData(color: fg),
            child: widget.child,
          ),
        ),
      ),
    );
    if (style.bend) {
      child = Listener(
        onPointerDown: _down,
        onPointerMove: _move,
        onPointerUp: _up,
        onPointerCancel: _up,
        child: child,
      );
    }
    return RepaintBoundary(child: child);
  }
}

/// The ring's layers, bottom to top as on the web: the surface, the metal band,
/// the circle variant's dark hairline, the halo, the inner-shadow rim and the
/// `::after` edge rim. The child paints above all of them.
class _RingPainter extends CustomPainter {
  _RingPainter(this.state, this.style) : super(repaint: state.repaint);

  final _MetalFxState state;
  final _RingStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final st = style, s = state;
    final kind = st.circle ? MetalShapeKind.circle : MetalShapeKind.pill;
    final radius = st.circle
        ? size.shortestSide / 2
        : math.min(st.borderRadius ?? double.infinity, size.shortestSide / 2);
    final mapping = MetalSheetMapping(size, st.shaderScale);
    final time = s.seconds;
    (double, double, double) sampler(Offset p) {
      final (u, v) = mapping.uv(p);
      return st.material.sample(u, v, time);
    }

    s._advance(st, size, radius, kind, sampler);
    final box = Offset.zero & size;
    final ratio = MetalGeometry.shapePerim(size.width, size.height, radius, kind) / MetalGeometry.rrPerim(140, 40, 20);
    final paths = s._paths(
      size,
      radius,
      st.ring,
      st.circle ? 2 : 1,
      MetalGlowPainter.overflow(ratio),
      s._field?.deform,
    );

    canvas.drawPath(paths.outer, s._fillPaint..color = st.fill);
    canvas.drawPath(
      paths.band,
      s.shading.paint(st.material, mapping, size, time, st.strength * st.material.shaderOpacity, st.dpr),
    );
    if (st.circle && st.dark) canvas.drawPath(paths.hairline, s._hairlinePaint);
    final frame = s._glowFrame;
    if (st.glow && frame != null) {
      MetalGlowPainter.paintRing(
        canvas,
        frame,
        box: box,
        band: paths.rim,
        surround: paths.surround,
        ratio: ratio,
        dpr: st.dpr,
        dark: st.dark,
        small: st.circle,
      );
    }
    if (st.innerShadow) paintInnerShadow(canvas, box, (c, offset) => c.drawPath(paths.band.shift(offset), Paint()));
    canvas.drawPath(paths.rim, s._rimPaint..color = st.dark ? const Color(0x1AFFFFFF) : const Color(0x0F000000));
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => oldDelegate.style != style;
}

class _RingPaths {
  _RingPaths(Size size, double radius, double ring, double rim, double overflow, MetalDeform? deform)
    : outer = MetalGeometry.roundRect(Offset.zero & size, radius, deform),
      band = MetalGeometry.band(size, radius, ring, deform),
      rim = MetalGeometry.band(size, radius, rim, deform),
      hairline = MetalGeometry.roundRect((Offset.zero & size).inflate(0.5), radius + 0.5, deform) {
    surround = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(overflow))
      ..addPath(outer, Offset.zero);
  }

  final Path outer;

  /// The metal band.
  final Path band;

  /// The `::after` rim and the halo's full-strength band.
  final Path rim;

  /// The circle variant's dark hairline just outside the box.
  final Path hairline;

  /// Everything outside the ring, where the halo shows at half strength.
  late final Path surround;
}

/// The Figma inner shadow (white 90 %, offset 0/1, blur 0.5): the silhouette
/// minus itself shifted down, blurred, kept inside the silhouette — a hairline
/// of light along every top edge. [silhouette] paints the shape at an offset
/// (its colour does not matter, only its coverage).
void paintInnerShadow(Canvas canvas, Rect box, void Function(Canvas canvas, Offset offset) silhouette) {
  // Room for glyph overhang and a bent ring bulging past the box.
  final bounds = box.inflate(16);
  canvas.saveLayer(bounds, Paint()..color = const Color(0xE6FFFFFF));
  canvas.saveLayer(bounds, Paint()..imageFilter = ui.ImageFilter.blur(sigmaX: 0.5, sigmaY: 0.5));
  silhouette(canvas, Offset.zero);
  canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstOut);
  silhouette(canvas, const Offset(0, 1));
  canvas
    ..restore()
    ..restore();
  canvas.saveLayer(bounds, Paint()..blendMode = BlendMode.dstIn);
  silhouette(canvas, Offset.zero);
  canvas
    ..restore()
    ..drawPaint(
      Paint()
        ..blendMode = BlendMode.srcIn
        ..color = const Color(0xFFFFFFFF),
    )
    ..restore();
}
