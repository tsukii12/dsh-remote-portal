// ADD6 routing policy on b27b1dd. Existing factory leaves are composed into
// nested objects; no new schema type/role or server protocol is introduced.
import 'package:dsh_app/plugins/seams/seams.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_app/ui/plugins/seats/plugin_settings_tiles.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../engine_settings/support.dart' show pumpPage, settle;
import '../../shell/golden_harness.dart' show FakeSettings;
import 'wave7_schema_routing_boundaries_test.dart' as fixture;

class _Settings extends EngineSettingsController {
  _Settings(this.value);
  final EngineSettings value;
  @override
  Future<EngineSettings?> build() async => value;
}

class _Installed extends InstalledPluginsController {
  _Installed(this.settings);
  final EngineSettings settings;
  @override
  Future<List<PluginBundle>?> build() async => [fixture.bundleFor(settings)];
}

EngineSettings nestedSettings({bool native = true}) {
  final schema = fixture.factorySchema(['paragraph', ...fixture.unsupported]) as Map;
  final refs = schema['refs'] as Map;
  final root = refs['${schema['uid']}'] as Map;
  final fields = Map.of(root['dict'] as Map);
  refs['1000'] = {
    'type': 'object',
    'dict': {'a': fields['callable'], 'deep': 1001},
  };
  refs['1001'] = {
    'type': 'object',
    'dict': {'b': fields['instance'], 'c': fields['impossible']},
  };
  root['dict'] = {if (native) 'paragraph': fields['paragraph'], 'unsupported': 1000};
  return EngineSettings(
    namespaces: SettingsDescription.fromJson({
      'namespaces': [
        {
          'ns': fixture.primary,
          'autoGenerate': true,
          'schema': schema,
          'value': {'paragraph': 'keep native'},
          'base': {'paragraph': 'keep native'},
          'user': {},
        },
      ],
    }).namespaces,
  );
}

SeatInventory reported(EngineSettings settings, String slot) {
  final inventory = fixture.inventoryFor(settings);
  return SeatInventory(
    packages: inventory.packages,
    webReachable: true,
    occupancy: {
      slot: [fixture.occupantFor(slot)],
    },
  );
}

void main() {
  test('a visible empty object has one fallback while hidden-only remains hidden', () {
    final empty = fixture.settingsFor({fixture.primary: []});
    final fields = schemaSections(empty[fixture.primary]!).expand((section) => section.fields).toList();
    expect(fields, hasLength(1));
    expect(fields.single.fallbackNode, isNotNull);
    expect(hasFormFields(empty[fixture.primary]!), isFalse);
    final hidden = fixture.settingsFor({fixture.primary: ['hidden']});
    expect(schemaSections(hidden[fixture.primary]!), isEmpty);
  });
  test('a wholly unsupported nested namespace collapses once at its root', () {
    final settings = nestedSettings(native: false);
    final sections = schemaSections(settings[fixture.primary]!);
    expect(sections, hasLength(1));
    expect(sections.single.fields, hasLength(1));
    expect(sections.single.fields.single.path, isEmpty);
    expect(sections.single.fields.single.fallbackNode, isNotNull);
    expect(hasFormFields(settings[fixture.primary]!), isFalse);
  });
  test('unsupported object subtree is one local fallback beside native leaves', () {
    final settings = nestedSettings();
    final fields = schemaSections(settings[fixture.primary]!).expand((s) => s.fields).toList();
    expect(fields, hasLength(2));
    expect(fields.first.path, ['paragraph']);
    expect(fields.last.path, ['unsupported']);
    expect(fields.last.fallbackNode, isNotNull);
    expect(hasFormFields(settings[fixture.primary]!), isTrue);
  });
  test('disabled factory text remains a real native control', () {
    final settings = fixture.settingsFor({
      fixture.primary: ['disabled'],
    });
    expect(hasFormFields(settings[fixture.primary]!), isTrue);
    expect(fixture.planFor(settings, Slots.bundleConfig, SeatPlacement.page).single.mode, SeatMode.native);
    expect(schemaSections(settings[fixture.primary]!).single.fields.single.fallbackNode, isNull);
  });
  test('all unsupported sibling namespaces use one occupant island instead of empty native', () {
    final settings = fixture.settingsFor({
      fixture.primary: ['callable'],
      fixture.secondary: ['@callable'],
      'third': ['binary'],
    });
    final plan = fixture.planFor(settings, Slots.bundleConfig, SeatPlacement.page);
    expect(plan, hasLength(1));
    expect(plan.single.mode, SeatMode.island);
  });
  for (final slot in [Slots.bundleConfig, Slots.settingsSection]) {
    test('every unsupported sibling gets a distinct web item at $slot', () {
      final settings = fixture.settingsFor({
        fixture.primary: ['paragraph'],
        fixture.secondary: ['@callable'],
        'third': ['binary'],
      });
      final plan = fixture.planFor(settings, slot, SeatPlacement.page);
      expect(plan.where((i) => i.mode == SeatMode.native), hasLength(1));
      expect(plan.where((i) => i.mode == SeatMode.webLink).map((i) => i.configNamespace), [fixture.secondary, 'third']);
      expect(plan.toSet(), hasLength(3));
    });
  }
  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      for (final entry in ['bundle', 'settings-hub']) {
        testWidgets('two sibling rows remain accessible at 320dp $scale $brightness $entry', (tester) async {
          final settings = fixture.settingsFor({
            fixture.primary: ['paragraph'],
            fixture.secondary: ['@callable'],
            'third': ['binary'],
          });
          final slot = entry == 'bundle' ? Slots.bundleConfig : Slots.settingsSection;
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          await pumpPage(
            tester,
            Scaffold(
              body: SingleChildScrollView(
                child: entry == 'bundle'
                    ? const PluginSeat(
                        slot: Slots.bundleConfig,
                        placement: SeatPlacement.page,
                        package: fixture.package,
                      )
                    : Consumer(builder: (context, ref, _) => Column(children: pluginSettingsTiles(ref))),
              ),
            ),
            brightness: brightness,
            overrides: [
              activeConnectionProvider.overrideWithValue(const AsyncData(null)),
              settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
              engineSettingsProvider.overrideWith(() => _Settings(settings)),
              installedPluginsProvider.overrideWith(() => _Installed(settings)),
              seatInventoryProvider.overrideWith((ref) => reported(settings, slot)),
              islandBudgetProvider.overrideWithValue(const NoIslandBudget()),
            ],
          );
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          await settle(tester);
          expect(find.byType(SchemaUnsupportedField), findsNWidgets(2));
          expect(tester.widgetList<SchemaUnsupportedField>(find.byType(SchemaUnsupportedField)).map((w) => w.ns), [
            fixture.secondary,
            'third',
          ]);
          expect(find.text('在网页版编辑此项'), findsNWidgets(2));
          for (final ns in [fixture.secondary, 'third']) {
            final row = find.byWidgetPredicate((w) => w is SchemaUnsupportedField && w.ns == ns);
            await tester.ensureVisible(row);
            expect(tester.getRect(row).height, greaterThanOrEqualTo(48));
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        });
      }
    }
  }
  testWidgets('generic engine page keeps one object fallback without expanding its children', (tester) async {
    final settings = nestedSettings();
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: fixture.primary),
      overrides: [
        activeConnectionProvider.overrideWithValue(const AsyncData(null)),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
        engineSettingsProvider.overrideWith(() => _Settings(settings)),
      ],
    );
    expect(find.byType(SchemaUnsupportedField), findsOneWidget);
    expect(find.text('在网页版编辑此项'), findsOneWidget);
    expect(find.byKey(const ValueKey('${fixture.primary}\u0000paragraph')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
