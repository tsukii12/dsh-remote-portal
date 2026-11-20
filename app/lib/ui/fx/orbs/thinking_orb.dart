// Portions derived from Libraries.dev Thinking orbs (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

// The ThinkingOrb widget, translated from thinking-orbs `src/ThinkingOrb.tsx`
// and the ink rule in `src/engine/core.ts`, with the SwiftUI and React Native
// ports' `displaySize`. Plain circles and lines on a CustomPainter: no shader,
// no filters, drawn as vectors at the device pixel ratio.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'orb_core.dart';
import 'orb_modes.dart';
import 'orb_presets.dart';

export 'orb_presets.dart' show OrbSize, OrbState;

/// The instant shown under reduced motion and before a paused orb has ever run;
/// the web build freezes at the same raw engine time.
const _stillT = 0.6;

/// 点的深浅按哪种底色画。
enum OrbTheme {
  /// 跟 [Theme.of] 的明暗走。光球放在和主题明暗相反的卡片上时(浅色 App 里的深色面板),
  /// 要钉成 [dark] 或 [light]。
  auto,

  /// 深色底:近处的点亮。
  dark,

  /// 浅色底:近处的点深。
  light,
}

/// 光球的墨色。近处的点就是这个颜色;越远,在深色底上越暗,在浅色底上越淡,
/// 所以换了颜色立体感也不变(作者的着色规则)。
@immutable
final class OrbInk {
  /// 跟主题色走(默认):主色的色相,饱和度压低,深浅跟着底色,只透出一点颜色。
  const OrbInk.theme() : color = null, _mono = false;

  /// 作者原版的灰阶墨:深色底上是白,浅色底上是黑。
  const OrbInk.mono() : color = null, _mono = true;

  /// 指定墨色(作者的 `color` 属性)。
  const OrbInk.tint(Color this.color) : _mono = false;

  final Color? color;
  final bool _mono;

  /// The nearest ink on a [dark] or light substrate.
  Color resolve(ColorScheme scheme, {required bool dark}) {
    if (color case final c?) return c;
    if (_mono) return dark ? const Color(0xFFFFFFFF) : const Color(0xFF000000);
    final base = HSLColor.fromColor(scheme.primary);
    // Close to the stock white / black so depth reads as strongly as the
    // grayscale original, with a whisper of the theme's hue.
    final sat = (base.saturation * 0.62).clamp(0.22, 0.42);
    return HSLColor.fromAHSL(1, base.hue, sat, dark ? 0.9 : 0.16).toColor();
  }

  @override
  bool operator ==(Object other) => other is OrbInk && other.color == color && other._mono == _mono;

  @override
  int get hashCode => Object.hash(color, _mono);
}

/// 点阵小光球:表示 AI 正在做什么的加载指示。九种状态([OrbState])各是作者手调的一套动画,
/// 两档尺寸([OrbSize])各有自己的点数、点大小和速度。
///
/// 用法(作者的规矩):放在一行说明文字旁边(「正在搜索…」),或者没地方放字时单独放;
/// 2 秒以内的等待不要用,一闪而过像故障;有确定进度的(上传、已知步数)用进度条。
/// 一屏不要同时放几十个。
///
/// 不可见时不耗电:动画跟着 [TickerMode] 停(切走的页面、收起的标签页);系统要求减少
/// 动画时只画一帧静止画面。所有光球读同一个帧时钟,同屏的几个步调一致。
class ThinkingOrb extends StatefulWidget {
  const ThinkingOrb({
    super.key,
    this.state = OrbState.working,
    this.size = OrbSize.px64,
    this.theme = OrbTheme.auto,
    this.ink = const OrbInk.theme(),
    this.speed = 1,
    this.paused = false,
    this.displaySize,
    this.semanticLabel,
  });

  /// 播哪段动画。
  final OrbState state;

  /// 调好的尺寸档:64 用在头像位置,20 跟一行字并排。
  final OrbSize size;

  /// 点按深色底还是浅色底画。
  final OrbTheme theme;

  /// 墨色,默认跟主题色。
  final OrbInk ink;

  /// 在作者调好的速度上再乘的倍数。
  final double speed;

  /// 停在当前这一帧。
  final bool paused;

  /// 实际占多大(逻辑像素)。几何仍按 [size] 那一档,只是整体缩放后画,依然清晰;
  /// 作者自己的例子把 64 档放进 56 的胶囊。和档位差得太多,点会显得过粗或过碎。
  final double? displaySize;

  /// 读屏文字。旁边已经有说明文字时留空,光球不进语义树。
  final String? semanticLabel;

  @override
  State<ThinkingOrb> createState() => _ThinkingOrbState();
}

class _ThinkingOrbState extends State<ThinkingOrb> with SingleTickerProviderStateMixin {
  final _clock = _OrbClock();
  final _frame = OrbFrame();
  late final Ticker _ticker = createTicker((_) => _clock.tick());
  bool _reduced = false;
  double? _frozen;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _frozen = context.dependOnInheritedWidgetOfExactType<OrbFrozenTime>()?.t;
    _sync();
  }

  @override
  void didUpdateWidget(ThinkingOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    _clock.speed = resolvePreset(widget.state, widget.size).speed * widget.speed;
    final still = _frozen ?? (_reduced ? _stillT : null);
    final run = still == null && !widget.paused;
    _clock.running = run;
    if (still != null && still != _clock.t) {
      _clock
        ..t = still
        ..tick();
    }
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = switch (widget.theme) {
      OrbTheme.dark => true,
      OrbTheme.light => false,
      OrbTheme.auto => theme.brightness == Brightness.dark,
    };
    final box = widget.displaySize ?? widget.size.px;
    Widget orb = SizedBox.square(
      dimension: box,
      child: RepaintBoundary(
        child: CustomPaint(
          painter: _OrbPainter(
            clock: _clock,
            frame: _frame,
            preset: resolvePreset(widget.state, widget.size),
            size: widget.size.px,
            dark: dark,
            ink: widget.ink.resolve(theme.colorScheme, dark: dark),
          ),
        ),
      ),
    );
    final label = widget.semanticLabel;
    if (label != null) orb = Semantics(label: label, image: true, child: orb);
    return orb;
  }
}

/// 把下面所有 [ThinkingOrb] 定在引擎时间 [t] 秒(原样,不乘速度),不再走动。给截图和
/// 测试用(一直在动的光球会让 `pumpAndSettle` 等不完);作者 SwiftUI 版的 `orbFrozenTime`。
class OrbFrozenTime extends InheritedWidget {
  const OrbFrozenTime({super.key, required this.t, required super.child});

  final double t;

  @override
  bool updateShouldNotify(OrbFrozenTime oldWidget) => t != oldWidget.t;
}

/// The shared clock. Every orb reads the same frame timestamp, so orbs on
/// screen stay in phase and resume in phase (the web build's single
/// `performance.now()`); the ticker only asks for a repaint.
class _OrbClock extends ChangeNotifier {
  /// Engine seconds per real second: the preset's baked speed times the
  /// widget's multiplier.
  double speed = 1;
  bool running = false;

  /// Engine time of the last painted frame; held while paused.
  double t = _stillT;

  double now() {
    if (running) {
      t = SchedulerBinding.instance.currentFrameTimeStamp.inMicroseconds / Duration.microsecondsPerSecond * speed;
    }
    return t;
  }

  void tick() => notifyListeners();
}

class _OrbPainter extends CustomPainter {
  _OrbPainter({
    required this.clock,
    required this.frame,
    required this.preset,
    required this.size,
    required this.dark,
    required this.ink,
  }) : _r = ink.r * 255,
       _g = ink.g * 255,
       _b = ink.b * 255,
       super(repaint: clock);

  final _OrbClock clock;
  final OrbFrame frame;
  final OrbPreset preset;

  /// The tuned size the geometry is built at.
  final double size;
  final bool dark;
  final Color ink;
  final double _r, _g, _b;
  final _fill = Paint();
  final _stroke = Paint()..style = PaintingStyle.stroke;

  /// One ink value to a colour: grayscale or tinted, the ramp running toward
  /// black on dark substrates and toward white on light ones. Channels are
  /// rounded to 8 bits as the canvas painter does; alpha is clamped as CSS
  /// clamps it (braid's outer strands reach just past 1).
  Color _inkOf(double white, double alpha) {
    final w = white.clamp(0.0, 1.0);
    final double r, g, b;
    if (dark) {
      r = (_r * (1 - w)).roundToDouble();
      g = (_g * (1 - w)).roundToDouble();
      b = (_b * (1 - w)).roundToDouble();
    } else {
      r = (_r + (255 - _r) * w).roundToDouble();
      g = (_g + (255 - _g) * w).roundToDouble();
      b = (_b + (255 - _b) * w).roundToDouble();
    }
    return Color.from(alpha: math.min(1.0, alpha), red: r / 255, green: g / 255, blue: b / 255);
  }

  @override
  void paint(Canvas canvas, Size box) {
    final f = frame;
    modeFrames[preset.mode]!(f, size, clock.now(), preset.opts);
    final zoom = box.width / size;
    if (zoom != 1) {
      canvas
        ..save()
        ..scale(zoom);
    }
    // lines first, so nodes sit on top of their edges
    for (var k = 0; k < f.lineCount; k++) {
      _stroke
        ..color = _inkOf(f.lineWhite(k), f.lineA(k))
        ..strokeWidth = f.lineW(k);
      canvas.drawLine(Offset(f.lineX1(k), f.lineY1(k)), Offset(f.lineX2(k), f.lineY2(k)), _stroke);
    }
    // dots are already z-sorted into draw order, far to near
    for (var k = 0; k < f.dotCount; k++) {
      _fill.color = _inkOf(f.white(k), f.a(k));
      canvas.drawCircle(Offset(f.x(k), f.y(k)), f.r(k), _fill);
    }
    if (zoom != 1) canvas.restore();
  }

  @override
  bool shouldRepaint(_OrbPainter old) =>
      old.preset != preset || old.size != size || old.dark != dark || old.ink != ink || old.clock != clock;
}
