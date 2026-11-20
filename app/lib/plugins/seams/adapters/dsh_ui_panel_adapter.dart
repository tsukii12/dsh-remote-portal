// `dsh-ui-panel` (plugin-seams.md §4.2, native-plugins.md §3.1): a plugin's
// native panel, drawn with the plugin view renderer under the plugin's name.
// Its occupants are the inventory's `dsh-go:<id>` cells: 对话详情's 「插件」
// tab for `session.tab`, 全部功能 for `features`, and the synthetic
// `dsh-go.panel` slot. A package with one shows it instead of its web entry
// there (the planner sees to that; ui.json can still ask for the web).

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../ui/plugins/native/native_panel.dart';
import '../seat_inventory.dart';
import '../seat_models.dart';
import '../seat_planner.dart';
import '../seat_state.dart';
import '../slot_catalog.dart';

class DshUiPanelAdapter implements NativeSlotAdapter {
  const DshUiPanelAdapter();

  @override
  String get id => 'dsh-ui-panel';

  @override
  Set<String> get slots => const {Slots.dshGoPanel, Slots.rightPaneTab, Slots.main};

  /// A native panel's cell (the inventory only makes them for declared,
  /// switched-on panels).
  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => SeatInventory.nativePanelId(o.cell) != null;

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.full;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) => NativePanelSeat(seat: seat, occupant: o);
}

/// The panel behind a seat's occupant; nothing once it is gone.
class NativePanelSeat extends ConsumerWidget {
  const NativePanelSeat({super.key, required this.seat, required this.occupant});

  final SeatContext seat;
  final SlotOccupant occupant;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(seatInventoryProvider.select((i) => i?.nativePanel(occupant.package, occupant.cell)));
    if (panel == null) return const SizedBox.shrink();
    final view = NativePanelView(panel: panel, sessionId: seat.sessionId);
    // In a list page or a tab, the card keeps the page's 16 gutter.
    return Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 16), child: view);
  }
}
