// Original W3-26 six counterexamples, promoted to required ADD6 b27 regressions.
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:flutter_test/flutter_test.dart';

import 'wave7_schema_routing_boundaries_test.dart' as fixture;

void main() {
  for (final key in fixture.unsupported) {
    test('real unsupported object leaf $key does not claim native routing', () {
      final settings = fixture.settingsFor({
        fixture.primary: [key],
      });
      final plan = fixture.planFor(settings, Slots.bundleConfig, SeatPlacement.page);
      expect(
        plan.single.mode,
        SeatMode.island,
        reason: 'this namespace has only a web fallback leaf and no actual native controls',
      );
    });
  }

  for (final slot in [Slots.bundleConfig, Slots.settingsSection]) {
    test('mixed namespace occupant retains access to unsupported sibling at $slot', () {
      final settings = fixture.settingsFor({
        fixture.primary: ['paragraph'],
        fixture.secondary: ['@callable'],
      });
      final inventory = fixture.inventoryFor(settings);
      expect(inventory.infoOf(fixture.package).rowIds, [fixture.primary, fixture.secondary]);
      expect(inventory.infoOf(fixture.package).configNamespaces, [fixture.primary]);
      // Row-level access proves the second namespace is a web-capable occupant.
      expect(
        fixture.planFor(settings, Slots.rowConfig, SeatPlacement.page, ns: fixture.secondary).single.mode,
        SeatMode.island,
      );
      final plan = fixture.planFor(settings, slot, SeatPlacement.page);
      expect(plan.where((item) => item.mode == SeatMode.native), hasLength(1));
      expect(
        plan.any((item) => item.mode == SeatMode.island || item.mode == SeatMode.webLink),
        isTrue,
        reason: 'bundle native coverage must not silently swallow the unsupported sibling namespace',
      );
    });
  }
}
