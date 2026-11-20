// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'beam_data.dart';
import 'beam_engine.dart';

/// The beam clock and fade the painters read; one per beam.
class BeamFrame extends ChangeNotifier {
  double _t = 0;
  double _fade = 0;
  bool _still = false;

  /// Seconds on the beam clock.
  double get t => _t;

  /// 0..1 fade in/out.
  double get fade => _fade;

  /// Draw the config's still frame instead of [t] (reduced motion).
  bool get still => _still;

  void set(double t, double fade, {bool still = false}) {
    if (t == _t && fade == _fade && still == _still) return;
    _t = t;
    _fade = fade;
    _still = still;
    notifyListeners();
  }
}

/// Paints one beam the way the web library stacks its CSS layers: the inner
/// glow (`::before`), the stroke ring (`::after`) and the bloom
/// (`[data-beam-bloom]`), each with the web's filter → clip → mask → opacity
/// order. Every `radial-gradient(ellipse …, colour, transparent)` is a unit
/// radial shader stretched by the canvas transform; conic gradients are sweep
/// shaders turned by the beam angle.
class BeamPainter extends CustomPainter {
  BeamPainter(this.config, this.frame, {this.behind = false}) : super(repaint: frame);

  final BeamConfig config;
  final BeamFrame frame;

  /// Paint pulse-outside's core and bloom, which sit under the child; every
  /// other layer goes over it.
  final bool behind;

  static const _unit = Rect.fromLTRB(-1, -1, 1, 1);
  static const _opaque = Color(0xFF000000);
  static const _white = Color(0xFFFFFFFF);
  static const _black = Color(0xFF000000);

  final _fill = Paint();
  final _layer = Paint();
  final _mask = Paint()..blendMode = BlendMode.dstIn;
  final _maskLayer = Paint()..blendMode = BlendMode.dstIn;
  final _cut = Paint()..blendMode = BlendMode.dstOut;
  late final _shadow = Paint()..maskFilter = MaskFilter.blur(BlurStyle.normal, _shadowBlur / 2);

  _Geometry? _geo;

  BeamPalette get _palette => config.palette;
  bool get _dark => config.dark;

  // ── Shaders, built once per config ────────────────────────────────────────

  static Shader _radial(List<Color> colors, [List<double>? stops]) => ui.Gradient.radial(Offset.zero, 1, colors, stops);

  /// `radial-gradient(ellipse, colour, transparent)`: transparent interpolates
  /// premultiplied in CSS, so the colour stays and only alpha falls.
  static Shader _fade(Color c) => _radial([c, c.withValues(alpha: 0)]);

  static Shader _sweep(List<(double, double)> stops, Color rgb) => ui.Gradient.sweep(
    Offset.zero,
    [for (final (_, a) in stops) rgb.withValues(alpha: a)],
    [for (final (p, _) in stops) p],
  );

  late final Shader _window = _sweep(beamWindowStops, _white);
  late final Shader _smallWindow = _sweep(beamSmallWindowStops, _white);
  late final Shader _highlight = _dark ? _sweep(beamWhiteStopsDark, _white) : _sweep(beamWhiteStopsLight, _black);
  late final Shader _bloom = _dark ? _sweep(beamBloomStopsDark, _white) : _sweep(beamBloomStopsLight, _black);

  double get _shadowBlur => config.size == BorderBeamSize.sm ? 5 : 9;

  /// Rotate stroke blobs: (shader, x, y, rx, ry).
  late final List<(Shader, double, double, double, double)> _rotateStroke = config.size == BorderBeamSize.sm
      ? [for (final (i, (x, y, rx, ry)) in beamSmallGeometry.indexed) (_fade(_palette.small[i]), x, y, rx, ry)]
      : [for (final (i, (x, y, rx, ry)) in beamBorderGeometry.indexed) (_fade(_palette.border[i]), x, y, rx, ry)];

  /// Rotate inner blobs: sm has its own table; md derives from the border
  /// palette at 90% size and a flat alpha (styles.ts `getInnerGradients`).
  late final List<(Shader, double, double, double, double)> _rotateInner = config.size == BorderBeamSize.sm
      ? [for (final (i, (x, y, rx, ry)) in beamSmallGeometry.indexed) (_fade(_palette.smallInner[i]), x, y, rx, ry)]
      : [
          for (final (i, (x, y, rx, ry)) in beamBorderGeometry.indexed)
            (
              _fade(_palette.border[i].withValues(alpha: config.mono ? 0.225 : 0.45)),
              x,
              y,
              (rx * 0.9).roundToDouble(),
              (ry * 0.9).roundToDouble(),
            ),
        ];

  late final List<Shader> _lineStroke = [for (final c in _dark ? _palette.lineDark : _palette.lineLight) _fade(c)];
  late final List<Shader> _lineInner = [for (final c in _palette.lineInner) _fade(c)];
  late final Shader _lineHighlight = _dark
      ? _radial(
          [_white.withValues(alpha: 0.38), _white.withValues(alpha: 0.12), _white.withValues(alpha: 0)],
          [0, 0.3, 0.65],
        )
      : _radial(
          [_black.withValues(alpha: 0.6), _black.withValues(alpha: 0.25), _black.withValues(alpha: 0)],
          [0, 0.35, 0.7],
        );
  late final List<_LineBloom> _lineBloom = _lineBloomTable(_palette, dark: _dark, mono: config.mono);

  late final PulseParams _pulseParams = PulseParams.of(
    inner: config.size == BorderBeamSize.pulseInner,
    dark: _dark,
    duration: config.duration,
  );
  late final PulseFrame _pulse = PulseFrame(_pulseParams);

  /// The nine-blob perimeter ring of pulse-inner.
  late final List<_PulseBlob> _pulseRing = [
    for (final (i, (x, y, rx, ry)) in beamBorderGeometry.indexed)
      _PulseBlob(_fade(_palette.border[i]), beamPulseRingMap[i].$1, beamPulseRingMap[i].$2, rx, ry, x, y),
  ];

  /// pulse-inner's inner glow: smaller ring blobs plus the four corner accents.
  late final List<_PulseBlob> _pulseInnerGlow = () {
    final accent = _dark ? _white.withValues(alpha: 0.18) : _black.withValues(alpha: 0.08);
    final corner = _radial([accent, accent.withValues(alpha: 0)], [0, 0.7]);
    return [
      for (final (i, (x, y, _, _)) in beamBorderGeometry.indexed)
        _PulseBlob(
          _fade(_palette.border[i]),
          beamPulseRingMap[i].$1,
          beamPulseRingMap[i].$2,
          beamPulseInnerSizes[i].$1,
          beamPulseInnerSizes[i].$2,
          x,
          y,
        ),
      _PulseBlob(corner, 0, 0, 60, 60, 0, 0),
      _PulseBlob(corner, 0, 1, 60, 60, 1, 0),
      _PulseBlob(corner, 0, 2, 60, 60, 0, 1),
      _PulseBlob(corner, 0, 3, 60, 60, 1, 1),
    ];
  }();

  List<_PulseBlob> _pulseTable(List<BeamPulseBlob> table, {double? frozenAlpha}) => [
    for (final (ci, region, quad, rx, ry, x, y) in table)
      _PulseBlob(
        _fade(frozenAlpha == null ? _palette.border[ci] : _palette.border[ci].withValues(alpha: frozenAlpha)),
        region,
        quad,
        rx,
        ry,
        x ?? beamBorderGeometry[ci].$1,
        y ?? beamBorderGeometry[ci].$2,
      ),
  ];

  late final _pulseInnerBloom = _pulseTable(beamPulseInnerBloom, frozenAlpha: _pulseParams.frozenBloomAlpha);
  late final _pulseOuterCore = _pulseTable(beamPulseOuterCore);
  late final _pulseOuterBloom = _pulseTable(beamPulseOuterBloom, frozenAlpha: _pulseParams.frozenBloomAlpha);

  // ── Painting ──────────────────────────────────────────────────────────────

  @override
  void paint(Canvas canvas, Size size) {
    final fade = frame.fade;
    if (fade <= 0 || size.isEmpty) return;
    final t = frame.still ? config.stillTime : frame.t;
    final geo = _geo;
    if (geo == null || geo.size != size) {
      _geo = _Geometry(size, config.radius, ringAtRadius: config.size.isPulse);
    }
    switch (config.size) {
      case BorderBeamSize.md || BorderBeamSize.sm:
        _paintRotate(canvas, t, fade);
      case BorderBeamSize.line:
        _paintLine(canvas, t, fade);
      case BorderBeamSize.pulseInner:
        _paintPulseInner(canvas, t, fade);
      case BorderBeamSize.pulseOutside:
        behind ? _paintPulseGlow(canvas, t, fade) : _paintPulseStroke(canvas, t, fade);
    }
  }

  void _paintRotate(Canvas canvas, double t, double fade) {
    final c = config;
    final g = _geo!;
    final p = c.preset;
    final small = c.size == BorderBeamSize.sm;
    final base = fade * c.strength * (c.mono ? 0.5 : 1);
    final turn = beamAngle(t, c.duration);
    // With static colours the web leaves these two layers unfiltered: the
    // brightness/saturate only live inside the hue-shift keyframes.
    final filter = c.staticColors
        ? null
        : ColorFilter.matrix(
            beamFilterMatrix(c.hueShift + beamHueDrift(t, c.hueRange, 12), c.brightness, c.saturation),
          );

    // Inner glow (::before, z-index 1).
    var op = _opacity(base * p.inner);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      for (final (shader, x, y, rx, ry) in _rotateInner.reversed) {
        _blob(canvas, shader, x * g.size.width, y * g.size.height, rx, ry);
      }
      _insetShadow(canvas, p.innerShadow);
      _conic(canvas, small ? _smallWindow : _window, turn, _mask);
      if (!small) _edgeMask(canvas);
      canvas.restore();
    }

    // Stroke ring (::after, z-index 2): colours under the conic highlight.
    op = _opacity(base * p.stroke);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      canvas.clipPath(g.ring);
      for (final (shader, x, y, rx, ry) in _rotateStroke.reversed) {
        _blob(canvas, shader, x * g.size.width, y * g.size.height, rx, ry);
      }
      _conic(canvas, _highlight, turn, _fill);
      _conic(canvas, _window, turn, _mask);
      canvas.restore();
    }

    // Bloom (z-index 3): the conic ring pattern blurred, then cut to the ring
    // (CSS applies the filter before the mask).
    op = _opacity(base * p.bloom);
    if (op > 0) {
      _begin(canvas, g.box, op);
      canvas.clipRRect(g.outer);
      _begin(
        canvas,
        g.box,
        1,
        imageFilter: ui.ImageFilter.compose(
          outer: ColorFilter.matrix(beamFilterMatrix(0, c.brightness, c.saturation)),
          inner: _blur(beamBlur(8, c.glowSize)),
        ),
      );
      canvas.clipRRect(g.ringOuter);
      _conic(canvas, _bloom, turn, _fill);
      canvas.restore();
      canvas.drawPath(g.cut, _cut);
      canvas.restore();
    }
  }

  void _paintLine(Canvas canvas, double t, double fade) {
    final c = config;
    final g = _geo!;
    final p = c.preset;
    final v = LineFrame.at(t, c.duration);
    final base = fade * v.edge * c.strength;
    if (base <= 0) return;
    final h = g.size.height;
    final bx = v.x * g.size.width;
    final filter = c.staticColors
        ? null
        : ColorFilter.matrix(
            beamFilterMatrix(c.hueShift + beamHueDrift(t, c.hueRange, 12), c.brightness, c.saturation),
          );

    // Inner glow (::before).
    var op = _opacity(base * p.inner);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      for (var i = beamLineInnerGeometry.length - 1; i >= 0; i--) {
        final (rx, ry, dx, dy) = beamLineInnerGeometry[i];
        _blob(canvas, _lineInner[i], bx + dx, h - dy.abs(), rx * v.w, ry * v.h);
      }
      _insetShadow(canvas, p.innerShadow);
      _ellipseMask(canvas, bx, h, 78 * v.w, 60 * v.h, 0.45);
      _edgeMask(canvas);
      canvas.restore();
    }

    // Stroke (::after): the travelling colours under a white highlight.
    op = _opacity(base * p.stroke);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      canvas.clipPath(g.ring);
      final geometry = _dark ? beamLineDarkGeometry : beamLineLightGeometry;
      for (var i = geometry.length - 1; i >= 0; i--) {
        final (rx, ry, dx, dy) = geometry[i];
        _blob(canvas, _lineStroke[i], bx + dx, h + dy, rx * v.w, ry * v.h);
      }
      _blob(canvas, _lineHighlight, bx, h + 2, (_dark ? 24 : 35) * v.w, 28 * v.h);
      _ellipseMask(canvas, bx, h, 78 * v.w, 60 * v.h, 0.45);
      canvas.restore();
    }

    // Bloom: fixed spikes along the bottom revealed by a window that follows
    // the beam, plus a glow dot riding with it.
    op = _opacity(base * p.bloom);
    if (op > 0) {
      _begin(canvas, g.box, op);
      canvas.clipRRect(g.outer);
      final ui.ImageFilter? bloomFilter = c.staticColors
          ? (c.mono ? _blur(6) : null)
          : ui.ImageFilter.compose(
              outer: ColorFilter.matrix(
                beamFilterMatrix(c.hueShift + beamHueDrift(t, c.hueRange + 10, 8), c.brightness, c.saturation),
              ),
              inner: _blur(beamBlur(8, c.glowSize)),
            );
      if (bloomFilter != null) _begin(canvas, g.box, 1, imageFilter: bloomFilter);
      canvas.clipRRect(g.ringOuter);
      for (final b in _lineBloom.reversed) {
        _blob(canvas, b.shader, b.x == null ? bx : b.x! * g.size.width, h + b.dy, b.w * b.wBy.of(v), b.h * b.hBy.of(v));
      }
      if (bloomFilter != null) canvas.restore();
      _ellipseMask(canvas, bx, h, 84 * v.w, 110 * v.h, 0.35);
      canvas.restore();
    }
  }

  ColorFilter _pulseFilter(double t) => ColorFilter.matrix(
    beamFilterMatrix(config.staticColors ? 0 : config.hueShift + _pulse.hue(t), config.brightness, config.saturation),
  );

  void _paintPulseInner(Canvas canvas, double t, double fade) {
    final c = config;
    final g = _geo!;
    final p = c.preset;
    _pulse.sample(t);
    final osc = _pulse.values;
    final filter = _pulseFilter(t);
    final base = fade * c.strength * (c.mono ? 0.5 : 1);

    // Inner glow (::before): edge-faded wash with corner accents.
    var op = _opacity(base * p.inner);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      _pulseBlobs(canvas, _pulseInnerGlow, osc, g.box, 1, 1);
      _edgeMask(canvas);
      canvas.restore();
    }

    // Ring (::after).
    op = _opacity(base * p.stroke);
    if (op > 0) {
      _begin(canvas, g.box, op, colorFilter: filter);
      canvas.clipRRect(g.outer);
      canvas.clipPath(g.ring);
      _pulseBlobs(canvas, _pulseRing, osc, g.box, 1, 1);
      canvas.restore();
    }

    // Bloom: frozen blobs blurred, then cut to the ring.
    op = _opacity(base * p.bloom);
    if (op > 0) {
      _begin(canvas, g.box, op);
      canvas.clipRRect(g.outer);
      _begin(
        canvas,
        g.box,
        1,
        imageFilter: ui.ImageFilter.compose(outer: filter, inner: _blur(beamBlur(8, c.glowSize))),
      );
      canvas.clipRRect(g.outer);
      _pulseBlobs(canvas, _pulseInnerBloom, null, g.box, 1, 1);
      canvas.restore();
      canvas.drawPath(g.cut, _cut);
      canvas.restore();
    }
  }

  /// pulse-outside under the child: the core (inset -10px) then the wide
  /// bloom (inset -30px), both blurred and squashed by `scale(0.95, 0.9)`.
  void _paintPulseGlow(Canvas canvas, double t, double fade) {
    final c = config;
    final g = _geo!;
    final p = c.preset;
    _pulse.sample(t);
    final filter = _pulseFilter(t);
    final base = fade * c.strength * (c.mono ? 0.5 : 1);
    final (sx, sy) = beamGlowScale(g.size.width, g.size.height);
    final centre = g.box.center;

    canvas.save();
    canvas.translate(centre.dx, centre.dy);
    canvas.scale(0.95, 0.9);
    canvas.translate(-centre.dx, -centre.dy);

    var op = _opacity(base * p.inner);
    if (op > 0) {
      final box = g.box.inflate(10);
      final blur = beamBlur(_dark ? 3 : 6, c.glowSize);
      _begin(
        canvas,
        box.inflate(blur * 3),
        op,
        imageFilter: ui.ImageFilter.compose(outer: filter, inner: _blur(blur)),
      );
      canvas.clipRRect(_rrect(box, c.radius + 10));
      _pulseBlobs(canvas, _pulseOuterCore, _pulse.values, box, sx, sy);
      canvas.restore();
    }

    op = _opacity(base * p.bloom);
    if (op > 0) {
      final box = g.box.inflate(30);
      final blur = beamBlur(_dark ? 22.5 : 15, c.glowSize);
      _begin(
        canvas,
        box.inflate(blur * 3),
        op,
        imageFilter: ui.ImageFilter.compose(outer: filter, inner: _blur(blur)),
      );
      canvas.clipRRect(_rrect(box, c.radius + 30));
      _pulseBlobs(canvas, _pulseOuterBloom, null, box, sx, sy);
      canvas.restore();
    }
    canvas.restore();
  }

  /// pulse-outside over the child: the crisp 1px coloured ring.
  void _paintPulseStroke(Canvas canvas, double t, double fade) {
    final c = config;
    final g = _geo!;
    final op = _opacity(fade * c.strength * (c.mono ? 0.5 : 1) * c.preset.stroke);
    if (op <= 0) return;
    _pulse.sample(t);
    final (sx, sy) = beamGlowScale(g.size.width, g.size.height);
    _begin(canvas, g.box, op, colorFilter: _pulseFilter(t));
    canvas.clipRRect(g.outer);
    canvas.clipPath(g.ring);
    _pulseBlobs(canvas, _pulseOuterCore, _pulse.values, g.box, sx, sy);
    canvas.restore();
  }

  // ── Primitives ────────────────────────────────────────────────────────────

  /// CSS clamps `opacity` to [0, 1]; several presets ask for more.
  static double _opacity(double v) => v.clamp(0.0, 1.0);

  static ui.ImageFilter _blur(double sigma) =>
      ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: TileMode.decal);

  static RRect _rrect(Rect r, double radius) => RRect.fromRectAndRadius(r, Radius.circular(radius)).scaleRadii();

  /// One CSS layer: filter and opacity apply to everything drawn until the
  /// matching restore.
  void _begin(Canvas canvas, Rect bounds, double opacity, {ColorFilter? colorFilter, ui.ImageFilter? imageFilter}) {
    _layer
      ..color = Color.fromRGBO(0, 0, 0, opacity)
      ..colorFilter = colorFilter
      ..imageFilter = imageFilter;
    canvas.saveLayer(bounds, _layer);
  }

  /// A unit radial [shader] stretched into an ellipse of radii [rx] × [ry] at
  /// ([cx], [cy]); [alpha] scales it (the pulse quadrant opacity).
  void _blob(Canvas canvas, Shader shader, double cx, double cy, double rx, double ry, [double alpha = 1]) {
    if (rx <= 0 || ry <= 0 || alpha <= 0) return;
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(rx, ry);
    _fill
      ..shader = shader
      ..color = Color.fromRGBO(0, 0, 0, alpha.clamp(0.0, 1.0));
    canvas.drawRect(_unit, _fill);
    canvas.restore();
  }

  void _pulseBlobs(Canvas canvas, List<_PulseBlob> blobs, Float64List? osc, Rect box, double sx, double sy) {
    for (var i = blobs.length - 1; i >= 0; i--) {
      final b = blobs[i];
      var rx = b.rx * sx;
      var ry = b.ry * sy;
      var cx = box.left + b.x * box.width;
      var cy = box.top + b.y * box.height;
      var alpha = 1.0;
      if (osc != null) {
        if (b.region > 0) {
          final k = (b.region - 1) * 4;
          rx *= osc[k];
          ry *= osc[k + 1] * osc[12];
          cx += osc[k + 2];
          cy += osc[k + 3];
        }
        alpha = osc[13 + b.quad];
      }
      _blob(canvas, b.shader, cx, cy, rx, ry, alpha);
    }
  }

  /// `conic-gradient(from <turn>)` centred on the box, filling the layer.
  void _conic(Canvas canvas, Shader shader, double turn, Paint paint) {
    final g = _geo!;
    canvas.save();
    canvas.translate(g.box.center.dx, g.box.center.dy);
    // CSS starts at 12 o'clock, a sweep shader at 3 o'clock.
    canvas.rotate((turn - 0.25) * 2 * math.pi);
    paint
      ..shader = shader
      ..color = _opaque;
    canvas.drawRect(Rect.fromCircle(center: Offset.zero, radius: g.cover), paint);
    canvas.restore();
  }

  /// Masks with `radial-gradient(ellipse rx ry at cx cy, white, rgba(255,255,255,.5) mid, transparent)`.
  void _ellipseMask(Canvas canvas, double cx, double cy, double rx, double ry, double mid) {
    final k = ry / rx;
    final m = Float64List(16)
      ..[0] = 1
      ..[5] = k
      ..[10] = 1
      ..[15] = 1
      ..[13] = cy - k * cy;
    _mask
      ..shader = ui.Gradient.radial(
        Offset(cx, cy),
        rx,
        [_white, _white.withValues(alpha: 0.5), _white.withValues(alpha: 0)],
        [0, mid, 1],
        TileMode.clamp,
        m,
      )
      ..color = _opaque;
    canvas.drawRect(_geo!.box, _mask);
  }

  /// The inner layers' edge fade: solid at every edge, clear [beamEdgeMaskPx]
  /// in — the union (`mask-composite: add`) of a vertical and a horizontal ramp.
  void _edgeMask(Canvas canvas) {
    final g = _geo!;
    canvas.saveLayer(g.box, _maskLayer);
    _fill
      ..shader = g.edgeV
      ..color = _opaque;
    canvas.drawRect(g.box, _fill);
    _fill.shader = g.edgeH;
    canvas.drawRect(g.box, _fill);
    canvas.restore();
  }

  /// `box-shadow: inset 0 0 <blur> 1px <colour>`.
  void _insetShadow(Canvas canvas, Color color) {
    if (color.a == 0) return;
    final g = _geo!;
    _shadow.color = color;
    canvas.drawDRRect(RRect.fromRectAndRadius(g.box.inflate(_shadowBlur * 2), Radius.zero), g.shadowHole, _shadow);
  }

  @override
  bool? hitTest(Offset position) => false;

  @override
  bool shouldRepaint(BeamPainter oldDelegate) =>
      oldDelegate.config != config || oldDelegate.frame != frame || oldDelegate.behind != behind;
}

/// Size-dependent shapes, rebuilt when the box changes.
class _Geometry {
  _Geometry(this.size, double radius, {required bool ringAtRadius}) : box = Offset.zero & size {
    outer = BeamPainter._rrect(box, radius);
    // The rotate and line rings use `border-radius: R - 1` with 1px padding;
    // the pulse rings sit on the full radius.
    final ringRadius = ringAtRadius ? radius : math.max(0.0, radius - beamBorderWidth);
    ringOuter = BeamPainter._rrect(box, ringRadius);
    final ringInner = BeamPainter._rrect(box.deflate(beamBorderWidth), math.max(0.0, ringRadius - beamBorderWidth));
    ring = Path()
      ..fillType = PathFillType.evenOdd
      ..addRRect(ringOuter)
      ..addRRect(ringInner);
    cut = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(box.inflate(2))
      ..addRRect(ringOuter)
      ..addRRect(ringInner);
    shadowHole = BeamPainter._rrect(box.deflate(1), math.max(0.0, radius - 1));
    edgeV = _edge(size.height, vertical: true);
    edgeH = _edge(size.width, vertical: false);
    cover = math.sqrt(size.width * size.width + size.height * size.height) / 2 + 2;
  }

  final Size size;
  final Rect box;
  late final RRect outer;
  late final RRect ringOuter;

  /// The 1px border ring, and everything but it (to cut a layer to the ring).
  late final Path ring;
  late final Path cut;
  late final RRect shadowHole;
  late final Shader edgeV;
  late final Shader edgeH;

  /// Half the diagonal: a rotated square this big covers the box.
  late final double cover;

  /// `linear-gradient(white, transparent 28px, transparent calc(100% - 28px), white)`
  /// with CSS's stop fix-up for boxes shorter than 56px.
  static Shader _edge(double extent, {required bool vertical}) {
    const e = beamEdgeMaskPx;
    final len = math.max(extent, e);
    return ui.Gradient.linear(
      Offset.zero,
      vertical ? Offset(0, len) : Offset(len, 0),
      const [Color(0xFFFFFFFF), Color(0x00FFFFFF), Color(0x00FFFFFF), Color(0xFFFFFFFF)],
      [0, e / len, math.max(e, extent - e) / len, 1],
    );
  }
}

class _PulseBlob {
  const _PulseBlob(this.shader, this.region, this.quad, this.rx, this.ry, this.x, this.y);

  final Shader shader;

  /// 1..3 picks the size/drift oscillators; 0 stays put (corner accents).
  final int region;

  /// 0..3 (tl, tr, bl, br) picks the opacity oscillator.
  final int quad;
  final double rx;
  final double ry;
  final double x;
  final double y;
}

/// What scales a line bloom radius.
enum _By {
  w,
  h,
  spike,
  spike2,
  invSpike,
  invSpike2;

  double of(LineFrame v) => switch (this) {
    w => v.w,
    h => v.h,
    spike => v.spike,
    spike2 => v.spike2,
    invSpike => 2 - v.spike,
    invSpike2 => 2 - v.spike2,
  };
}

class _LineBloom {
  const _LineBloom(this.shader, this.x, this.dy, this.w, this.wBy, this.h, this.hBy);

  final Shader shader;

  /// Fixed centre as a fraction of the width, or null to ride with the beam.
  final double? x;

  /// Centre offset from the bottom edge.
  final double dy;
  final double w;
  final _By wBy;
  final double h;
  final _By hBy;
}

/// styles.ts `getLineBloomGradients`: five spikes in the palette's bloom
/// colours plus two at the spike colours, the glow dot and the ambient wash
/// (dark), or a dark shadow under the beam (light). Mono turns the thin bars
/// into wide, faint glows.
List<_LineBloom> _lineBloomTable(BeamPalette palette, {required bool dark, required bool mono}) {
  // styles.ts `attenuateSpike` / `withAlpha` (alphas written with toFixed(2)).
  Color att(Color c, double f) => c.withValues(alpha: (c.a * f * 100).round() / 100);
  Color alpha(Color c, double a) => c.withValues(alpha: a);
  Shader grad(List<Color> colors, List<double> stops) => BeamPainter._radial(colors, stops);
  Shader spikeGrad(Color c1, Color c2, double mid, double end) =>
      grad([c1, c2, c2.withValues(alpha: 0)], [0, mid, end]);

  final (primary, secondary) = dark ? palette.spike : palette.spikeLight;
  final spikes = [
    for (final (c1, c2) in dark ? palette.bloomDark : palette.bloomLight)
      mono ? (att(c1, 0.14), att(c2, 0.14 * 0.7)) : (c1, c2),
  ];
  final sc1 = mono ? att(primary, 0.14) : primary;
  final sc2 = mono ? att(secondary, 0.12) : secondary;
  final Color sc1Mid;
  final Color sc2Mid;
  if (dark) {
    sc1Mid = mono ? att(primary, 0.09) : primary;
    sc2Mid = alpha(secondary, mono ? 0.06 : 0.49);
  } else {
    sc1Mid = mono ? att(primary, 0.11) : alpha(primary, 0.85);
    sc2Mid = mono ? att(secondary, 0.09) : alpha(secondary, 0.7);
  }
  final thin = mono ? (12.0, 14.0, 12.0, 10.0, 12.0) : (0.8, 2.0, 1.2, 0.6, 1.0);
  final tall = mono ? (42.0, 38.0, 40.0, 32.0) : (92.0, 72.0, 85.0, 60.0);

  final table = [
    _LineBloom(spikeGrad(sc1, sc1Mid, 0.3, 0.88), 0.08, -2, thin.$1, _By.spike, tall.$1, _By.h),
    _LineBloom(spikeGrad(sc2, sc2Mid, 0.5, 0.95), 0.22, -4, 10, _By.spike2, 35, _By.h),
    _LineBloom(spikeGrad(spikes[0].$1, spikes[0].$2, 0.4, 0.9), 0.36, -3, thin.$2, _By.invSpike, tall.$2, _By.h),
    _LineBloom(spikeGrad(spikes[1].$1, spikes[1].$2, 0.55, 0.96), 0.5, -2, 14, _By.spike2, 28, _By.h),
    _LineBloom(spikeGrad(spikes[2].$1, spikes[2].$2, 0.35, 0.89), 0.64, -4, thin.$3, _By.invSpike2, tall.$3, _By.h),
    _LineBloom(spikeGrad(spikes[3].$1, spikes[3].$2, 0.48, 0.94), 0.78, -2, 7, _By.spike, 45, _By.h),
    _LineBloom(
      spikeGrad(spikes[4].$1, spikes[4].$2, 0.42, 0.91),
      0.92,
      -3,
      dark ? thin.$4 : thin.$5,
      _By.invSpike,
      tall.$4,
      _By.h,
    ),
  ];
  if (dark) {
    final k = mono ? 0.5 : 1.0;
    const w = Color(0xFFFFFFFF);
    table.addAll([
      _LineBloom(
        grad([alpha(w, 1 * k), alpha(w, 0.9 * k), alpha(w, 0.5 * k), alpha(w, 0)], [0, 0.2, 0.5, 1]),
        null,
        1,
        21,
        _By.spike,
        15,
        _By.spike2,
      ),
      _LineBloom(
        grad([alpha(w, 0.3 * k), alpha(w, 0.12 * k), alpha(w, 0.03 * k), alpha(w, 0)], [0, 0.25, 0.55, 0.8]),
        null,
        0,
        42,
        _By.w,
        40,
        _By.h,
      ),
    ]);
  } else {
    const b = Color(0xFF000000);
    table.add(
      _LineBloom(
        grad([alpha(b, 0.5), alpha(b, 0.18), alpha(b, 0.03), alpha(b, 0)], [0, 0.3, 0.6, 0.85]),
        null,
        0,
        50,
        _By.w,
        32,
        _By.h,
      ),
    );
  }
  return table;
}
