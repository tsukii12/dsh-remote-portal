
import 'package:flutter/widgets.dart';

const deepSeekBlue = Color(0xFF4D6BFE);
const deepSeekBlueDark = Color(0xFF7A98FB);
Color whaleColorFor(Brightness brightness) => brightness == Brightness.dark ? deepSeekBlueDark : deepSeekBlue;

class WhaleTail extends StatefulWidget {
  const WhaleTail({super.key, this.level = 1, required this.color, this.height = 20, this.still = false});
  final int level;
  final Color color;
  final double height;
  final bool still;
  @override
  State<WhaleTail> createState() => WhaleTailState();
}
class WhaleTailState extends State<WhaleTail> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _update();
  }
  @override
  void didUpdateWidget(WhaleTail oldWidget) {
    super.didUpdateWidget(oldWidget);
    _update();
  }
  void _update() {
    if (widget.still || MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }
  @override
  void dispose() { _pulse.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _pulse.drive(Tween(begin: 0.55, end: 1.0)),
    child: ClipRRect(borderRadius: BorderRadius.circular(widget.height * 0.22),
      child: Image.asset('assets/yuremote/logo.png', width: widget.height, height: widget.height,
        excludeFromSemantics: true)),
  );
}
