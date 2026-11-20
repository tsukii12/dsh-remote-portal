// Portions derived from Libraries.dev Metal (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'metal_material.dart';

/// The material shader (`shaders/fx/metal_liquid.frag`), loaded once.
abstract final class MetalShader {
  static const asset = 'shaders/fx/metal_liquid.frag';

  static Future<ui.FragmentProgram?>? _program;

  /// Null when the program cannot load (widget tests): painters then fall back
  /// to [MetalShading]'s gradient.
  static Future<ui.FragmentProgram?> load() =>
      _program ??= ui.FragmentProgram.fromAsset(asset)
          .then<ui.FragmentProgram?>((program) => program, onError: (Object _) => null);
}

/// The paint that lays the material down: the fragment shader once it has
/// loaded, otherwise a vertical gradient sampled from the CPU port.
class MetalShading {
  ui.FragmentShader? shader;
  final _paint = Paint();

  /// [time] is the instance clock in seconds (before the preset's speed);
  /// [opacity] multiplies the material's alpha; [box] is the element's box.
  Paint paint(
    MetalMaterial material,
    MetalSheetMapping mapping,
    Size box,
    double time,
    double opacity,
    double dpr, {
    BlendMode blendMode = BlendMode.srcOver,
  }) {
    final s = shader;
    if (s != null) {
      final tint = material.colorTint, back = material.colorBack;
      s
        ..setFloat(0, mapping.originX)
        ..setFloat(1, mapping.originY)
        ..setFloat(2, mapping.scaleX)
        ..setFloat(3, mapping.scaleY)
        ..setFloat(4, time * material.speed)
        ..setFloat(5, back.r)
        ..setFloat(6, back.g)
        ..setFloat(7, back.b)
        ..setFloat(8, back.a)
        ..setFloat(9, tint.r)
        ..setFloat(10, tint.g)
        ..setFloat(11, tint.b)
        ..setFloat(12, tint.a)
        ..setFloat(13, material.repetition)
        ..setFloat(14, material.softness)
        ..setFloat(15, material.shiftRed)
        ..setFloat(16, material.shiftBlue)
        ..setFloat(17, material.distortion)
        ..setFloat(18, material.contour)
        ..setFloat(19, material.angle)
        ..setFloat(20, opacity)
        ..setFloat(21, dpr);
      _paint.shader = s;
    } else {
      const n = 6;
      final colors = <Color>[];
      final stops = <double>[];
      for (var i = 0; i < n; i++) {
        final (u, v) = mapping.uv(Offset(box.width / 2, box.height * i / (n - 1)));
        final (r, g, b) = material.sample(u, v, time);
        colors.add(
          Color.from(alpha: opacity, red: r.clamp(0.0, 1.0), green: g.clamp(0.0, 1.0), blue: b.clamp(0.0, 1.0)),
        );
        stops.add(i / (n - 1));
      }
      _paint.shader = ui.Gradient.linear(Offset.zero, Offset(0, box.height), colors, stops);
    }
    return _paint..blendMode = blendMode;
  }
}

/// The clock the three metal widgets share. The ticker runs only while there
/// is something to move: not paused and no reduced motion, or a bend still
/// settling. Painters repaint from [repaint].
abstract class MetalState<T extends StatefulWidget> extends State<T> with SingleTickerProviderStateMixin<T> {
  /// A representative frame of the material: where the clock starts, and what
  /// reduced motion shows.
  static const stillSeconds = 2.0;

  final repaint = _Repaint();
  final shading = MetalShading();
  late final Ticker _ticker = createTicker(_tick);
  Duration _last = Duration.zero;

  /// Animation time since mount, ms. Holds while paused or under reduced motion.
  double clockMs = 0;

  /// Wall time since mount, ms — the bend runs on it, also while paused.
  double wallMs = 0;

  /// The system asks for less motion: a still frame, no loop.
  bool reduced = false;

  bool get paused;

  /// Something besides the material needs frames (a bend settling).
  bool get busy => false;

  /// Material time, seconds.
  double get seconds => stillSeconds + clockMs / 1000;

  bool get _animating => !reduced && !paused;

  @override
  void initState() {
    super.initState();
    MetalShader.load().then((program) {
      if (!mounted || program == null) return;
      setState(() => shading.shader = program.fragmentShader());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    reduced = AppMotion.reduced(context);
    syncTicker();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    syncTicker();
  }

  void syncTicker() {
    final run = _animating || busy;
    if (run && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1000;
    _last = elapsed;
    wallMs += dt;
    if (_animating) clockMs += dt;
    repaint.notify();
    if (!_animating && !busy) _ticker.stop();
  }

  @override
  void dispose() {
    _ticker.dispose();
    shading.shader?.dispose();
    repaint.dispose();
    super.dispose();
  }
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}
