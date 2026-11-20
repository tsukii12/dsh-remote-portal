// Measured layout of the schema form's rows at 320dp and large text: a
// title keeps priority over its value, and the local fallback row says
// 「在网页版编辑此项」 in full under its title with the open-external glyph
// on the chevrons' column.

import 'package:dsh_app/ui/common/overview_card.dart' show OverviewChevron;
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_row.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart' show goldenApp;
import 'form_catalog_scenarios.dart' show catalogFixture, formCatalogScenes, pumpCatalogScene;
import 'support.dart';

/// The catalog fields [values] names (plus `visible`), 320 wide at [scale].
Future<void> pumpCatalogFields(WidgetTester tester, Map<String, Object?> values, {required double scale}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 900);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final schema = catalogFixture('schemastery-form-catalog') as Map<String, dynamic>;
  final root = (schema['refs'] as Map)['${schema['uid']}'] as Map;
  final dict = root['dict'] as Map;
  root['dict'] = {
    for (final key in [...values.keys, 'visible']) key: dict[key],
  };
  final base = {...values, 'visible': true}..removeWhere((_, value) => value == null);
  final host = FakeSettingsHost(
    describe: {
      'namespaces': [
        {'ns': 'catalog', 'schema': schema, 'base': base, 'value': base, 'revision': 0},
      ],
    },
  );
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      overrides: engineOverrides(DshClient.withCarrier(host)),
      home: const EngineSettingsPage(ns: 'catalog', title: '插件配置'),
    ),
  );
  await flush(tester);
}

Finder rowOf(String title) => find.ancestor(of: find.text(title), matching: find.byType(EngineFieldRow)).first;

/// Where a trailing glyph's ink ends on screen, from its glyph's geometry.
double inkRight(WidgetTester tester, Finder row, IconData icon, double inkFraction) {
  final glyph = tester.getRect(find.descendant(of: row, matching: find.byIcon(icon)));
  return glyph.left + inkFraction * glyph.width;
}

void main() {
  testWidgets('a title comes before its value: one-word titles stay on one line beside a long value, 320 at 1.3×', (
    tester,
  ) async {
    const long = 'https://example.test/voice/settings/a-rather-long-homepage';
    await pumpCatalogFields(tester, {'timestamp': '2026-10-27T12:00:00Z', 'homepage': long, 'text': long}, scale: 1.3);
    final line = tester.getSize(find.text('Visible')).height;
    (double, double) widths(String title, String value) {
      final shown = find.descendant(of: rowOf(title), matching: find.text(value));
      expect(tester.renderObject<RenderParagraph>(shown).didExceedMaxLines, isTrue, reason: '$title: the value is cut');
      return (tester.getSize(shown).width, tester.getRect(shown).right - tester.getRect(find.text(title)).left);
    }

    for (final (title, value) in [('Timestamp', '2026-10-27T12:00:00Z'), ('Homepage', long)]) {
      expect(tester.getSize(find.text(title)).height, line, reason: '$title on one line');
      widths(title, value);
    }
    // A short title leaves its value the rest of the line, more than the
    // share it keeps against a long title.
    expect(tester.getSize(find.text('Text')).height, line);
    final (value, text) = widths('Text', long);
    expect(
      value,
      greaterThan(text * EngineFieldRow.valueShare + 1),
      reason: 'a short title does not cut its value early',
    );
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('a real plugin\'s titles break between words, 320 at $scale×', (tester) async {
      await pumpCatalogScene(
        tester,
        formCatalogScenes.firstWhere((scene) => scene.name == 'goodandready-dsh-voice-0.9.42'),
        brightness: Brightness.light,
        scale: scale,
      );
      tester.view.physicalSize = const Size(320, 4000);
      await tester.pump();
      for (final (title, word) in [
        ('Deepgram key env', 'Deepgram'),
        ('Deepgram base url', 'Deepgram'),
        ('Whisper model', 'Whisper'),
      ]) {
        final paragraph = tester.renderObject<RenderParagraph>(find.text(title));
        final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: word.length));
        expect(boxes.map((box) => box.top).toSet(), hasLength(1), reason: '「$title」 keeps 「$word」 on one line');
      }
      // A title longer than its line keeps it: its value has its share only.
      final row = rowOf('Deepgram base url');
      final value = find.descendant(
        of: row,
        matching: find.byWidgetPredicate((w) => w is Text && w.maxLines == 1 && w.textAlign == TextAlign.end),
      );
      final text = tester.getRect(value).right - tester.getRect(find.text('Deepgram base url')).left;
      expect(tester.getSize(value).width, lessThanOrEqualTo(text * EngineFieldRow.valueShare + 0.5));
      expect(tester.getSize(value).width, greaterThanOrEqualTo(text * EngineFieldRow.valueFloor - 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets(
      'the local fallback row: the web line in full under the title, glyph on the chevrons\' column, $scale×',
      (tester) async {
        await pumpCatalogFields(tester, {'text': 'Voice input', 'callable': null}, scale: scale);
        const web = '在网页版编辑此项';
        final fallback = rowOf('Callable');
        final line = find.descendant(of: fallback, matching: find.text(web));
        expect(line, findsOneWidget);
        expect(find.text(web), findsOneWidget, reason: 'a subtitle, not also a value');
        expect(tester.renderObject<RenderParagraph>(line).didExceedMaxLines, isFalse, reason: 'never cut');
        expect(tester.getRect(line).left, tester.getRect(find.text('Callable')).left, reason: 'under the title');
        expect(tester.getRect(line).top, greaterThan(tester.getRect(find.text('Callable')).bottom - 0.5));
        expect(find.descendant(of: fallback, matching: find.byType(OverviewChevron)), findsNothing);
        final external = inkRight(tester, fallback, AppIcons.openExternal, ExternalGlyph.inkRight);
        final chevron = inkRight(tester, rowOf('Text'), AppIcons.disclosure, DisclosureChevron.inkRight);
        expect(external, closeTo(chevron, 0.5), reason: 'open-external ink at $external, chevron ink at $chevron');
        expect(
          tester.getRect(fallback).width,
          tester.getRect(rowOf('Text')).width,
          reason: 'the whole row is the target',
        );
        expect(
          tester.getSemantics(fallback),
          isSemantics(isButton: true, isEnabled: true, hasTapAction: true, label: 'Callable\n$web'),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
