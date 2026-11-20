// Small motions of the fluid tier (AppMotion.fluid). Each only moves, scales or
// strokes one small thing, and on the standard tier is the plain widget it replaces.

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../theme/motion.dart';

/// Long press with a body: held, the thing sinks a little; when the press lands it
/// springs up past its size, as the menu opens. The standard tier only has the press.
class HoldLift extends StatefulWidget {
  const HoldLift({super.key, required this.child, this.onLongPress, this.behavior});

  final Widget child;
  final VoidCallback? onLongPress;
  final HitTestBehavior? behavior;

  /// How far the edges may move: a long reply sinks by less than a short bubble.
  static const _maxEdgeShift = 6.0;
  static const _maxSink = 0.03;

  /// A scroll starts within this; only after it does the press show.
  static const _showAfter = Duration(milliseconds: 110);

  /// About what's left of the long-press timeout by then.
  static const _sinkFor = Duration(milliseconds: 390);

  @override
  State<HoldLift> createState() => _HoldLiftState();
}

class _HoldLiftState extends State<HoldLift> with SingleTickerProviderStateMixin {
  /// 0 at rest, 1 sunk, below 0 past its size on the way back.
  late final AnimationController _press = AnimationController.unbounded(vsync: this);
  Timer? _delay;
  double _sink = HoldLift._maxSink;

  @override
  void dispose() {
    _delay?.cancel();
    _press.dispose();
    super.dispose();
  }

  void _down(LongPressDownDetails _) {
    final size = context.size;
    if (size != null) {
      final longest = math.max(size.width, size.height);
      if (longest > 0) _sink = math.min(HoldLift._maxSink, 2 * HoldLift._maxEdgeShift / longest);
    }
    _delay?.cancel();
    _delay = Timer(HoldLift._showAfter, () {
      if (mounted) unawaited(_press.animateTo(1, duration: HoldLift._sinkFor, curve: Curves.easeOut));
    });
  }

  void _settle({double velocity = 0}) {
    _delay?.cancel();
    if (_press.value == 0 && velocity == 0) {
      // The sink can already be running before its first tick moves the value.
      _press.stop();
      return;
    }
    _press.animateWith(
      SpringSimulation(
        AppMotion.releaseSpring,
        _press.value,
        0,
        velocity,
        snapToEnd: true,
        tolerance: const Tolerance(distance: 0.002, velocity: 0.02),
      ),
    );
  }

  void _fire() {
    // A quick kick on top of the sink: it passes its size even from not very deep.
    _settle(velocity: -6);
    widget.onLongPress?.call();
  }

  @override
  Widget build(BuildContext context) {
    final onLongPress = widget.onLongPress;
    // The tiers differ by a remount, only ever seen from 设置 → 性能, so that the
    // standard tier's tree is exactly the plain GestureDetector.
    if (onLongPress == null || !AppMotion.fluid(context)) {
      return GestureDetector(behavior: widget.behavior, onLongPress: onLongPress, child: widget.child);
    }
    return GestureDetector(
      behavior: widget.behavior,
      onLongPress: _fire,
      onLongPressDown: _down,
      onLongPressCancel: _settle,
      child: AnimatedBuilder(
        animation: _press,
        child: widget.child,
        builder: (context, child) => Transform.scale(scale: 1 - _sink * _press.value, child: child),
      ),
    );
  }
}

/// A check mark drawn stroke by stroke, the size of an [Icon] where it stands.
class DrawnCheck extends StatefulWidget {
  const DrawnCheck({super.key, this.size, this.color});

  /// Default: [IconTheme]'s.
  final double? size;
  final Color? color;

  @override
  State<DrawnCheck> createState() => _DrawnCheckState();
}

class _DrawnCheckState extends State<DrawnCheck> with SingleTickerProviderStateMixin {
  static const _duration = Duration(milliseconds: 280);
  late final AnimationController _draw = AnimationController(vsync: this, duration: _duration)..forward();
  late final Animation<double> _curved = CurvedAnimation(parent: _draw, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _draw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icons = IconTheme.of(context);
    final size = widget.size ?? icons.size ?? 24;
    return CustomPaint(
      size: Size.square(size),
      painter: _CheckPainter(progress: _curved, color: widget.color ?? icons.color ?? const Color(0xFF000000)),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.progress, required this.color}) : super(repaint: progress);

  final Animation<double> progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.width / 24;
    final path = Path()
      ..moveTo(5 * unit, 12.5 * unit)
      ..lineTo(10 * unit, 17.5 * unit)
      ..lineTo(19 * unit, 7 * unit);
    final metric = path.computeMetrics().first;
    canvas.drawPath(
      metric.extractPath(0, metric.length * progress.value),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2 * unit
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.color != color || old.progress != progress;
}

/// A short text crossfading to its next [value]. On the standard tier, just [child].
class FluidTextSwap extends StatelessWidget {
  const FluidTextSwap({super.key, required this.value, required this.child});

  /// What the text says: when it changes, the old one fades out under the new.
  final String value;
  final Widget child;

  static Widget _startAligned(Widget? current, List<Widget> previous) =>
      Stack(alignment: AlignmentDirectional.centerStart, children: [...previous, ?current]);

  @override
  Widget build(BuildContext context) {
    if (!AppMotion.fluid(context)) return child;
    return AnimatedSwitcher(
      duration: AppMotion.standard,
      switchInCurve: AppMotion.std,
      switchOutCurve: AppMotion.std,
      layoutBuilder: _startAligned,
      child: KeyedSubtree(key: ValueKey<String>(value), child: child),
    );
  }
}

/// [child] fading in once as it appears: a whole conversation opening, too large to move.
/// On the standard tier, just [child].
class FluidFadeIn extends StatelessWidget {
  const FluidFadeIn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!AppMotion.fluid(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.quick,
      curve: AppMotion.std,
      builder: (context, opacity, child) => Opacity(opacity: opacity, child: child),
      child: child,
    );
  }
}

/// The number [text] stands for; a capped badge's `99+` is more than 99.
@visibleForTesting
int? rollingCountValue(String text) => text.endsWith('+')
    ? switch (int.tryParse(text.substring(0, text.length - 1))) {
        final n? => n + 1,
        null => null,
      }
    : int.tryParse(text);

/// Text that holds a number: when it changes, the digits that changed roll, up for
/// more and down for less. At rest, and on the standard tier, it is plain [Text].
class RollingCount extends StatefulWidget {
  const RollingCount(this.text, {super.key, this.style, this.textScaler});

  final String text;
  final TextStyle? style;
  final TextScaler? textScaler;

  @override
  State<RollingCount> createState() => _RollingCountState();
}

class _RollingCountState extends State<RollingCount> with SingleTickerProviderStateMixin {
  late final AnimationController _roll = AnimationController(vsync: this, duration: AppMotion.thumbCurve.duration)
    ..addStatusListener((status) {
      if (status == AnimationStatus.completed && mounted) setState(() => _from = null);
    });
  late final Animation<double> _curved = CurvedAnimation(parent: _roll, curve: AppMotion.thumbCurve);

  /// What it rolls from; null at rest.
  String? _from;
  bool _up = true;

  @override
  void didUpdateWidget(RollingCount old) {
    super.didUpdateWidget(old);
    if (old.text == widget.text || !AppMotion.fluid(context)) return;
    final before = rollingCountValue(old.text);
    final after = rollingCountValue(widget.text);
    _up = before == null || after == null || after >= before;
    _from = old.text;
    unawaited(_roll.forward(from: 0));
  }

  @override
  void dispose() {
    _roll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = widget.style;
    Widget text(String value) => Text(value, style: style, textScaler: widget.textScaler);
    final from = _from;
    if (from == null) return text(widget.text);
    // Lined up from the right, as digits are.
    final to = widget.text;
    final length = math.max(from.length, to.length);
    final oldChars = from.padLeft(length);
    final newChars = to.padLeft(length);
    final distance = (style?.fontSize ?? DefaultTextStyle.of(context).style.fontSize ?? 14) * 1.2;
    final sign = _up ? 1.0 : -1.0;
    return AnimatedBuilder(
      animation: _curved,
      builder: (context, _) {
        final t = _curved.value;
        return ClipRect(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < length; i++)
                if (oldChars[i] == newChars[i])
                  if (newChars[i] != ' ') text(newChars[i]) else const SizedBox.shrink()
                else
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      if (oldChars[i] != ' ')
                        Transform.translate(offset: Offset(0, -sign * distance * t), child: text(oldChars[i])),
                      if (newChars[i] != ' ')
                        Transform.translate(offset: Offset(0, sign * distance * (1 - t)), child: text(newChars[i])),
                    ],
                  ),
            ],
          ),
        );
      },
    );
  }
}

/// Something quietly going on: a thin quarter arc turning at one slow, even speed. No
/// growing and shrinking like Material's indicator, nothing for the eye to chase.
class QuietArc extends StatefulWidget {
  const QuietArc({super.key, this.size = 14, required this.color});

  final double size;
  final Color color;

  @override
  State<QuietArc> createState() => _QuietArcState();
}

class _QuietArcState extends State<QuietArc> with SingleTickerProviderStateMixin {
  static const _turn = Duration(milliseconds: 1100);
  late final AnimationController _spin = AnimationController(vsync: this, duration: _turn);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.reduced(context)) {
      _spin.stop();
    } else if (!_spin.isAnimating) {
      unawaited(_spin.repeat());
    }
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    child: CustomPaint(
      size: Size.square(widget.size),
      painter: _ArcPainter(turn: _spin, color: widget.color),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter({required this.turn, required this.color}) : super(repaint: turn);

  final Animation<double> turn;
  final Color color;

  static const _stroke = 1.6;
  static const _sweep = math.pi * 0.6;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(_stroke / 2);
    canvas.drawArc(
      rect,
      turn.value * 2 * math.pi - math.pi / 2,
      _sweep,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_ArcPainter old) => old.color != color || old.turn != turn;
}
