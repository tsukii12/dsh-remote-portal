// Regression cases discovered by the independent F1 review.
// The original failing evidence remains in the delivery review-evidence directory.
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_styles.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const captureKey = ValueKey('review-capture');
Widget page(Object view, Brightness brightness) => testApp(
  Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: RepaintBoundary(
        key: captureKey,
        child: PluginView(view: view, onAction: (_) async => true),
      ),
    ),
  ),
  brightness: brightness,
);

Map<String, Object?> paddedNode(Map<String, Object?> leaf, int layers, {String type = 'stack'}) {
  var result = leaf;
  for (var i = 0; i < layers; i++) {
    result = {
      'type': type,
      'style': {'padding': 'L', 'card': 'outlined'},
      'children': [result],
    };
  }
  return result;
}

Map<String, Object?> actionNode(int count) => {
  'type': 'actions',
  'items': [
    for (var i = 0; i < count; i++) {'label': 'Save $i', 'action': 'save$i', 'icon': 'check'},
  ],
};

void expectRealTargets(WidgetTester tester) {
  final boundary = tester.getRect(find.byKey(const ValueKey('plugin-v2-boundary')));
  final buttons = find.byType(DshUiV2ActionButton);
  expect(buttons, findsWidgets);
  for (final element in buttons.evaluate()) {
    final rect = tester.getRect(find.byWidget(element.widget));
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.left, greaterThanOrEqualTo(boundary.left));
    expect(rect.right, lessThanOrEqualTo(boundary.right));
  }
  final paddings = find.byWidgetPredicate(
    (w) =>
        w is Padding &&
        w.key is ValueKey<String> &&
        (w.key! as ValueKey<String>).value.startsWith('plugin-v2-padding:'),
  );
  for (final element in paddings.evaluate()) {
    final widget = element.widget as Padding;
    final inset = widget.padding as EdgeInsets;
    expect(inset, EdgeInsets.all(inset.left));
    expect(inset.left, inInclusiveRange(0, 16));
    final padded = tester.getRect(find.byWidget(widget));
    // Measure constraints realized by the layout; do not just inspect the
    // leaf's nominal ConstrainedBox minimum.
    expect(padded.width - inset.horizontal, greaterThanOrEqualTo(48));
  }
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadTestFonts);
  for (final brightness in Brightness.values) {
    testWidgets('selected donut legend retains contrast ${brightness.name}', (tester) async {
      usePhoneView(tester);
      final view = {
        'v': 2,
        'type': 'stack',
        'style': {'background': '#000000'},
        'children': [
          {
            'type': 'chart',
            'kind': 'donut',
            'unit': 'kg',
            'categories': ['Alpha', 'Bravo', 'Charlie'],
            'series': [
              {
                'values': [1, 2, 3],
              },
            ],
          },
        ],
      };
      await tester.pumpWidget(page(view, brightness));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bravo'));
      await tester.pumpAndSettle();
      final row = find.ancestor(
        of: find.text('Alpha'),
        matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_DonutLegendRow'),
      );
      final faded = tester.widget<AnimatedOpacity>(find.descendant(of: row, matching: find.byType(AnimatedOpacity)));
      final label = find.descendant(of: row, matching: find.text('Alpha'));
      final percentage = find.descendant(of: row, matching: find.text('16.7%'));
      final key = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w.runtimeType.toString() == '_Key'));
      final background = Theme.of(tester.element(row)).colorScheme.surface.toARGB32() & 0xFFFFFF;
      final foreground = tester.widget<Text>(label).style!.color!;
      final percentForeground = tester.widget<Text>(percentage).style!.color!;
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final origin = tester.getTopLeft(find.byKey(captureKey));
      final labelRect = tester.getRect(label).shift(-origin);
      final percentRect = tester.getRect(percentage).shift(-origin);
      final keyPoint = tester.getCenter(key) - origin;
      final number = find.descendant(of: row, matching: find.byWidgetPredicate((w) => w is Text && w.textSpan != null));
      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: number, matching: find.byType(RichText)),
      );
      final plain = paragraph.text.toPlainText();
      Rect rangeRect(int start, int end) => paragraph
          .getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: end))
          .map((box) => box.toRect())
          .reduce((a, b) => a.expandToInclude(b))
          .shift(paragraph.localToGlobal(Offset.zero) - origin);
      final numberRect = rangeRect(plain.indexOf('1'), plain.indexOf('1') + 1);
      final unitRect = rangeRect(plain.indexOf('kg'), plain.indexOf('kg') + 2);
      final measured = (await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = (await picture.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          int rgb(int x, int y) {
            final i = (y * picture.width + x) * 4;
            return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
          }

          double maxInkContrast(Rect rect) {
            var maximum = 1.0;
            for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
              for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
                maximum = math.max(maximum, dshUiContrast(rgb(x, y), background));
              }
            }
            return maximum;
          }

          final keyPixel = rgb(keyPoint.dx.floor(), keyPoint.dy.floor());
          return {
            'labelMaxRasterContrast': maxInkContrast(labelRect),
            'percentMaxRasterContrast': maxInkContrast(percentRect),
            'numberMaxRasterContrast': maxInkContrast(numberRect),
            'unitMaxRasterContrast': maxInkContrast(unitRect),
            'keyRgb': keyPixel,
            'keyRasterContrast': dshUiContrast(keyPixel, background),
          };
        } finally {
          picture.dispose();
        }
      }))!;
      final blendedLabel = Color.alphaBlend(
        foreground.withValues(alpha: faded.opacity),
        Color(0xFF000000 | background),
      );
      final blendedPercent = Color.alphaBlend(
        percentForeground.withValues(alpha: faded.opacity),
        Color(0xFF000000 | background),
      );
      // Print measurements before the required invariant, so both themes remain inspectable on failure.
      debugPrint(
        jsonEncode({
          'case': 'donutLegend',
          'theme': brightness.name,
          'opacity': faded.opacity,
          'background': background.toRadixString(16),
          'labelDesignRatioAfterOpacity': dshUiContrast(blendedLabel.toARGB32() & 0xFFFFFF, background),
          'percentDesignRatioAfterOpacity': dshUiContrast(blendedPercent.toARGB32() & 0xFFFFFF, background),
          ...measured,
        }),
      );
      expect(tester.takeException(), isNull);
      expect(
        measured['labelMaxRasterContrast'],
        greaterThanOrEqualTo(4.5),
        reason: 'even the strongest fully rendered label pixels must be able to reach the text floor',
      );
      expect(measured['percentMaxRasterContrast'], greaterThanOrEqualTo(4.5));
      expect(measured['numberMaxRasterContrast'], greaterThanOrEqualTo(4.5));
      expect(measured['unitMaxRasterContrast'], greaterThanOrEqualTo(4.5));
      expect(measured['keyRasterContrast'], greaterThanOrEqualTo(3));
    });
  }

  test('app rejects malformed spacing types with diagnostics', () {
    for (final spacing in [
      ['S'],
      {'toString': null},
    ]) {
      final view = {
        'v': 2,
        'type': 'stack',
        'style': {'padding': spacing, 'gap': spacing},
        'children': [
          {'type': 'text', 'text': 'ok'},
        ],
      };
      final parsed = parseDshUiPluginUncached(jsonDecode(jsonEncode(view)), profile: DshUiProfile.panel) as DshUiParsed;
      final style = parsed.view.styles['view']!;
      debugPrint(
        jsonEncode({
          'case': 'appMalformedSpacing',
          'input': spacing,
          'padding': style.padding,
          'gap': style.gap,
          'issuePaths': parsed.view.issues.map((i) => i.path).toList(),
        }),
      );
      expect(style.padding, 0);
      expect(style.gap, 16);
      expect(parsed.view.issues.map((i) => i.path), containsAll(['view.style.padding', 'view.style.gap']));
    }
  });

  testWidgets('valid nested padding preserves minimum action width', (tester) async {
    usePhoneView(tester);
    tester.view.physicalSize = const Size(640, 1688);
    Map<String, Object?> view = {
      'type': 'actions',
      'items': [
        {'label': 'Save', 'action': 'save'},
      ],
    };
    for (var i = 0; i < 7; i++) {
      view = {
        'type': 'stack',
        'style': {'padding': 'L'},
        'children': [view],
      };
    }
    view['v'] = 2;
    final parsed = parseDshUiPluginUncached(view, profile: DshUiProfile.panel) as DshUiParsed;
    expect(parsed.view.nodes.whereType<DshUiActions>(), hasLength(1));
    await tester.pumpWidget(page(view, Brightness.light));
    await tester.pumpAndSettle();
    final button = find.byType(DshUiV2ActionButton);
    final size = tester.getSize(button);
    debugPrint(
      jsonEncode({
        'case': 'nestedPadding',
        'logicalScreenWidth': 320,
        'nodeCount': parsed.view.nodes.length,
        'depth': 8,
        'paddingLevels': 7,
        'buttonWidth': size.width,
        'buttonHeight': size.height,
        'issuePaths': parsed.view.issues.map((i) => i.path).toList(),
      }),
    );
    expect(tester.takeException(), isNull);
    expect(size.width, greaterThanOrEqualTo(48));
  });

  for (final scale in [1.0, 2.0]) {
    for (final width in [160.0, 320.0]) {
      for (final count in [1, 2, 4]) {
        testWidgets('nested padding keeps $count real targets at width $width and scale $scale', (tester) async {
          usePhoneView(tester);
          tester.view.physicalSize = Size(width * 2, 4000);
          final view = paddedNode(actionNode(count), 7)..['v'] = 2;
          final parsed = parseDshUiPluginUncached(view, profile: DshUiProfile.panel) as DshUiParsed;
          expect(parsed.view.nodes.whereType<DshUiActions>(), hasLength(1));
          await tester.pumpWidget(
            testApp(
              MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: SingleChildScrollView(
                    padding: const EdgeInsets.all(16),
                    child: PluginView(view: view, onAction: (_) async => true),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expectRealTargets(tester);
          if (count == 2) {
            final buttons = find.byType(DshUiV2ActionButton);
            expect(tester.getTopLeft(buttons.at(1)).dy, greaterThan(tester.getBottomRight(buttons.at(0)).dy));
          }
          final reduced = find.byWidgetPredicate(
            (w) =>
                w is Padding &&
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('plugin-v2-padding:') &&
                (w.padding as EdgeInsets).left < 16,
          );
          expect(reduced, findsWidgets, reason: 'The regression must actually exercise adaptive padding.');
        });
      }
    }
  }

  for (final width in [320.0, 960.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('weighted rows and nested rows preserve control widths at $width / $scale', (tester) async {
        usePhoneView(tester);
        tester.view.physicalSize = Size(width * 2, 4000);
        final view = {
          'v': 2,
          'type': 'row',
          'style': {
            'columns': [1, 3],
            'padding': 'L',
            'gap': 'M',
          },
          'children': [
            paddedNode(actionNode(2), 6, type: 'row'),
            paddedNode({'type': 'confirm', 'id': 'sure', 'confirmLabel': 'Continue', 'cancelLabel': 'Back'}, 6),
          ],
        };
        final parsed = parseDshUiPluginUncached(view, profile: DshUiProfile.panel) as DshUiParsed;
        expect(parsed.view.nodes.whereType<DshUiActions>(), hasLength(1));
        expect(parsed.view.nodes.whereType<DshUiConfirm>(), hasLength(1));
        await tester.pumpWidget(
          testApp(
            MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: PluginView(view: view, onAction: (_) async => true),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expectRealTargets(tester);
      });
    }
  }

  testWidgets('hover retains checked action background', (tester) async {
    usePhoneView(tester);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        page({
          'v': 2,
          'accent': '#FFFFFF',
          'type': 'actions',
          'items': [
            {'label': 'Hover', 'action': 'go'},
          ],
        }, brightness),
      );
      await tester.pumpAndSettle();
      final finder = find.byType(DshUiV2ActionButton);
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(finder));
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(find.descendant(of: finder, matching: find.byType(Material)));
      expect((material.shape! as OutlinedBorder).side.width, 2);
      final ink = tester.widget<InkWell>(find.descendant(of: finder, matching: find.byType(InkWell)));
      expect(ink.overlayColor!.resolve({WidgetState.hovered}), Colors.transparent);
      final rect = tester.getRect(finder);
      final point = Offset(rect.center.dx, rect.top + 6) - tester.getTopLeft(find.byKey(captureKey));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final rgb = (await tester.runAsync(() async {
        final picture = await boundary.toImage(pixelRatio: 1);
        try {
          final bytes = (await picture.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          final i = (point.dy.floor() * picture.width + point.dx.floor()) * 4;
          return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        } finally {
          picture.dispose();
        }
      }))!;
      final fg = tester.widget<Text>(find.text('Hover')).style!.color!.toARGB32() & 0xFFFFFF;
      debugPrint(
        jsonEncode({
          'case': 'hover',
          'theme': brightness.name,
          'background': rgb.toRadixString(16),
          'ratio': dshUiContrast(fg, rgb),
        }),
      );
      expect(dshUiContrast(fg, rgb), greaterThanOrEqualTo(4.5));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    }
  });
}
