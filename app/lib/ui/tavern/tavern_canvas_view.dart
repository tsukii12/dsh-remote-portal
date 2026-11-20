
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/l10n.dart';
import '../../tavern/tavern_canvas.dart';
import '../../tavern/tavern_canvas_calls.dart';

typedef TavernCanvasBuilder = Widget Function({
  required List<TavernCanvasEntry> entries,
  required ValueListenable<(String, String)?> streaming,
  required void Function(String nodeId) onMenu,
  TavernCanvasCalls? calls,
});
final tavernCanvasLibrariesProvider = FutureProvider<List<String>>((ref) async => const []);
final tavernCanvasBuilderProvider = Provider<TavernCanvasBuilder>(
  (ref) => ({required entries, required streaming, required onMenu, calls}) =>
    TavernCanvasView(entries: entries, streaming: streaming, onMenu: onMenu, calls: calls));
class TavernCanvasView extends StatelessWidget {
  const TavernCanvasView({super.key, required this.entries, required this.streaming,
    required this.onMenu, this.calls});
  final List<TavernCanvasEntry> entries;
  final ValueListenable<(String, String)?> streaming;
  final void Function(String nodeId) onMenu;
  final TavernCanvasCalls? calls;
  @override
  Widget build(BuildContext context) => Center(child: Text(context.l10n.portalWebRemoved));
}
