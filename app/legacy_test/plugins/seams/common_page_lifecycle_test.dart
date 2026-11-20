import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../seats/support.dart';

class _Inventory extends Notifier<SeatInventory> {
  @override
  SeatInventory build() => seatInventory();
  void show(SeatInventory inventory) => state = inventory;
}

final _inventoryProvider = NotifierProvider<_Inventory, SeatInventory>(_Inventory.new);

void main() {
  for (final slot in [Slots.sidebarFooter, Slots.settingsPluginsTab, Slots.pluginDetailSection]) {
    test('open $slot stops using stale, disabled or removed package evidence', () async {
      final c = ProviderContainer(
        overrides: [
          ...seatOverrides(inventoryOf: (ref) => ref.watch(_inventoryProvider), budget: const OpenIslandBudget()),
          seatOverridesProvider.overrideWithValue(SeatOverrides.none),
        ],
      );
      addTearDown(c.dispose);
      final request = SeatRequest(slot: slot, placement: SeatPlacement.page, package: probe, cell: 'entry');
      c.listen(seatPlanProvider(request), (_, _) {});
      final occupancy = {
        slot: [occupant(slot, probe, 'entry')],
      };
      final active = seatInventory(occupancy: occupancy);
      final inventory = c.read(_inventoryProvider.notifier);
      inventory.show(active);
      expect(c.read(seatPlanProvider(request)).visible.single.mode, SeatMode.island);
      for (final unavailable in [
        SeatInventory(packages: active.packages, occupancy: occupancy, occupancyStale: true, webReachable: true),
        SeatInventory(
          packages: const {probe: PluginClientInfo(package: probe, installed: true, enabled: false)},
          occupancy: occupancy,
          webReachable: true,
        ),
        SeatInventory(occupancy: occupancy, webReachable: true),
      ]) {
        inventory.show(unavailable);
        expect(c.read(seatPlanProvider(request)).isEmpty, isTrue);
      }
      inventory.show(active);
      expect(c.read(seatPlanProvider(request)).visible.single.mode, SeatMode.island);
    });
  }
}
