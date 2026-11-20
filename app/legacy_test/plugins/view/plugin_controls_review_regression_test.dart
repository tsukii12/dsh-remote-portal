// Regression cases derived from the independent F2 review; original evidence
// remains separate and unchanged. These tests exercise actual widget layouts.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_model.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_controls.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_controls_state.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/semantics_tap_check.dart';
import 'support.dart';

Future<bool> _ok(PluginAction _) async => true;
Widget _bed(Object view, {Object? data, PluginActionHandler send = _ok, Brightness brightness = Brightness.light}) =>
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: PluginView(view: view, data: data, onAction: send),
        ),
      ),
      brightness: brightness,
    );

double _contrast(Color a, Color b) =>
    (math.max(a.computeLuminance(), b.computeLuminance()) + .05) /
    (math.min(a.computeLuminance(), b.computeLuminance()) + .05);

void _phone(WidgetTester tester, {double scale = 1}) {
  usePhoneView(tester);
  tester.view.physicalSize = const Size(640, 7000);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

/// The stepper's − / + target (both draw a glyph, not a text label).
Finder _step(String path, {required bool up}) => find.descendant(
  of: find.byKey(ValueKey('stepper-${up ? 'up' : 'down'}:$path')),
  matching: find.byType(OutlinedButton),
);

void _inside(Rect child, Rect parent) {
  expect(child.left, greaterThanOrEqualTo(parent.left - .01));
  expect(child.right, lessThanOrEqualTo(parent.right + .01));
  expect(child.top, greaterThanOrEqualTo(parent.top - .01));
  expect(child.bottom, lessThanOrEqualTo(parent.bottom + .01));
}

Map<String, Object?> _deepView() {
  Map<String, Object?> node = {
    'type': 'form',
    'submit': 'save',
    'children': [
      {'type': 'stepper', 'label': 'Count', 'bind': 'data.count', 'min': 0, 'max': 10},
      {'type': 'toggle', 'label': 'Enabled', 'bind': 'data.enabled'},
      {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
      {'type': 'codeBlock', 'language': 'javascript', 'code': 'const n = 1;'},
    ],
  };
  node = {
    'type': 'stack',
    'style': {'padding': 'L'},
    'children': [node],
  };
  node = {
    'type': 'grid',
    'children': [node],
  };
  node = {
    'type': 'timeline',
    'items': [
      {
        'label': 'Step',
        'children': [node],
      },
    ],
  };
  node = {
    'type': 'collapsible',
    'label': 'Details',
    'expanded': true,
    'children': [node],
  };
  node = {
    'type': 'grid',
    'children': [node],
  };
  return {
    'v': 2,
    'type': 'stack',
    'style': {'padding': 'L'},
    'children': [node],
  };
}

void main() {
  setUpAll(loadTestFonts);

  for (final scenario in [
    (name: 'fractional maximum', min: 0.0, max: .9999999999999, step: 1.0, start: 0.0, up: true),
    (name: 'fractional minimum', min: -.9999999999999, max: 0.0, step: 1.0, start: 0.0, up: false),
    (name: 'small positive boundary', min: .000000000123456789, max: 1.0, step: 1.0, start: 1.0, up: false),
  ]) {
    testWidgets('stepper stores the exact valid ${scenario.name}', (tester) async {
      _phone(tester);
      final sent = <PluginAction>[];
      final source = {
        'v': 2,
        'type': 'form',
        'submit': 'save',
        'children': [
          {
            'type': 'stepper',
            'label': 'Count',
            'bind': 'data.count',
            'min': scenario.min,
            'max': scenario.max,
            'step': scenario.step,
          },
        ],
      };
      final parsed = parsePluginView(source, data: {'count': scenario.start}) as DshUiParsed;
      expect(parsed.view.issues.where((i) => i.path != 'view.accent'), isEmpty);
      await tester.pumpWidget(
        _bed(
          source,
          data: {'count': scenario.start},
          send: (a) async {
            sent.add(a);
            return true;
          },
        ),
      );
      await tester.tap(_step('view.children[0]', up: scenario.up));
      await tester.pump();
      final node = tester.widget<DshUiInputView>(find.byType(DshUiInputView)).node;
      final state = PluginControlsScope.maybeOf(tester.element(find.byType(DshUiInputView)))!;
      final actual = state.value(node);
      expect(actual, scenario.up ? scenario.max : scenario.min);
      expect(node.validate(actual), isNull);
      final exhausted = tester.widget<OutlinedButton>(_step('view.children[0]', up: scenario.up));
      expect(exhausted.onPressed, isNull);
      await tester.tap(find.byKey(const ValueKey('submit:view')));
      await tester.pump();
      expect(sent.single.args, {
        'values': {'data.count': actual},
      });
    });
  }

  testWidgets('decimal steps remain monotone and bounded through repeated updates', (tester) async {
    _phone(tester);
    await tester.pumpWidget(
      _bed(
        {'v': 2, 'type': 'stepper', 'label': 'Count', 'bind': 'data.count', 'min': -.3, 'max': .3, 'step': .1},
        data: {'count': -.3},
      ),
    );
    var previous = -.3;
    for (var i = 0; i < 10; i++) {
      final button = tester.widget<OutlinedButton>(_step('view', up: true));
      if (button.onPressed == null) break;
      await tester.tap(_step('view', up: true));
      await tester.pump();
      final node = tester.widget<DshUiInputView>(find.byType(DshUiInputView)).node;
      final next = PluginControlsScope.maybeOf(tester.element(find.byType(DshUiInputView)))!.value(node) as num;
      expect(next, greaterThan(previous));
      expect(next, inInclusiveRange(-.3, .3));
      expect(node.validate(next), isNull);
      previous = next.toDouble();
    }
    expect(previous, .3);
    expect(tester.widget<OutlinedButton>(_step('view', up: true)).onPressed, isNull);
  });

  for (final start in [-1e12, 1e12]) {
    testWidgets('unrepresentable step at $start is disabled without changing a draft', (tester) async {
      _phone(tester);
      await tester.pumpWidget(
        _bed(
          {'v': 2, 'type': 'stepper', 'label': 'Count', 'bind': 'data.count', 'min': -1e12, 'max': 1e12, 'step': 1e-9},
          data: {'count': start},
        ),
      );
      for (final button in tester.widgetList<OutlinedButton>(find.byType(OutlinedButton))) {
        expect(button.onPressed, isNull);
      }
      final node = tester.widget<DshUiInputView>(find.byType(DshUiInputView)).node;
      final state = PluginControlsScope.maybeOf(tester.element(find.byType(DshUiInputView)))!;
      expect(state.value(node), start);
      expect(state.dirty(node.bind!), isFalse);
      expect(node.validate(start), isNull);
    });
  }

  for (final scale in [1.0, 2.0]) {
    testWidgets('a real 80 dp stepper stacks targets at scale $scale', (tester) async {
      _phone(tester, scale: scale);
      const node = DshUiInput(
        path: 'view',
        kind: 'stepper',
        label: 'Count',
        bind: 'data.count',
        value: 1,
        min: 0,
        max: 10,
      );
      final state = PluginDraftController()
        ..syncInputs([node])
        ..setHandler(_ok);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Center(
              child: SizedBox(
                width: 80,
                child: PluginControlsScope(
                  controller: state,
                  child: const DshUiInputView(node: node),
                ),
              ),
            ),
          ),
        ),
      );
      final parent = tester.getRect(find.byType(DshUiInputView));
      expect(parent.width, 80);
      final targets = find.byType(OutlinedButton);
      final first = tester.getRect(targets.at(0)), second = tester.getRect(targets.at(1));
      for (final rect in [first, second]) {
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        _inside(rect, parent);
      }
      expect(second.top, greaterThanOrEqualTo(first.bottom));
      expect(first.size, second.size);
      expect(tester.takeException(), isNull);
    });

    testWidgets('maximum-depth mixed containers preserve controls at 320 dp scale $scale', (tester) async {
      _phone(tester, scale: scale);
      final view = _deepView();
      final parsed = parsePluginView(view, data: {'count': 1, 'enabled': false, 'name': 'A'}) as DshUiParsed;
      expect(
        parsed.view.issues.where((i) => i.path != 'view.accent'),
        isEmpty,
        reason: 'The deep fixture must remain legal, not disappear through fallback',
      );
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(_bed(view, data: {'count': 1, 'enabled': false, 'name': 'A'}));
      await tester.pump();
      expect(find.byType(DshUiInputView), findsNWidgets(3));
      expect(find.byType(SelectableText), findsOneWidget);
      final parent = tester.getRect(find.byType(PluginView));
      for (final finder in [find.byType(OutlinedButton), find.byType(TextField)]) {
        for (final element in finder.evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          _inside(rect, parent);
        }
      }
      final paddings = find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('plugin-control-padding:'),
      );
      expect(paddings, findsWidgets);
      for (final widget in tester.widgetList<Padding>(paddings)) {
        final p = widget.padding.resolve(TextDirection.ltr);
        expect([p.top, p.right, p.bottom], [p.left, p.left, p.left]);
      }
      expectAllButtonsTappable();
      final toggle = find.semantics.byPredicate(
        (node) => !node.isMergedIntoParent && node.getSemanticsData().flagsCollection.isToggled != ui.Tristate.none,
      );
      expect(toggle, findsOneWidget);
      final toggleNode = toggle.evaluate().single;
      expect(toggleNode.rect.width, greaterThanOrEqualTo(48));
      expect(toggleNode.rect.height, greaterThanOrEqualTo(48));
      expect(toggleNode.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
      debugPrint(
        'F2_REPAIR_DEEP scale=$scale inputs=${tester.getRect(find.byType(DshUiInputView).first).width} buttons=${find.byType(OutlinedButton).evaluate().map((e) => tester.getSize(find.byWidget(e.widget))).toList()}',
      );
      semantics.dispose();
      expect(tester.takeException(), isNull);
    });
  }

  for (final brightness in Brightness.values) {
    for (final background in [null, '#000000']) {
      for (final selected in [false, true]) {
        testWidgets('toggle actual paint and focus $brightness background=$background selected=$selected', (
          tester,
        ) async {
          _phone(tester);
          const capture = ValueKey('toggle-raster');
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: _bed(
                {
                  'v': 2,
                  'type': 'stack',
                  'accent': '#FFFF00',
                  if (background != null) 'style': {'background': background},
                  'children': [
                    {'type': 'toggle', 'label': 'Enabled', 'bind': 'data.enabled'},
                  ],
                },
                data: {'enabled': selected},
                brightness: brightness,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final tile = find.byKey(const ValueKey('input:view.children[0]'));
          final toggle = find.byKey(const ValueKey('plugin-toggle-switch'));
          double outlineWidth() => Theme.of(tester.element(toggle)).switchTheme.trackOutlineWidth!.resolve({})!;
          final rect = tester.getRect(toggle);
          final origin = tester.getTopLeft(find.byKey(capture));
          final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
          Future<List<Color>> pixels() async => (await tester.runAsync(() async {
            final image = await boundary.toImage();
            try {
              final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
              Color at(Offset p) {
                p -= origin;
                final i = (p.dy.floor() * image.width + p.dx.floor()) * 4;
                return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
              }

              return [
                at(rect.center.translate(selected ? -14 : 14, 0)),
                at(rect.center.translate(selected ? 10 : -10, -9)),
                at(rect.center.translate(0, 22)),
                at(rect.center.translate(0, -15)),
              ];
            } finally {
              image.dispose();
            }
          }))!;
          final before = await pixels();
          final track = before[0], thumb = before[1], bg = before[2], outline = before[3];
          expect(_contrast(thumb, track), greaterThanOrEqualTo(3));
          expect(math.max(_contrast(track, bg), _contrast(outline, bg)), greaterThanOrEqualTo(3));
          expect(outlineWidth(), 2);
          tester.widget<Switch>(toggle).focusNode!.requestFocus();
          await tester.pumpAndSettle();
          // Focus thickens the track outline; the row itself is never washed.
          expect(outlineWidth(), 3);
          final focused = await pixels();
          expect(focused.take(3), before.take(3), reason: 'Focus must not tint the verified graphic or its surface');
          debugPrint(
            'F2_REPAIR_TOGGLE ${brightness.name} bg=$background on=$selected thumb/track=${_contrast(thumb, track)} boundary/background=${math.max(_contrast(track, bg), _contrast(outline, bg))}',
          );
          final press = await tester.startGesture(tester.getRect(tile).topLeft + const Offset(30, 30));
          await tester.pump(const Duration(milliseconds: 150));
          expect((await pixels()).take(3), before.take(3), reason: 'Press does not tint the checked switch palette');
          await press.cancel();
          await tester.pumpAndSettle();
          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();
          expect(tester.widget<Switch>(toggle).value, !selected);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
