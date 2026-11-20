// Measured symmetry of the Cordis plugin sheet: the facts card and the
// buttons on the sheet's 20 gutter, the secondary pair mirrored, every
// button 50 tall; and at 360 wide with large text nothing overflows.

import 'package:dsh_app/ui/cordis/cordis_page.dart';
import 'package:dsh_app/ui/cordis/cordis_plugin_sheet.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

void main() {
  for (final (width, scale) in [(390.0, 1.0), (360.0, 1.3)]) {
    testWidgets('plugin sheet at $width / $scale', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = Size(width * 2, 844 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        goldenApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
              child: const CordisPage(),
            ),
          ),
          brightness: Brightness.light,
          overrides: cordisOverrides(),
        ),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.tap(find.text('桌面时钟'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);

      final sheet = find.byType(CordisPluginSheet);
      Rect rect(Finder f) => tester.getRect(find.descendant(of: sheet, matching: f));
      const gutter = 20.0;

      final card = rect(find.byType(ListPageCard));
      expect(card.left, closeTo(gutter, .5));
      expect(card.right, closeTo(width - gutter, .5));

      final open = rect(find.widgetWithText(FilledButton, '在网页版打开'));
      final stop = rect(find.widgetWithText(OutlinedButton, '停止'));
      final remove = rect(find.widgetWithText(OutlinedButton, '移除'));
      expect(open.left, closeTo(gutter, .5));
      expect(open.right, closeTo(width - gutter, .5));
      for (final button in [open, stop, remove]) {
        expect(button.height, 50);
      }
      if ((stop.top - remove.top).abs() < .5) {
        // Side by side: equal halves, 8 apart, mirrored about the centre.
        expect(stop.left, closeTo(gutter, .5));
        expect(remove.right, closeTo(width - gutter, .5));
        expect(stop.width, closeTo(remove.width, .5));
        expect(remove.left - stop.right, closeTo(8, .5));
        expect((stop.left + remove.right) / 2, closeTo(width / 2, .5));
      } else {
        for (final button in [stop, remove]) {
          expect(button.left, closeTo(gutter, .5));
          expect(button.right, closeTo(width - gutter, .5));
        }
      }
      // The facts card and the buttons share both edges.
      expect(card.left, closeTo(open.left, .5));
      expect(card.right, closeTo(open.right, .5));
    });
  }

  testWidgets('page rows: the status dot sits in the middle of the glyph column', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(home: const CordisPage(), brightness: Brightness.light, overrides: cordisOverrides()),
    );
    await tester.pump(const Duration(milliseconds: 600));
    final row = find.ancestor(of: find.text('桌面时钟'), matching: find.byType(CordisPluginRow));
    // The card's glass (its margin is outside).
    final card = tester.getRect(find.ancestor(of: row, matching: find.byType(GlassSurface)).first);
    final dot = tester.getRect(find.descendant(of: row, matching: find.byType(StatusDot)));
    // Card at 16; row content 16 in; a 32 glyph column.
    expect(card.left, 16);
    expect(card.right, 390 - 16);
    expect(dot.center.dx, closeTo(card.left + ListPageRow.horizontal + ListPageRow.glyphSlot / 2, .5));
    expect(dot.center.dy, closeTo(tester.getRect(row).center.dy, .5));
  });

  testWidgets('failure line: icon and 详情 on the two gutters', (tester) async {
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(home: const CordisPage(), brightness: Brightness.light, overrides: cordisOverrides()),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.tap(find.text('翻译助手'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    final sheet = find.byType(CordisPluginSheet);
    final icon = tester.getRect(find.descendant(of: sheet, matching: find.byIcon(AppIcons.error)));
    final toggle = tester.getRect(find.descendant(of: sheet, matching: find.text('详情')));
    final card = tester.getRect(find.descendant(of: sheet, matching: find.byType(ListPageCard)));
    expect(icon.left, closeTo(20, .5));
    expect(toggle.right, closeTo(390 - 20, .5));
    expect(icon.center.dy, closeTo(toggle.center.dy, 1));
    expect(card.left, closeTo(icon.left, .5));
    expect(card.right, closeTo(toggle.right, .5));
  });
}
