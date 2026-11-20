// Cordis › one plugin › its interactive region (`tool.view.cordis`,
// docs/design/plugin-seams.md §3): the list stays native, the region the
// plugin draws in DSH Web shows here as a page island in a card. Nothing when
// it can't be one — the sheet's own 「在网页版打开」 sits right under it.

import 'package:dsh_client/dsh_client.dart' show CordisPlugin;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../plugins/seams/seams.dart';
import '../../theme/theme.dart';

class CordisIslandSeat extends ConsumerStatefulWidget {
  const CordisIslandSeat({super.key, required this.plugin});

  final CordisPlugin plugin;

  /// The card's height: two fifths of the window, between [minHeight] and
  /// [maxHeight] (the sheet's facts and actions keep some room).
  static const minHeight = 240.0;
  static const maxHeight = 360.0;

  /// Space between the card and what follows it.
  static const gap = 20.0;

  @override
  ConsumerState<CordisIslandSeat> createState() => _CordisIslandSeatState();
}

class _CordisIslandSeatState extends ConsumerState<CordisIslandSeat> {
  /// The island that couldn't come up: the card folds away instead of
  /// showing an empty frame.
  IslandSpec? _fallen;

  @override
  Widget build(BuildContext context) {
    final plugin = widget.plugin;
    final plan = ref.watch(
      seatPlanProvider(SeatRequest(slot: Slots.cordisView, placement: SeatPlacement.page, sessionId: plugin.agentId)),
    );
    // The native item is the list this sheet was opened from: only the
    // island of this plugin belongs here.
    final item = plan.visible
        .where((i) => i.mode == SeatMode.island && CordisAdapter.matches(plugin, i.occupant))
        .firstOrNull;
    final spec = item?.island;
    if (item == null || spec == null || spec == _fallen) return const SizedBox.shrink();

    Widget fallback(BuildContext context) {
      if (_fallen != spec) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _fallen = spec);
        });
      }
      return const SizedBox.shrink();
    }

    final island = ref.watch(seatRenderersProvider).island;
    final height = (MediaQuery.sizeOf(context).height * 0.4).clamp(
      CordisIslandSeat.minHeight,
      CordisIslandSeat.maxHeight,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: CordisIslandSeat.gap),
      child: SizedBox(
        height: height,
        child: GlassSurface(
          tier: GlassTier.card,
          borderRadius: AppShape.radiusLg,
          child: ClipRSuperellipse(
            borderRadius: AppShape.radiusLg,
            child: Builder(builder: (context) => island?.call(context, spec, [item], fallback) ?? fallback(context)),
          ),
        ),
      ),
    );
  }
}
