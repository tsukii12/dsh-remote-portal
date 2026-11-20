// Portions derived from Libraries.dev Voice (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.
//
// The glow's layers, bottom to top as the web stacks them (`styles.ts`,
// `drawBand` in `voiceDriver.ts`, and the SwiftUI `VoiceGlowLayers`):
//
// 1. the inner light (`::before`): the lobes at 46%, a faint inset shadow,
//    masked to the ceiling ellipse and to 28px fades along the edges;
// 2. the edge stroke (`::after`): the lobes at full strength and a hot core
//    in the 1px ring of the outline;
// 3. the bloom: the lobes blurred, masked to a taller ellipse;
// 4. the band: an organic bell traced on the ceiling with chromatic fringes;
// 5. the epicentre (light theme): a white wash under the band line.
//
// Every CSS `radial-gradient(ellipse rx ry at x y, c 0%, transparent F%)` is
// a cached unit-circle gradient drawn under a translate + scale, so a frame
// allocates no shaders for the lobes. The layer's CSS filter
// (`hue-rotate brightness saturate`) is a colour matrix on its saveLayer.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'voice_driver.dart';
import 'voice_style.dart';

/// Paints one [VoiceGlowEngine] frame; holds the shaders, paths and paints
/// it reuses across frames.
class VoiceGlowRenderer {
  VoiceGlowConfig? _config;
  Size _size = Size.zero;

  // Per config.
  final _strokeLobes = List.generate(voiceLobes.length, (_) => Paint());
  final _innerLobes = List.generate(voiceLobes.length, (_) => Paint());
  final _bloomLobes = List.generate(voiceLobes.length, (_) => Paint());
  double _fade = 0.7;
  double _bloomFade = 0.72;
  late ui.ImageFilter _bloomBlur;
  late ui.ImageFilter _haloBlur;
  late ui.ImageFilter _ridgeBlur;
  late ui.ImageFilter _coreBlur;
  double _coreBlurSigma = 0;
  final _core = Paint();
  double _coreEnd = 0;
  ColorFilter? _staticFilter;

  // Per size.
  RRect _clip = RRect.zero;
  final _ring = Path();
  final _shadowPath = Path();
  final _shadow = Paint();
  final _fadeV = Paint();
  final _fadeH = Paint();

  // Per frame, reused.
  final _layer = Paint();
  final _blur = Paint();
  final _dstIn = Paint()..blendMode = BlendMode.dstIn;
  final _stroke = Paint()
    ..style = PaintingStyle.stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  final _line = Path();
  final _below = Path();
  final _xs = Float64List(voiceBandSamples + 1);
  final _ys = Float64List(voiceBandSamples + 1);
  final _lobeY = Float64List(voiceLobes.length);
  double _bandX0 = double.nan;
  double _bandX1 = double.nan;
  final _bandShaders = List<ui.Shader?>.filled(4, null);

  static const _white = Color(0xFFFFFFFF);
  static const _clear = Color(0x00FFFFFF);

  /// The ellipse every layer is masked to: white at the centre, 0.5 at
  /// [mid], [tail] at 85% when given, transparent at the rim.
  static Paint _edgeMask(double mid, double tail) => Paint()
    ..blendMode = BlendMode.dstIn
    ..shader = ui.Gradient.radial(
      Offset.zero,
      1,
      [_white, const Color(0x80FFFFFF), if (tail > 0) _white.withValues(alpha: tail), _clear],
      [0, mid, if (tail > 0) 0.85, 1],
    );

  static final _innerMask = _edgeMask(0.45, 0.3);
  static final _strokeMask = _edgeMask(0.45, 0);
  static final _bloomMask = _edgeMask(0.35, 0);

  /// The hot core at the centre of the edge: white on dark, ink on light.
  static final _highlightDark = Paint()
    ..shader = ui.Gradient.radial(
      Offset.zero,
      1,
      const [
        Color.fromRGBO(255, 255, 255, 0.45),
        Color.fromRGBO(255, 255, 255, 0.14),
        Color.fromRGBO(255, 255, 255, 0),
      ],
      const [0, 0.30, 0.65],
    );
  static final _highlightLight = Paint()
    ..shader = ui.Gradient.radial(
      Offset.zero,
      1,
      const [Color.fromRGBO(0, 0, 0, 0.55), Color.fromRGBO(0, 0, 0, 0.22), Color.fromRGBO(0, 0, 0, 0)],
      const [0, 0.35, 0.70],
    );

  void _build(VoiceGlowConfig c) {
    _config = c;
    final g = c.geometry;
    _fade = (70 * g.softness).clamp(40, 95).roundToDouble() / 100;
    _bloomFade = math.min(95, _fade * 100 + 2) / 100;
    void lobes(List<Paint> paints, double alpha, double fade) {
      for (var i = 0; i < paints.length; i++) {
        final color = c.colors[i % c.colors.length];
        paints[i].shader = ui.Gradient.radial(
          Offset.zero,
          1,
          [color.withValues(alpha: alpha), color.withValues(alpha: 0)],
          [0, fade],
        );
      }
    }

    lobes(_strokeLobes, 1, _fade);
    lobes(_innerLobes, 0.46, _fade);
    lobes(_bloomLobes, c.dark ? 0.9 : 0.7, _bloomFade);
    double blur(double px) => math.max(0.5, (px * g.glowSize * 100).roundToDouble() / 100);
    final bloomSigma = blur(10);
    _bloomBlur = ui.ImageFilter.blur(sigmaX: bloomSigma, sigmaY: bloomSigma, tileMode: TileMode.decal);
    // The band's blur is canonical in CSS px: 3.5 × bandWidth / 2 for the
    // ridge, three times that for its halo.
    final ridge = math.max(0.01, 3.5 * g.bandWidth / 2);
    _ridgeBlur = ui.ImageFilter.blur(sigmaX: ridge, sigmaY: ridge, tileMode: TileMode.decal);
    _haloBlur = ui.ImageFilter.blur(sigmaX: ridge * 3, sigmaY: ridge * 3, tileMode: TileMode.decal);
    _coreBlurSigma = blur(8);
    _coreBlur = ui.ImageFilter.blur(sigmaX: _coreBlurSigma, sigmaY: _coreBlurSigma, tileMode: TileMode.decal);

    // The epicentre: past 1 the solid white core widens, the fade starts
    // later and the ellipse grows, washing out more of the colour beneath.
    final boost = (g.coreLight.clamp(0.0, 3.0) - 1).clamp(0.0, 2.0);
    final b1 = math.min(1.0, boost), b2 = math.max(0.0, boost - 1);
    _coreEnd = (72 + 14 * b1 + 8 * b2) / 100;
    _core.shader = ui.Gradient.radial(
      Offset.zero,
      1,
      [_white, _white, _white.withValues(alpha: math.min(1, 0.55 + 0.35 * b1 + 0.1 * b2)), _clear],
      [0, (45 * b1 + 27 * b2) / 100, (40 + 25 * b1 + 15 * b2) / 100, _coreEnd],
    );

    _staticFilter = c.staticColors || c.reducedMotion || c.hueRange == 0
        ? ColorFilter.matrix(voiceColorFilterMatrix(c.hueBase, c.brightness, c.saturation))
        : null;
    _shadow.color = c.innerShadow;
    _size = Size.zero;
    _bandX0 = double.nan;
  }

  void _layout(Size size, VoiceGlowConfig c) {
    _size = size;
    final box = Offset.zero & size;
    final r = voicePaintedRadius(c.radius, size.width, size.height);
    final inner = RRect.fromRectAndRadius(box.deflate(1), Radius.circular(math.max(0, r - 1)));
    _clip = RRect.fromRectAndRadius(box, Radius.circular(r));
    // The 1px ring the stroke paints into.
    _ring
      ..reset()
      ..fillType = PathFillType.evenOdd
      ..addRRect(_clip)
      ..addRRect(inner);
    // `box-shadow: inset 0 0 9px 1px`: everything outside the box shrunk by
    // the 1px spread, blurred by half the 9px radius.
    _shadowPath
      ..reset()
      ..fillType = PathFillType.evenOdd
      ..addRect(box.inflate(40 * c.scale))
      ..addRRect(inner);
    _shadow.maskFilter = MaskFilter.blur(BlurStyle.normal, 4.5 * c.scale);
    // The inner light's corner fades: 28px ramps along the top and bottom,
    // unioned with the same along the sides.
    final cornerFade = (28 * c.scale * 10).roundToDouble() / 10;
    List<double> stops(double extent) {
      final a = math.min(1.0, cornerFade / extent);
      return [0, a, math.max(a, 1 - a), 1];
    }

    const ramp = [_white, _clear, _clear, _white];
    _fadeV.shader = ui.Gradient.linear(Offset.zero, Offset(0, size.height), ramp, stops(size.height));
    _fadeH.shader = ui.Gradient.linear(Offset.zero, Offset(size.width, 0), ramp, stops(size.width));
  }

  void paint(Canvas canvas, Size size, VoiceGlowConfig c, VoiceGlowEngine e) {
    final presence = e.shownPresence;
    if (presence <= 0.002 || size.isEmpty) return;
    if (!identical(c, _config)) _build(c);
    if (size != _size) _layout(size, c);
    final g = c.geometry;
    final cw = size.width, ch = size.height;
    final box = Offset.zero & size;

    // Where the beam sits, and — while gathered — how far it and every lobe
    // lift along the corner arcs they pass through.
    final beamX = cw / 2 + e.cx * e.w;
    final radius = voicePaintedRadius(c.radius, cw, ch);
    final cornerBlend = e.morph * e.cornerFollow;
    final lobeReach = 30 * c.scale * e.w;
    final my = ch - voiceCornerLift(beamX, cw, radius, lobeReach * 1.4) * cornerBlend;
    for (var i = 0; i < voiceLobes.length; i++) {
      _lobeY[i] = -voiceCornerLift(cw / 2 + (e.cx + e.lobeX[i]) * e.w, cw, radius, lobeReach) * cornerBlend;
    }
    final filter =
        _staticFilter ?? ColorFilter.matrix(voiceColorFilterMatrix(c.hueBase + e.hue, c.brightness, c.saturation));
    final base = presence * e.glow * c.strength;

    canvas.save();
    canvas.clipRRect(_clip);

    // 1 · Inner light.
    var rx = voiceCeilingHalfWidth * g.rangeWidth * e.w * e.maskWidth;
    var ry = voiceCeilingHeight * g.rangeHeight * e.h + e.lift;
    var bounds = _bounds(beamX, my, rx, ry, box);
    if (bounds != null) {
      canvas.save();
      canvas.clipRect(bounds);
      canvas.saveLayer(bounds, _layerPaint(base * c.innerOpacity, filter));
      _lobes(
        canvas,
        _innerLobes,
        g.glowWidth * 0.9 * g.innerScale,
        g.glowHeight * 0.9 * g.innerScale * g.innerHeight,
        0,
        _fade,
        e,
        cw,
        ch,
      );
      canvas.drawPath(_shadowPath, _shadow);
      canvas.saveLayer(bounds, _dstIn);
      canvas.drawRect(bounds, _fadeV);
      canvas.drawRect(bounds, _fadeH);
      canvas.restore();
      _mask(canvas, beamX, my, rx, ry, bounds, _innerMask);
      canvas.restore();
      canvas.restore();

      // 2 · Edge stroke, same ellipse.
      canvas.save();
      canvas.clipRect(bounds);
      canvas.clipPath(_ring);
      canvas.saveLayer(bounds, _layerPaint(base * c.strokeOpacity, filter));
      _lobes(canvas, _strokeLobes, g.glowWidth * g.strokeScale, g.glowHeight * g.strokeScale, 2, _fade, e, cw, ch);
      final hx = (c.dark ? 30 : 40) * g.coreSize * e.w;
      final hy = 30 * g.coreSize * e.h;
      final hEnd = c.dark ? 0.65 : 0.70;
      if (hx > 0 && hy > 0) {
        _unit(
          canvas,
          beamX,
          my + 2,
          hx,
          hy,
          Rect.fromLTRB(-hEnd, -hEnd, hEnd, hEnd),
          c.dark ? _highlightDark : _highlightLight,
        );
      }
      _mask(canvas, beamX, my, rx, ry, bounds, _strokeMask);
      canvas.restore();
      canvas.restore();
    }

    // 3 · Bloom: blurred first, masked after (CSS filters before it masks).
    rx = 200 * g.rangeWidth * e.w * e.maskWidth;
    ry = 130 * g.rangeHeight * e.h + e.lift;
    bounds = _bounds(beamX, my, rx, ry, box);
    if (bounds != null) {
      canvas.save();
      canvas.clipRect(bounds);
      canvas.saveLayer(bounds, _layerPaint(base * c.bloomOpacity, filter));
      _blur
        ..color = const Color(0xFF000000)
        ..colorFilter = null
        ..imageFilter = _bloomBlur;
      canvas.saveLayer(bounds, _blur);
      _lobes(
        canvas,
        _bloomLobes,
        g.glowWidth * 1.15 * g.bloomScale,
        g.glowHeight * 1.5 * g.bloomScale * g.bloomHeight,
        0,
        _bloomFade,
        e,
        cw,
        ch,
      );
      canvas.restore();
      _mask(canvas, beamX, my, rx, ry, bounds, _bloomMask);
      canvas.restore();
      canvas.restore();
    }

    // 4 · Band, 5 · epicentre: both ride the band line.
    voiceBandPoints(c, e, cw, ch, _xs, _ys);
    final bandAlpha = math.min(1.0, 0.6 * g.bandStrength * e.bendA);
    if (bandAlpha >= 0.005 && g.bandWidth > 0) _band(canvas, c, e, box, bandAlpha, presence * c.strength, filter);
    if (g.coreLight > 0) _coreWash(canvas, c, e, box, beamX, my, presence);

    canvas.restore();
  }

  Paint _layerPaint(double opacity, ColorFilter filter) => _layer
    ..color = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0))
    ..colorFilter = filter;

  static Rect? _bounds(double cx, double cy, double rx, double ry, Rect box) {
    if (rx <= 0 || ry <= 0) return null;
    final r = Rect.fromLTRB(cx - rx, cy - ry, cx + rx, cy + ry).intersect(box);
    return r.width > 0 && r.height > 0 ? r : null;
  }

  /// Draws [unitRect] of a unit-circle shader as the ellipse ([rx], [ry]) at ([cx], [cy]).
  static void _unit(Canvas canvas, double cx, double cy, double rx, double ry, Rect unitRect, Paint paint) {
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(rx, ry);
    canvas.drawRect(unitRect, paint);
    canvas.restore();
  }

  /// Multiplies the whole of [bounds] by the ellipse mask.
  static void _mask(Canvas canvas, double cx, double cy, double rx, double ry, Rect bounds, Paint mask) {
    _unit(
      canvas,
      cx,
      cy,
      rx,
      ry,
      Rect.fromLTRB(
        (bounds.left - cx) / rx,
        (bounds.top - cy) / ry,
        (bounds.right - cx) / rx,
        (bounds.bottom - cy) / ry,
      ),
      mask,
    );
  }

  /// The seven lobes of one layer, last first (CSS paints the first
  /// background on top).
  void _lobes(
    Canvas canvas,
    List<Paint> paints,
    double sw,
    double sh,
    double y,
    double fade,
    VoiceGlowEngine e,
    double cw,
    double ch,
  ) {
    final unit = Rect.fromLTRB(-fade, -fade, fade, fade);
    for (var i = voiceLobes.length - 1; i >= 0; i--) {
      final lobe = voiceLobes[i];
      final rx = (lobe.w * sw).roundToDouble() * e.w;
      final ry = (lobe.h * sh).roundToDouble() * e.h * e.lobeL[i];
      if (rx <= 0 || ry <= 0) continue;
      _unit(canvas, cw / 2 + (e.cx + e.lobeX[i]) * e.w, ch + y + _lobeY[i], rx, ry, unit, paints[i]);
    }
  }

  /// The band: a thin ridge of stacked strokes (a linear ramp across its
  /// thickness) with the above fringe riding over it and the below one under,
  /// a faint middle one between, and a wide soft halo beneath — split further
  /// and thickened by the voice.
  void _band(
    Canvas canvas,
    VoiceGlowConfig c,
    VoiceGlowEngine e,
    Rect box,
    double alpha,
    double opacity,
    ColorFilter filter,
  ) {
    final g = c.geometry;
    final bw = g.bandWidth * (1 + 0.35 * e.level);
    final split = g.bandAberration.clamp(0.0, 1.0) * (0.35 + 0.65 * e.level);
    final dy = (4 + 12 * split) * c.scale;
    final dx = 4 * split * c.scale;
    final base = (c.dark ? 0.42 : 0.4) * alpha;
    final thickness = 14 * bw;

    var top = _ys[0], bottom = _ys[0];
    _line
      ..reset()
      ..moveTo(_xs[0], _ys[0]);
    for (var i = 1; i < _xs.length; i++) {
      _line.lineTo(_xs[i], _ys[i]);
      top = math.min(top, _ys[i]);
      bottom = math.max(bottom, _ys[i]);
    }
    final x0 = _xs[0], x1 = _xs[_xs.length - 1];
    if (x0 != _bandX0 || x1 != _bandX1) {
      _bandX0 = x0;
      _bandX1 = x1;
      // Faded into the edge at both ends so the band never stops in a stub:
      // short when the tail reaches the corners, long when it ends inside.
      final fade = g.bandTail > 0 ? 0.015 : 0.18;
      final b = c.bandColors;
      for (final (i, color) in [b.core, b.above, b.mid, b.below].indexed) {
        _bandShaders[i] = ui.Gradient.linear(
          Offset(x0, 0),
          Offset(x1, 0),
          [color.withValues(alpha: 0), color, color, color.withValues(alpha: 0)],
          [0, fade, 1 - fade, 1],
        );
      }
    }
    final ridge = 3.5 * g.bandWidth / 2;
    final pad = thickness * 1.1 + ridge * 9 + dy + dx;
    final bounds = Rect.fromLTRB(x0 - pad, top - pad, x1 + pad, bottom + pad).intersect(box);
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final layerAlpha = Color.fromRGBO(0, 0, 0, opacity.clamp(0.0, 1.0));

    // The halo: wide and hazy, three times the ridge's blur.
    canvas.saveLayer(
      bounds,
      _blur
        ..color = layerAlpha
        ..colorFilter = filter
        ..imageFilter = _haloBlur,
    );
    canvas.drawPath(
      _line,
      _stroke
        ..shader = _bandShaders[0]
        ..color = Color.fromRGBO(0, 0, 0, base * 0.3)
        ..strokeWidth = thickness * 2.2,
    );
    canvas.restore();

    canvas.saveLayer(bounds, _blur..imageFilter = _ridgeBlur);
    _ridge(canvas, _bandShaders[1]!, base, dx, -dy, thickness);
    _ridge(canvas, _bandShaders[2]!, base * 0.55, dx * 0.35, -dy * 0.35, thickness);
    _ridge(canvas, _bandShaders[3]!, base, -dx, dy, thickness);
    _ridge(canvas, _bandShaders[0]!, base * 0.9, 0, 0, thickness);
    canvas.restore();
  }

  static const _ramp = [(1.0, 0.16), (0.72, 0.2), (0.46, 0.26), (0.22, 0.34)];

  void _ridge(Canvas canvas, ui.Shader shader, double alpha, double ox, double oy, double thickness) {
    canvas.save();
    canvas.translate(ox, oy);
    _stroke.shader = shader;
    for (final (width, a) in _ramp) {
      _stroke
        ..color = Color.fromRGBO(0, 0, 0, (alpha * a).clamp(0.0, 1.0))
        ..strokeWidth = math.max(0.6, thickness * width);
      canvas.drawPath(_line, _stroke);
    }
    canvas.restore();
  }

  /// The epicentre: a soft white wash at the source, clipped to below the
  /// band line and blurred after the cut, so the centre reads lighter than
  /// the band. It follows the glow's presence but not `strength`.
  void _coreWash(
    Canvas canvas,
    VoiceGlowConfig c,
    VoiceGlowEngine e,
    Rect box,
    double beamX,
    double my,
    double presence,
  ) {
    final g = c.geometry;
    final coreLight = g.coreLight.clamp(0.0, 3.0);
    final boost = (coreLight - 1).clamp(0.0, 2.0);
    final opacity = presence * math.min(1.0, e.glow * math.min(1.0, coreLight) * (1.6 + 1.4 * boost));
    final grow = 1 + 0.3 * boost;
    final rx = 120 * g.coreLightWidth * grow * c.scale * e.w;
    final ry = 70 * g.coreLightHeight * grow * c.scale * e.h + e.lift;
    if (opacity <= 0.005 || rx <= 0 || ry <= 0) return;
    final bounds = Rect.fromLTRB(
      beamX - rx * _coreEnd,
      my - ry * _coreEnd,
      beamX + rx * _coreEnd,
      my + ry * _coreEnd,
    ).inflate(_coreBlurSigma * 3).intersect(box);
    if (bounds.width <= 0 || bounds.height <= 0) return;
    _below
      ..reset()
      ..moveTo(0, box.height);
    for (var i = 0; i < _xs.length; i++) {
      _below.lineTo(_xs[i], _ys[i]);
    }
    _below
      ..lineTo(box.width, box.height)
      ..close();
    canvas.saveLayer(
      bounds,
      _blur
        ..color = Color.fromRGBO(0, 0, 0, opacity)
        ..colorFilter = null
        ..imageFilter = _coreBlur,
    );
    canvas.clipPath(_below);
    _unit(canvas, beamX, my, rx, ry, Rect.fromLTRB(-_coreEnd, -_coreEnd, _coreEnd, _coreEnd), _core);
    canvas.restore();
  }
}

/// The [CustomPainter] over a [VoiceGlowRenderer]; [repaint] fires once per driven frame.
class VoiceGlowPainter extends CustomPainter {
  VoiceGlowPainter({required this.renderer, required this.engine, required this.config, super.repaint});

  final VoiceGlowRenderer renderer;
  final VoiceGlowEngine engine;
  final VoiceGlowConfig config;

  @override
  void paint(Canvas canvas, Size size) => renderer.paint(canvas, size, config, engine);

  @override
  bool shouldRepaint(VoiceGlowPainter oldDelegate) =>
      !identical(oldDelegate.config, config) || !identical(oldDelegate.engine, engine);
}
