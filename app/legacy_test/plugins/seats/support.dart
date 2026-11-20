// Fixed seats for the page tests: an inventory with third-party occupants,
// a budget that says which islands may open, and a stand-in for the island
// (a WebView can't draw in a widget test).

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/plugins/seats/seat_links.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/web/web_target.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;

import '../support/fake_plugin_host.dart' show bundleJson;

const probe = 'dsh-k4-probe';
const pet = 'dsh-pet';

final probeBundle = PluginBundle.fromJson(
  bundleJson(
    probe,
    version: '0.1.0',
    title: {'zh': '岛屿探针', 'en': 'Island probe'},
    description: {'zh': '在原生界面里试一试网页插件的设置、面板和页签。', 'en': 'Tries plugin seats.'},
  ),
);
final petBundle = PluginBundle.fromJson(bundleJson(pet, version: '0.4.2', title: {'zh': '桌宠', 'en': 'Desktop pet'}));

SlotOccupant occupant(String slot, String package, String cell, {String? label}) =>
    SlotOccupant(slot: slot, package: package, cell: cell, label: label);

/// A host with the bridge (Tier B), the route guard and DSH Web.
SeatInventory seatInventory({
  Map<String, List<SlotOccupant>> occupancy = const {},
  ClientInventoryTier tier = ClientInventoryTier.bridge,
  bool routeGuard = true,
}) => SeatInventory(
  tier: tier,
  routeGuard: routeGuard,
  webReachable: true,
  packages: {
    for (final name in [probe, pet])
      name: PluginClientInfo(package: name, hasClient: true, installed: true, enabled: true, rowIds: [name]),
  },
  occupancy: tier == ClientInventoryTier.bridge ? occupancy : null,
);

/// Every occupant the page tests seat.
final fullOccupancy = <String, List<SlotOccupant>>{
  Slots.settingsSection: [occupant(Slots.settingsSection, probe, 'k4-probe', label: '岛屿探针')],
  Slots.generalItem: [occupant(Slots.generalItem, pet, 'pet-reminder', label: '桌宠提醒')],
  Slots.main: [occupant(Slots.main, probe, 'k4-panel'), occupant(Slots.main, pet, 'pet-panel')],
  Slots.panelList: [
    occupant(Slots.panelList, probe, 'k4-panel', label: '探针面板'),
    occupant(Slots.panelList, pet, 'pet-panel', label: '桌宠面板'),
  ],
  Slots.rightPaneTab: [occupant(Slots.rightPaneTab, probe, 'k4-tab')],
  Slots.rightPaneTabTitle: [occupant(Slots.rightPaneTabTitle, probe, 'k4-tab', label: '探针页签')],
  Slots.cordisView: [occupant(Slots.cordisView, 'clock-a1b2', 'clock-a1b2')],
};

/// Islands for everything but [webOnly]'s packages.
class PickyBudget implements IslandBudget {
  const PickyBudget({this.webOnly = const {}});
  final Set<String> webOnly;

  @override
  bool canOpen(IslandSpec spec) => spec.package == null || !webOnly.contains(spec.package);
}

class FixedHost extends ActiveHostController {
  FixedHost(this.host);
  final HostRef host;

  @override
  HostRef build() => host;
}

class FixedInstalled extends InstalledPluginsController {
  FixedInstalled(this.bundles);
  final List<PluginBundle>? bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;
}

class NoEngineSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

/// Where the seats tried to open DSH Web.
final openedWeb = <DshWebTarget>[];

/// The real web entries; [island] stands in for the IslandView.
SeatRenderers testRenderers({SeatIslandBuilderOverride? island}) => SeatRenderers(
  island: island ?? (context, spec, items, fallback) => FakeIsland(spec: spec),
  webLink: (context, seat, item) => SeatWebLink(seat: seat, item: item),
);

typedef SeatIslandBuilderOverride = Widget Function(
  BuildContext context,
  IslandSpec spec,
  List<SeatItem> items,
  WidgetBuilder fallback,
);

/// The seat overrides every page test shares.
List<Override> seatOverrides({
  SeatInventory? inventory,
  IslandBudget budget = const PickyBudget(webOnly: {pet}),
  HostRef host = HostRef.none,
  List<PluginBundle>? bundles,
  SeatRenderers? renderers,
  bool engineSettings = true,
  SeatInventory? Function(Ref ref)? inventoryOf,
}) => [
  seatInventoryProvider.overrideWith(inventoryOf ?? (ref) => inventory),
  activeHostProvider.overrideWith(() => FixedHost(host)),
  islandBudgetProvider.overrideWithValue(budget),
  seatRenderersProvider.overrideWithValue(renderers ?? testRenderers()),
  installedPluginsProvider.overrideWith(() => FixedInstalled(bundles ?? [probeBundle, petBundle])),
  if (engineSettings) engineSettingsProvider.overrideWith(NoEngineSettings.new),
  seatWebOpenerProvider.overrideWithValue((context, ref, target) => openedWeb.add(target)),
];

/// What a plugin's page might look like once its island is up: a heading,
/// a few setting lines and a button, in the app's colours.
class FakeIsland extends StatelessWidget {
  const FakeIsland({super.key, required this.spec});

  final IslandSpec spec;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = DshColors.of(context);
    Widget line(String title, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
          Text(value, style: theme.textTheme.bodyMedium?.copyWith(color: colors.textTertiary)),
        ],
      ),
    );
    return Semantics(
      label: 'island ${spec.slot}',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('探针', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            line('提醒频率', '每小时'),
            line('安静时段', '22:00–8:00'),
            line('跟随主题', '开'),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: () {}, child: const Text('点我')),
          ],
        ),
      ),
    );
  }
}
