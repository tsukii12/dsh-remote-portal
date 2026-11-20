import 'package:flutter/widgets.dart';

/// [AnimatedSize] that steps aside when there is nothing to animate.
///
/// With "remove animations" on, `AppMotion.of` hands out [Duration.zero];
/// a zero-length `AnimatedSize` finishes its controller synchronously inside
/// its own `performLayout`, re-dirties itself and asserts ("RenderAnimatedSize
/// was mutated in its own performLayout"). Here a zero [duration] lays the
/// child out directly, so the size simply snaps.
///
/// ```dart
/// SmoothSize(
///   duration: AppMotion.of(context, AppMotion.standard),
///   curve: AppMotion.std,
///   alignment: Alignment.bottomCenter,
///   child: banner,
/// )
/// ```
class SmoothSize extends StatelessWidget {
  const SmoothSize({
    super.key,
    required this.duration,
    this.curve = Curves.linear,
    this.alignment = Alignment.center,
    this.clipBehavior = Clip.hardEdge,
    this.child,
  });

  final Duration duration;
  final Curve curve;
  final AlignmentGeometry alignment;
  final Clip clipBehavior;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    if (duration == Duration.zero) return child ?? const SizedBox.shrink();
    return AnimatedSize(
      duration: duration,
      curve: curve,
      alignment: alignment,
      clipBehavior: clipBehavior,
      child: child,
    );
  }
}
