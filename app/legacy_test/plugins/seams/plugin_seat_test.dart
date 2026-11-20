import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';

class _Host extends ActiveHostController {
  _Host(this.host);
  final HostRef host;

  @override
  HostRef build() => host;
}

class _Installed extends InstalledPluginsController {
  _Installed(this.bundles);
  final List<PluginBundle>? bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;
}

class _NoSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

/// Draws its occupants as text.
class _TextAdapter implements NativeSlotAdapter {
  const _TextAdapter(this.packages);
  final Set<String> packages;

  @override
  String get id => 'text';

  @override
  Set<String> get slots => const {Slots.settingsSection, Slots.inputDock};

  @override
  bool canRender(SlotOccupant o, PluginClientInfo info) => packages.contains(o.package);

  @override
  NativeCoverage coverage(SlotOccupant o) => NativeCoverage.full;

  @override
  Widget build(BuildContext context, SeatContext seat, SlotOccupant o) => Text('native ${o.package}');
}

SeatInventory _inventory(Map<String, List<SlotOccupant>> occupancy) =>
    SeatInventory(tier: ClientInventoryTier.bridge, occupancy: occupancy, webReachable: true);

SlotOccupant _o(String slot, String package, String cell) => SlotOccupant(slot: slot, package: package, cell: cell);

final _renderers = SeatRenderers(
  island: (context, spec, items, fallback) => Text('island ${spec.form.name} ${items.length}'),
  webLink: (context, seat, item) => Text('web ${item.occupant.package}'),
);

Future<void> _pump(
  WidgetTester tester,
  Widget seat, {
  SeatInventory? inventory,
  HostRef host = const HostRef.portal('box'),
  IslandBudget budget = const OpenIslandBudget(),
  SeatRenderers renderers = const SeatRenderers(),
  SeatOverrides overrides = SeatOverrides.none,
  Set<String> native = const {},
}) async {
  final List<Override> overrides0 = [
    seatInventoryProvider.overrideWith((ref) => inventory),
    activeHostProvider.overrideWith(() => _Host(host)),
    islandBudgetProvider.overrideWithValue(budget),
    seatRenderersProvider.overrideWithValue(renderers),
    seatOverridesProvider.overrideWithValue(overrides),
    slotAdapterRegistryProvider.overrideWithValue(SlotAdapterRegistry([_TextAdapter(native)])),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides0,
      child: MaterialApp(
        home: Scaffold(body: Column(children: [seat, const Text('below')])),
      ),
    ),
  );
}

void main() {
  const section = PluginSeat(slot: Slots.settingsSection, placement: SeatPlacement.page);

  testWidgets('nothing at all without an inventory or a third-party occupant', (tester) async {
    await _pump(tester, section, renderers: _renderers);
    expect(tester.getSize(find.byType(PluginSeat)), Size.zero);
    await _pump(
      tester,
      section,
      renderers: _renderers,
      inventory: _inventory({
        Slots.settingsSection: [
          const SlotOccupant(
            slot: Slots.settingsSection,
            package: '@deepseek-ai/dsh-client-ui-settings-general',
            cell: 'general',
            official: true,
          ),
        ],
      }),
    );
    expect(tester.getSize(find.byType(PluginSeat)), Size.zero);
    expect(find.text('below'), findsOneWidget);
  });

  testWidgets('native first, then island, in plan order', (tester) async {
    await _pump(
      tester,
      section,
      renderers: _renderers,
      native: {'dsh-pet'},
      inventory: _inventory({
        Slots.settingsSection: [
          _o(Slots.settingsSection, 'dsh-pet', 'pet'),
          _o(Slots.settingsSection, 'dsh-cost-meter', 'cost'),
        ],
      }),
    );
    expect(find.text('native dsh-pet'), findsOneWidget);
    expect(find.text('island page 1'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('native dsh-pet')).dy,
      lessThan(tester.getTopLeft(find.text('island page 1')).dy),
    );
  });

  testWidgets('a panel island is drawn once for every occupant it shows', (tester) async {
    await _pump(
      tester,
      const PluginSeat(slot: Slots.inputDock, placement: SeatPlacement.panel, sessionId: 's1'),
      renderers: _renderers,
      inventory: _inventory({
        Slots.inputDock: [_o(Slots.inputDock, 'cost', 'cost'), _o(Slots.inputDock, 'mood', 'mood')],
      }),
    );
    expect(find.text('island panel 2'), findsOneWidget);
  });

  testWidgets('no islands: web entries; no island view yet: its fallback', (tester) async {
    final inventory = _inventory({
      Slots.settingsSection: [_o(Slots.settingsSection, 'dsh-cost-meter', 'cost')],
    });
    await _pump(tester, section, renderers: _renderers, inventory: inventory, budget: const NoIslandBudget());
    expect(find.text('web dsh-cost-meter'), findsOneWidget);
    await _pump(
      tester,
      section,
      renderers: SeatRenderers(webLink: _renderers.webLink),
      inventory: inventory,
    );
    expect(find.text('web dsh-cost-meter'), findsOneWidget);
    // Nothing wired at all: the seat stays empty.
    await _pump(tester, section, inventory: inventory);
    expect(find.textContaining('dsh-cost-meter'), findsNothing);
  });

  testWidgets('narrowed to a package; hidden by ui.json', (tester) async {
    final inventory = _inventory({
      Slots.settingsSection: [
        _o(Slots.settingsSection, 'dsh-pet', 'pet'),
        _o(Slots.settingsSection, 'dsh-cost-meter', 'cost'),
      ],
    });
    await _pump(
      tester,
      const PluginSeat(slot: Slots.settingsSection, placement: SeatPlacement.row, package: 'dsh-pet'),
      renderers: _renderers,
      inventory: inventory,
    );
    expect(find.text('web dsh-pet'), findsOneWidget);
    expect(find.text('web dsh-cost-meter'), findsNothing);
    await _pump(
      tester,
      section,
      renderers: _renderers,
      inventory: inventory,
      budget: const NoIslandBudget(),
      overrides: const SeatOverrides({
        Slots.settingsSection: {'dsh-pet': SeatOverride.hidden},
      }),
    );
    expect(find.text('web dsh-pet'), findsNothing);
    expect(find.text('web dsh-cost-meter'), findsOneWidget);
  });

  testWidgets('the local engine without the route guard gets no island', (tester) async {
    await _pump(
      tester,
      section,
      host: HostRef.none,
      renderers: _renderers,
      inventory: _inventory({
        Slots.settingsSection: [_o(Slots.settingsSection, 'dsh-cost-meter', 'cost')],
      }),
    );
    expect(find.text('web dsh-cost-meter'), findsOneWidget);
    expect(find.textContaining('island'), findsNothing);
  });

  group('seatInventoryProvider', () {
    final bundles = [
      PluginBundle.fromJson({
        'name': 'dsh-pet',
        'enabled': true,
        'installed': true,
        'rows': [
          {'rowId': 'pet', 'moduleName': 'dsh-pet'},
        ],
      }),
    ];
    final boot = WebBootGraph.fromJson({
      'rev': 'g1',
      'entries': [
        {'id': 'dsh-pet', 'rev': 'p1'},
      ],
    });

    ProviderContainer container({required DshClient? client, List<PluginBundle>? installed, BridgeInventory? bridge}) {
      final c = ProviderContainer(
        overrides: [
          activeConnectionProvider.overrideWithValue(
            AsyncData(client == null ? null : HostConnection(hostId: '', client: client, label: '电脑 · SSH', isLocal: false)),
          ),
          installedPluginsProvider.overrideWith(() => _Installed(installed)),
          webBootProvider.overrideWith((ref) async => boot),
          bridgeInventoryProvider.overrideWith((ref) async => bridge),
          engineSettingsProvider.overrideWith(_NoSettings.new),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    Future<SeatInventory?> read(ProviderContainer c) async {
      c.listen(seatInventoryProvider, (_, _) {});
      await c.read(installedPluginsProvider.future);
      await c.read(webBootProvider.future);
      await c.read(bridgeInventoryProvider.future);
      await c.read(engineSettingsProvider.future);
      return c.read(seatInventoryProvider);
    }

    test('null while not connected or before the bundle list', () async {
      expect(await read(container(client: null, installed: bundles)), isNull);
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
      addTearDown(client.close);
      expect(await read(container(client: client, installed: null)), isNull);
    });

    test('combines the bundle list, boot graph and bridge of the active host', () async {
      final client = DshClient(DshConnection(Uri.parse('http://127.0.0.1:9')));
      addTearDown(client.close);
      var inventory = (await read(container(client: client, installed: bundles)))!;
      expect(inventory.tier, ClientInventoryTier.boot);
      expect(inventory.webReachable, isTrue);
      expect(inventory.infoOf('dsh-pet').hasClient, isTrue);
      expect(inventory.occupantsFor(Slots.bundleConfig).single.inferred, isTrue);

      final bridge = BridgeInventory.fromJson({
        'bootRev': 'g1',
        'routeGuard': true,
        'slots': {
          Slots.settingsSection: [
            {'package': 'dsh-pet', 'cell': 'pet', 'label': '桌宠'},
          ],
        },
      });
      inventory = (await read(container(client: client, installed: bundles, bridge: bridge)))!;
      expect(inventory.tier, ClientInventoryTier.bridge);
      expect(inventory.routeGuard, isTrue);
      expect(inventory.needsProbe, isFalse);
      expect(inventory.occupantsFor(Slots.settingsSection).single.label, '桌宠');
    });
  });
}
