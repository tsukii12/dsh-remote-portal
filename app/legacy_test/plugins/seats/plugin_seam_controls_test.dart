import 'dart:convert';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/plugins/seams/seat_preferences.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seam_controls.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_seat_page.dart';
import 'package:dsh_app/ui_config/ui_config.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../shell/golden_harness.dart';
import '../../ui_config/support.dart' show FakeUiSource;
import 'support.dart';

final _occupancy = <String, List<SlotOccupant>>{
  Slots.shellOverlay: [occupant(Slots.shellOverlay, probe, 'probe-overlay'), occupant(Slots.shellOverlay, pet, 'pet')],
  Slots.sidebarFooter: [occupant(Slots.sidebarFooter, probe, 'footer')],
  Slots.settingsPluginsTab: [occupant(Slots.settingsPluginsTab, probe, 'settings')],
  Slots.pluginDetailSection: [occupant(Slots.pluginDetailSection, probe, 'detail')],
};

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  SeatInventory? inventory,
  IslandBudget budget = const OpenIslandBudget(),
  UiConfigSource? source,
}) async {
  await tester.pumpWidget(
    goldenApp(
      home: const Scaffold(
        body: SingleChildScrollView(child: PluginSeamControls(package: probe)),
      ),
      brightness: Brightness.light,
      overrides: [
        ...seatOverrides(
          inventory: inventory ?? seatInventory(occupancy: _occupancy),
          budget: budget,
        ),
        uiConfigSourceBuilderProvider.overrideWithValue((ref, host) => source),
      ],
    ),
  );
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(tester.element(find.byType(PluginSeamControls)));
}

Finder _page(String slot, String cell) => find.byKey(ValueKey('seam-page-$slot-$probe-$cell'));

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    openedWeb.clear();
  });

  testWidgets('overlay is off by default; each plugin opts in and out independently', (tester) async {
    final c = await _pump(tester);
    const request = SeatRequest(slot: Slots.shellOverlay, placement: SeatPlacement.overlay, package: probe);
    const other = SeatRequest(slot: Slots.shellOverlay, placement: SeatPlacement.overlay, package: pet);
    Switch control() => tester.widget<Switch>(find.byKey(const ValueKey('plugin-overlay-switch')));
    expect(control().value, isFalse);
    expect(c.read(seatPlanProvider(request)).visible.where((i) => i.mode == SeatMode.island), isEmpty);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(control().value, isTrue);
    expect(c.read(seatPlanProvider(request)).visible.single.mode, SeatMode.island);
    expect(c.read(seatPlanProvider(other)).visible.where((i) => i.mode == SeatMode.island), isEmpty);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(control().value, isFalse);
    expect(c.read(seatPlanProvider(request)).visible, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString(SeatPreferencesController.prefsKey)!)['local:local'][probe], isFalse);
  });

  for (final (name, inventory) in <(String, SeatInventory)>[
    ('no occupancy', seatInventory(tier: ClientInventoryTier.boot)),
    ('no matching occupants', seatInventory()),
    (
      'stale occupancy',
      SeatInventory(
        tier: ClientInventoryTier.bridge,
        packages: seatInventory().packages,
        occupancy: _occupancy,
        occupancyStale: true,
        webReachable: true,
      ),
    ),
    (
      'disabled plugin',
      SeatInventory(
        tier: ClientInventoryTier.bridge,
        packages: const {probe: PluginClientInfo(package: probe, hasClient: true, installed: true, enabled: false)},
        occupancy: _occupancy,
        webReachable: true,
      ),
    ),
  ]) {
    testWidgets('$name does not create an overlay switch or fake page entry', (tester) async {
      await _pump(tester, inventory: inventory);
      expect(find.byKey(const ValueKey('plugin-seam-controls')), findsNothing);
      expect(find.byType(Switch), findsNothing);
    });
  }

  for (final (slot, cell) in [
    (Slots.sidebarFooter, 'footer'),
    (Slots.settingsPluginsTab, 'settings'),
    (Slots.pluginDetailSection, 'detail'),
  ]) {
    testWidgets('$slot opens a whole page narrowed to its package and cell', (tester) async {
      await _pump(tester);
      await tester.tap(_page(slot, cell));
      await tester.pumpAndSettle();
      final page = tester.widget<PluginSeatPage>(find.byType(PluginSeatPage));
      expect(page.request, SeatRequest(slot: slot, placement: SeatPlacement.page, package: probe, cell: cell));
      final spec = tester.widget<FakeIsland>(find.byType(FakeIsland)).spec;
      expect((spec.slot, spec.package, spec.cell, spec.form), (slot, probe, cell, IslandForm.page));
    });
  }

  testWidgets('page entry keeps a Web fallback when no island budget is available', (tester) async {
    await _pump(tester, budget: const NoIslandBudget());
    expect(find.byKey(const ValueKey('plugin-overlay-switch')), findsNothing);
    await tester.tap(_page(Slots.settingsPluginsTab, 'settings'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginSeatPage), findsOneWidget);
    expect(find.byType(FakeIsland), findsNothing);
    expect(find.text('在网页版打开'), findsOneWidget);
    await tester.tap(find.text('在网页版打开'));
    await tester.pumpAndSettle();
    expect(openedWeb, hasLength(1));
  });

  testWidgets('ui.json wins, locks the switch and can restore the saved local choice', (tester) async {
    final source = FakeUiSource();
    final c = await _pump(tester, source: source);
    await c.read(seatPreferencesProvider.notifier).setOverlay(HostRef.none, probe, false);
    source.text(
      jsonEncode({
        'version': 1,
        'plugins': {
          'seats': {
            Slots.shellOverlay: {probe: 'island'},
          },
        },
      }),
    );
    await tester.pumpAndSettle();
    var control = tester.widget<Switch>(find.byType(Switch));
    expect(control.value, isTrue);
    expect(control.onChanged, isNull);
    final setting = UiSettingKey.seat(Slots.shellOverlay, probe);
    await tester.tap(find.byKey(ValueKey('from-ui-json-${setting.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ui-json-restore-default')));
    await tester.pumpAndSettle();
    control = tester.widget<Switch>(find.byType(Switch));
    expect(control.value, isFalse);
    expect(control.onChanged, isNotNull);
    expect(c.read(uiSettingEntryProvider(setting)), isNull);
  });
}
