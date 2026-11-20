// The seat a native page places where plugins may show up (plugin-seams.md
// §4.1). Without a third-party occupant it renders nothing and the page is
// unchanged.

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'seat_models.dart';
import 'seat_planner.dart';
import 'seat_state.dart';

class PluginSeat extends ConsumerWidget {
  const PluginSeat({
    super.key,
    required this.slot,
    this.sessionId,
    required this.placement,
    this.package,
    this.cell,
    this.layout,
  });

  final String slot;

  /// For session / session-maybe slots.
  final String? sessionId;
  final SeatPlacement placement;

  /// Only this package's occupants (a plugin's own page).
  final String? package;

  /// Only this cell.
  final String? cell;

  /// Lays out the items; a stretched column by default.
  final Widget Function(BuildContext context, List<Widget> children)? layout;

  SeatRequest get request =>
      SeatRequest(slot: slot, placement: placement, sessionId: sessionId, package: package, cell: cell);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plan = ref.watch(seatPlanProvider(request));
    final items = plan.visible;
    if (items.isEmpty) return const SizedBox.shrink();
    final renderers = ref.watch(seatRenderersProvider);

    Widget webLink(BuildContext context, SeatItem item) =>
        renderers.webLink?.call(context, plan.seat, item) ?? const SizedBox.shrink();

    // Items sharing an island spec are one island, placed where the first sits.
    final islands = <IslandSpec, List<SeatItem>>{};
    for (final item in items) {
      if (item.island case final spec?) (islands[spec] ??= []).add(item);
    }

    final children = <Widget>[];
    for (final item in items) {
      final key = ValueKey([
        item.mode.name, item.occupant.package, item.occupant.cell, ?item.configNamespace,
      ].join('|'));
      switch (item.mode) {
        case SeatMode.native:
          children.add(KeyedSubtree(key: key, child: item.adapter!.build(context, plan.seat, item.occupant)));
        case SeatMode.island:
          final group = islands[item.island!]!;
          if (!identical(group.first, item)) continue;
          Widget fallback(BuildContext context) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [for (final i in group) webLink(context, i)],
          );
          children.add(
            KeyedSubtree(
              key: ValueKey('island|${item.island!.key}'),
              child: Builder(
                builder: (context) =>
                    renderers.island?.call(context, item.island!, group, fallback) ?? fallback(context),
              ),
            ),
          );
        case SeatMode.webLink:
          children.add(
            KeyedSubtree(
              key: key,
              child: Builder(builder: (context) => webLink(context, item)),
            ),
          );
        case SeatMode.hidden:
          break;
      }
    }
    return layout?.call(context, children) ??
        Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }
}
