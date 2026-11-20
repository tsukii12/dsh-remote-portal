// The tile style picker (lib/ui/settings/appearance/tile_style_picker.dart).
//
// - Geometry: three equal columns, equal gaps, equal padding; square previews
//   whose 2 × 2 tiles sit at equal insets on every side; labels centred under
//   their previews.
// - Behaviour: the default (扁平双色) is selected first; a tap selects and stores.
// - Narrow phone at large text: nothing overflows.
// - Goldens in a settings card, light and dark.
//
//   flutter test test/tiles/tile_style_picker_test.dart

import 'dart:ui' show Tristate;

import 'package:dsh_app/state/tile_style_state.dart';
import 'package:dsh_app/ui/common/feature_tile.dart';
import 'package:dsh_app/ui/settings/appearance/tile_style_picker.dart';
import 'package:dsh_app/ui/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support.dart';

Widget _page({double textScale = 1}) => Builder(
  builder: (context) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
    child: const SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: EdgeInsets.only(top: 24),
          child: SettingsSection(title: '功能图标', children: [TileStylePicker()]),
        ),
      ),
    ),
  ),
);

Rect _preview(WidgetTester tester, TileStyle style) => tester.getRect(find.byKey(ValueKey('tile-style-${style.name}')));

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('geometry: equal columns, gaps, padding and insets', (tester) async {
    useView(tester, 390, 400);
    await tester.pumpWidget(tileApp(_page()));
    await tester.pump();

    final picker = tester.getRect(find.byType(TileStylePicker));
    final rects = [for (final s in TileStyle.values) _preview(tester, s)];
    // Square previews of one width.
    for (final r in rects) {
      expect(r.width, closeTo(r.height, 0.01));
      expect(r.width, closeTo(rects.first.width, 0.01));
    }
    // Equal gaps; the row padded alike on the left, right and top.
    expect(rects[1].left - rects[0].right, closeTo(TileStylePicker.gap, 0.01));
    expect(rects[2].left - rects[1].right, closeTo(TileStylePicker.gap, 0.01));
    expect(rects.first.left - picker.left, closeTo(16, 0.01));
    expect(picker.right - rects.last.right, closeTo(16, 0.01));
    expect(rects.first.top - picker.top, closeTo(16, 0.01));
    // All three on one line.
    for (final r in rects) {
      expect(r.top, closeTo(rects.first.top, 0.01));
    }

    for (final (i, style) in TileStyle.values.indexed) {
      final box = rects[i];
      final tiles = find.descendant(
        of: find.byKey(ValueKey('tile-style-${style.name}')),
        matching: find.byType(FeatureTile),
      );
      expect(tiles, findsNWidgets(4));
      final t = [for (var k = 0; k < 4; k++) tester.getRect(tiles.at(k))];
      final left = t[0].left - box.left;
      final top = t[0].top - box.top;
      final right = box.right - t[1].right;
      final bottom = box.bottom - t[3].bottom;
      expect(left, closeTo(top, 0.01), reason: style.name);
      expect(right, closeTo(left, 0.01), reason: style.name);
      expect(bottom, closeTo(left, 0.01), reason: style.name);
      expect(t[1].left - t[0].right, closeTo(t[2].top - t[0].bottom, 0.01));
      expect(left, closeTo(box.width * TileStylePicker.inset, 0.01));
      // The label is centred under its preview.
      final label = tester.getRect(find.text(style.label));
      expect(label.center.dx, closeTo(box.center.dx, 0.5), reason: style.label);
      expect(label.top - box.bottom, closeTo(8, 0.01));
    }
  });

  testWidgets('the default is selected first; a tap selects and stores', (tester) async {
    useView(tester, 390, 400);
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(tileApp(_page()));
    await tester.pump();

    expect(TileStyle.values.first, TileStyle.duotone);
    expect(tester.getSemantics(find.bySemanticsLabel('扁平双色')).flagsCollection.isSelected, Tristate.isTrue);
    expect(tester.getSemantics(find.bySemanticsLabel('极简几何')).flagsCollection.isSelected, Tristate.isFalse);

    await tester.tap(find.text('极简几何'));
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(tester.element(find.byType(TileStylePicker)));
    expect(container.read(tileStyleProvider), TileStyle.geometric);
    expect(tester.getSemantics(find.bySemanticsLabel('极简几何')).flagsCollection.isSelected, Tristate.isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('tile_style'), 'geometric');
    // The ring is drawn inside the edge: choosing moves nothing.
    Rect firstTile() => tester.getRect(
      find.descendant(of: find.byKey(const ValueKey('tile-style-duotone')), matching: find.byType(FeatureTile)).first,
    );
    final before = (_preview(tester, TileStyle.duotone), firstTile());
    await tester.tap(find.text('扁平双色'));
    await tester.pumpAndSettle();
    expect((_preview(tester, TileStyle.duotone), firstTile()), before);
    handle.dispose();
  });

  testWidgets('a narrow phone at large text fits', (tester) async {
    useView(tester, 360, 400);
    await tester.pumpWidget(tileApp(_page(textScale: 1.3)));
    await tester.pump();
    expect(tester.takeException(), isNull);
    for (final s in TileStyle.values) {
      final label = tester.renderObject<RenderParagraph>(find.text(s.label));
      expect(label.didExceedMaxLines, isFalse, reason: s.label);
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden (${brightness.name})', (tester) async {
      useView(tester, 390, 260);
      await tester.pumpWidget(tileApp(_page(), brightness: brightness));
      await decodeImages(tester);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/tile_style_picker_${brightness.name}.png'),
      );
    });
  }
}
