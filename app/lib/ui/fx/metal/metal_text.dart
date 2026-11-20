// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'metal_fx.dart' show paintInnerShadow;
import 'metal_geometry.dart';
import 'metal_glow.dart';
import 'metal_material.dart';
import 'metal_shader.dart';

/// 字形里的液态金属（metal-fx v2 的 `<MetalText>`）：文字先按 [color] 画出来，金属按
/// `strength × metalOpacity` 盖在字形上，字形顶边有一道细亮线。用在页面的主标题上，一页一处。
///
/// 和 [Text] 一样排版（可换行、对齐、跟随系统字号），语义就是文字本身。
class MetalText extends StatefulWidget {
  const MetalText(
    this.text, {
    super.key,
    this.style,
    this.color,
    this.textAlign,
    this.maxLines,
    this.preset,
    this.material,
    this.brightness,
    this.strength = 1,
    this.metalOpacity,
    this.shaderScale = 2.8,
    this.innerShadow = true,
    this.glow = false,
    this.glowGain = 2.5,
    this.paused = false,
  });

  final String text;

  /// 合并在 [DefaultTextStyle] 上；颜色用 [color]。
  final TextStyle? style;

  /// 金属底下的字色。默认深色 #E2E2E2（原作），浅色是带一点主题色相的石墨色。
  final Color? color;
  final TextAlign? textAlign;
  final int? maxLines;

  /// 原作配色；null 时用跟主题的石墨银。
  final MetalPreset? preset;
  final MetalMaterial? material;
  final Brightness? brightness;

  /// 0..1，乘在金属和高光上。
  final double strength;

  /// 金属盖在字色上的量（0..1），再乘 [strength]。默认深色 0.62（原作）；浅色 0.34——
  /// 材质大部分是亮银，盖多了白底上的字会发灰看不清，浅色只让它在深色字上流过一层光泽。
  final double? metalOpacity;

  /// 字形里金属的缩放。
  final double shaderScale;

  /// 字形顶边的细亮线。
  final bool innerShadow;

  /// 字形上的游走高光。原作默认关（设计稿里没有）。
  final bool glow;
  final double glowGain;
  final bool paused;

  /// The default base colour: the author's #E2E2E2 on dark, graphite with a
  /// trace of the theme's hue on light.
  static Color defaultColor(Color primary, Brightness brightness) => brightness == Brightness.dark
      ? const Color(0xFFE2E2E2)
      : HSLColor.fromAHSL(1, HSLColor.fromColor(primary).hue, 0.08, 0.2).toColor();

  @override
  State<MetalText> createState() => _MetalTextState();
}

typedef _TextStyle = ({
  TextSpan span,
  TextAlign align,
  TextDirection direction,
  TextScaler scaler,
  int? maxLines,
  TextHeightBehavior? heightBehavior,
  MetalMaterial material,
  bool dark,
  double strength,
  double metalOpacity,
  double shaderScale,
  bool glow,
  double glowGain,
  double dpr,
});

class _MetalTextState extends MetalState<MetalText> {
  final _glow = MetalGlowState();
  MetalGlowFrame? _glowFrame;
  double? _steppedAt;
  Object? _steppedKey;

  // White glyphs laid out exactly like the RichText underneath: the mask.
  final _glyphs = TextPainter();
  Object? _glyphKey;

  // Glyph points on a ~2 px grid: where the halo may sit (point mode).
  List<Offset>? _points;
  Object? _pointsKey;

  @override
  bool get paused => widget.paused;

  TextPainter glyphs(_TextStyle st, Size size) {
    final key = (st.span, st.align, st.direction, st.scaler, st.maxLines, st.heightBehavior, size);
    if (key != _glyphKey) {
      _glyphKey = key;
      _glyphs
        ..text = TextSpan(
          text: st.span.text,
          style: st.span.style!.copyWith(color: const Color(0xFFFFFFFF)),
        )
        ..textAlign = st.align
        ..textDirection = st.direction
        ..textScaler = st.scaler
        ..maxLines = st.maxLines
        ..textHeightBehavior = st.heightBehavior
        ..layout(minWidth: size.width, maxWidth: size.width);
    }
    return _glyphs;
  }

  /// Rasterises the glyphs once per layout and keeps the covered points of a
  /// 2-px grid (the SwiftUI port's `rasterizeGlyphs`).
  Future<void> _rasterize(Object key, Size size, TextPainter glyphs) async {
    if (size.width < 1 || size.height < 1) {
      _points = const [];
      return;
    }
    final recorder = ui.PictureRecorder();
    glyphs.paint(Canvas(recorder), Offset.zero);
    final picture = recorder.endRecording();
    final w = size.width.ceil(), h = size.height.ceil();
    final image = await picture.toImage(w, h);
    picture.dispose();
    final data = await image.toByteData();
    image.dispose();
    if (!mounted || key != _pointsKey || data == null) return;
    const step = 2;
    _points = [
      for (var y = step ~/ 2; y < h; y += step)
        for (var x = step ~/ 2; x < w; x += step)
          if (data.getUint8((y * w + x) * 4 + 3) > 128) Offset(x.toDouble(), y.toDouble()),
    ];
    repaint.notify();
  }

  void _advance(_TextStyle st, Size size, MetalSampler sampler, TextPainter glyphs) {
    if (!st.glow) return;
    if (_pointsKey != _glyphKey) {
      _pointsKey = _glyphKey;
      _points = null;
      _rasterize(_glyphKey!, size, glyphs);
    }
    final points = _points;
    if (points == null || points.isEmpty) return;
    if (_steppedAt == wallMs && identical(_steppedKey, _glyphKey) && _steppedKey != null) return;
    _steppedAt = wallMs;
    _steppedKey = _glyphKey;
    _glow.configure(size, 4, MetalShapeKind.pill, points: points);
    final strength = st.strength * st.metalOpacity * st.glowGain;
    if (reduced || (paused && _glowFrame == null)) {
      _glowFrame = _glow.still(sampler, strength: strength, dark: st.dark);
    } else if (!paused) {
      _glowFrame = _glow.tick(clockMs, sampler, strength: strength, dark: st.dark);
    }
  }

  @override
  void dispose() {
    _glyphs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final brightness = widget.brightness ?? theme.brightness;
    final base = DefaultTextStyle.of(context);
    var textStyle = base.style.merge(widget.style);
    if (MediaQuery.boldTextOf(context)) textStyle = textStyle.merge(const TextStyle(fontWeight: FontWeight.bold));
    textStyle = textStyle.copyWith(
      color: widget.color ?? MetalText.defaultColor(theme.colorScheme.primary, brightness),
    );
    final style = (
      span: TextSpan(text: widget.text, style: textStyle),
      align: widget.textAlign ?? base.textAlign ?? TextAlign.start,
      direction: Directionality.of(context),
      scaler: MediaQuery.textScalerOf(context),
      maxLines: widget.maxLines ?? base.maxLines,
      heightBehavior: base.textHeightBehavior ?? DefaultTextHeightBehavior.maybeOf(context),
      material: widget.material ?? MetalMaterial.resolve(widget.preset, theme.colorScheme.primary, brightness),
      dark: brightness == Brightness.dark,
      strength: widget.strength.clamp(0.0, 1.0),
      metalOpacity: widget.metalOpacity ?? (brightness == Brightness.dark ? 0.62 : 0.34),
      shaderScale: widget.shaderScale,
      glow: widget.glow,
      glowGain: widget.glowGain,
      dpr: MediaQuery.devicePixelRatioOf(context),
    );
    final text = RichText(
      text: style.span,
      textAlign: style.align,
      textDirection: style.direction,
      textScaler: style.scaler,
      maxLines: style.maxLines,
      overflow: base.overflow,
      textHeightBehavior: style.heightBehavior,
    );
    final metal = RepaintBoundary(
      child: CustomPaint(foregroundPainter: _MetalGlyphPainter(this, style), child: text),
    );
    if (!widget.innerShadow) return metal;
    return CustomPaint(foregroundPainter: _GlyphRimPainter(this, style), child: metal);
  }
}

/// The metal composited over the base text inside the glyphs, and the halo.
class _MetalGlyphPainter extends CustomPainter {
  _MetalGlyphPainter(this.state, this.style) : super(repaint: state.repaint);

  final _MetalTextState state;
  final _TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final st = style, s = state;
    final glyphs = s.glyphs(st, size);
    final mapping = MetalSheetMapping(size, st.shaderScale);
    final time = s.seconds;
    final bounds = (Offset.zero & size).inflate(4);
    canvas.saveLayer(bounds, Paint());
    glyphs.paint(canvas, Offset.zero);
    canvas.drawRect(
      bounds,
      s.shading.paint(
        st.material,
        mapping,
        size,
        time,
        st.strength * st.metalOpacity * st.material.shaderOpacity,
        st.dpr,
        blendMode: BlendMode.srcIn,
      ),
    );
    canvas.restore();

    if (!st.glow) return;
    (double, double, double) sampler(Offset p) {
      final (u, v) = mapping.uv(p);
      return st.material.sample(u, v, time);
    }

    s._advance(st, size, sampler, glyphs);
    final frame = s._glowFrame;
    if (frame == null) return;
    MetalGlowPainter.paintMasked(
      canvas,
      frame,
      box: Offset.zero & size,
      ratio: s._glow.ratio,
      dpr: st.dpr,
      dark: st.dark,
      mask: (c) {
        // The glyphs plus a soft skirt, so the halo's blur reads on small type.
        c.saveLayer(
          bounds.inflate(12),
          Paint()
            ..color = const Color(0x80000000)
            ..imageFilter = ui.ImageFilter.blur(sigmaX: 3.5, sigmaY: 3.5),
        );
        glyphs.paint(c, Offset.zero);
        c.restore();
        glyphs.paint(c, Offset.zero);
      },
    );
  }

  @override
  bool shouldRepaint(_MetalGlyphPainter oldDelegate) => oldDelegate.style != style;
}

/// The inner-shadow hairline on the glyphs, above the metal. Static.
class _GlyphRimPainter extends CustomPainter {
  _GlyphRimPainter(this.state, this.style);

  final _MetalTextState state;
  final _TextStyle style;

  @override
  void paint(Canvas canvas, Size size) {
    final glyphs = state.glyphs(style, size);
    paintInnerShadow(canvas, Offset.zero & size, glyphs.paint);
  }

  @override
  bool shouldRepaint(_GlyphRimPainter oldDelegate) => oldDelegate.style != style;
}
