// Web overlays belong to the chat surface, below native drawers and routes.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/seams/seams.dart';
import '../../../state/chat_state.dart';

/// Only explicitly enabled, budgeted entries get a platform view. Web-link
/// fallbacks stay in plugin details; never paint a full-screen error card here.
class PluginOverlayLayer extends ConsumerWidget {
  const PluginOverlayLayer({super.key, this.sessionId});

  final String? sessionId;

  static const request = SeatRequest(slot: Slots.shellOverlay, placement: SeatPlacement.overlay);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = sessionId;
    if (id != null && ref.watch(chatProvider(id).select((s) => s.openApproval != null || s.questions.isNotEmpty))) {
      return const SizedBox.shrink();
    }
    final inventory = ref.watch(seatInventoryProvider);
    if (inventory == null || inventory.occupancyStale) return const SizedBox.shrink();
    final plan = ref.watch(seatPlanProvider(request));
    final render = ref.watch(seatRenderersProvider).island;
    if (render == null) return const SizedBox.shrink();
    final islands = <IslandSpec, List<SeatItem>>{};
    for (final item in plan.items) {
      if (item.mode == SeatMode.island && inventory.infoOf(item.occupant.package).enabled) {
        (islands[item.island!] ??= []).add(item);
      }
    }
    return Stack(
      fit: StackFit.expand,
      children: [
        for (final MapEntry(key: spec, value: items) in islands.entries)
          Positioned.fill(
            key: ValueKey('plugin-overlay|${spec.key}'),
            child: render(context, spec, items, (_) => const SizedBox.shrink()),
          ),
      ],
    );
  }
}
