import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/plugins/config/plugin_config_page.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/schema_collapsed_groups.dart' show SchemaCollapsedGroup;
import 'package:dsh_app/ui/engine_settings/schema_form.dart';
import 'package:dsh_app/ui/plugins/plugin_inventory_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/form_catalog_scenarios.dart';
import '../engine_settings/support.dart';
import '../shell/golden_harness.dart' show goldenApp;
import '../support/semantics_tap_check.dart';

// Public market metadata, trimmed without rewriting titles/descriptions. The
// metadata failure below is deliberate fault injection, not a real package fault.
final entries = (jsonDecode(File('test/plugins/fixtures/wave7-voice-market.json').readAsStringSync()) as List)
    .cast<Map<String, dynamic>>();
const metadataFailure =
    'Could not read package metadata: connection closed while resolving package information. '
    '获取插件说明失败，请重试。';

void main() {
  for (final brightness in Brightness.values) {
    for (final scale in [1.3, 2.0]) {
      for (final entry in entries) {
        testWidgets('inventory ${entry['name']} ${brightness.name} $scale semantics and detail reachability', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(320, 900);
          tester.platformDispatcher.textScaleFactorTestValue = scale;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          final semantics = tester.ensureSemantics();
          final hasSchema = entry['name'] == 'dsh-ears';
          final host = FakeSettingsHost(
            describe: {
              'namespaces': [
                if (hasSchema)
                  {'ns': 'ears', 'schema': catalogFixture('dsh-ears-0.4.3'), 'base': {}, 'value': {}, 'revision': 0},
              ],
            },
          );
          // Installed from the market: its row is a plugin's.
          if (hasSchema) {
            host.bundles = [
              {
                'name': 'dsh-ears',
                'enabled': true,
                'installed': true,
                'source': 'dsh-ears@0.4.3',
                'rows': [
                  {'rowId': 'ears', 'moduleName': 'dsh-ears'},
                ],
              },
            ];
          }
          final item = InventoryItem(
            entryId: hasSchema ? 'include:ears' : 'include:xiaomi',
            moduleName: entry['name'] as String,
            title: entry['title'] as String,
            description: entry['description'] as String,
            version: (entry['versions'] as List).first['version'] as String,
            status: InventoryStatus.values.first,
            metaError: metadataFailure,
          );
          await tester.pumpWidget(
            goldenApp(
              brightness: brightness,
              overrides: engineOverrides(DshClient.withCarrier(host)),
              home: Scaffold(
                body: ListView(children: [InventoryRow(item: item)]),
              ),
            ),
          );
          await flush(tester);
          final row = tester.getSemantics(find.byType(InventoryRow)).getSemanticsData();
          expect(row.label, contains(item.title));
          expect(row.flagsCollection.isButton, isTrue);
          expect(row.hasAction(ui.SemanticsAction.tap), isTrue);
          expect(tester.getSize(find.byType(InventoryRow)).height, greaterThanOrEqualTo(48));
          await tester.tap(find.byType(InventoryRow));
          await flush(tester);
          expect(
            MediaQuery.textScalerOf(tester.element(find.byType(InventorySheet))).scale(10),
            closeTo(scale * 10, .01),
          );
          expect(
            find.descendant(of: find.byType(InventorySheet), matching: find.text(item.description!)),
            findsOneWidget,
          );
          final details = find.descendant(of: find.byType(InventorySheet), matching: find.byType(Scrollable));
          await tester.scrollUntilVisible(find.textContaining(metadataFailure), 200, scrollable: details.first);
          expect(find.textContaining(metadataFailure).hitTestable(), findsOneWidget);
          expectAllButtonsTappable();
          if (hasSchema) {
            await tester.scrollUntilVisible(find.text(appL10n.commonSettings), 200, scrollable: details.first);
            await tester.tap(find.text(appL10n.commonSettings));
            await flush(tester);
            expect(find.byType(PluginConfigPage), findsOneWidget);
            // Main's collapse groups are cards whose first row is the header.
            await tester.tap(find.byType(SchemaCollapsedGroup).first);
            await settle(tester);
            final displayName = find.byWidgetPredicate(
              (w) => w is SchemaFieldTile && w.spec.path.last == 'displayName',
            );
            await tester.ensureVisible(displayName);
            // The scroll lands on the next frame (the page opens with a search).
            await tester.pump();
            await tester.tap(displayName);
            await settle(tester);
            host.beforeMutate = (_) => throw const DshRemoteException('settings/rejected', 'injected failure');
            await tester.enterText(find.byKey(const ValueKey('text-input')), 'Voice preference');
            await tester.tap(find.text(appL10n.commonDone));
            await flush(tester);
            expect(find.byType(TextFieldSheet), findsOneWidget);
            expect(find.text(appL10n.commonSaveFailed), findsWidgets);
            expect(
              tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).controller!.text,
              'Voice preference',
            );
            expectAllButtonsTappable();
            host.beforeMutate = null;
            await tester.tap(find.text(appL10n.commonDone));
            await flush(tester);
            expect(find.byType(TextFieldSheet), findsNothing);
            expect(host.namespaces['ears']!.user['general'], {'displayName': 'Voice preference'});
          } else {
            expect(
              find.text(appL10n.commonSettings),
              findsNothing,
              reason: 'market listing alone does not invent a settings schema',
            );
          }
          semantics.dispose();
          expect(tester.takeException(), isNull);
        });
      }

      testWidgets('local web fallback has spoken label and reachable action ${brightness.name} $scale', (tester) async {
        final semantics = tester.ensureSemantics();
        await pumpCatalogScene(
          tester,
          const FormCatalogScene('callable', 'readOnly'),
          brightness: brightness,
          scale: scale,
        );
        final fallback = find.byType(SchemaUnsupportedField);
        final data = tester.getSemantics(fallback).getSemanticsData();
        expect(data.label, contains('Callable'));
        expect(data.label, contains('在网页版编辑此项'));
        expect(data.flagsCollection.isButton, isTrue);
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(tester.getSize(fallback).height, greaterThanOrEqualTo(48));
        expect(fallback.hitTestable(), findsOneWidget);
        expectAllButtonsTappable();
        expect(find.byType(Switch), findsOneWidget);
        semantics.dispose();
      });
    }
  }
}
