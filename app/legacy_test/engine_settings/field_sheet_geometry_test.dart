// Measured symmetry inside the field sheets: the color swatches as a 2 × 4
// grid spanning the field with equal outer insets, and an array row's ⊖
// inked to the trailing edge of 添加 under it.

import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/sequence_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'form_catalog_scenarios.dart';

FormCatalogScene scene(String name) => formCatalogScenes.firstWhere((scene) => scene.name == name);

void main() {
  for (final scale in [1.0, 1.3]) {
    testWidgets('swatches: 2 rows of 4 across the field, equal insets, 48 targets, 320 wide at $scale×', (
      tester,
    ) async {
      await pumpCatalogScene(tester, scene('tint'), brightness: Brightness.light, scale: scale);
      final field = tester.getRect(find.byKey(const ValueKey('text-input')));
      Finder cell(String hex) => find.byKey(ValueKey('schema-color-swatch-$hex'));
      final cells = [for (final hex in SchemaColorSwatches.presets) tester.getRect(cell(hex))];
      final dots = [
        for (final hex in SchemaColorSwatches.presets)
          tester.getRect(find.descendant(of: cell(hex), matching: find.byType(SchemaColorDot))),
      ];
      expect(dots, hasLength(8));
      const columns = SchemaColorSwatches.columns;
      for (var row = 0; row < 2; row++) {
        final line = dots.sublist(row * columns, (row + 1) * columns);
        expect(line.map((d) => d.center.dy).toSet(), hasLength(1), reason: 'row $row is one line');
        final left = line.first.left - field.left;
        final right = field.right - line.last.right;
        expect(left, closeTo(right, 0.5), reason: 'row $row: left inset $left, right inset $right');
        for (var i = 1; i < columns - 1; i++) {
          expect(
            line[i + 1].center.dx - line[i].center.dx,
            closeTo(line[i].center.dx - line[i - 1].center.dx, 0.5),
            reason: 'columns evenly spaced',
          );
        }
        final targets = cells.sublist(row * columns, (row + 1) * columns);
        expect(targets.first.left, closeTo(field.left, 0.5), reason: 'the grid spans the field');
        expect(targets.last.right, closeTo(field.right, 0.5));
      }
      for (var i = 0; i < columns; i++) {
        expect(dots[i + columns].center.dx, closeTo(dots[i].center.dx, 0.01), reason: 'columns line up');
      }
      expect(dots[columns].top, greaterThan(dots.first.bottom), reason: 'two rows');
      for (final target in cells) {
        expect(target.width, greaterThanOrEqualTo(48));
        expect(target.height, greaterThanOrEqualTo(48));
      }

      await tester.tap(cell('#ef4444'));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).controller!.text, '#ef4444');
      expect(tester.takeException(), isNull);
    });

    testWidgets('array rows: the ⊖ ink ends on 添加\'s trailing edge, 320 wide at $scale×', (tester) async {
      await pumpCatalogScene(tester, scene('toggles'), brightness: Brightness.light, scale: scale);
      final add = tester.getRect(find.widgetWithText(OutlinedButton, '添加'));
      final keys = find.byType(RemoveItemKey);
      expect(keys, findsNWidgets(2));
      for (var i = 0; i < 2; i++) {
        final target = tester.getRect(keys.at(i));
        expect(target.size, const Size.square(48), reason: 'a full target');
        expect(target.right, closeTo(add.right, 0.5), reason: 'the target stays inside the content');
        final glyph = tester.getRect(find.descendant(of: keys.at(i), matching: find.byType(Icon)));
        // minus-circle's ink: x 13.6–242.4 of the font's 256 grid.
        final inkRight = glyph.left + 242.4 / 256 * glyph.width;
        expect(inkRight, closeTo(add.right, 0.5), reason: 'row $i: ink ends at $inkRight, 添加 at ${add.right}');
      }
      expect(tester.takeException(), isNull);
    });
  }
}
