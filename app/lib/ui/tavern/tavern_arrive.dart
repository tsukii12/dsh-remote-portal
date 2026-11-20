// Things that turn up in the story's chrome after the page is open — the
// director's suggestions in the capsule row, a state value's 「+5」 — fade in
// and rise a little as they come, siblings 30ms apart (docs/design/
// roleplay-ui.md §11). FadeSlideIn only plays in a list's first moments; these
// come later, whenever the engine has them.

import 'package:flutter/widgets.dart';

import '../theme/motion.dart';

/// [child] arriving: faded in and risen [AppMotion.rise] over
/// [AppMotion.standard], [index] × [AppMotion.stagger] after its first build
/// (only the first [AppMotion.staggerLimit] wait). Plays once per element: key
/// it by what it shows to play again for something new. Reduced motion shows
/// it at once.
class TavernArrive extends StatefulWidget {
  const TavernArrive({super.key, required this.child, this.index = 0});

  final Widget child;
  final int index;

  @override
  State<TavernArrive> createState() => _TavernArriveState();
}

class _TavernArriveState extends State<TavernArrive> with SingleTickerProviderStateMixin {
  AnimationController? _controller;
  Animation<double>? _shown;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller != null || AppMotion.reduced(context)) return;
    final lead = AppMotion.stagger * widget.index.clamp(0, AppMotion.staggerLimit);
    final total = lead + AppMotion.standard;
    final controller = AnimationController(vsync: this, duration: total)..forward();
    _controller = controller;
    _shown = CurvedAnimation(
      parent: controller,
      curve: Interval(lead.inMicroseconds / total.inMicroseconds, 1, curve: AppMotion.enter),
    );
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _shown;
    if (shown == null) return widget.child;
    return AnimatedBuilder(
      animation: shown,
      builder: (context, child) => Opacity(
        opacity: shown.value,
        child: Transform.translate(offset: Offset(0, (1 - shown.value) * AppMotion.rise), child: child),
      ),
      child: widget.child,
    );
  }
}
