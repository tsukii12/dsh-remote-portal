import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/cordis_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Installed extends InstalledPluginsController {
  _Installed(this.bundles);
  final List<PluginBundle> bundles;

  @override
  Future<List<PluginBundle>?> build() async => bundles;
}

class _NoSettings extends EngineSettingsController {
  @override
  Future<EngineSettings?> build() async => null;
}

const _seat = SeatContext(host: HostRef.portal('box'), placement: SeatPlacement.row);

PluginClientInfo _info(List<String> namespaces) => PluginClientInfo(
  package: 'dsh-pet',
  hasClient: true,
  rowIds: const ['pet', 'pet-voice'],
  configNamespaces: namespaces,
);

void main() {
  group('schema-config', () {
    const adapter = SchemaConfigAdapter();

    test('serves the three config slots when describe has a drawable namespace', () {
      expect(adapter.slots, {Slots.settingsSection, Slots.bundleConfig, Slots.rowConfig});
      const section = SlotOccupant(slot: Slots.settingsSection, package: 'dsh-pet', cell: 'pet');
      expect(adapter.canRender(section, _info(['pet'])), isTrue);
      expect(adapter.canRender(section, _info([])), isFalse);
      expect(adapter.coverage(section), NativeCoverage.full);
    });

    test('a row config draws only its own row', () {
      const voice = SlotOccupant(slot: Slots.rowConfig, package: 'dsh-pet', cell: 'dsh-pet#pet-voice');
      expect(SchemaConfigAdapter.namespacesFor(voice, _info(['pet', 'pet-voice'])), ['pet-voice']);
      expect(adapter.canRender(voice, _info(['pet'])), isFalse);
      const page = SlotOccupant(slot: Slots.bundleConfig, package: 'dsh-pet', cell: 'dsh-pet');
      expect(SchemaConfigAdapter.namespacesFor(page, _info(['pet', 'pet-voice'])), ['pet', 'pet-voice']);
    });

    testWidgets('as a row: one 「设置」 row for a single namespace; the form waits for the settings', (tester) async {
      final bundle = PluginBundle.fromJson({
        'name': 'dsh-pet',
        'installed': true,
        'enabled': true,
        'meta': {'title': '桌宠'},
        'rows': [
          {'rowId': 'pet', 'moduleName': 'dsh-pet'},
        ],
      });
      Future<void> pump(SeatPlacement placement) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            seatInventoryProvider.overrideWith(
              (ref) => SeatInventory(
                packages: {
                  'dsh-pet': const PluginClientInfo(
                    package: 'dsh-pet',
                    hasClient: true,
                    rowIds: ['pet'],
                    configNamespaces: ['pet'],
                  ),
                },
              ),
            ),
            installedPluginsProvider.overrideWith(() => _Installed([bundle])),
            engineSettingsProvider.overrideWith(_NoSettings.new),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) => adapter.build(
                  context,
                  SeatContext(host: const HostRef.portal('box'), placement: placement),
                  const SlotOccupant(slot: Slots.bundleConfig, package: 'dsh-pet', cell: 'dsh-pet'),
                ),
              ),
            ),
          ),
        ),
      );
      await pump(SeatPlacement.row);
      await tester.pump();
      expect(find.text('设置'), findsOneWidget);
      await pump(SeatPlacement.page);
      await tester.pump();
      expect(find.text('设置'), findsNothing);
      expect(tester.getSize(find.byType(SchemaConfigSeat)), Size.zero);
    });
  });

  group('cordis', () {
    const adapter = CordisAdapter();
    final plugin = CordisPlugin.fromJson({
      'pluginId': 'weather',
      'agentId': 'session-1',
      'packages': [
        {'packageId': 'weather@2', 'name': '天气', 'purpose': '看天气', 'hasClientHalf': true},
      ],
    })!;

    test('always drawable, list part only', () {
      const o = SlotOccupant(slot: Slots.cordisView, package: 'weather@2', cell: 'k');
      expect(adapter.canRender(o, const PluginClientInfo.assumed('weather@2')), isTrue);
      expect(adapter.coverage(o), NativeCoverage.partial);
    });

    test('matches the plugin by plugin id or package id, as package or cell', () {
      bool m(String package, String cell) =>
          CordisAdapter.matches(plugin, SlotOccupant(slot: Slots.cordisView, package: package, cell: cell));
      expect(m('x', 'weather'), isTrue);
      expect(m('weather', 'x'), isTrue);
      expect(m('weather@2', 'x'), isTrue);
      expect(m('x', 'weather@2'), isTrue);
      expect(m('x', 'y'), isFalse);
    });

    testWidgets('draws the matching Cordis row, nothing otherwise', (tester) async {
      Future<void> pump(String package) => tester.pumpWidget(
        ProviderScope(
          overrides: [
            cordisInventoryProvider.overrideWith((ref) async => [plugin]),
          ],
          child: MaterialApp(
            theme: buildLightTheme(),
            home: Scaffold(
              body: Builder(
                builder: (context) =>
                    adapter.build(context, _seat, SlotOccupant(slot: Slots.cordisView, package: package, cell: '')),
              ),
            ),
          ),
        ),
      );
      await pump('weather@2');
      await tester.pump();
      expect(find.text('天气'), findsOneWidget);
      expect(find.text('看天气'), findsOneWidget);
      expect(find.text('未运行'), findsOneWidget);
      await pump('someone-else');
      await tester.pump();
      expect(find.text('天气'), findsNothing);
    });
  });

  group('P2 skeletons', () {
    test('dsh-ui-panel matches native panel cells only; pet matches nothing yet', () {
      // Native panels occupy `dsh-go:<id>` cells (test/plugins/native/native_panel_test.dart).
      for (final slot in [Slots.dshGoPanel, Slots.rightPaneTab, Slots.main]) {
        final native = SlotOccupant(slot: slot, package: 'dsh-cost', cell: 'dsh-go:cost');
        final web = SlotOccupant(slot: slot, package: 'dsh-cost', cell: 'cost');
        expect(const DshUiPanelAdapter().slots, contains(slot));
        expect(const DshUiPanelAdapter().canRender(native, const PluginClientInfo(package: 'dsh-cost')), isTrue);
        expect(
          const DshUiPanelAdapter().canRender(web, const PluginClientInfo(package: 'dsh-cost', panels: ['cost'])),
          isFalse,
        );
      }
      const pet = SlotOccupant(slot: Slots.shellOverlay, package: 'dsh-pet', cell: 'pet');
      expect(const PetAdapter().canRender(pet, const PluginClientInfo(package: 'dsh-pet', pet: 'codex')), isFalse);
    });
  });
}
