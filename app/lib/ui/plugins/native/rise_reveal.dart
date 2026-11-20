// How the rows above the composer come and go — like the activity strip, they
// rise from behind the composer and sink back. The slot's height follows the
// animation (the list's bottom padding with it); the row itself is always drawn
// whole, never clipped or faded: the part still below the slot is under the
// composer's glass, which is painted after it.

import 'package:flutter/widgets.dart';

import '../../theme/motion.dart';

class RiseReveal extends StatefulWidget {
  const RiseReveal({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<RiseReveal> createState() => _RiseRevealState();
}

class _RiseRevealState extends State<RiseReveal> with SingleTickerProviderStateMixin {
  late final AnimationController _rise = AnimationController(
    vsync: this,
    duration: AppMotion.standard,
    value: widget.open ? 1 : 0,
  )..addStatusListener(_onStatus);
  late final CurvedAnimation _height = CurvedAnimation(
    parent: _rise,
    curve: AppMotion.std,
    reverseCurve: AppMotion.std.flipped,
  );

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rise.duration = AppMotion.of(context, AppMotion.standard);
  }

  @override
  void didUpdateWidget(RiseReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _rise.duration = AppMotion.of(context, AppMotion.standard);
    if (widget.open != oldWidget.open) widget.open ? _rise.forward() : _rise.reverse();
  }

  @override
  void dispose() {
    _height.dispose();
    _rise.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.open && _rise.isDismissed) return const SizedBox(width: double.infinity);
    return IgnorePointer(
      ignoring: !widget.open,
      child: AnimatedBuilder(
        animation: _height,
        builder: (context, child) => Align(alignment: Alignment.topCenter, heightFactor: _height.value, child: child),
        child: widget.child,
      ),
    );
  }
}
