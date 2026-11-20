// Portions derived from Libraries.dev Image (https://github.com/Jakubantalik/Libraries.dev), MIT, Copyright (c) 2026 Jakub Antalik. See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/motion.dart';
import 'cycle.dart';
import 'field.dart';
import 'presets.dart';
import 'renderer.dart';
import 'reveal.dart';

export 'cycle.dart' show ImageGenerationPhase;
export 'presets.dart' show ImageGenerationPreset;

/// 生图占位：图还在生成时，盒子里是一片慢慢翻涌的像素马赛克；图到了，马赛克
/// 一格一格溶解成这张图并停住；再生成时，图碎回像素翻涌，新图再从翻涌里溶出来。
///
/// 移植自 Libraries.dev 的 Image（npm `img-fx`）：马赛克是原库 WebGL 着色器的
/// Flutter 片元着色器版本（两遍：每格一次的格子场，再逐像素合成），溶解、停住、
/// 淡出、再生成翻涌照搬原库 `reveal.ts` 的状态机和时长（溶解 3 秒、淡出 300ms、
/// 翻涌像素化 0.8 秒、新图交接约 2 秒），帧率按原库封顶 10fps。
///
/// 尺寸跟父级走（需要有界约束，通常外面是最终图片比例的盒子）。默认配色跟主题：
/// 主色色相、低饱和、深浅跟主题；`themed: false` 用原库预设的灰阶。
///
/// 系统要求减少动画时只画一帧静止的马赛克，图到了直接显示，不播溶解。
class ImageGeneration extends StatefulWidget {
  const ImageGeneration({
    super.key,
    this.image,
    this.generating = false,
    this.preset = ImageGenerationPreset.pixelsOrganic,
    this.themed = true,
    this.colors,
    this.cardBg,
    this.brightness,
    this.strength = 1,
    this.speed = 1,
    this.pixelScale = 1,
    this.paused = false,
    this.frameRate = 10,
    this.tintFromImage = true,
    this.borderRadius,
    this.onPhase,
    this.onImageError,
    this.child,
  });

  /// 生成好的图。null 时是翻涌的马赛克；有图（且 [generating] 为假）时马赛克溶解成
  /// 它并停住；换成另一张图时，旧图碎成像素再溶成新图。
  final ImageProvider? image;

  /// 正在生成。图已显示时打开它，图碎回像素一直翻涌（原库的 Regenerate），直到它
  /// 变回假，[image] 再从翻涌里溶出来；这期间把 [image] 清掉也照样翻涌。没有图时
  /// 不影响什么。
  final bool generating;

  /// 跑哪种效果。
  final ImageGenerationPreset preset;

  /// 跟主题配色（默认）。false 用原库预设自己的配色。
  final bool themed;

  /// 逐格覆盖调色板（最多 7 格）；null 的格子保留预设或主题的颜色。
  final List<Color?>? colors;

  /// 卡片底色：画在最底下，也是着色器做对比的颜色（和它太接近的格子会淡掉）。
  /// 默认跟主题时取 `colorScheme.surfaceContainerHigh`，预设配色时取预设的底色。
  final Color? cardBg;

  /// 深浅，默认跟 `Theme.of(context).brightness`。
  final Brightness? brightness;

  /// 0..2。0..1 只改马赛克的不透明度；大于 1 时加强配色和高光。
  final double strength;

  /// 动画速度倍数，1 是预设自己的节奏。
  final double speed;

  /// 像素格大小倍数：2 是格子大一倍，0.5 小一半。
  final double pixelScale;

  /// 冻结动画，停在当前帧；溶解等动作也跟着停，解冻后接着走。
  final bool paused;

  /// 帧率上限（1..60）。原库是 10：马赛克漂得慢，10 帧够看也省电。
  final double frameRate;

  /// 再生成时，翻涌的颜色从正在碎掉的那张图里取（原库 `tintFromImage`）。
  final bool tintFromImage;

  /// 圆角，用 RSuperellipse 裁。null 时不裁，交给外面。
  final BorderRadius? borderRadius;

  /// 阶段变化（溶解开始、图完整显示、开始淡出、回到马赛克）。
  final ValueChanged<ImageGenerationPhase>? onPhase;

  /// [image] 解码失败；没给时按 Flutter 的方式报错。失败后留在马赛克。
  final ImageErrorListener? onImageError;

  /// 画在效果上面的内容（比如进度文字），撑满整块。
  final Widget? child;

  /// Fixes the random start, cell orders and churn pick (previews, tests).
  @visibleForTesting
  static int? debugSeed;

  @override
  State<ImageGeneration> createState() => _ImageGenerationState();
}

class _ImageGenerationState extends State<ImageGeneration> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _renderer = FxRenderer();

  /// Engine frame serial; the painter repaints on it.
  final _frame = ValueNotifier<int>(0);
  late final math.Random _random = math.Random(ImageGeneration.debugSeed);
  late final FxReveal _reveal = FxReveal(now: () => _clockMs, random: _random);
  late final FxCycle _cycle = FxCycle(reveal: _reveal, load: _load, onPhase: _onCyclePhase, onError: _onLoadError);

  /// The instance clock (`accumulatedTime`), seconds; random start so cards
  /// don't move in lockstep.
  late double _time = _random.nextDouble() * 1000;

  /// Engine clock, ms: advances only while the ticker runs.
  double _clockMs = 0;
  double _tickerBase = 0;
  double _lastFrameMs = 0;
  double _lastTickMs = 0;
  Size _size = Size.zero;
  bool _reduced = false;

  late Brightness _brightness;
  late FxPresetMode _mode;
  late FxLook _look;
  late FxField _field;
  double? _fieldStrength;

  /// The regenerate churn's image-born palette and its pixel preset (when the
  /// authored one is the sweep); cleared once the next image is visible.
  FxLook? _tint;
  ImageGenerationPreset? _churnPreset;

  /// Reduced motion: the picture shown without a reveal.
  RevealImage? _still;
  ImageProvider? _stillSrc;

  @override
  void initState() {
    super.initState();
    // Made here, not lazily: under reduced motion it may first be touched in dispose().
    _ticker = createTicker(_onTick);
    FxPrograms.load().then((_) {
      if (mounted) _frame.value++;
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduced = AppMotion.reduced(context);
    if (reduced != _reduced) {
      _reduced = reduced;
      if (reduced) {
        _cycle.stop();
        _tint = null;
        _churnPreset = null;
      } else {
        _stillSrc = null;
        _still?.dispose();
        _still = null;
      }
    }
    _sync();
  }

  @override
  void didUpdateWidget(ImageGeneration oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cycle.dispose();
    _reveal.dispose();
    _renderer.dispose();
    _still?.dispose();
    _frame.dispose();
    super.dispose();
  }

  /// Map [ImageGeneration.image] / [ImageGeneration.generating] onto the
  /// cycle: reveal and hold, regenerate, or hide.
  void _sync() {
    if (_reduced) {
      _syncStill();
      return;
    }
    final img = widget.image;
    final phase = _reveal.phase;
    final shown = phase == RevealPhase.reveal || phase == RevealPhase.hold;
    if (img != null && !widget.generating) {
      if (_cycle.currentSrc != img) {
        // A different picture over a shown one churns first; the idle that
        // follows reveals it over the churn.
        if (shown) {
          _regenerate();
        } else if (phase != RevealPhase.hide) {
          _cycle.triggerOnce(img);
        }
      }
    } else if (widget.generating && shown) {
      _regenerate();
    } else if (img == null && !widget.generating && (shown || phase == RevealPhase.boil)) {
      _cycle.triggerHide();
    } else {
      // Nothing may be revealed now: forget a decode still running, or a
      // picture already handed to the churn.
      _cycle.cancel();
    }
    _updateTicker();
  }

  /// `triggerRegenerate`: churn on a pixel preset, recoloured from the image.
  void _regenerate() {
    final authored = widget.preset;
    final churn = authored.isPixelChurn
        ? null
        : (_random.nextBool() ? ImageGenerationPreset.pixelsMechanic : ImageGenerationPreset.pixelsOrganic);
    final pixels = widget.tintFromImage ? _reveal.image?.tintPixels : null;
    final tint = pixels == null ? null : sampleTint(pixels, (churn ?? authored).mode(_brightness).colors);
    setState(() {
      if (tint != null) _tint = tint;
      if (churn != null) _churnPreset = churn;
    });
    _cycle.triggerBoil();
  }

  void _onCyclePhase(ImageGenerationPhase phase, ImageProvider? src) {
    if (phase == ImageGenerationPhase.visible && (_tint != null || _churnPreset != null)) {
      setState(() {
        _tint = null;
        _churnPreset = null;
      });
    }
    final onPhase = widget.onPhase;
    if (onPhase != null) {
      // Phases can change while this widget updates; tell the parent after the frame.
      if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onPhase?.call(phase);
        });
      } else {
        onPhase(phase);
      }
    }
    if (phase == ImageGenerationPhase.idle) {
      _sync();
    } else {
      _updateTicker();
    }
  }

  void _onLoadError(Object error, StackTrace? stack) {
    if (!mounted) return;
    final onError = widget.onImageError;
    if (onError != null) {
      onError(error, stack);
    } else {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'image generation',
          context: ErrorDescription('decoding the generated image'),
        ),
      );
    }
  }

  /// `loadImage`: the first frame of [src], decoded.
  Future<RevealImage> _load(ImageProvider src) {
    final completer = Completer<RevealImage>();
    final stream = src.resolve(createLocalImageConfiguration(context));
    late final ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(RevealImage(info.image));
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  void _syncStill() {
    final src = widget.image != null && !widget.generating ? widget.image : null;
    if (src == _stillSrc) return;
    _stillSrc = src;
    _still?.dispose();
    _still = null;
    if (src == null) return;
    _load(src).then((img) {
      if (!mounted || _stillSrc != src) {
        img.dispose();
        return;
      }
      // The same picture may have been asked for twice; keep the newer decode.
      setState(() {
        _still?.dispose();
        _still = img;
      });
    }, onError: _onLoadError);
  }

  void _updateTicker() {
    final want = !_reduced && !widget.paused && _reveal.phase != RevealPhase.hold;
    if (want == _ticker.isActive) return;
    if (want) {
      _tickerBase = _clockMs;
      _lastTickMs = _clockMs;
      // Draw the first frame at once rather than an interval later.
      _lastFrameMs = _clockMs - 1000;
      _ticker.start();
    } else {
      _ticker.stop();
    }
  }

  /// renderer.ts `tick`: frames capped at [ImageGeneration.frameRate].
  void _onTick(Duration elapsed) {
    final now = _tickerBase + elapsed.inMicroseconds / 1000;
    _clockMs = now;
    final interval = 1000 / widget.frameRate.clamp(1, 60);
    final since = now - _lastFrameMs;
    if (since < interval) return;
    _lastFrameMs = now - since % interval;
    _time += (now - _lastTickMs) / 1000 * widget.speed;
    _lastTickMs = now;
    if (_size.isEmpty) return;
    final before = _reveal.phase;
    _reveal.frame(
      FxFrame(mode: _mode, look: _look, size: _size, pixelScale: widget.pixelScale, time: _time, sample: _sample),
      now,
    );
    _frame.value++;
    // Read the shown image back once, ready for a regenerate's tint.
    if (widget.tintFromImage) _reveal.image?.prepareTint(_size);
    // A hide the cycle doesn't track (out of a churn) ended: catch up.
    if (before == RevealPhase.hide && _reveal.phase == RevealPhase.idle) _sync();
    _updateTicker();
  }

  Uint8List? _sample(bool fresh) => _renderer.sample(fresh, _field, _mode, _look, _size, _time, widget.pixelScale);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    _brightness = widget.brightness ?? theme.brightness;
    final mode = (_churnPreset ?? widget.preset).mode(_brightness);
    final look =
        _tint ??
        (widget.themed
            ? FxLook.themed(
                mode,
                theme.colorScheme.primary,
                widget.cardBg ?? theme.colorScheme.surfaceContainerHigh,
                colors: widget.colors,
              )
            : FxLook.preset(mode, cardBg: widget.cardBg, colors: widget.colors));
    if (_fieldStrength == null || !identical(mode, _mode) || look != _look || widget.strength != _fieldStrength) {
      _mode = mode;
      _look = look;
      _fieldStrength = widget.strength;
      _field = FxField(mode, look, strength: widget.strength);
    }
    Widget result = LayoutBuilder(
      builder: (context, constraints) {
        _size = constraints.biggest;
        return RepaintBoundary(
          child: CustomPaint(painter: _FxPainter(this), child: const SizedBox.expand()),
        );
      },
    );
    if (widget.child case final child?) {
      result = Stack(fit: StackFit.expand, children: [result, child]);
    }
    if (widget.borderRadius case final radius?) {
      result = ClipRSuperellipse(borderRadius: radius, child: result);
    }
    return result;
  }
}

class _FxPainter extends CustomPainter {
  _FxPainter(this.s) : super(repaint: s._frame);

  final _ImageGenerationState s;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    canvas.drawRect(Offset.zero & size, Paint()..color = s._look.cardBg);
    final FxOverlay? overlay;
    final double mosaic, overlayOpacity;
    if (s._reduced) {
      final still = s._still;
      overlay = still == null ? null : FxOverlayImage(still);
      mosaic = still == null ? 1 : 0;
      overlayOpacity = 1;
    } else {
      overlay = s._reveal.overlay;
      mosaic = s._reveal.shaderOpacity;
      overlayOpacity = s._reveal.overlayOpacity;
    }
    final opacity = s.widget.strength.clamp(0.0, 1.0) * mosaic;
    if (opacity > 0.001) {
      s._renderer.paintMosaic(
        canvas,
        size,
        s._field,
        s._mode,
        s._look,
        s._time,
        s.widget.pixelScale,
        opacity,
        s._frame.value,
      );
    }
    s._renderer.paintOverlay(canvas, size, overlay, overlayOpacity);
  }

  @override
  bool shouldRepaint(_FxPainter oldDelegate) => true;
}
