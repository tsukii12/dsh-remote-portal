import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// First-appearance entrance: fades in while rising [AppMotion.rise] (8dp).
///
/// [index] staggers siblings by [AppMotion.stagger] (30ms); only the first
/// [AppMotion.staggerLimit] (8) animate, later ones are simply there.
///
/// It plays **once per list**, not every time an item is built: inside a
/// scroll view, items built more than [_window] after the first one (scrolled
/// into view later, or rebuilt by a new query) appear without animating. Outside
/// a scroll view it plays once per element.
///
/// Reduced motion shows the child at once. Semantics are always included, so
/// finders and screen readers see the child during the fade.
class FadeSlideIn extends StatefulWidget {
  const FadeSlideIn({
    super.key,
    required this.child,
    this.index = 0,
    this.delay = Duration.zero,
    this.duration = AppMotion.standard,
    this.offset = AppMotion.rise,
  });

  final Widget child;

  /// Position among siblings; drives the stagger.
  final int index;

  /// Extra delay before the stagger (e.g. wait for a page transition).
  final Duration delay;
  final Duration duration;

  /// Rise distance in logical pixels.
  final double offset;

  /// The fluid tier rises this many times further.
  static const _fluidRise = 2.5;

  /// How long after a scroll view's first entrance later items still animate.
  static const _window = Duration(milliseconds: 400);

  /// First entrance per scroll view (keyed weakly on its state).
  static final Expando<DateTime> _firstSeen = Expando('FadeSlideIn.firstSeen');

  @override
  State<FadeSlideIn> createState() => _FadeSlideInState();
}

class _FadeSlideInState extends State<FadeSlideIn> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _curve;

  /// The fluid tier: the rise on a spring of its own, from further down.
  Animation<double>? _rise;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    if (!_shouldAnimate()) return;
    final fluid = AppMotion.fluid(context);
    final lead = widget.delay + AppMotion.stagger * widget.index;
    final total = lead + (fluid ? AppMotion.riseCurve.duration : widget.duration);
    final controller = AnimationController(vsync: this, duration: total);
    final start = total.inMicroseconds == 0 ? 0.0 : lead.inMicroseconds / total.inMicroseconds;
    _controller = controller;
    _curve = CurvedAnimation(
      parent: controller,
      curve: Interval(
        start,
        fluid ? (lead + widget.duration).inMicroseconds / total.inMicroseconds : 1,
        curve: AppMotion.enter,
      ),
    );
    if (fluid) {
      _rise = CurvedAnimation(
        parent: controller,
        curve: Interval(start, 1, curve: AppMotion.riseCurve),
      );
    }
    controller.forward();
  }

  bool _shouldAnimate() {
    if (AppMotion.reduced(context)) return false;
    if (widget.index >= AppMotion.staggerLimit) return false;
    final scrollable = Scrollable.maybeOf(context);
    if (scrollable == null) return true;
    final now = DateTime.now();
    final first = FadeSlideIn._firstSeen[scrollable];
    if (first == null) {
      FadeSlideIn._firstSeen[scrollable] = now;
      return true;
    }
    return now.difference(first) <= FadeSlideIn._window;
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curve = _curve;
    if (curve == null) return widget.child;
    final rise = _rise;
    return AnimatedBuilder(
      animation: rise ?? curve,
      builder: (context, child) => Transform.translate(
        offset: rise == null
            ? Offset(0, widget.offset * (1 - curve.value))
            : Offset(0, widget.offset * FadeSlideIn._fluidRise * (1 - rise.value)),
        child: Opacity(opacity: curve.value, alwaysIncludeSemantics: true, child: child),
      ),
      child: widget.child,
    );
  }
}

/// A column whose children enter one after another ([FadeSlideIn] with their
/// index). For a `ListView` / `SliverList`, use [FadeInList.wrap] on the
/// children instead.
class FadeInList extends StatelessWidget {
  const FadeInList({
    super.key,
    required this.children,
    this.delay = Duration.zero,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.spacing = 0,
  });

  final List<Widget> children;
  final Duration delay;
  final CrossAxisAlignment crossAxisAlignment;
  final double spacing;

  /// Wraps each child in a [FadeSlideIn] with its index.
  static List<Widget> wrap(List<Widget> children, {Duration delay = Duration.zero}) => [
    for (final (i, child) in children.indexed) FadeSlideIn(index: i, delay: delay, child: child),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      spacing: spacing,
      children: wrap(children, delay: delay),
    );
  }
}
