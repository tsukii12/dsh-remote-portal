// Portions derived from Libraries.dev Voice (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'voice_driver.dart';
import 'voice_painter.dart';
import 'voice_style.dart';

export 'voice_driver.dart' show VoiceBeamMotion, VoiceLevelScale;
export 'voice_style.dart' show VoiceBandColors, VoiceBeamColorVariant, VoiceBeamType;

/// 随人声从底边升起的彩色光（Libraries.dev 的 Voice / `voice-glow`）。
///
/// 光沿 [child] 的底边居中，随 [level] 升起、变宽、泛开。
///
/// - 输入框听写：`type: standard`，[level] 接听写音量。
/// - 通话页底部：`type: mobile`，听时接麦克风音量，她说话时接朗读音量——
///   换音源时把 [levelScale] 一起换掉。
///
/// 作者的 MIT 包里没有「处理中」那段左右扫（那是 Libraries Pro 的），只有
/// 底层的 [motion]：把光收成一束、放到某处。
/// 光画在 [child] 上面、[foreground] 下面：要保持清晰的文字和按钮放进
/// [foreground]（作者的做法是给它们 `z-index: 5`）。光按 [borderRadius]
/// 裁成圆角，[child] 本身不裁。
///
/// 音量从外面给，组件不碰麦克风。每帧读一次 [level]，不会让外面重建。
/// 系统要求减少动画时没有循环：不呼吸、不流动，只在 [level] 或 [motion]
/// 变化时换一帧（光是音量表，音量照样显示）。
class VoiceBeam extends StatefulWidget {
  const VoiceBeam({
    super.key,
    required this.child,
    this.foreground,
    this.type = VoiceBeamType.standard,
    this.level,
    this.levelScale = VoiceLevelScale.linear,
    this.motion,
    this.active = true,
    this.paused = false,
    this.colorVariant,
    this.colors,
    this.bandColors,
    this.theme,
    this.borderRadius = 16,
    this.scale,
    this.sensitivity = 3.1,
    this.threshold = 0.015,
    this.attack = 0.325,
    this.release = 0.86,
    this.idle,
    this.breatheDuration = 5.2,
    this.bands = true,
    this.reach,
    this.spread,
    this.flow,
    this.bend,
    this.bandStrength,
    this.bandWidth,
    this.glowSize,
    this.strength,
    this.brightness,
    this.saturation,
    this.staticColors = false,
    this.hueRange,
    this.hueDuration,
  });

  /// 光下面的东西（宿主的底色、边框）。决定组件的大小。
  final Widget child;

  /// 光上面的东西：文字、按钮。铺满 [child] 的大小。
  final Widget? foreground;

  /// 宿主类型：输入框、录音胶囊、手机整屏底部。
  final VoiceBeamType type;

  /// 0–1 的音量，每帧读一次。怎么理解这个数看 [levelScale]。
  final ValueListenable<double>? level;

  /// [level] 是什么刻度：系统识别器的 0–1 用 [VoiceLevelScale.linear]；
  /// 通话采音用 [VoiceLevelScale.callCapture]；朗读播放和云端听写录音用
  /// [VoiceLevelScale.playback]。
  final VoiceLevelScale levelScale;

  /// 光的大尺度姿态，每帧读一次（作者的 `motion`）；不给就是随声的光。
  final ValueListenable<VoiceBeamMotion>? motion;

  /// 关掉时光淡出（0.5 s），打开时淡入（0.6 s）；淡完就停帧。
  final bool active;

  /// 定格在当前这一帧，不淡出。
  final bool paused;

  /// 作者的八套配色之一；不给就跟主题色走（主色和相邻色相，饱和度压低）。
  final VoiceBeamColorVariant? colorVariant;

  /// 自己的七团光的颜色，中心在前、再往外成对；缺的位置用配色里的。
  final List<Color>? colors;

  /// 光带的颜色；不给时跟 [colorVariant]：主题配色用主题色相，作者配色用作者的。
  final VoiceBandColors? bandColors;

  /// 按深色还是浅色背景调；不给就跟 `Theme.of(context).brightness`。
  final Brightness? theme;

  /// [child] 的圆角，光按它裁、按它拐弯。
  final double borderRadius;

  /// 整体大小，所有像素尺寸一起乘。作者按约 371 宽的输入框调，更窄时传
  /// `min(1, width / 371)`。不给就用类型的（`mobile` 1.25、`pill` 0.45）。
  final double? scale;

  /// 输入增益，只作用于 dBFS 刻度的音量。
  final double sensitivity;

  /// 噪声门，0–1：低于它算安静。
  final double threshold;

  /// 升起用的秒数。
  final double attack;

  /// 回落用的秒数。
  final double release;

  /// 安静时的呼吸存在感，0–1；0 表示安静时完全不见。
  final double? idle;

  /// 呼吸的周期，秒。
  final double breatheDuration;

  /// 低 / 中 / 高三段分别推动不同的光团（没有频谱时由音量合成）。
  final bool bands;

  /// 满音量时升高到静止高度的几倍。
  final double? reach;

  /// 满音量时变宽多少（静止宽度的比例）。
  final double? spread;

  /// 说话时颜色往侧边流的速度，px/s；负数往左，0 不流。
  final double? flow;

  /// 满音量时光的顶边在中间拱起多少 px。
  final double? bend;

  /// 光带的不透明度，0 隐藏。
  final double? bandStrength;

  /// 光带的粗细。
  final double? bandWidth;

  /// 光晕模糊半径的倍数。
  final double? glowSize;

  /// 整体强度，0–1。
  final double? strength;

  /// 光的亮度倍数。
  final double? brightness;

  /// 光的饱和度倍数。
  final double? saturation;

  /// 关掉缓慢的色相漂移。
  final bool staticColors;

  /// 色相漂移的幅度，度。
  final double? hueRange;

  /// 色相漂移的周期，秒。
  final double? hueDuration;

  @override
  State<VoiceBeam> createState() => _VoiceBeamState();
}

class _VoiceBeamState extends State<VoiceBeam> with SingleTickerProviderStateMixin {
  final _engine = VoiceGlowEngine();
  final _renderer = VoiceGlowRenderer();
  final _repaint = _Repaint();
  late final Ticker _ticker = createTicker(_tick);
  late VoiceGlowConfig _config;
  Duration? _last;
  bool _reduced = false;
  ValueListenable<double>? _levelHeard;
  ValueListenable<VoiceBeamMotion>? _motionHeard;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = AppMotion.reduced(context);
    _config = _resolve();
    _sync();
  }

  @override
  void didUpdateWidget(VoiceBeam oldWidget) {
    super.didUpdateWidget(oldWidget);
    _config = _resolve();
    _sync();
  }

  VoiceGlowConfig _resolve() {
    final theme = Theme.of(context);
    final w = widget;
    return VoiceGlowConfig.resolve(
      type: w.type,
      dark: (w.theme ?? theme.brightness) == Brightness.dark,
      scheme: theme.colorScheme,
      colorVariant: w.colorVariant,
      colors: w.colors,
      bandColors: w.bandColors,
      radius: w.borderRadius,
      levelScale: w.levelScale,
      sensitivity: w.sensitivity,
      threshold: w.threshold,
      attack: w.attack,
      release: w.release,
      breatheDuration: w.breatheDuration,
      bands: w.bands,
      scale: w.scale,
      glowSize: w.glowSize,
      idle: w.idle,
      reach: w.reach,
      spread: w.spread,
      flow: w.flow,
      bend: w.bend,
      bandStrength: w.bandStrength,
      bandWidth: w.bandWidth,
      strength: w.strength,
      brightness: w.brightness,
      saturation: w.saturation,
      staticColors: w.staticColors,
      hueRange: w.hueRange,
      hueDuration: w.hueDuration,
      reducedMotion: _reduced,
    );
  }

  /// Runs the ticker while something moves: active and not paused, or
  /// fading out. Reduced motion never runs it; it redraws a still frame
  /// whenever the level or the motion changes instead.
  void _sync() {
    final level = _reduced ? widget.level : null;
    if (!identical(level, _levelHeard)) {
      _levelHeard?.removeListener(_still);
      _levelHeard = level?..addListener(_still);
    }
    final motion = _reduced ? widget.motion : null;
    if (!identical(motion, _motionHeard)) {
      _motionHeard?.removeListener(_still);
      _motionHeard = motion?..addListener(_still);
    }
    if (_reduced) {
      if (_ticker.isActive) _ticker.stop();
      _still();
      return;
    }
    final run = widget.active ? !widget.paused : _engine.visible;
    if (run && !_ticker.isActive) {
      _last = null;
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  void _still() {
    _engine.still(
      _config,
      input: widget.level?.value ?? 0,
      motion: widget.motion?.value ?? VoiceBeamMotion.rest,
      active: widget.active,
    );
    _repaint.notify();
  }

  void _tick(Duration elapsed) {
    final last = _last;
    _last = elapsed;
    final dt = last == null ? 1 / 60 : ((elapsed - last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _engine.step(
      _config,
      dt: dt,
      input: widget.level?.value ?? 0,
      motion: widget.motion?.value ?? VoiceBeamMotion.rest,
      active: widget.active,
      frozen: widget.paused,
    );
    _repaint.notify();
    if (!widget.active && !_engine.visible) _ticker.stop();
  }

  @override
  void dispose() {
    _levelHeard?.removeListener(_still);
    _motionHeard?.removeListener(_still);
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: CustomPaint(
                painter: VoiceGlowPainter(renderer: _renderer, engine: _engine, config: _config, repaint: _repaint),
              ),
            ),
          ),
        ),
        if (widget.foreground case final foreground?) Positioned.fill(child: foreground),
      ],
    );
  }
}

class _Repaint extends ChangeNotifier {
  void notify() => notifyListeners();
}
