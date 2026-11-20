// Portions derived from Libraries.dev Border beam (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'beam_data.dart';
import 'beam_engine.dart';
import 'beam_painter.dart';

export 'beam_data.dart' show BeamPalette, BorderBeamColorVariant, BorderBeamSize, BorderBeamTheme;

/// 沿边框走的一道光（Libraries.dev Border beam 的移植）。包住 [child]，不改它的布局。
///
/// 用法照原库：
/// - 等待超过 3 秒的工作（回复流式输出、代理在跑）：包住输入框，`size: md` 或 `line`，
///   [active] 接真实的状态；短等待不要光。
/// - 突出一个按钮：`size: pulseInner`；突出一个输入框：`size: pulseOutside`。
///
/// 光画在子组件上面（pulseOutside 的光晕画在下面并溢出边界，子组件要有不透明背景，
/// 外层也不能裁剪）。除 pulseOutside 外，光都裁在 [borderRadius] 的圆角矩形里；圆角要
/// 和子组件自己的圆角一致，原库能自动读，这里得传。
///
/// 不传 [colorVariant] 时配色跟主题主色走（旋转族只在主色左右小幅漂移，呼吸族不转色相）；
/// 深浅色跟 `Theme.of(context).brightness`。系统要求减少动画时只画一帧静止的光，开关不渐变。
/// 每帧要重画几层遮罩和模糊，一屏只放几个，用完把 [active] 关掉。
class BorderBeam extends StatefulWidget {
  const BorderBeam({
    super.key,
    required this.child,
    this.size = BorderBeamSize.md,
    this.colorVariant,
    this.theme,
    this.staticColors,
    this.duration,
    this.active = true,
    this.borderRadius,
    this.brightness,
    this.saturation,
    this.hueRange = 30,
    this.hueShift = 0,
    this.glowSize = 1,
    this.strength = 1,
    this.onActivate,
    this.onDeactivate,
  });

  final Widget child;

  /// Beam type (the web library's `size`).
  final BorderBeamSize size;

  /// One of the author's palettes; null follows the theme's primary colour.
  final BorderBeamColorVariant? colorVariant;

  /// Tune for a dark or light surface; null follows the app theme.
  final BorderBeamTheme? theme;

  /// No hue drift. Forced for `mono`; defaults to false, except the theme
  /// palette on the pulse types, whose drift is a full hue circle.
  final bool? staticColors;

  /// Seconds per rotation / travel / breath. Defaults: md and sm 1.96, line
  /// 3.1, pulse 2.3.
  final double? duration;

  /// Runs the effect; switching fades in over 0.6 s or out over 0.5 s.
  final bool active;

  /// The child's corner radius. Defaults to 16 (sm: 32).
  final double? borderRadius;

  /// Glow brightness multiplier; defaults to the type's preset.
  final double? brightness;

  /// Glow saturation multiplier; defaults to the type's preset.
  final double? saturation;

  /// ± degrees of the hue drift (capped at 13 for line).
  final double hueRange;

  /// Base hue rotation in degrees, added wherever the beam hue-rotates.
  final double hueShift;

  /// Multiplies every glow blur radius.
  final double glowSize;

  /// 0–1 opacity of the beam layers only, never the child.
  final double strength;

  /// Called when a fade-in finishes.
  final VoidCallback? onActivate;

  /// Called when a fade-out finishes and the layers are gone.
  final VoidCallback? onDeactivate;

  @override
  State<BorderBeam> createState() => _BorderBeamState();
}

class _BorderBeamState extends State<BorderBeam> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  final _frame = BeamFrame();

  /// Seconds on the beam clock; the ticker restarts from zero, so it adds to
  /// [_clockBase].
  double _clock = 0;
  double _clockBase = 0;
  BeamFade _fade = BeamFade.off;

  /// The layers exist: from switching on until a fade-out finishes.
  bool _shown = false;
  bool _announced = false;
  bool _reduced = false;
  bool _started = false;

  BeamConfig? _config;
  BeamPainter? _over;
  BeamPainter? _under;
  Color? _seed;
  BeamPalette? _seedPalette;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduced(context);
    if (!_started) {
      _started = true;
      _reduced = reduced;
      if (widget.active) _switch(true);
    } else if (reduced != _reduced) {
      _reduced = reduced;
      _drive();
    }
  }

  @override
  void didUpdateWidget(BorderBeam oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) _switch(widget.active);
  }

  @override
  void dispose() {
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  void _switch(bool on) {
    final from = _fade.at(_clock);
    final duration = _reduced ? 0.0 : (on ? beamFadeIn : beamFadeOut);
    _fade = BeamFade(from, on ? 1 : 0, _clock, duration);
    _announced = false;
    if (on) _shown = true;
    _drive();
  }

  /// Runs the ticker while the layers are shown and motion is allowed; under
  /// reduced motion settles at once on a still frame.
  void _drive() {
    if (!_shown || _reduced) {
      if (_ticker.isActive) {
        _ticker.stop();
        _clockBase = _clock;
      }
    }
    if (!_shown) return;
    if (_reduced) {
      final on = _fade.to > 0;
      _fade = BeamFade(_fade.to, _fade.to, _clock, 0);
      _frame.set(_clock, _fade.to, still: true);
      if (!on) _shown = false;
      if (!_announced) {
        _announced = true;
        final callback = on ? widget.onActivate : widget.onDeactivate;
        if (callback != null) SchedulerBinding.instance.addPostFrameCallback((_) => callback());
      }
      return;
    }
    if (!_ticker.isActive) {
      _clockBase = _clock;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    _clock = _clockBase + elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final fade = _fade.at(_clock);
    if (_fade.doneAt(_clock)) {
      if (_fade.to == 0) {
        _ticker.stop();
        _clockBase = _clock;
        _frame.set(_clock, 0);
        setState(() => _shown = false);
        widget.onDeactivate?.call();
        return;
      }
      if (!_announced) {
        _announced = true;
        widget.onActivate?.call();
      }
    }
    // Pulse breathing is slow; like the web's shared driver it moves at
    // ~30 fps while the fade keeps the display rate.
    var t = _clock;
    if (_config!.size.isPulse && _clock - _frame.t < 1 / 30 - 0.002) t = _frame.t;
    _frame.set(t, fade);
  }

  BeamConfig _resolve(BuildContext context) {
    final w = widget;
    final theme = Theme.of(context);
    final dark = switch (w.theme) {
      null => theme.brightness == Brightness.dark,
      BorderBeamTheme.dark => true,
      BorderBeamTheme.light => false,
    };
    final variant = w.colorVariant;
    final BeamPalette palette;
    if (variant != null) {
      palette = variant.palette;
    } else {
      final seed = theme.colorScheme.primary;
      if (seed != _seed) {
        _seed = seed;
        _seedPalette = BeamPalette.fromSeed(seed);
      }
      palette = _seedPalette!;
    }
    final mono = variant == BorderBeamColorVariant.mono;
    final preset = BeamThemePreset.of(w.size, dark: dark);
    return BeamConfig(
      size: w.size,
      palette: palette,
      mono: mono,
      dark: dark,
      // The theme palette keeps the rotate/line drift (±30°/±13° stays among
      // the theme's neighbours, and the line bloom needs its blur) but not
      // the pulse family's full-circle hue spin.
      staticColors: mono || (w.staticColors ?? (variant == null && w.size.isPulse)),
      duration: w.duration ?? beamDefaultDuration(w.size),
      radius: w.borderRadius ?? beamDefaultRadius(w.size),
      brightness: w.brightness ?? preset.brightness,
      saturation: w.saturation ?? preset.saturation,
      hueRange: w.size == BorderBeamSize.line ? math.min(w.hueRange, 13) : w.hueRange,
      hueShift: w.hueShift,
      glowSize: w.glowSize,
      strength: w.strength.clamp(0.0, 1.0),
    );
  }

  @override
  Widget build(BuildContext context) {
    final config = _resolve(context);
    if (config != _config) {
      _config = config;
      _over = BeamPainter(config, _frame);
      _under = config.size == BorderBeamSize.pulseOutside ? BeamPainter(config, _frame, behind: true) : null;
    }
    return RepaintBoundary(
      child: CustomPaint(
        painter: _shown ? _under : null,
        foregroundPainter: _shown ? _over : null,
        willChange: _shown && !_reduced,
        child: RepaintBoundary(child: widget.child),
      ),
    );
  }
}
