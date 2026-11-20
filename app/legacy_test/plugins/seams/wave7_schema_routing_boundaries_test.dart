// Additional 2055976 routing boundaries, using the checked-in real
// @deepseek-ai/schemastery 3.18.5 factory serialization (not invented types).
// The fixture provenance/generator is documented in the form catalog package.
// ignore_for_file: depend_on_referenced_packages
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/plugin_config/plugin_config_state.dart' show PluginConfigScope, pluginConfigScopeProvider;
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../engine_settings/support.dart' show pumpPage, settle;
import '../../shell/golden_harness.dart' show FakeSettings;

const package = 'dsh-wave7-routing-boundaries';
const primary = 'wave7-native';
const secondary = 'wave7-unsupported';
const unsupported = ['callable', 'instance', 'impossible', 'binary'];

Object factorySchema(List<String> keys) {
  final schema =
      jsonDecode(File('test/engine_settings/fixtures/schemastery-form-catalog.json').readAsStringSync()) as Map;
  final root = (schema['refs'] as Map)['${schema['uid']}'] as Map;
  final fields = root['dict'] as Map;
  if (keys.length == 1 && keys.single.startsWith('@')) {
    schema['uid'] = fields[keys.single.substring(1)];
  } else {
    root['dict'] = {for (final key in keys) key: fields[key]};
  }
  return schema;
}

EngineSettings settingsFor(Map<String, List<String>> selection) => EngineSettings(
  namespaces: SettingsDescription.fromJson({
    'namespaces': [
      for (final entry in selection.entries)
        {
          'ns': entry.key,
          'autoGenerate': true,
          'schema': factorySchema(entry.value),
          'value': {'paragraph': 'First line\n第二行', 'opacity': .5},
          'base': {'paragraph': 'First line\n第二行', 'opacity': .5},
          'user': {},
          'revision': 0,
        },
    ],
  }).namespaces,
);

PluginBundle bundleFor(EngineSettings settings) => PluginBundle.fromJson({
  'name': package,
  'enabled': true,
  'installed': true,
  'source': '$package@1.0.0',
  'rows': [
    for (final ns in settings.namespaces.keys) {'rowId': ns, 'moduleName': package},
  ],
});

SeatInventory inventoryFor(EngineSettings settings) => SeatInventory.from(
  ClientInventory.combine(
    bundles: [bundleFor(settings)],
    boot: WebBootGraph.fromJson({
      'rev': 'factory-boundaries',
      'entries': [
        {'id': package, 'rev': '1'},
      ],
    }),
  ),
  namespaces: settings.namespaces,
  webReachable: true,
);

SlotOccupant occupantFor(String slot, {String ns = primary}) =>
    SlotOccupant(slot: slot, package: package, cell: slot == Slots.rowConfig ? '$package#$ns' : package);

List<SeatItem> planFor(
  EngineSettings settings,
  String slot,
  SeatPlacement placement, {
  String ns = primary,
  bool islands = true,
  bool reachable = true,
}) => SlotAdapterRegistry.standard().plan(
  slot,
  [occupantFor(slot, ns: ns)],
  SeatContext(host: const HostRef.portal('factory-host'), placement: placement, webAvailable: reachable),
  inventory: inventoryFor(settings),
  budget: islands ? const OpenIslandBudget() : const NoIslandBudget(),
  overrides: SeatOverrides.none,
);

class _Settings extends EngineSettingsController {
  _Settings(this.settings);
  final EngineSettings settings;
  @override
  Future<EngineSettings?> build() async => settings;
}

class _Installed extends InstalledPluginsController {
  _Installed(this.settings);
  final EngineSettings settings;
  @override
  Future<List<PluginBundle>?> build() async => [bundleFor(settings)];
}

void main() {
  for (final slot in [Slots.settingsSection, Slots.bundleConfig, Slots.rowConfig]) {
    test('real unsupported factory root keeps page island and row web at $slot', () {
      final settings = settingsFor({
        primary: ['@callable'],
      });
      expect(hasFormFields(settings[primary]!), isFalse);
      expect(inventoryFor(settings).infoOf(package).configNamespaces, isEmpty);
      expect(planFor(settings, slot, SeatPlacement.page).single.mode, SeatMode.island);
      expect(planFor(settings, slot, SeatPlacement.row).single.mode, SeatMode.webLink);
      expect(planFor(settings, slot, SeatPlacement.page, islands: false).single.mode, SeatMode.webLink);
      expect(planFor(settings, slot, SeatPlacement.page, reachable: false).single.mode, SeatMode.hidden);
    });
    test('mixed real schema retains native placement at $slot', () {
      final settings = settingsFor({
        primary: ['paragraph', ...unsupported],
      });
      expect(hasFormFields(settings[primary]!), isTrue);
      for (final placement in [SeatPlacement.page, SeatPlacement.row]) {
        final plan = planFor(settings, slot, placement);
        expect(plan, hasLength(1));
        expect(plan.single.mode, SeatMode.native);
        expect(plan.single.adapter, isA<SchemaConfigAdapter>());
      }
    });
  }

  test('row config cannot borrow a sibling namespace or a missing row', () {
    final settings = settingsFor({
      primary: ['paragraph'],
      secondary: ['@callable'],
    });
    expect(inventoryFor(settings).infoOf(package).configNamespaces, [primary]);
    expect(planFor(settings, Slots.rowConfig, SeatPlacement.page).single.mode, SeatMode.native);
    for (final ns in [secondary, 'missing-row']) {
      expect(planFor(settings, Slots.rowConfig, SeatPlacement.page, ns: ns).single.mode, SeatMode.island);
      expect(planFor(settings, Slots.rowConfig, SeatPlacement.row, ns: ns).single.mode, SeatMode.webLink);
    }
  });

  // Same serialized roles through the generic engine page, inline plugin
  // seat, and row-to-page navigation. No changes to owner field/sheet UI.
  for (final role in ['paragraph', 'opacity']) {
    for (final entry in ['engine', 'inline-seat', 'row-seat']) {
      testWidgets('real $role role plus local unsupported item through $entry', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final settings = settingsFor({
          primary: [role, 'callable'],
        });
        final seat = SchemaConfigSeat(
          occupant: occupantFor(Slots.rowConfig),
          placement: entry == 'row-seat' ? SeatPlacement.row : SeatPlacement.page,
        );
        await pumpPage(
          tester,
          entry == 'engine'
              ? const EngineSettingsPage(ns: primary)
              : Scaffold(body: SingleChildScrollView(child: seat)),
          overrides: [
            activeConnectionProvider.overrideWithValue(const AsyncData(null)),
            settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
            installedPluginsProvider.overrideWith(() => _Installed(settings)),
            // No connection here, so no plugin list the Host confirmed: the
            // routing under test takes the bundle as the confirmed one.
            pluginConfigScopeProvider.overrideWithValue(PluginConfigScope.of([bundleFor(settings)])),
            engineSettingsProvider.overrideWith(() => _Settings(settings)),
            seatInventoryProvider.overrideWith((ref) => inventoryFor(settings)),
          ],
        );
        // pumpPage sets its default 390dp viewport; enforce the narrow seam after mounting.
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 900);
        await settle(tester);
        expect(tester.view.physicalSize.width / tester.view.devicePixelRatio, 320);
        if (entry == 'row-seat') {
          expect(find.text('设置'), findsOneWidget);
          await tester.tap(find.text('设置'));
          await settle(tester);
        }
        expect(find.text('在网页版编辑此项'), findsOneWidget);
        final field = find.byKey(ValueKey('$primary\u0000$role'));
        expect(field, findsOneWidget);
        await tester.ensureVisible(field);
        await tester.tap(field);
        await settle(tester);
        if (role == 'paragraph') {
          final text = tester.widget<TextField>(find.byType(TextField).first);
          expect(text.maxLines, greaterThan(1));
          expect(text.keyboardType, TextInputType.multiline);
          expect(text.controller!.text, isEmpty);
          expect(text.decoration!.hintText, 'First line\n第二行');
        } else {
          expect(find.byType(Slider), findsOneWidget);
          expect(tester.widget<Slider>(find.byType(Slider)).value, .5);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
