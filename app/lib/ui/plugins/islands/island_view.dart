
import 'package:flutter/material.dart';
import '../../../plugins/seams/seat_models.dart';

abstract final class IslandProbeMetrics {
  static const width = 360.0;
  static const height = 640.0;
}
abstract final class IslandPanelMetrics {
  static const minHeight = 72.0;
  static const maxHeight = 360.0;
}
class IslandView extends StatelessWidget {
  const IslandView({super.key, required this.spec, required this.fallback,
    this.labels = const [], this.panelMaxHeight = IslandPanelMetrics.maxHeight,
    this.insets = EdgeInsets.zero, this.onOpenSession, this.onReady});
  final IslandSpec spec;
  final WidgetBuilder fallback;
  final List<String> labels;
  final double panelMaxHeight;
  final EdgeInsets insets;
  final Future<bool> Function(String)? onOpenSession;
  final ValueChanged<Object?>? onReady;
  @override
  Widget build(BuildContext context) => fallback(context);
}
