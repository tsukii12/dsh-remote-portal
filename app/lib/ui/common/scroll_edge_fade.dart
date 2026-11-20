// Soft edges on a sheet's scrolling body: an edge fades only while there is
// more to scroll past it, so content at rest is never dimmed.

import 'package:flutter/material.dart';

class ScrollEdgeFade extends StatefulWidget {
  const ScrollEdgeFade({super.key, required this.child});

  final Widget child;

  /// How deep an edge fades once there is that much more past it.
  static const extent = 12.0;

  @override
  State<ScrollEdgeFade> createState() => _ScrollEdgeFadeState();
}

class _ScrollEdgeFadeState extends State<ScrollEdgeFade> {
  double _top = 0;
  double _bottom = 0;

  bool _onScroll(ScrollMetrics metrics, int depth) {
    if (depth != 0 || metrics.axis != Axis.vertical) return false;
    final top = metrics.extentBefore.clamp(0.0, ScrollEdgeFade.extent);
    final bottom = metrics.extentAfter.clamp(0.0, ScrollEdgeFade.extent);
    if (top != _top || bottom != _bottom) {
      setState(() {
        _top = top;
        _bottom = bottom;
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => NotificationListener<ScrollMetricsNotification>(
    onNotification: (n) => _onScroll(n.metrics, n.depth),
    child: NotificationListener<ScrollNotification>(
      onNotification: (n) => _onScroll(n.metrics, n.depth),
      // Always in the tree: the child keeps its state as the edges change.
      child: ShaderMask(
        blendMode: BlendMode.dstIn,
        shaderCallback: (rect) {
          final h = rect.height <= 0 ? 1.0 : rect.height;
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _top > 0 ? const Color(0x00000000) : const Color(0xFF000000),
              const Color(0xFF000000),
              const Color(0xFF000000),
              _bottom > 0 ? const Color(0x00000000) : const Color(0xFF000000),
            ],
            stops: [0, (_top / h).clamp(0.0, 0.5), 1 - (_bottom / h).clamp(0.0, 0.5), 1],
          ).createShader(rect);
        },
        child: widget.child,
      ),
    ),
  );
}
