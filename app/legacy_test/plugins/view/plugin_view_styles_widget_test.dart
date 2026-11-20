import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_styles.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart' show dshUiContrast;
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_blocks.dart' show DshUiProgressBlock, DshUiListBlock;
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_widgets.dart' show DshUiOptionRow;
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'style_fixtures.dart';
import 'support.dart';

Future<bool> action(PluginAction _) async => true;

Widget page(Object view, {double scale = 1, Brightness brightness = Brightness.light}) => testApp(
  MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(scale)),
    child: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: PluginView(view: view, onAction: action),
      ),
    ),
  ),
  brightness: brightness,
);

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    for (final scale in [0.85, 1.0, 1.3, 2.0]) {
      for (final width in [320.0, 390.0]) {
        testWidgets('v2 fits $width at $scale in ${brightness.name}', (tester) async {
          usePhoneView(tester);
          tester.view.physicalSize = Size(width * 2, 1688);
          await tester.pumpWidget(page(styleGallery, scale: scale, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          expect(find.byKey(const ValueKey('plugin-v2-attribution')), findsOneWidget);
          final boundary = tester.getRect(find.byKey(const ValueKey('plugin-v2-boundary')));
          for (final item in find.byType(DshUiStyledText).evaluate()) {
            final rect = tester.getRect(find.byWidget(item.widget));
            expect(rect.left, greaterThanOrEqualTo(boundary.left));
            expect(rect.right, lessThanOrEqualTo(boundary.right + 0.01));
          }
        });
      }
    }
  }

  testWidgets('v2 same-row buttons measure equal all-side padding, height and minimum target', (tester) async {
    usePhoneView(tester);
    tester.view.physicalSize = const Size(1280, 1688);
    await tester.pumpWidget(
      page({
        'v': 2,
        'type': 'actions',
        'items': [
          {'label': '短', 'action': 'a'},
          {'label': 'A longer button label', 'action': 'b'},
        ],
      }, scale: 2),
    );
    final buttons = find.byType(DshUiV2ActionButton);
    expect(buttons, findsNWidgets(2));
    final sizes = buttons.evaluate().map((e) => tester.getSize(find.byWidget(e.widget))).toList();
    expect(tester.getTopLeft(buttons.at(0)).dy, tester.getTopLeft(buttons.at(1)).dy);
    expect(sizes[0].height, sizes[1].height);
    for (final size in sizes) {
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    for (final label in ['短', 'A longer button label']) {
      final padding = tester.widget<Padding>(find.byKey(ValueKey('plugin-v2-button-padding:$label')));
      expect(padding.padding, const EdgeInsets.all(12));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('v2 confirmation shares the plugin outline rather than a grant control', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(page({'v': 2, 'type': 'confirm', 'id': 'save', 'confirmLabel': '保存', 'cancelLabel': '返回'}));
    expect(find.byType(DshUiV2ActionButton), findsNWidgets(2));
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byKey(const ValueKey('plugin-v2-attribution')), findsOneWidget);
  });

  testWidgets('v2 action has a labelled semantic tap and keyboard activation', (tester) async {
    usePhoneView(tester);
    final semantics = tester.ensureSemantics();
    try {
      var calls = 0;
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: PluginView(
              view: const {
                'v': 2,
                'type': 'actions',
                'items': [
                  {'label': 'Copy summary', 'action': 'copy'},
                ],
              },
              onAction: (_) async {
                calls++;
                return true;
              },
            ),
          ),
        ),
      );
      final data = tester.getSemantics(find.byType(DshUiV2ActionButton)).getSemanticsData();
      expect(data.label, 'Copy summary');
      expect(data.hasAction(SemanticsAction.tap), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('v2 focus and press keep the actual button background and visible outline', (tester) async {
    usePhoneView(tester);
    const view = {
      'v': 2,
      'accent': '#FFFFFF',
      'type': 'actions',
      'items': [
        {'label': 'Action', 'action': 'go'},
      ],
    };
    final style = (parsePluginView(view) as DshUiParsed).view.styles['view']!;
    const captureKey = ValueKey('state-capture');
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: RepaintBoundary(
              key: captureKey,
              child: PluginView(key: ValueKey(brightness), view: view, onAction: action),
            ),
          ),
          brightness: brightness,
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(DshUiV2ActionButton);
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
      final rect = tester.getRect(button);
      final point = Offset(rect.center.dx, rect.top + 6) - tester.getTopLeft(find.byKey(captureKey));
      Future<int> backgroundPixel() async => (await tester.runAsync(() async {
        final picture = await boundary.toImage();
        try {
          final bytes = (await picture.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          final i = (point.dy.floor() * picture.width + point.dx.floor()) * 4;
          return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        } finally {
          picture.dispose();
        }
      }))!;
      double borderWidth() =>
          (tester.widget<Material>(find.descendant(of: button, matching: find.byType(Material))).shape!
                  as OutlinedBorder)
              .side
              .width;
      final dark = brightness == Brightness.dark;
      expect(await backgroundPixel(), style.background.at(dark));
      expect(borderWidth(), 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(borderWidth(), 2, reason: 'keyboard focus stays visible without a colour wash');
      expect(dshUiContrast(style.accent.at(dark), await backgroundPixel()), greaterThanOrEqualTo(4.5));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 150));
      expect(borderWidth(), 2);
      expect(await backgroundPixel(), style.background.at(dark));
      expect(dshUiContrast(style.accent.at(dark), await backgroundPixel()), greaterThanOrEqualTo(4.5));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
  });

  for (final kind in ['list', 'options']) {
    testWidgets('v2 $kind secondary text retains raster contrast under focus and press', (tester) async {
      usePhoneView(tester);
      final node = kind == 'list'
          ? {
              'type': 'list',
              'items': [
                {'title': 'Title', 'subtitle': 'Secondary', 'action': 'go'},
              ],
            }
          : {
              'type': 'options',
              'id': 'go',
              'options': [
                {'label': 'Title', 'description': 'Secondary', 'value': 'a'},
              ],
            };
      final view = {
        'v': 2,
        'type': 'stack',
        'style': {'background': '#000000'},
        'children': [node],
      };
      final style = (parsePluginView(view) as DshUiParsed).view.styles['view.children[0]']!;
      const captureKey = ValueKey('row-capture');
      for (final brightness in Brightness.values) {
        var calls = 0;
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: RepaintBoundary(
                key: captureKey,
                child: PluginView(
                  key: ValueKey('$kind:$brightness'),
                  view: view,
                  onAction: (_) async {
                    calls++;
                    return true;
                  },
                ),
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final row = kind == 'list' ? find.byType(DshUiListBlock) : find.byType(DshUiOptionRow);
        final rect = tester.getRect(row);
        final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(captureKey));
        final point = Offset(rect.center.dx, rect.top + 6) - tester.getTopLeft(find.byKey(captureKey));
        Future<int> pixel() async => (await tester.runAsync(() async {
          final picture = await boundary.toImage();
          try {
            final bytes = (await picture.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
            final i = (point.dy.floor() * picture.width + point.dx.floor()) * 4;
            return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
          } finally {
            picture.dispose();
          }
        }))!;
        final dark = brightness == Brightness.dark;
        final secondary = tester.widget<Text>(find.text('Secondary'));
        expect(secondary.style!.color!.toARGB32() & 0xFFFFFF, style.muted.at(dark));
        expect(await pixel(), style.background.at(dark));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        expect(dshUiContrast(style.muted.at(dark), await pixel()), greaterThanOrEqualTo(4.5));
        final feedback = tester.widget<DecoratedBox>(
          find.descendant(of: row, matching: find.byKey(const ValueKey('plugin-v2-ink-feedback'))),
        );
        expect(((feedback.decoration as ShapeDecoration).shape as OutlinedBorder).side.width, 2);
        final gesture = await tester.startGesture(rect.center);
        await tester.pump(const Duration(milliseconds: 150));
        expect(await pixel(), style.background.at(dark));
        expect(dshUiContrast(style.muted.at(dark), await pixel()), greaterThanOrEqualTo(4.5));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('columns use integer ratios when there is room and stack when narrow', (tester) async {
    usePhoneView(tester);
    final view = {
      'v': 2,
      'type': 'row',
      'style': {
        'columns': [1, 2],
        'dividers': true,
      },
      'children': [
        {
          'type': 'stack',
          'style': {'card': 'surface'},
          'children': [
            {'type': 'text', 'text': 'one'},
          ],
        },
        {
          'type': 'stack',
          'style': {'card': 'surface'},
          'children': [
            {'type': 'text', 'text': 'two'},
          ],
        },
      ],
    };
    final first = find.byKey(const ValueKey('plugin-v2-layout:view.children[0]'));
    final second = find.byKey(const ValueKey('plugin-v2-layout:view.children[1]'));
    tester.view.physicalSize = const Size(1800, 1688);
    await tester.pumpWidget(page(view));
    expect(tester.getRect(first).top, tester.getRect(second).top);
    expect(tester.getSize(second).width / tester.getSize(first).width, closeTo(2, 0.001));
    final divider = find.byKey(const ValueKey('plugin-v2-divider:view:0:1'));
    expect(divider, findsOneWidget);
    expect(tester.getRect(divider).left, greaterThan(tester.getRect(first).right));
    expect(tester.getRect(divider).right, lessThan(tester.getRect(second).left));
    tester.view.physicalSize = const Size(640, 1688);
    await tester.pumpWidget(page(view, scale: 2));
    expect(tester.getRect(second).top, greaterThan(tester.getRect(first).bottom));
    expect(divider, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('text paints the exact corrected colour, spans remain inert, maxLines elides', (tester) async {
    usePhoneView(tester);
    final view = {
      'v': 2,
      'type': 'text',
      'text': 'fallback',
      'style': {'color': '#FFFFFF', 'maxLines': 1},
      'spans': [
        {'text': 'https://example.com ${'long content ' * 30}', 'color': '#FFFFFF', 'background': 'pink'},
      ],
    };
    final parsed = (parsePluginView(view) as DshUiParsed).view;
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(page(view, brightness: brightness));
      await tester.pumpAndSettle();
      final widget = tester.widget<Text>(
        find.descendant(of: find.byType(DshUiStyledText), matching: find.byType(Text)),
      );
      expect(widget.maxLines, 1);
      expect(widget.overflow, TextOverflow.ellipsis);
      final rich = (widget.textSpan! as TextSpan).children!.single as TextSpan;
      final style = parsed.styles['view']!.spans.single;
      expect(rich.style!.color!.toARGB32() & 0xFFFFFF, style.color.at(brightness == Brightness.dark));
      expect(rich.style!.backgroundColor!.toARGB32() & 0xFFFFFF, style.background!.at(brightness == Brightness.dark));
      expect(rich.recognizer, isNull);
    }
  });

  testWidgets('v1 keeps its rendering path, v2 attribution survives unknown hide/position fields', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      page({
        'type': 'text',
        'text': 'v1',
        'style': {'opacity': 0},
      }),
    );
    expect(find.byType(DshUiStyledNode), findsNothing);
    expect(find.byKey(const ValueKey('plugin-v2-boundary')), findsNothing);
    await tester.pumpWidget(
      page({
        'v': 2,
        'type': 'text',
        'text': 'v2',
        'style': {'opacity': 0, 'position': 'fixed', 'top': -1000},
      }),
    );
    expect(find.byKey(const ValueKey('plugin-v2-attribution')), findsOneWidget);
    final boundary = tester.getRect(find.byKey(const ValueKey('plugin-v2-boundary')));
    final attribution = tester.getRect(find.byKey(const ValueKey('plugin-v2-attribution')));
    expect(attribution.top, greaterThan(boundary.top));
    expect(attribution.left - boundary.left, 12);
    expect(boundary.right - attribution.right, 12);
    expect(tester.takeException(), isNull);
  });

  testWidgets('center and end alignment position the actual glyphs across the full row', (tester) async {
    usePhoneView(tester);
    for (final align in ['center', 'end']) {
      await tester.pumpWidget(
        page({
          'v': 2,
          'type': 'stack',
          'children': [
            {
              'type': 'text',
              'text': 'Align',
              'style': {'align': align},
            },
          ],
        }),
      );
      final rich = find.descendant(of: find.byType(DshUiStyledText), matching: find.byType(RichText));
      final paragraph = tester.renderObject<RenderParagraph>(rich);
      final box = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 0, extentOffset: 5)).single;
      expect(
        align == 'center' ? (box.left + box.right) / 2 : box.right,
        closeTo(paragraph.size.width * (align == 'center' ? 0.5 : 1), 0.1),
      );
    }
  });

  testWidgets('nested colours retain readable Material foreground pairs for controls', (tester) async {
    usePhoneView(tester);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        page({
          'v': 2,
          'accent': 'teal',
          'type': 'stack',
          'style': {'card': 'tinted', 'background': '#000000'},
          'children': [
            {'type': 'text', 'text': 'inside'},
          ],
        }, brightness: brightness),
      );
      await tester.pumpAndSettle();
      final colors = Theme.of(tester.element(find.byType(DshUiStyledText))).colorScheme;
      for (final (fg, bg) in [
        (colors.primary, colors.surface),
        (colors.onPrimary, colors.primary),
        (colors.error, colors.surface),
        (colors.onError, colors.error),
      ]) {
        expect(dshUiContrast(fg.toARGB32() & 0xFFFFFF, bg.toARGB32() & 0xFFFFFF), greaterThanOrEqualTo(4.5));
      }
    }
  });

  for (final kind in ['bar', 'hbar', 'donut']) {
    testWidgets('v2 $kind keeps painted category contrast after selecting another category', (tester) async {
      usePhoneView(tester);
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          page({
            'v': 2,
            'type': 'stack',
            'style': {'background': '#000000'},
            'children': [
              {
                'type': 'chart',
                'kind': kind,
                'categories': ['a', 'b', 'c'],
                'series': [
                  {
                    'values': [1, 2, 3],
                  },
                ],
              },
            ],
          }, brightness: brightness),
        );
        final name = kind == 'bar'
            ? '_XYPainter'
            : kind == 'hbar'
            ? '_HBarPainter'
            : '_DonutPainter';
        final finder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == name);
        final box = tester.getRect(finder);
        final before = find.text('b').evaluate().length;
        await tester.tapAt(kind == 'donut' ? Offset(box.right - 20, box.center.dy) : box.center);
        await tester.pumpAndSettle();
        expect(find.text('b').evaluate().length, before + 1, reason: 'selection is active');
        final painter = tester.widget<CustomPaint>(finder).painter!;
        final background = Theme.of(tester.element(finder)).colorScheme.surface.toARGB32() & 0xFFFFFF;
        var categories = 0;
        expect(
          (Canvas canvas) => painter.paint(canvas, box.size),
          paints..everything((method, arguments) {
            if (method == #drawRRect || method == #drawArc) {
              final color = arguments.whereType<Paint>().single.color;
              categories++;
              return color.a == 1 && dshUiContrast(color.toARGB32() & 0xFFFFFF, background) >= 3;
            }
            return true;
          }),
        );
        expect(categories, 3);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('v2 compare and progress paint the checked background; read-only options stay opaque', (tester) async {
    usePhoneView(tester);
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: PluginView(
              view: const {
                'v': 2,
                'type': 'stack',
                'style': {'background': '#000000'},
                'children': [
                  {
                    'type': 'compare',
                    'items': [
                      {
                        'title': 'Plan',
                        'badge': 'Best',
                        'rows': {'Cost': 1},
                      },
                    ],
                  },
                  {'type': 'progress', 'label': 'Progress', 'value': 50, 'max': 100},
                  {
                    'type': 'options',
                    'id': 'choice',
                    'options': [
                      {'label': 'Read-only', 'value': 'a'},
                    ],
                  },
                ],
              },
            ),
          ),
          brightness: brightness,
        ),
      );
      final well = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_CompareWell');
      final decoration =
          tester.widget<DecoratedBox>(find.descendant(of: well, matching: find.byType(DecoratedBox)).first).decoration
              as ShapeDecoration;
      final background = Theme.of(tester.element(well)).colorScheme.surface;
      expect(decoration.color, background);
      final track =
          tester
                  .widget<DecoratedBox>(
                    find.descendant(of: find.byType(DshUiProgressBlock), matching: find.byType(DecoratedBox)).first,
                  )
                  .decoration
              as ShapeDecoration;
      expect(track.color, background);
      expect((track.shape as StadiumBorder).side.width, 1);
      final option = find.byType(DshUiOptionRow);
      final opacity = tester.widget<AnimatedOpacity>(
        find.descendant(of: option, matching: find.byType(AnimatedOpacity)),
      );
      expect(opacity.opacity, 1);
      final target = tester.widget<ConstrainedBox>(
        find.descendant(
          of: option,
          matching: find.byWidgetPredicate((w) => w is ConstrainedBox && w.constraints.minHeight == 48),
        ),
      );
      final padding = target.child! as Padding;
      final outer = tester.getRect(find.byWidget(padding));
      final inner = tester.getRect(find.byWidget(padding.child!));
      expect([
        inner.left - outer.left,
        outer.right - inner.right,
        inner.top - outer.top,
        outer.bottom - inner.bottom,
      ], everyElement(closeTo(12, 0.001)));
      expect(tester.getSize(option).height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('strip flattens styles while retaining an owned attribution', (tester) async {
    usePhoneView(tester);
    await tester.pumpWidget(
      testApp(
        const Scaffold(
          body: PluginView(
            view: {
              'v': 2,
              'type': 'text',
              'text': 'brief',
              'style': {'size': 'display', 'color': '#FFFFFF'},
            },
            budget: PluginViewBudget.strip,
          ),
        ),
      ),
    );
    expect(find.byType(DshUiStyledText), findsNothing);
    expect(find.byKey(const ValueKey('plugin-v2-attribution')), findsOneWidget);
    expect(find.text('brief'), findsOneWidget);
  });
}
