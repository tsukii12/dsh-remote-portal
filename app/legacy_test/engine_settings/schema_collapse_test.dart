import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/common/overview_card.dart' show OverviewChevron;
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_app/ui/engine_settings/schema_collapsed_groups.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

/// The row (of any kind) a title sits in.
Finder rowOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(EngineFieldRow)).first;

/// The card a widget sits in.
Rect cardOf(WidgetTester tester, Finder child) =>
    tester.getRect(find.ancestor(of: child, matching: find.byType(GlassSurface)).first);

/// Where the centre of the chevron's ink is on screen: a fixed point of its
/// glyph, so a turned caret is measured at the same place as a still one.
Offset chevronInk(WidgetTester tester, Finder row) {
  final chevron = find.descendant(
    of: row,
    matching: find.byWidgetPredicate((w) => w is OverviewChevron || w is DisclosureChevron),
  );
  final icon = tester.renderObject<RenderBox>(find.descendant(of: chevron, matching: find.byType(Icon)));
  final size = icon.size;
  return icon.localToGlobal(Offset((DisclosureChevron.inkCentre.x + 1) / 2 * size.width, size.height / 2));
}

Object earsSchema() => jsonDecode(File('test/engine_settings/fixtures/dsh-ears-0.4.3.json').readAsStringSync());
FakeSettingsHost earsHost() => FakeSettingsHost(
  describe: {
    'namespaces': [
      {'ns': 'ears', 'schema': earsSchema(), 'value': {}, 'base': {}, 'revision': 0},
    ],
  },
);

void main() {
  test('real dsh-ears container collapse metadata survives reference decoding', () {
    final node = SchemaNode.fromJson(earsSchema());
    expect(node.meta.collapse, isFalse);
    expect(node.fields!['general']!.meta.collapse, isTrue);
    expect(node.fields!['general']!.fields!['shortcut']!.meta.collapse, isTrue);
    expect(SchemaMeta.fromJson({'collapse': false}).collapse, isFalse);
  });

  testWidgets('collapsed voice group hides descendants and nested groups open independently', (tester) async {
    final host = earsHost();
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'ears'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    final general = SchemaNode.fromJson(earsSchema()).fields!['general']!;
    final generalTitle = labelFor('general', general, const FieldCopy());
    final shortcutTitle = labelFor('shortcut', general.fields!['shortcut']!, const FieldCopy());
    expect(find.text('Display name'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    await tester.tap(find.text(generalTitle));
    await settle(tester);
    expect(
      find.byType(Switch),
      findsOneWidget,
      reason: 'general sounds is visible but shortcut switch stays collapsed',
    );
    await tester.tap(find.text(shortcutTitle));
    await settle(tester);
    expect(find.byType(Switch), findsNWidgets(2));
    await tester.tap(find.byType(Switch).first);
    await flush(tester);
    expect(host.mutates(), hasLength(1), reason: 'collapse only changes layout, not the field write path');
  });

  for (final scale in [1.0, 1.3]) {
    testWidgets('a group is a card: header on the rows\' text and chevron columns, 320 wide at $scale×', (
      tester,
    ) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'ears'),
        overrides: engineOverrides(DshClient.withCarrier(earsHost())),
      );
      tester.view.physicalSize = const Size(320 * 2, 1800 * 2);
      await tester.pump();
      final general = labelFor('general', SchemaNode.fromJson(earsSchema()).fields!['general']!, const FieldCopy());
      const plain = 'Schema version';
      final header = rowOf(general);

      expect(
        find.descendant(of: header, matching: find.text('4 项')),
        findsOneWidget,
        reason: 'its settings counted',
      );
      final card = cardOf(tester, header);
      expect((card.left, card.right), (cardOf(tester, rowOf(plain)).left, cardOf(tester, rowOf(plain)).right));
      expect(card.left, 16, reason: 'a card like the others, not a title on the page');
      final textStart = tester.getRect(find.text(plain)).left;
      expect(
        tester.getRect(find.text(general)).left,
        closeTo(textStart, 0.5),
        reason: 'header text on the rows\' text column',
      );
      expect(chevronInk(tester, header).dx, closeTo(chevronInk(tester, rowOf(plain)).dx, 0.5), reason: 'closed');

      await tester.tap(header);
      await settle(tester);
      const inside = 'Display name';
      expect(
        cardOf(tester, rowOf(inside)),
        cardOf(tester, header),
        reason: 'the fields open inside the header\'s card',
      );
      expect(tester.getRect(find.text(inside)).left, closeTo(textStart, 0.5));
      expect(tester.getRect(find.text(general)).left, closeTo(textStart, 0.5));
      final open = chevronInk(tester, header);
      expect(open.dx, closeTo(chevronInk(tester, rowOf(inside)).dx, 0.5), reason: 'open, turned about its ink');
      expect(open.dx, closeTo(chevronInk(tester, rowOf(plain)).dx, 0.5));
      final shortcut = labelFor(
        'shortcut',
        SchemaNode.fromJson(earsSchema()).fields!['general']!.fields!['shortcut']!,
        const FieldCopy(),
      );
      expect(tester.getRect(find.text(shortcut)).left, closeTo(textStart, 0.5), reason: 'a nested header too');
      expect(chevronInk(tester, rowOf(shortcut)).dx, closeTo(open.dx, 0.5));
      expect(cardOf(tester, rowOf(shortcut)), cardOf(tester, header));
      expect(tester.takeException(), isNull);
    });
  }

  for (final name in ['member', 'overridden', 'interleaved']) {
    testWidgets('real intersect $name keeps member collapse and last-member precedence', (tester) async {
      final cases = jsonDecode(
        File('test/engine_settings/fixtures/schemastery-collapse-intersect.json').readAsStringSync(),
      ) as Map;
      final host = FakeSettingsHost(
        describe: {
          'namespaces': [
            {'ns': 'intersect', 'schema': cases[name], 'base': {}, 'value': {}, 'revision': 0},
          ],
        },
      );
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'intersect'),
        overrides: engineOverrides(DshClient.withCarrier(host)),
      );
      if (name == 'member') {
        expect(find.byType(SchemaCollapsedGroup), findsOneWidget);
        expect(find.byType(Switch), findsOneWidget);
        await tester.tap(find.byType(Switch));
        await flush(tester);
        expect(host.namespaces['intersect']!.user, {'beta': true});
        await tester.tap(find.byType(SchemaCollapsedGroup));
        await settle(tester);
        expect(find.byType(Switch), findsNWidgets(2));
      } else if (name == 'interleaved') {
        final tiles = tester.widgetList<SchemaCollapsedGroup>(find.byType(SchemaCollapsedGroup)).toList();
        expect(tiles, hasLength(2));
        expect(tiles.map((tile) => tile.key).toSet(), hasLength(2));
        expect(find.byType(Switch), findsOneWidget);
        await tester.tap(find.byType(SchemaCollapsedGroup).first);
        await settle(tester);
        expect(find.byType(Switch), findsNWidgets(2));
      } else {
        expect(
          find.byType(SchemaCollapsedGroup),
          findsNothing,
          reason: 'a later free member owns shared; the earlier collapsed declaration cannot lock it',
        );
      }
    });
  }

  for (final brightness in Brightness.values) {
    testWidgets('real voice groups at narrow large text ${brightness.name}', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'ears'),
        overrides: engineOverrides(DshClient.withCarrier(earsHost())),
        brightness: brightness,
      );
      tester.view.physicalSize = const Size(640, 1800);
      await tester.pump();
      await tester.tap(find.byType(SchemaCollapsedGroup).first);
      await settle(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
