// Every editor sheet of a field has one anatomy: the title with its × (the
// only way out), the body, and 完成 (with 恢复默认 beside it once the value
// is the user's) — the text sheet's header and button spacing exactly.

import 'package:dsh_app/ui/common/app_sheet.dart';
import 'package:dsh_app/ui/common/sheet_title_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'form_catalog_scenarios.dart';

typedef SheetGeometry = ({
  double titleLeft,
  double titleCentre,
  double closeRight,
  double closeCentre,
  double doneLeft,
  double doneRight,
  double doneBottom,
  double doneHeight,
});

SheetGeometry measure(WidgetTester tester) {
  final sheet = tester.getRect(find.byType(BottomSheet));
  final title = tester.getRect(find.descendant(of: find.byType(SheetTitleBar), matching: find.byType(Text)).first);
  final close = tester.getRect(find.byType(SheetIconButton));
  final done = tester.getRect(find.widgetWithText(FilledButton, '完成'));
  return (
    titleLeft: title.left - sheet.left,
    titleCentre: title.center.dy - sheet.top,
    closeRight: sheet.right - close.right,
    closeCentre: close.center.dy - sheet.top,
    doneLeft: done.left - sheet.left,
    doneRight: sheet.right - done.right,
    doneBottom: sheet.bottom - done.bottom,
    doneHeight: done.height,
  );
}

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('bitset, tuple, boolean array, any and secret open like the text sheet at $scale×', (tester) async {
      final scenes = {for (final scene in formCatalogScenes) scene.name: scene};
      await pumpCatalogScene(tester, scenes['text']!, brightness: Brightness.light, scale: scale);
      final reference = measure(tester);
      expect(reference.doneHeight, 48);
      for (final name in ['bits', 'tuple', 'toggles', 'data', 'password']) {
        // A fresh tree: the last scene's sheet must not stay on its route.
        await tester.pumpWidget(const SizedBox());
        await pumpCatalogScene(tester, scenes[name]!, brightness: Brightness.light, scale: scale);
        expect(
          find.descendant(
            of: find.byType(SheetTitleBar),
            matching: find.text('${name[0].toUpperCase()}${name.substring(1)}'),
          ),
          findsOneWidget,
          reason: 'the $name sheet is the one measured',
        );
        expect(find.byType(SheetDragHandle), findsNothing, reason: '$name: one way out, the ×');
        expect(find.byType(SheetIconButton), findsOneWidget, reason: name);
        expect(find.text('保存'), findsNothing, reason: name);
        final geometry = measure(tester);
        for (final (label, value, expected) in [
          ('title left', geometry.titleLeft, reference.titleLeft),
          ('title centre', geometry.titleCentre, reference.titleCentre),
          ('× right', geometry.closeRight, reference.closeRight),
          ('× centre', geometry.closeCentre, reference.closeCentre),
          ('完成 left', geometry.doneLeft, reference.doneLeft),
          ('完成 right', geometry.doneRight, reference.doneRight),
          ('完成 bottom', geometry.doneBottom, reference.doneBottom),
          ('完成 height', geometry.doneHeight, reference.doneHeight),
        ]) {
          expect(value, closeTo(expected, 0.5), reason: '$name: $label');
        }
        expect(geometry.doneLeft, closeTo(geometry.doneRight, 0.5), reason: '$name: 完成 centred');
      }

      // An object list's entry page: 完成 beside 删除, on the same footing.
      await tester.pumpWidget(const SizedBox());
      await pumpCatalogScene(tester, scenes['table']!, brightness: Brightness.light, scale: scale);
      await tester.tap(find.text('Voice route'));
      await tester.pumpAndSettle();
      expect(find.text('保存'), findsNothing, reason: 'table entry');
      final sheet = tester.getRect(find.byType(BottomSheet));
      final done = tester.getRect(find.widgetWithText(FilledButton, '完成'));
      expect(sheet.right - done.right, closeTo(reference.doneRight, 0.5));
      expect(sheet.bottom - done.bottom, closeTo(reference.doneBottom, 0.5));
      expect(done.height, reference.doneHeight);
    });
  }
}
