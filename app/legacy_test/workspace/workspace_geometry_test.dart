// Measured symmetry of the workspace chrome: the drawer's switcher on the
// 10 / 20 grid, breadcrumb capsules with equal insets on one centre line,
// the switcher sheet's cards and the browser's bottom button mirrored.
//
//   flutter test test/workspace/workspace_geometry_test.dart

import 'package:dsh_app/ui/common/breadcrumb_row.dart';
import 'package:dsh_app/ui/common/list_page_row.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_app/ui/shell/sessions_drawer.dart';
import 'package:dsh_app/ui/theme/theme.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_app/ui/workspace/workspace_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shell/golden_harness.dart';
import 'support.dart';

const _eps = 0.01;

Matcher _near(double v) => closeTo(v, _eps);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpDrawer(WidgetTester tester) async {
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
      brightness: Brightness.light,
      overrides: workspaceOverrides(sampleWorkspaceHost()),
    ),
  );
  await _settle(tester);
}

void main() {
  group('drawer switcher', () {
    testWidgets('glyph on the 20 line, highlight on the 10 line, 36 tall, one centre line', (tester) async {
      await _pumpDrawer(tester);
      final drawer = tester.getRect(find.byType(SessionsDrawer));
      final switcher = find.byType(WorkspaceSwitcher);
      final ink = tester.getRect(find.descendant(of: switcher, matching: find.byType(InkWell)));
      final icons = find.descendant(of: switcher, matching: find.byType(Icon));
      final glyph = tester.getRect(icons.first);
      final chevron = tester.getRect(icons.last);
      final label = tester.getRect(find.descendant(of: switcher, matching: find.text('dsh-app')));
      final eyebrow = tester.getRect(find.text('今天'));
      final tile = tester.getRect(find.byType(SessionTile).first);

      expect(ink.left - drawer.left, _near(10));
      expect(glyph.left - drawer.left, _near(20));
      // The highlight hugs its content with the same 10 on both ends.
      expect(ink.right - chevron.right, _near(glyph.left - ink.left));
      expect(ink.height, _near(WorkspaceSwitcher.height));
      expect(glyph.center.dy, _near(ink.center.dy));
      expect(chevron.center.dy, _near(ink.center.dy));
      expect(label.center.dy, closeTo(ink.center.dy, 0.75));
      // Same text line as the day labels and the rows' highlight edge.
      expect(eyebrow.left - drawer.left, _near(20));
      expect(tile.left, _near(ink.left));
    });
  });

  group('breadcrumbs', () {
    testWidgets('capsules: equal insets, one height, one centre line; first on the page gutter', (tester) async {
      usePhoneSurface(tester);
      await tester.pumpWidget(
        goldenApp(
          home: const DirectoryBrowserPage(start: '/root/code/dsh-app'),
          brightness: Brightness.light,
          overrides: workspaceOverrides(sampleWorkspaceHost()),
        ),
      );
      await _settle(tester);
      final capsules = find.byType(BreadcrumbCapsule);
      expect(capsules, findsNWidgets(3));
      final rects = [for (var i = 0; i < 3; i++) tester.getRect(capsules.at(i))];
      for (var i = 0; i < 3; i++) {
        final text = tester.getRect(find.descendant(of: capsules.at(i), matching: find.byType(Text)));
        expect(text.left - rects[i].left, _near(BreadcrumbCapsule.inset));
        expect(rects[i].right - text.right, _near(BreadcrumbCapsule.inset));
        expect(rects[i].height, _near(BreadcrumbRow.height));
        expect(rects[i].center.dy, _near(rects[0].center.dy));
      }
      // Separators: the same gap between every pair.
      expect(rects[1].left - rects[0].right, _near(rects[2].left - rects[1].right));
      final card = tester.getRect(
        find.descendant(of: find.byType(ListPageCard), matching: find.byType(GlassSurface)).first,
      );
      expect(rects[0].left, _near(card.left));
      expect(card.top - rects.last.bottom, _near(12));
      expect(rects[0].left, _near(16));

      // The bottom button mirrors the card.
      final button = tester.getRect(find.byType(FilledButton));
      expect(button.left, _near(card.left));
      expect(tester.view.physicalSize.width / tester.view.devicePixelRatio - button.right, _near(button.left));
    });
  });

  group('switcher sheet', () {
    testWidgets('cards 20 in on both sides; rows share the glyph column', (tester) async {
      await _pumpDrawer(tester);
      await tester.tap(find.descendant(of: find.byType(WorkspaceSwitcher), matching: find.byType(InkWell)));
      await _settle(tester);
      final sheet = tester.getRect(find.byType(WorkspaceSheet));
      final cards = find.descendant(of: find.byType(WorkspaceSheet), matching: find.byType(GlassSurface));
      expect(cards, findsWidgets);
      for (var i = 0; i < tester.widgetList(cards).length; i++) {
        final r = tester.getRect(cards.at(i));
        expect(r.left - sheet.left, _near(20));
        expect(sheet.right - r.right, _near(20));
      }
      final rows = find.descendant(of: find.byType(WorkspaceSheet), matching: find.byType(ListPageRow));
      final glyphLefts = {
        for (var i = 0; i < tester.widgetList(rows).length; i++)
          tester.getRect(find.descendant(of: rows.at(i), matching: find.byType(Icon)).first).left.toStringAsFixed(2),
      };
      expect(glyphLefts, hasLength(1));
    });
  });
}
