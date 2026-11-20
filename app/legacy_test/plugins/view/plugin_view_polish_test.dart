// Measured layout for the view-v2 visual polish: equal-height rows, aligned
// fields, selection states, field-like pickers, primary actions and symmetry.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_chart.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_controls.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_row.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_styles.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/semantics_tap_check.dart';

import 'plugin_controls_fixtures.dart';
import 'style_fixtures.dart';
import 'support.dart';

Future<bool> _ok(PluginAction _) async => true;

Widget _bed(Object view, {Object? data, Brightness brightness = Brightness.light}) => testApp(
  Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: PluginView(view: view, data: data, onAction: _ok),
    ),
  ),
  brightness: brightness,
);

void _size(WidgetTester tester, double width, double scale, {double height = 2400}) {
  usePhoneView(tester);
  tester.view.physicalSize = Size(width * 2, height * 2);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

double _contrast(Color a, Color b) =>
    (math.max(a.computeLuminance(), b.computeLuminance()) + .05) /
    (math.min(a.computeLuminance(), b.computeLuminance()) + .05);

/// The nearest painted shape around [finder] (a segment, chip or field).
ShapeDecoration _shape(WidgetTester tester, Finder finder) => tester
    .widgetList<DecoratedBox>(find.ancestor(of: finder, matching: find.byType(DecoratedBox)))
    .map((d) => d.decoration)
    .whereType<ShapeDecoration>()
    .firstWhere((d) => d.color != null);

Color _textColor(WidgetTester tester, String text) =>
    tester.widget<RichText>(find.descendant(of: find.text(text), matching: find.byType(RichText))).text.style!.color!;

FontWeight? _textWeight(WidgetTester tester, String text) => tester
    .widget<RichText>(find.descendant(of: find.text(text), matching: find.byType(RichText)))
    .text
    .style!
    .fontWeight;

const _choices = <String, Object?>{
  'v': 2,
  'type': 'form',
  'submit': 'save',
  'submitLabel': 'Save',
  'children': [
    {
      'type': 'segmented',
      'label': 'Mode',
      'bind': 'data.mode',
      'options': ['Day', 'Week', 'Month'],
    },
    {
      'type': 'chips',
      'label': 'Tags',
      'bind': 'data.tags',
      'multi': true,
      'options': ['Red', 'Green', 'Blue'],
    },
    {'type': 'rating', 'label': 'Score', 'bind': 'data.score', 'max': 5},
  ],
};

const _choiceData = <String, Object?>{
  'mode': 'Week',
  'tags': ['Green'],
  'score': 3,
};

Rect _card(WidgetTester tester, String path) => tester.getRect(find.byKey(ValueKey('plugin-v2-layout:$path')));

Map<String, Object?> _chart() => {
  'type': 'chart',
  'kind': 'donut',
  'categories': ['Alpha', 'Bravo'],
  'series': [
    {
      'values': [1, 2],
    },
  ],
};

Map<String, Object?> _container(String card, List<Object?> children) => {
  'type': 'stack',
  'style': {'card': card},
  'children': children,
};

Finder _keyed(String prefix) =>
    find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith(prefix));

ShapeBorder _border(WidgetTester tester, Finder finder) =>
    (tester.widget<DecoratedBox>(finder).decoration as ShapeDecoration).shape;

void main() {
  setUpAll(loadTestFonts);

  group('8 · equal-height container cards', () {
    for (final brightness in Brightness.values) {
      testWidgets('gallery row cards share top and bottom edges ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(_bed(styleGallery, brightness: brightness));
        await tester.pump();
        final a = _card(tester, 'view.children[3].children[0]');
        final b = _card(tester, 'view.children[3].children[1]');
        expect(a.top, b.top);
        expect(a.bottom, b.bottom);
        expect(a.width, closeTo(b.width, 0.01));
        // Content keeps its natural height at the top of the taller card.
        final value = tester.getRect(find.text('70%'));
        expect(value.top - b.top, lessThan(b.height / 2));
        expect(tester.takeException(), isNull);
      });
    }

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('each wrapped row is equal on its own at 320 dp scale $scale', (tester) async {
        _size(tester, 320, scale);
        await tester.pumpWidget(
          _bed({
            'v': 2,
            'type': 'row',
            'style': {'gap': 'S'},
            'children': [
              {
                'type': 'stack',
                'style': {'card': 'surface', 'padding': 'S'},
                'children': [
                  {'type': 'text', 'text': 'One'},
                ],
              },
              {
                'type': 'stack',
                'style': {'card': 'outlined', 'padding': 'S'},
                'children': [
                  {'type': 'text', 'text': 'Two with a much longer body that wraps over several lines'},
                ],
              },
              {
                'type': 'stack',
                'style': {'card': 'tinted', 'padding': 'S'},
                'children': [
                  {'type': 'text', 'text': 'Three'},
                ],
              },
            ],
          }),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        final rects = [for (var i = 0; i < 3; i++) _card(tester, 'view.children[$i]')];
        final rows = <double, List<Rect>>{};
        for (final r in rects) {
          rows.putIfAbsent(r.top, () => []).add(r);
        }
        for (final row in rows.values) {
          for (final r in row) {
            expect(r.height, closeTo(row.first.height, 0.01));
            expect(r.bottom, closeTo(row.first.bottom, 0.01));
          }
        }
      });
    }

    testWidgets('a plain cell keeps the row alignment beside a card', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'row',
          'style': {'align': 'center'},
          'children': [
            {'type': 'text', 'text': 'Centred'},
            {
              'type': 'stack',
              'style': {'card': 'surface', 'padding': 'L'},
              'children': [
                {'type': 'text', 'text': 'A\nB\nC'},
              ],
            },
          ],
        }),
      );
      await tester.pump();
      final card = _card(tester, 'view.children[1]');
      final text = tester.getRect(find.text('Centred'));
      expect(text.center.dy, closeTo(card.center.dy, 0.5));
    });

    testWidgets('a cell that grows after layout grows its row (grid with a fold)', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'stack',
          'children': [
            {
              'type': 'grid',
              'columns': 2,
              'children': [
                {
                  'type': 'collapsible',
                  'label': 'More',
                  'children': [
                    {'type': 'text', 'text': 'Line one\nLine two\nLine three\nLine four'},
                  ],
                },
                {'type': 'tag', 'text': 'Side'},
              ],
            },
            {'type': 'text', 'text': 'After'},
          ],
        }),
      );
      await tester.pump();
      final row = find.byType(DshUiEqualRow);
      final cells = find.descendant(of: row, matching: find.byType(DshUiCellFill));
      expect(cells, findsNWidgets(2));
      final before = tester.getRect(cells.at(0)).height;
      expect(tester.getRect(cells.at(1)).height, before);
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      final after = [tester.getRect(cells.at(0)), tester.getRect(cells.at(1))];
      expect(after[0].height, greaterThan(before + 40));
      expect(after[1].height, after[0].height);
      expect(
        tester.getRect(find.textContaining('Line four', findRichText: true)).bottom,
        lessThanOrEqualTo(after[0].bottom),
      );
      // Before this change a Table kept the old row height and the opened
      // content painted over the next node.
      expect(tester.getRect(find.text('After')).top, greaterThan(after[0].bottom));
      await tester.tap(find.text('More'));
      await tester.pumpAndSettle();
      expect(tester.getRect(cells.at(0)).height, closeTo(before, 0.01));
      expect(tester.takeException(), isNull);
    });

    for (final kind in ['styled-first', 'chart-first', 'plain-container-first', 'second-card-truncation']) {
      testWidgets('first-cell state survives 2 → 1 → 2 columns: $kind', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(760, 1800);
        addTearDown(tester.view.reset);
        final first = switch (kind) {
          'chart-first' => _chart(),
          'plain-container-first' => _container('plain', [_chart()]),
          _ => _container('surface', [_chart()]),
        };
        final second = _container(
          'outlined',
          kind == 'second-card-truncation'
              ? List.generate(33, (i) => {'type': 'text', 'text': 'Second line $i'})
              : [
                  {'type': 'text', 'text': 'Second'},
                ],
        );
        await tester.pumpWidget(
          _bed({
            'v': 2,
            'type': 'row',
            'style': {
              'columns': [1, 1],
            },
            'children': [first, second],
          }),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bravo'));
        await tester.pumpAndSettle();
        final initial = tester.state(find.byType(DshUiChartView));
        expect(find.text('Bravo'), findsNWidgets(2));
        for (final width in [320.0, 760.0]) {
          tester.view.physicalSize = Size(width, 1800);
          await tester.pumpAndSettle();
          expect(identical(tester.state(find.byType(DshUiChartView)), initial), isTrue, reason: 'width $width');
          expect(find.text('Bravo'), findsNWidgets(2));
          expect(tester.takeException(), isNull);
        }
      });
    }
  });

  group('1 · selected states', () {
    for (final brightness in Brightness.values) {
      testWidgets('segments and chips: tonal fill, accent outline, readable text ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(_bed(_choices, data: _choiceData, brightness: brightness));
        await tester.pump();
        for (final (on, off) in [('Week', 'Day'), ('Green', 'Red')]) {
          final a = _shape(tester, find.text(on)), b = _shape(tester, find.text(off));
          expect(a.color, isNot(b.color), reason: '$on vs $off fill');
          final edge = (a.shape as OutlinedBorder).side;
          expect(edge.width, greaterThanOrEqualTo(1));
          expect(_contrast(edge.color, a.color!), greaterThanOrEqualTo(3), reason: 'selected outline vs its fill');
          expect(_contrast(_textColor(tester, on), a.color!), greaterThanOrEqualTo(4.5));
          expect(_contrast(_textColor(tester, off), b.color!), greaterThanOrEqualTo(4.5));
          expect(_textWeight(tester, on), FontWeight.w600);
          expect(_textWeight(tester, off), FontWeight.w500);
          expect(a.color!.a, 1);
          expect(b.color!.a, 1);
        }
        // A chosen chip also carries a check mark: not colour alone.
        Finder icons(String o) =>
            find.descendant(of: find.byKey(ValueKey('choice:view.children[1]:$o')), matching: find.byType(Icon));
        expect(icons('Green'), findsOneWidget);
        expect(icons('Red'), findsNothing);
        // Selection is never the app's solid approval style.
        expect(find.byType(FilledButton), findsNothing);
        final scheme = Theme.of(tester.element(find.text('Week'))).colorScheme;
        expect(_shape(tester, find.text('Week')).color, isNot(scheme.primary));
      });

      testWidgets('tabs: accent label and one centred indicator bar ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(
          _bed({
            'v': 2,
            'type': 'tabs',
            'items': [
              {
                'label': 'Overview',
                'children': [
                  {'type': 'text', 'text': 'First'},
                ],
              },
              {
                'label': 'Details',
                'children': [
                  {'type': 'text', 'text': 'Second'},
                ],
              },
            ],
          }, brightness: brightness),
        );
        await tester.pump();
        final indicator = find.byKey(const ValueKey('plugin-tab-indicator'));
        expect(indicator, findsOneWidget);
        final on = tester.getRect(find.byKey(const ValueKey('plugin-tab:0')));
        final bar = tester.getRect(indicator);
        expect(bar.bottom, closeTo(on.bottom, 0.01));
        expect(bar.left - on.left, closeTo(on.right - bar.right, 0.01));
        expect(_textColor(tester, 'Overview'), isNot(_textColor(tester, 'Details')));
        expect(_textWeight(tester, 'Overview'), FontWeight.w600);
        expect(
          _contrast(_textColor(tester, 'Details'), Theme.of(tester.element(indicator)).colorScheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        await tester.tap(find.text('Details'));
        await tester.pump();
        expect(find.text('Second'), findsOneWidget);
        expect(tester.getRect(indicator).left, greaterThan(on.right - 1));
      });
    }

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('segments: same-row equal height, equal padding, centred labels, 48 dp at $scale', (tester) async {
        _size(tester, 320, scale);
        await tester.pumpWidget(_bed(_choices, data: _choiceData));
        await tester.pump();
        expect(tester.takeException(), isNull);
        const options = ['Day', 'Week', 'Month'];
        final segments = [for (final o in options) find.byKey(ValueKey('choice:view.children[0]:$o'))];
        final rects = [for (final f in segments) tester.getRect(f)];
        for (final r in rects) {
          expect(r.height, greaterThanOrEqualTo(48));
          expect(r.width, greaterThanOrEqualTo(48));
          for (final other in rects.where((o) => (o.top - r.top).abs() < .01)) {
            expect(other.height, closeTo(r.height, .01));
          }
        }
        for (final (i, o) in options.indexed) {
          final paddingFinder = find.descendant(
            of: segments[i],
            matching: find.byKey(ValueKey('plugin-choice-padding:$i')),
          );
          final p = tester.widget<Padding>(paddingFinder).padding.resolve(TextDirection.ltr);
          expect([p.top, p.right, p.bottom], [p.left, p.left, p.left]);
          final box = tester.getRect(paddingFinder);
          final text = tester.getRect(find.text(o));
          expect(text.center.dx, closeTo(box.center.dx, .5));
          expect(text.center.dy, closeTo(box.center.dy, .5));
        }
        // The track is symmetric: equal inset outside the outer segments.
        final track = tester.getRect(find.byKey(const ValueKey('plugin-segmented-track')));
        final shapes = [
          for (final o in options)
            tester.getRect(find.ancestor(of: find.text(o), matching: find.byType(DecoratedBox)).first),
        ];
        // The painted segments, not just their targets, share a row height.
        for (final r in shapes) {
          for (final other in shapes.where((o) => (o.top - r.top).abs() < .01)) {
            expect(other.height, closeTo(r.height, .01));
          }
        }
        expect(
          shapes.map((r) => r.left).reduce(math.min) - track.left,
          closeTo(track.right - shapes.map((r) => r.right).reduce(math.max), .01),
        );
        expect(
          shapes.map((r) => r.top).reduce(math.min) - track.top,
          closeTo(track.bottom - shapes.map((r) => r.bottom).reduce(math.max), .01),
        );
        // Chips in one run share a height; each chip target is 48 dp.
        final chips = [
          for (final o in ['Red', 'Green', 'Blue']) tester.getRect(find.byKey(ValueKey('choice:view.children[1]:$o'))),
        ];
        for (final c in chips) {
          expect(c.height, greaterThanOrEqualTo(48));
          for (final other in chips.where((o) => (o.top - c.top).abs() < .01)) {
            expect(other.height, closeTo(c.height, .01));
          }
        }
      });
    }

    testWidgets('selection semantics: selected flags, tab roles, every target tappable', (tester) async {
      _size(tester, 390, 1);
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_bed(_choices, data: _choiceData));
      await tester.pump();
      SemanticsData data(String key) => tester.getSemantics(find.byKey(ValueKey(key))).getSemanticsData();
      expect(data('choice:view.children[0]:Week').flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(data('choice:view.children[0]:Day').flagsCollection.isSelected, ui.Tristate.isFalse);
      expect(data('choice:view.children[1]:Green').flagsCollection.isSelected, ui.Tristate.isTrue);
      expectAllButtonsTappable();
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'tabs',
          'items': [
            {
              'label': 'One',
              'children': [
                {'type': 'text', 'text': 'A'},
              ],
            },
            {
              'label': 'Two',
              'children': [
                {'type': 'text', 'text': 'B'},
              ],
            },
          ],
        }),
      );
      await tester.pump();
      expect(data('plugin-tab:0').role, SemanticsRole.tab);
      expect(data('plugin-tab:0').flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(data('plugin-tab:1').flagsCollection.isSelected, ui.Tristate.isFalse);
      expect(data('plugin-tab:1').hasAction(SemanticsAction.tap), isTrue);
      expect(tester.takeException(), isNull);
      handle.dispose();
    });
  });

  group('1 · segment separators', () {
    Map<String, Object?> view(List<String> options, Object? value) => {
      'v': 2,
      'type': 'segmented',
      'label': 'Mode',
      'bind': 'data.mode',
      'options': options,
    };
    Rect shape(WidgetTester tester, String o) =>
        tester.getRect(find.ancestor(of: find.text(o), matching: find.byType(DecoratedBox)).first);

    testWidgets('a hairline only between two unchosen neighbours, centred in their gap', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(_bed(view(['Day', 'Week', 'Month'], 'Day'), data: {'mode': 'Day'}));
      await tester.pump();
      expect(find.byKey(const ValueKey('plugin-segment-separator:1')), findsNothing, reason: 'beside the chosen one');
      final line = find.byKey(const ValueKey('plugin-segment-separator:2'));
      expect(line, findsOneWidget);
      final r = tester.getRect(line);
      final week = shape(tester, 'Week'), month = shape(tester, 'Month');
      expect(r.center.dx, closeTo((week.right + month.left) / 2, .01));
      expect(r.center.dy, closeTo(week.center.dy, .01));
      expect(r.width, 1);
      await tester.pumpWidget(_bed(view(['Day', 'Week', 'Month'], 'Week'), data: {'mode': 'Week'}));
      await tester.pump();
      expect(_keyed('plugin-segment-separator:'), findsNothing);
    });

    for (final scale in [1.0, 1.3]) {
      testWidgets('a short chosen segment is painted as tall as a wrapped neighbour at $scale', (tester) async {
        _size(tester, 390, scale);
        await tester.pumpWidget(_bed(view(['A', 'A longer wrapped option'], 'A'), data: {'mode': 'A'}));
        await tester.pump();
        final a = shape(tester, 'A'), b = shape(tester, 'A longer wrapped option');
        expect(a.top, closeTo(b.top, .01));
        expect(b.height, greaterThan(48), reason: 'the neighbour wraps');
        expect(a.height, closeTo(b.height, .01));
      });
    }

    testWidgets('stacked at 320 dp / 2x: a rule between unchosen rows', (tester) async {
      _size(tester, 320, 2);
      await tester.pumpWidget(_bed(view(['Short', 'A longer choice that wraps'], null)));
      await tester.pump();
      expect(tester.takeException(), isNull);
      final a = shape(tester, 'Short'), b = shape(tester, 'A longer choice that wraps');
      expect(b.top, greaterThan(a.bottom), reason: 'stacked');
      final rule = tester.getRect(find.byKey(const ValueKey('plugin-segment-rule:1')));
      expect(rule.center.dy, closeTo((a.bottom + b.top) / 2, .01));
      expect(rule.left - a.left, closeTo(a.right - rule.right, .01));
      expect(rule.height, 1);
    });
  });

  group('2 · rating stars', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      testWidgets('one row of 48 dp star targets at $width dp / $scale', (tester) async {
        _size(tester, width, scale);
        final handle = tester.ensureSemantics();
        await tester.pumpWidget(_bed(_choices, data: _choiceData));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final stars = [for (var i = 1; i <= 5; i++) find.byKey(ValueKey('rating:view.children[2]:$i'))];
        final rects = [for (final s in stars) tester.getRect(s)];
        for (final r in rects) {
          expect(r.top, rects.first.top, reason: 'never wraps');
          expect(r.width, greaterThanOrEqualTo(48));
          expect(r.height, greaterThanOrEqualTo(48));
        }
        for (var i = 1; i < 5; i++) {
          expect(rects[i].left, closeTo(rects[i - 1].right, .01));
        }
        // The first glyph starts at the same edge as the field label.
        final label = tester.getRect(find.text('Score'));
        final glyph = tester.getRect(find.descendant(of: stars.first, matching: find.byType(Icon)));
        expect(glyph.left, closeTo(label.left, .5));
        final semantics = tester.getSemantics(stars[3]).getSemanticsData();
        expect(semantics.label, contains('4'));
        expect(semantics.hasAction(SemanticsAction.tap), isTrue);
        expect(tester.getSemantics(stars[2]).getSemanticsData().flagsCollection.isSelected, ui.Tristate.isTrue);
        handle.dispose();
      });
    }

    testWidgets('ten stars stay on one row at 320 dp, sharing the width', (tester) async {
      _size(tester, 320, 2);
      await tester.pumpWidget(
        _bed({'v': 2, 'type': 'rating', 'label': 'Score', 'bind': 'data.score', 'max': 10}, data: {'score': 7}),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final rects = [for (var i = 1; i <= 10; i++) tester.getRect(find.byKey(ValueKey('rating:view:$i')))];
      expect(rects.map((r) => r.top).toSet(), hasLength(1));
      expect(rects.last.right, lessThanOrEqualTo(320 - 16));
      for (final r in rects) {
        expect(r.height, greaterThanOrEqualTo(48));
      }
    });

    testWidgets('tapping a star sets that value', (tester) async {
      _size(tester, 390, 1);
      final sent = <PluginAction>[];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SingleChildScrollView(
              child: PluginView(
                view: _choices,
                data: _choiceData,
                onAction: (a) async {
                  sent.add(a);
                  return true;
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('rating:view.children[2]:5')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('submit:view')));
      await tester.pump();
      expect((sent.single.args['values']! as Map)['data.score'], 5);
    });
  });

  group('7 · primary action', () {
    for (final brightness in Brightness.values) {
      testWidgets('form submit is tonal accent with an accent outline, never solid ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(_bed(_choices, data: _choiceData, brightness: brightness));
        await tester.pump();
        final submit = find.byKey(const ValueKey('submit:view'));
        final material = tester.widget<Material>(find.descendant(of: submit, matching: find.byType(Material)).first);
        final scheme = Theme.of(tester.element(find.text('Save'))).colorScheme;
        final fill = material.color!;
        expect(fill.a, 1);
        expect(fill, isNot(scheme.primary), reason: 'a solid accent fill is the app approval style');
        expect(fill, isNot(scheme.surface), reason: 'the main action stands out from the surface');
        final edge = (material.shape! as OutlinedBorder).side;
        expect(_contrast(edge.color, fill), greaterThanOrEqualTo(3));
        expect(_contrast(edge.color, scheme.surface), greaterThanOrEqualTo(3));
        expect(_contrast(_textColor(tester, 'Save'), fill), greaterThanOrEqualTo(4.5));
        expect(find.byType(FilledButton), findsNothing);
        final button = tester.widget<OutlinedButton>(
          find.descendant(of: submit, matching: find.byType(OutlinedButton)),
        );
        final p = button.style!.padding!.resolve({})!.resolve(TextDirection.ltr);
        expect([p.top, p.right, p.bottom], [p.left, p.left, p.left]);
      });

      testWidgets('confirm: the confirm side is the tonal primary, cancel stays outlined ${brightness.name}', (
        tester,
      ) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(
          _bed({
            'v': 2,
            'type': 'confirm',
            'id': 'go',
            'confirmLabel': 'Go',
            'cancelLabel': 'Back',
          }, brightness: brightness),
        );
        await tester.pump();
        final buttons = find.byType(DshUiV2ActionButton);
        expect(buttons, findsNWidgets(2));
        Material material(int i) =>
            tester.widget<Material>(find.descendant(of: buttons.at(i), matching: find.byType(Material)).first);
        expect(material(0).color, Colors.transparent);
        final fill = material(1).color!;
        final scheme = Theme.of(tester.element(find.text('Go'))).colorScheme;
        expect(fill.a, 1);
        expect(fill, isNot(scheme.primary));
        expect(_contrast(_textColor(tester, 'Go'), fill), greaterThanOrEqualTo(4.5));
        expect(tester.getSize(buttons.at(0)).height, tester.getSize(buttons.at(1)).height);
        expect(tester.getTopLeft(buttons.at(0)).dy, tester.getTopLeft(buttons.at(1)).dy);
      });
    }
  });
  group('6 · toggle row alignment', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      for (final brightness in Brightness.values) {
        testWidgets('label on the field-label edge, switch on the input edge $width/$scale ${brightness.name}', (
          tester,
        ) async {
          _size(tester, width, scale, height: 6000);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_bed(inputFixture, data: controlsData, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final fieldLabel = tester.getRect(find.text('Name *'));
          final label = tester.getRect(find.text('Enable notifications'));
          final row = tester.getRect(find.byKey(const ValueKey('input:view.children[4]')));
          final field = tester.getRect(
            find.descendant(
              of: find.byKey(const ValueKey('input:view.children[2]')),
              matching: find.byType(InputDecorator),
            ),
          );
          final toggle = find.byKey(const ValueKey('plugin-toggle-switch'));
          final track = tester.getRect(toggle);
          // The label starts where every other field label starts.
          expect(label.left, closeTo(fieldLabel.left, .5));
          expect(row.left, closeTo(field.left, .01));
          expect(row.right, closeTo(field.right, .01));
          expect(row.height, greaterThanOrEqualTo(48));
          if (track.top >= label.bottom - .01) {
            // Too narrow for one line: the switch sits under the label, same edge.
            expect(track.left, closeTo(label.left, .5));
          } else {
            // The switch track ends where every input ends; both are centred
            // on the 48 dp row.
            expect(track.right, closeTo(field.right, .5));
            expect(track.center.dy, closeTo(row.center.dy, .5));
            expect(label.center.dy, closeTo(row.center.dy, .5));
          }
          // The whole row is one labelled toggle a screen reader can flip.
          final node = tester.getSemantics(toggle).getSemanticsData();
          expect(node.label, contains('Enable notifications'));
          expect(node.flagsCollection.isToggled, ui.Tristate.isTrue);
          expect(node.hasAction(SemanticsAction.tap), isTrue);
          handle.dispose();
        });
      }
    }

    testWidgets('tapping the label flips the switch; focus thickens only the track outline', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(
        _bed({'v': 2, 'type': 'toggle', 'label': 'Alerts', 'bind': 'data.on'}, data: {'on': false}),
      );
      await tester.pump();
      final toggle = find.byKey(const ValueKey('plugin-toggle-switch'));
      await tester.tap(find.text('Alerts'));
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      double width() => Theme.of(tester.element(toggle)).switchTheme.trackOutlineWidth!.resolve({})!;
      expect(width(), 2);
      tester.widget<Switch>(toggle).focusNode!.requestFocus();
      await tester.pump();
      expect(width(), 3);
    });
  });

  group('9 · pickers and the stepper read as inputs', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      for (final brightness in Brightness.values) {
        testWidgets('value on the start edge, icon at the end, text-field outline $width/$scale ${brightness.name}', (
          tester,
        ) async {
          _size(tester, width, scale, height: 6000);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_bed(inputFixture, data: controlsData, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final amount = find.byKey(const ValueKey('input:view.children[2]'));
          final decorator = tester.widget<InputDecorator>(
            find.descendant(of: amount, matching: find.byType(InputDecorator)),
          );
          final enabled = (decorator.decoration.enabledBorder! as OutlineInputBorder).borderSide;
          final editable = tester.getRect(find.descendant(of: amount, matching: find.byType(EditableText)));
          final outer = tester.getRect(find.descendant(of: amount, matching: find.byType(InputDecorator)));
          final inset = editable.left - outer.left;
          final vertical = editable.top - outer.top;
          expect(inset, closeTo(16, .5));
          for (final (key, value, icon) in [
            ('select:view.children[7]', 'A longer second category', AppIcons.expand),
            ('date:view.children[10]', '2026-10-27', AppIcons.calendar),
            ('time:view.children[11]', '09:30', AppIcons.time),
          ]) {
            final picker = find.byKey(ValueKey(key));
            final box = tester.getRect(picker);
            final text = tester.getRect(find.descendant(of: picker, matching: find.text(value)));
            final glyph = tester.getRect(find.descendant(of: picker, matching: find.byType(Icon)));
            // Same width and edges as the text field above it.
            expect(box.left, closeTo(outer.left, .01), reason: key);
            expect(box.right, closeTo(outer.right, .01), reason: key);
            expect(box.height, greaterThanOrEqualTo(48));
            // The value starts where typed text starts; the icon mirrors that inset.
            expect(text.left - box.left, closeTo(inset, .5), reason: key);
            expect(box.right - glyph.right, closeTo(inset, .5), reason: key);
            expect(glyph.center.dy, closeTo(box.center.dy, .5), reason: key);
            expect(text.top - box.top, closeTo(box.bottom - text.bottom, .5), reason: key);
            expect(tester.widget<Icon>(find.descendant(of: picker, matching: find.byType(Icon))).icon, icon);
            // Never truncated, never a button.
            final shown = tester.widget<Text>(find.descendant(of: picker, matching: find.text(value)));
            expect(shown.maxLines, isNull);
            expect(shown.overflow, isNull);
            expect(find.descendant(of: picker, matching: find.byType(OutlinedButton)), findsNothing);
            // The same outline and fill as a text field.
            final material = tester.widget<Material>(
              find.descendant(of: picker, matching: find.byType(Material)).first,
            );
            final side = (material.shape! as OutlinedBorder).side;
            expect(side.color, enabled.color, reason: key);
            expect(side.width, enabled.width, reason: key);
            expect(material.color, decorator.decoration.fillColor);
            expect(_contrast(_textColor(tester, value), material.color!), greaterThanOrEqualTo(4.5));
            // A labelled button for assistive technology, with its value.
            final node = tester.getSemantics(picker).getSemanticsData();
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.label, contains(value));
            expect(node.hasAction(SemanticsAction.tap), isTrue);
          }
          // A single-line picker is exactly as tall as a single-line text field.
          if (scale < 2) {
            expect(
              tester.getRect(find.byKey(const ValueKey('date:view.children[10]'))).height,
              closeTo(editable.height + 2 * vertical, .5),
            );
          }
          // Stepper: one outlined field, − at the start, + at the end, value centred.
          final stepper = find.byKey(const ValueKey('stepper-field:view.children[3]'));
          if (stepper.evaluate().isNotEmpty) {
            final frame = tester.getRect(stepper);
            final down = tester.getRect(find.byKey(const ValueKey('stepper-down:view.children[3]')));
            final up = tester.getRect(find.byKey(const ValueKey('stepper-up:view.children[3]')));
            final value = tester.getRect(find.descendant(of: stepper, matching: find.text('2')));
            expect(frame.left, closeTo(outer.left, .01));
            expect(frame.right, closeTo(outer.right, .01));
            expect(down.left, closeTo(frame.left, .01));
            expect(frame.right, closeTo(up.right, .01));
            expect(down.size, up.size);
            expect(down.height, greaterThanOrEqualTo(48));
            expect(down.width, greaterThanOrEqualTo(48));
            expect(value.center.dx, closeTo(frame.center.dx, .5));
            expect(value.center.dy, closeTo(frame.center.dy, .5));
            if (scale < 2) expect(frame.height, closeTo(editable.height + 2 * vertical, .5));
          }
          // Slider: the label on the field-label edge, the value on the input edge.
          final level = tester.getRect(find.byKey(const ValueKey('slider-value:view.children[5]')));
          expect(level.right, closeTo(outer.right, .5));
          expect(tester.getRect(find.text('Level')).left, closeTo(outer.left, .5));
          expectAllButtonsTappable();
          handle.dispose();
        });
      }
    }

    testWidgets('an empty picker shows a readable placeholder, not a value', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'stack',
          'children': [
            {
              'type': 'select',
              'label': 'Pick',
              'bind': 'data.pick',
              'placeholder': 'Choose one',
              'options': ['A', 'B'],
            },
            {'type': 'date', 'label': 'When', 'bind': 'data.when'},
          ],
        }),
      );
      await tester.pump();
      final valueColor = Theme.of(tester.element(find.text('Choose one'))).colorScheme.onSurface;
      for (final text in ['Choose one', '选择']) {
        final placeholder = find.text(text);
        expect(placeholder, findsOneWidget, reason: text);
        final color = _textColor(tester, text);
        expect(color, isNot(valueColor));
        final material = tester.widget<Material>(find.ancestor(of: placeholder, matching: find.byType(Material)).first);
        expect(_contrast(color, material.color!), greaterThanOrEqualTo(4.5));
      }
    });
  });
  group('3 · folds, tabs and the carousel pager', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      for (final brightness in Brightness.values) {
        testWidgets('fold headers: title, caret and content on one edge $width/$scale ${brightness.name}', (
          tester,
        ) async {
          _size(tester, width, scale, height: 6000);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_bed(structureFixture, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          for (final (path, i, label) in [
            ('view.children[1]', 0, 'Folded content'),
            ('view.children[2]', 0, 'Group A'),
            ('view.children[2]', 1, 'Group B'),
          ]) {
            final group = tester.getRect(find.byKey(ValueKey('plugin-fold:$path')));
            final header = find.byKey(ValueKey('plugin-fold-header:$path:$i'));
            final row = tester.getRect(header);
            final title = tester.getRect(find.text(label));
            final caret = find.descendant(of: header, matching: find.byType(Icon));
            final glyph = tester.getRect(caret);
            expect(row.left, closeTo(group.left, .01));
            expect(row.right, closeTo(group.right, .01));
            expect(row.height, greaterThanOrEqualTo(48));
            // Equal insets: title from the start edge, caret from the end edge.
            expect(title.left - row.left, closeTo(row.right - glyph.right, .5), reason: label);
            expect(title.left - row.left, greaterThan(0));
            expect(glyph.center.dy, closeTo(row.center.dy, .5));
            expect(tester.widget<Icon>(caret).icon, AppIcons.expand);
            final node = tester.getSemantics(header).getSemanticsData();
            expect(node.label, label);
            expect(node.flagsCollection.isButton, isTrue);
            expect(node.flagsCollection.isExpanded, ui.Tristate.isFalse);
            expect(node.hasAction(SemanticsAction.tap), isTrue);
          }
          // Accordion sections share one outline, divided by a hairline.
          final a = tester.getRect(find.byKey(const ValueKey('plugin-fold-header:view.children[2]:0')));
          final b = tester.getRect(find.byKey(const ValueKey('plugin-fold-header:view.children[2]:1')));
          expect(b.top - a.bottom, closeTo(1, .01));
          expect(a.height, closeTo(b.height, .01));
          // Opening turns the caret and reveals content on the title's edge.
          await tester.tap(find.text('Folded content'));
          await tester.pumpAndSettle();
          final header = find.byKey(const ValueKey('plugin-fold-header:view.children[1]:0'));
          expect(tester.getSemantics(header).getSemanticsData().flagsCollection.isExpanded, ui.Tristate.isTrue);
          expect(
            tester.widget<AnimatedRotation>(find.descendant(of: header, matching: find.byType(AnimatedRotation))).turns,
            .5,
          );
          final revealed = tester.getRect(find.text('Revealed content'));
          final group = tester.getRect(find.byKey(const ValueKey('plugin-fold:view.children[1]')));
          expect(revealed.left, closeTo(tester.getRect(find.text('Folded content')).left, .5));
          expect(revealed.top, greaterThanOrEqualTo(tester.getRect(header).bottom));
          expect(group.bottom - revealed.bottom, greaterThanOrEqualTo(revealed.left - group.left - .5));
          expect(tester.takeException(), isNull);
          expectAllButtonsTappable();
          handle.dispose();
        });

        testWidgets('carousel: a light centred pager, no wide buttons $width/$scale ${brightness.name}', (
          tester,
        ) async {
          _size(tester, width, scale, height: 6000);
          final handle = tester.ensureSemantics();
          await tester.pumpWidget(_bed(structureFixture, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          final previous = find.byKey(const ValueKey('carousel-previous:view.children[3]'));
          final next = find.byKey(const ValueKey('carousel-next:view.children[3]'));
          final p = tester.getRect(previous), n = tester.getRect(next);
          final column = tester.getRect(find.byKey(const ValueKey('plugin-fold:view.children[1]')));
          for (final r in [p, n]) {
            expect(r.width, closeTo(48, .01), reason: 'an icon target, not a wide button');
            expect(r.height, closeTo(48, .01));
          }
          expect(p.top, n.top);
          // Centred as a group.
          expect(p.left - column.left, closeTo(column.right - n.right, .5));
          // Icon only, no label text, no idle outline.
          for (final f in [previous, next]) {
            expect(find.descendant(of: f, matching: find.byType(Text)), findsNothing);
            final material = tester.widget<Material>(find.descendant(of: f, matching: find.byType(Material)).first);
            expect((material.shape! as OutlinedBorder).side.color, material.color);
          }
          // Position: dots (wide active dot in the accent) or "1 / 2".
          final dots = find.byKey(const ValueKey('carousel-dots:view.children[3]'));
          if (dots.evaluate().isNotEmpty) {
            final shapes = tester
                .widgetList<AnimatedContainer>(find.descendant(of: dots, matching: find.byType(AnimatedContainer)))
                .toList();
            expect(shapes, hasLength(2));
            final dotRect = tester.getRect(dots);
            expect(dotRect.center.dx, closeTo((p.right + n.left) / 2, .5));
            expect(dotRect.center.dy, closeTo(p.center.dy, .5));
          } else {
            expect(find.text('1 / 2'), findsOneWidget);
          }
          SemanticsData data(Finder f) => tester.getSemantics(f).getSemanticsData();
          expect(data(previous).label, '上一页');
          expect(data(previous).flagsCollection.isEnabled, ui.Tristate.isFalse);
          expect(data(next).label, '下一页');
          expect(data(next).hasAction(SemanticsAction.tap), isTrue);
          final title = find.byKey(const ValueKey('plugin-carousel-title:view.children[3]'));
          expect(data(title).label, 'Page one · 1/2');
          expect(data(title).flagsCollection.isLiveRegion, isTrue);
          await tester.tap(next);
          await tester.pumpAndSettle();
          expect(find.text('Second page'), findsOneWidget);
          expect(data(title).label, 'Page two · 2/2');
          expect(data(next).flagsCollection.isEnabled, ui.Tristate.isFalse);
          expect(data(previous).flagsCollection.isEnabled, ui.Tristate.isTrue);
          // The title starts on the content edge.
          expect(tester.getRect(title).left, closeTo(column.left, .5));
          expectAllButtonsTappable();
          handle.dispose();
        });
      }
    }

    testWidgets('eight pages at 320 dp / 2x still fit one pager row', (tester) async {
      _size(tester, 320, 2);
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'carousel',
          'items': [
            for (var i = 1; i <= 8; i++)
              {
                'label': 'Page $i',
                'children': [
                  {'type': 'text', 'text': 'Body $i'},
                ],
              },
          ],
        }),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      final p = tester.getRect(find.byKey(const ValueKey('carousel-previous:view')));
      final n = tester.getRect(find.byKey(const ValueKey('carousel-next:view')));
      expect(p.top, n.top);
      expect(n.right, lessThanOrEqualTo(320 - 16));
    });
  });

  group('4 · code block header', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      for (final brightness in Brightness.values) {
        testWidgets('language and copy share one centred line $width/$scale ${brightness.name}', (tester) async {
          _size(tester, width, scale, height: 6000);
          final handle = tester.ensureSemantics();
          final copied = <String>[];
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
            if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
            return null;
          });
          addTearDown(
            () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null),
          );
          await tester.pumpWidget(_bed(structureFixture, brightness: brightness));
          await tester.pump();
          expect(tester.takeException(), isNull);
          const path = 'view.children[6]';
          final header = tester.getRect(find.byKey(const ValueKey('plugin-code-header:$path')));
          final language = tester.getRect(find.byKey(const ValueKey('plugin-code-language:$path')));
          final copy = find.byKey(const ValueKey('plugin-code-copy:$path'));
          final target = tester.getRect(copy);
          final code = tester.getRect(find.byType(SelectableText));
          final glyph = tester.getRect(find.descendant(of: find.text('javascript'), matching: find.byType(RichText)));
          expect(header.height, greaterThanOrEqualTo(48));
          // Copy at the far edge, on the language's line, both centred.
          expect(target.right, closeTo(header.right, .01));
          expect(target.top, lessThan(glyph.bottom));
          expect(glyph.top, lessThan(target.bottom));
          expect(target.center.dy, closeTo(header.center.dy, .5));
          expect(glyph.center.dy, closeTo(header.center.dy, .5));
          expect(target.width, greaterThanOrEqualTo(48));
          expect(target.height, greaterThanOrEqualTo(48));
          // The language starts where the code starts.
          expect(language.left, closeTo(code.left, .5));
          expect(language.left - header.left, greaterThan(0));
          // Readable on the header strip.
          final strip = tester.widget<ColoredBox>(find.byKey(const ValueKey('plugin-code-header:$path'))).color;
          expect(_contrast(_textColor(tester, 'javascript'), strip), greaterThanOrEqualTo(4.5));
          final button = tester.widget<OutlinedButton>(
            find.descendant(of: copy, matching: find.byType(OutlinedButton)),
          );
          expect(_contrast(button.style!.foregroundColor!.resolve({})!, strip), greaterThanOrEqualTo(4.5));
          SemanticsData data() => tester.getSemantics(copy).getSemanticsData();
          expect(data().label, '复制');
          expect(data().hasAction(SemanticsAction.tap), isTrue);
          await tester.tap(copy);
          await tester.pump();
          expect(copied.single, contains('console.log(total);'));
          expect(data().label, '已复制');
          expect(tester.takeException(), isNull);
          handle.dispose();
        });
      }
    }
  });

  group('5 · grid badges', () {
    for (final (width, scale) in [(390.0, 1.0), (320.0, 1.3), (320.0, 2.0)]) {
      testWidgets('badges start at the top of every cell with the cell inset $width/$scale', (tester) async {
        _size(tester, width, scale, height: 6000);
        await tester.pumpWidget(_bed(structureFixture));
        await tester.pump();
        expect(tester.takeException(), isNull);
        final cells = [
          tester.getRect(find.byKey(const ValueKey('plugin-grid-cell:view.children[4].children[0]'))),
          tester.getRect(find.byKey(const ValueKey('plugin-grid-cell:view.children[4].children[1]'))),
        ];
        final badges = [
          tester.getRect(find.ancestor(of: find.text('Ready'), matching: _keyed('plugin-badge:'))),
          tester.getRect(find.ancestor(of: find.text('Native'), matching: _keyed('plugin-badge:'))),
        ];
        for (var i = 0; i < 2; i++) {
          expect(badges[i].top - cells[i].top, closeTo(badges[i].left - cells[i].left, .01), reason: 'cell $i');
          expect(badges[i].top - cells[i].top, closeTo(12, .01));
        }
        if ((cells[0].top - cells[1].top).abs() < .01) {
          expect(badges[0].top, closeTo(badges[1].top, .01));
          expect(cells[0].height, closeTo(cells[1].height, .01));
        }
      });
    }

    for (final brightness in Brightness.values) {
      testWidgets('a badge is a quiet tonal label, not an outlined button ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(_bed(structureFixture, brightness: brightness));
        await tester.pump();
        final badge = find.ancestor(of: find.text('Ready'), matching: _keyed('plugin-badge:'));
        final decoration = tester.widget<DecoratedBox>(badge).decoration as ShapeDecoration;
        expect((decoration.shape as OutlinedBorder).side, BorderSide.none);
        final surface = Theme.of(tester.element(badge)).colorScheme.surface;
        expect(decoration.color, isNot(surface));
        expect(decoration.color!.a, 1);
        expect(_contrast(_textColor(tester, 'Ready'), decoration.color!), greaterThanOrEqualTo(4.5));
        expect(find.ancestor(of: find.text('Ready'), matching: find.byType(OutlinedButton)), findsNothing);
        // The text sits centred in the label.
        final box = tester.getRect(badge);
        final text = tester.getRect(find.text('Ready'));
        expect(text.center.dx, closeTo(box.center.dx, .5));
        expect(text.center.dy, closeTo(box.center.dy, .5));
      });
    }

    testWidgets('a lone tag beside a tall cell stays at the top', (tester) async {
      _size(tester, 390, 1);
      await tester.pumpWidget(
        _bed({
          'v': 2,
          'type': 'grid',
          'columns': 2,
          'children': [
            {'type': 'text', 'text': 'One\nTwo\nThree\nFour'},
            {'type': 'tag', 'text': 'Side'},
          ],
        }),
      );
      await tester.pump();
      final cell = tester.getRect(find.byKey(const ValueKey('plugin-grid-cell:view.children[1]')));
      final tag = tester.getRect(find.ancestor(of: find.text('Side'), matching: _keyed('plugin-badge:')));
      expect(tag.top - cell.top, closeTo(tag.left - cell.left, .01));
      expect(cell.bottom - tag.bottom, greaterThan(40));
    });
  });

  group('10 · one system of edges, corners, strokes and type', () {
    for (final brightness in Brightness.values) {
      testWidgets('containers share the app corner and one hairline ${brightness.name}', (tester) async {
        _size(tester, 390, 1);
        await tester.pumpWidget(_bed(structureFixture, brightness: brightness));
        await tester.pump();
        final borders = [
          _border(tester, find.byKey(const ValueKey('plugin-fold:view.children[1]'))),
          _border(tester, find.byKey(const ValueKey('plugin-fold:view.children[2]'))),
          _border(tester, find.byKey(const ValueKey('plugin-grid-cell:view.children[4].children[0]'))),
          _border(tester, find.byKey(const ValueKey('plugin-grid-cell:view.children[4].children[1]'))),
          _border(
            tester,
            find
                .ancestor(
                  of: find.byKey(const ValueKey('plugin-code-header:view.children[6]')),
                  matching: find.byType(DecoratedBox),
                )
                .evaluate()
                .map((e) => e.widget as DecoratedBox)
                .where((d) => d.decoration is ShapeDecoration)
                .map(find.byWidget)
                .first,
          ),
        ];
        final first = borders.first as OutlinedBorder;
        for (final border in borders) {
          expect(border, isA<RoundedSuperellipseBorder>());
          final b = border as RoundedSuperellipseBorder;
          expect(b.borderRadius, (first as RoundedSuperellipseBorder).borderRadius);
          expect(b.side.width, 1);
          expect(b.side.color, first.side.color);
        }
        // The hairline is quieter than an input's edge but still visible.
        final surface = Theme.of(tester.element(find.text('First tab'))).colorScheme.surface;
        expect(_contrast(first.side.color, surface), greaterThan(1.15));
        expect(_contrast(first.side.color, surface), lessThan(3));
      });
    }

    for (final (width, scale) in [(390.0, 1.0), (320.0, 2.0)]) {
      testWidgets('every field label is one style, fields 16 dp apart $width/$scale', (tester) async {
        _size(tester, width, scale, height: 7000);
        await tester.pumpWidget(_bed(inputFixture, data: controlsData));
        await tester.pump();
        final labels = [
          'Name *',
          'Notes',
          'Amount',
          'Count',
          'Level',
          'Range',
          'Category',
          'Mode',
          'Tags',
          'Date',
          'Time',
          'Rating',
        ];
        TextStyle style(String t) =>
            tester.widget<RichText>(find.descendant(of: find.text(t), matching: find.byType(RichText))).text.style!;
        final reference = style(labels.first);
        final left = tester.getRect(find.text(labels.first)).left;
        for (final label in labels) {
          expect(style(label).fontSize, reference.fontSize, reason: label);
          expect(style(label).fontWeight, reference.fontWeight, reason: label);
          expect(style(label).color, reference.color, reason: label);
          expect(tester.getRect(find.text(label)).left, closeTo(left, .5), reason: label);
        }
        final inputs = find.byType(DshUiInputView);
        for (var i = 1; i < inputs.evaluate().length; i++) {
          expect(tester.getRect(inputs.at(i)).top - tester.getRect(inputs.at(i - 1)).bottom, closeTo(16, .01));
        }
      });
    }

    for (final scale in [1.0, 2.0]) {
      testWidgets('cards and grid cells keep their inset on a phone at $scale', (tester) async {
        _size(tester, scale == 1 ? 390 : 320, scale);
        await tester.pumpWidget(_bed(styleGallery));
        await tester.pump();
        // The requested inset survives 2x text at 320 dp: text never touches
        // a tinted or outlined edge.
        for (final (path, inset) in [
          ('view.children[3].children[0]', 12.0),
          ('view.children[3].children[1]', 12.0),
          ('view.children[4]', 16.0),
        ]) {
          final padding = tester.widget<Padding>(find.byKey(ValueKey('plugin-v2-padding:$path')));
          expect(padding.padding, EdgeInsets.all(inset), reason: path);
        }
        await tester.pumpWidget(_bed(structureFixture));
        await tester.pump();
        for (final element in _keyed('plugin-control-padding:view.children[4]').evaluate()) {
          expect(((element.widget as Padding).padding as EdgeInsets).left, 12);
        }
      });
    }
  });
}
