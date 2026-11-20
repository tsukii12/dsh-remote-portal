import 'dart:async';
import 'dart:ui' as ui;

import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_plugin_controls.dart';
import 'package:dsh_app/ui/plugins/view/plugin_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/semantics_tap_check.dart';
import 'plugin_controls_fixtures.dart';
import 'support.dart';

Future<bool> _ok(PluginAction _) async => true;
Widget bed(
  Object view, {
  Object? data,
  PluginActionHandler? send = _ok,
  Brightness brightness = Brightness.light,
  Key? key,
}) => testApp(
  Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: PluginView(key: key, view: view, data: data, onAction: send),
    ),
  ),
  brightness: brightness,
);

void size(WidgetTester tester, double width, double scale) {
  usePhoneView(tester);
  tester.view.physicalSize = Size(width * 2, 844 * 2);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUpAll(loadTestFonts);

  for (final brightness in Brightness.values) {
    testWidgets('focus and press preserve the actual button background $brightness', (tester) async {
      size(tester, 390, 1);
      const capture = ValueKey('button-raster');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: bed({'v': 2, 'type': 'form', 'submit': 'save', 'children': <Object>[]}, brightness: brightness),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('submit:view'));
      final material = find.descendant(of: button, matching: find.byType(Material)).first;
      final expected = tester.widget<Material>(material).color!.toARGB32() & 0xFFFFFF;
      final rect = tester.getRect(button);
      final point = Offset(rect.center.dx, rect.top + 6) - tester.getTopLeft(find.byKey(capture));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      Future<int> pixel() async => (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          final i = (point.dy.floor() * image.width + point.dx.floor()) * 4;
          return (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
        } finally {
          image.dispose();
        }
      }))!;
      expect(await pixel(), expected);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect((tester.widget<Material>(material).shape! as OutlinedBorder).side.width, 2);
      expect(await pixel(), expected);
      final gesture = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 150));
      expect(await pixel(), expected);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('text input hover preserves the painted fill and hint contrast $brightness', (tester) async {
      size(tester, 390, 1);
      const capture = ValueKey('field-raster');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: bed({
            'v': 2,
            'type': 'stack',
            'style': {'background': '#000000'},
            'children': [
              {'type': 'textField', 'label': 'Name', 'placeholder': 'A name', 'bind': 'data.name'},
            ],
          }, brightness: brightness),
        ),
      );
      await tester.pumpAndSettle();
      final field = tester.widget<TextField>(find.byType(TextField));
      final fill = field.decoration!.fillColor!;
      final rect = tester.getRect(find.byType(TextField));
      final point = Offset(rect.right - 12, rect.top + 10) - tester.getTopLeft(find.byKey(capture));
      final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(capture));
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(rect.center);
      await tester.pumpAndSettle();
      expect(tester.widget<InputDecorator>(find.byType(InputDecorator)).isHovering, isTrue);
      final painted = (await tester.runAsync(() async {
        final image = await boundary.toImage();
        try {
          final bytes = (await image.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
          final i = (point.dy.floor() * image.width + point.dx.floor()) * 4;
          return Color.fromARGB(bytes[i + 3], bytes[i], bytes[i + 1], bytes[i + 2]);
        } finally {
          image.dispose();
        }
      }))!;
      expect(painted.toARGB32(), fill.toARGB32());
      final a = field.decoration!.hintStyle!.color!.computeLuminance(), b = painted.computeLuminance();
      expect(a > b ? (a + .05) / (b + .05) : (b + .05) / (a + .05), greaterThanOrEqualTo(4.5));
      await mouse.removePointer();
      expect(tester.takeException(), isNull);
    });

    testWidgets('v2 inputs and highlighted code pair with painted surfaces $brightness', (tester) async {
      size(tester, 390, 1);
      tester.view.physicalSize = const Size(780, 3000);
      await tester.pumpWidget(
        bed({
          'v': 2,
          'type': 'stack',
          'accent': '#FFFF00',
          'style': {'card': 'tinted', 'background': '#000000'},
          'children': [
            {'type': 'textField', 'label': 'Name', 'placeholder': 'A name', 'bind': 'data.name'},
            {'type': 'toggle', 'label': 'Enabled', 'bind': 'data.enabled'},
            {'type': 'codeBlock', 'language': 'js', 'code': '// comment\nconst n = "value" + 42;'},
            {'type': 'codeBlock', 'language': 'diff', 'code': '- old\n+ new'},
            {'type': 'tag', 'text': 'A tag'},
          ],
        }, brightness: brightness),
      );
      await tester.pump();
      void readable(Color foreground, Color background) {
        final a = foreground.computeLuminance(), b = background.computeLuminance();
        final ratio = a > b ? (a + 0.05) / (b + 0.05) : (b + 0.05) / (a + 0.05);
        expect(foreground.a, 1);
        expect(background.a, 1);
        expect(ratio, greaterThanOrEqualTo(4.5));
      }

      final field = tester.widget<TextField>(find.byType(TextField));
      final decorator = tester.widget<InputDecorator>(find.byType(InputDecorator));
      final fill = decorator.decoration.fillColor!;
      readable(field.style!.color!, fill);
      readable(decorator.decoration.hintStyle!.color!, fill);
      readable(decorator.decoration.labelStyle!.color!, fill);
      for (final element in find.byType(SelectableText).evaluate()) {
        final code = element.widget as SelectableText;
        final painted = tester.widget<DecoratedBox>(
          find.ancestor(of: find.byWidget(code), matching: find.byType(DecoratedBox)).first,
        );
        final background = (painted.decoration as BoxDecoration).color!;
        void visit(TextSpan span, Color foreground, Color parentBackground) {
          final color = span.style?.color ?? foreground;
          final bg = span.style?.backgroundColor ?? parentBackground;
          if (span.text?.isNotEmpty == true) readable(color, bg);
          for (final child in span.children ?? const <InlineSpan>[]) {
            if (child is TextSpan) visit(child, color, bg);
          }
        }

        visit(code.textSpan!, field.style!.color!, background);
      }
      for (final element in find.byType(OutlinedButton).evaluate()) {
        final material = tester.widget<Material>(
          find.descendant(of: find.byWidget(element.widget), matching: find.byType(Material)).first,
        );
        final button = element.widget as OutlinedButton;
        readable(button.style!.foregroundColor!.resolve({})!, material.color!);
      }
      expect(tester.takeException(), isNull);
    });

    for (final scale in [1.0, 1.3, 2.0]) {
      testWidgets('all controls fit 320 dp $brightness scale $scale', (tester) async {
        size(tester, 320, scale);
        await tester.pumpWidget(bed(inputFixture, data: controlsData, brightness: brightness));
        await tester.pump();
        expect(tester.takeException(), isNull);
        for (final element in find.byType(OutlinedButton).evaluate()) {
          final rect = tester.getRect(find.byWidget(element.widget));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
        }
        await tester.pumpWidget(bed(structureFixture, brightness: brightness));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'nested grid and bounded code also lay out');
      });
    }
  }

  for (final scale in [1.0, 1.3, 2.0]) {
    testWidgets('measured equal cells and symmetric padding at scale $scale', (tester) async {
      size(tester, 390, scale);
      final buttons = [
        for (final label in ['Short', 'Longer text wraps to more lines'])
          DshUiControlButton(label: label, onPressed: () {}),
      ];
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: DshUiControlChoices(columns: 2, buttons: buttons),
            ),
          ),
        ),
      );
      await tester.pump();
      final found = find.byType(OutlinedButton);
      final a = tester.getRect(found.at(0)), b = tester.getRect(found.at(1));
      debugPrint(
        'F2_GEOMETRY scale=$scale first=${a.size} second=${b.size} sameRow=${(a.top - b.top).abs() < 0.01} padding=12/12/12/12',
      );
      expect(a.width, closeTo(b.width, 0.01));
      if ((a.top - b.top).abs() < 0.01) expect(a.height, closeTo(b.height, 0.01));
      for (var i = 0; i < 2; i++) {
        final finder = found.at(i);
        final button = tester.widget<OutlinedButton>(finder);
        final padding = button.style!.padding!.resolve({})!.resolve(TextDirection.ltr);
        expect([padding.left, padding.top, padding.right, padding.bottom], [12, 12, 12, 12]);
        final rect = tester.getRect(finder);
        final text = tester.getRect(find.descendant(of: finder, matching: find.byType(Text)));
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        expect(text.center.dx, closeTo(rect.center.dx, 0.01));
        expect(text.center.dy, closeTo(rect.center.dy, 0.01));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a partial final row preserves equal outer margins', (tester) async {
    size(tester, 390, 1);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: DshUiControlChoices(
              buttons: [for (var i = 0; i < 5; i++) DshUiControlButton(label: '$i', onPressed: () {})],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final found = find.byType(OutlinedButton);
    final first = tester.getRect(found.at(0));
    final third = tester.getRect(found.at(2));
    final fourth = tester.getRect(found.at(3));
    final fifth = tester.getRect(found.at(4));
    expect(first.left, 16);
    expect(third.right, 374);
    expect(fourth.left, 16);
    expect(fifth.right, 374);
    expect(fourth.width, fifth.width);
    expect(fourth.height, fifth.height);
  });

  testWidgets('local binding updates a derived metric and submits exact values', (tester) async {
    size(tester, 390, 1);
    final sent = <PluginAction>[];
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'number', 'label': 'Quantity', 'bind': 'data.count', 'min': 0, 'max': 100, 'required': true},
        {
          'type': 'metric',
          'label': 'Computed',
          'value': {'=': 'data.count*2'},
        },
      ],
    };
    await tester.pumpWidget(
      bed(
        source,
        data: {'count': 2},
        send: (action) async {
          sent.add(action);
          return true;
        },
      ),
    );
    await tester.enterText(find.byType(TextField), '7');
    await tester.pump();
    expect(find.text('14'), findsWidgets);
    expect(sent, isEmpty);
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await tester.pump();
    expect(sent.single.args, {
      'values': {'data.count': 7.0},
    });
  });

  testWidgets('length limit bounds Unicode scalars, including combining sequences', (tester) async {
    size(tester, 390, 1);
    await tester.pumpWidget(
      bed({'v': 2, 'type': 'textField', 'label': 'Bounded', 'bind': 'data.name', 'maxLength': 4}),
    );
    await tester.enterText(find.byType(TextField), 'a\u0301\u0301\u0301\u0301\u0301');
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text.runes.length, 4);
    expect(find.text('4/4'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('inline validation prevents submit and retains the draft on failure', (tester) async {
    size(tester, 390, 1);
    var sent = 0;
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'textField', 'label': 'Name', 'bind': 'data.name', 'required': true, 'minLength': 2},
      ],
    };
    await tester.pumpWidget(
      bed(
        source,
        data: {'name': ''},
        send: (_) async {
          sent++;
          return false;
        },
      ),
    );
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await tester.pump();
    expect(sent, 0);
    expect(find.text('请填写此项'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Local draft');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await tester.pump();
    expect(sent, 1);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'Local draft');
    expect(find.text('未保存，请重试'), findsWidgets);
  });

  testWidgets('segmented, chips, toggle, stepper and select change local values', (tester) async {
    size(tester, 390, 1);
    tester.view.physicalSize = const Size(780, 3000);
    final sent = <PluginAction>[];
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {
          'type': 'segmented',
          'label': 'Mode',
          'bind': 'data.mode',
          'options': ['A', 'B'],
        },
        {
          'type': 'chips',
          'label': 'Tags',
          'bind': 'data.tags',
          'options': ['one', 'two'],
          'multi': true,
        },
        {'type': 'toggle', 'label': 'Enabled', 'bind': 'data.enabled'},
        {'type': 'stepper', 'label': 'Count', 'bind': 'data.count', 'min': 0, 'max': 5},
        {
          'type': 'select',
          'label': 'Select',
          'bind': 'data.select',
          'options': ['Alpha', 'Beta'],
        },
      ],
    };
    await tester.pumpWidget(
      bed(
        source,
        data: {
          'mode': 'A',
          'tags': ['one'],
          'enabled': false,
          'count': 1,
          'select': 'Alpha',
        },
        send: (a) async {
          sent.add(a);
          return true;
        },
      ),
    );
    await tester.tap(find.text('B'));
    await tester.tap(find.text('two'));
    await tester.tap(find.text('Enabled'));
    await tester.tap(find.byKey(const ValueKey('stepper-up:view.children[3]')));
    await tester.tap(find.byKey(const ValueKey('select:view.children[4]')));
    await tester.pumpAndSettle();
    expect(find.text('插件选项'), findsOneWidget);
    await tester.tap(find.text('Beta').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await tester.pump();
    expect(sent.single.args, {
      'values': {
        'data.mode': 'B',
        'data.tags': ['one', 'two'],
        'data.enabled': true,
        'data.count': 2.0,
        'data.select': 'Beta',
      },
    });
  });

  testWidgets('tabs, folds and carousel navigate locally without invokes', (tester) async {
    size(tester, 390, 1);
    tester.view.physicalSize = const Size(780, 4000);
    var calls = 0;
    await tester.pumpWidget(
      bed(
        structureFixture,
        send: (_) async {
          calls++;
          return true;
        },
      ),
    );
    expect(find.text('First tab'), findsOneWidget);
    await tester.tap(find.text('Details'));
    await tester.pump();
    expect(find.text('Second tab'), findsOneWidget);
    expect(find.text('First tab'), findsNothing);
    await tester.tap(find.text('Folded content'));
    await tester.pump();
    expect(find.text('Revealed content'), findsOneWidget);
    await tester.tap(find.text('Group B'));
    await tester.pump();
    expect(find.text('Group B content'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('carousel-next:view.children[3]')));
    await tester.pump();
    expect(find.text('Second page'), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('native date and time pickers, rating and range feed the form', (tester) async {
    size(tester, 390, 1);
    final sent = <PluginAction>[];
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'date', 'label': 'Date', 'bind': 'data.date'},
        {'type': 'time', 'label': 'Time', 'bind': 'data.time'},
        {'type': 'rating', 'label': 'Rating', 'bind': 'data.rating', 'max': 5},
        {'type': 'slider', 'label': 'Range', 'bind': 'data.range', 'range': true},
      ],
    };
    await tester.pumpWidget(
      bed(
        source,
        data: {
          'date': '2026-10-27',
          'time': '09:30',
          'rating': 2,
          'range': [10, 80],
        },
        send: (a) async {
          sent.add(a);
          return true;
        },
      ),
    );
    await tester.tap(find.text('2026-10-27'));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    expect(find.text('插件日期'), findsOneWidget);
    await tester.tap(find.text('29').first);
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    expect(find.text('2026-10-29'), findsOneWidget);
    await tester.tap(find.text('09:30'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TimePickerDialog>(find.byType(TimePickerDialog)).initialTime,
      const TimeOfDay(hour: 9, minute: 30),
    );
    await tester.tap(find.text('确定').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rating:view.children[2]:4')));
    tester.widget<RangeSlider>(find.byType(RangeSlider)).onChanged!(const RangeValues(20, 90));
    await tester.pump();
    final submit = find.byKey(const ValueKey('submit:view'));
    await tester.ensureVisible(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(sent.single.args, {
      'values': {
        'data.date': '2026-10-29',
        'data.time': '09:30',
        'data.rating': 4,
        'data.range': [20.0, 90.0],
      },
    });
  });

  testWidgets('dropdown keeps host attribution visible with large text and long options', (tester) async {
    size(tester, 320, 2);
    await tester.pumpWidget(
      bed({
        'v': 2,
        'type': 'select',
        'label': 'Choice',
        'bind': 'data.choice',
        'options': [
          for (var i = 0; i < 24; i++) {'label': 'A descriptive option number $i', 'value': '$i'},
        ],
      }, brightness: Brightness.dark),
    );
    await tester.tap(find.byKey(const ValueKey('select:view')));
    await tester.pumpAndSettle();
    expect(find.text('插件选项'), findsOneWidget);
    final header = tester.getRect(find.text('插件选项'));
    final menuMaterial = tester.widget<Material>(
      find.ancestor(of: find.text('插件选项'), matching: find.byType(Material)).first,
    );
    expect(menuMaterial.color!.a, 1);
    expect(menuMaterial.surfaceTintColor, Colors.transparent);
    final scroll = find
        .ancestor(of: find.byType(MenuItemButton).first, matching: find.byType(SingleChildScrollView))
        .first;
    await tester.drag(scroll, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(tester.getRect(find.text('插件选项')), header);
    for (final element in find.byType(MenuItemButton).evaluate()) {
      expect(tester.getSize(find.byWidget(element.widget)).height, greaterThanOrEqualTo(48));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('host date and time dialogs fit a narrow display at 2x text', (tester) async {
    size(tester, 320, 2);
    await tester.pumpWidget(
      bed(
        {
          'v': 2,
          'type': 'stack',
          'children': [
            {'type': 'date', 'label': 'Date', 'bind': 'data.date'},
            {'type': 'time', 'label': 'Time', 'bind': 'data.time'},
          ],
        },
        data: {'date': '2026-10-27', 'time': '09:30'},
      ),
    );
    await tester.tap(find.text('2026-10-27'));
    await tester.pumpAndSettle();
    expect(find.text('插件日期'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('09:30'));
    await tester.tap(find.text('09:30'));
    await tester.pumpAndSettle();
    expect(find.text('插件时间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
  });

  testWidgets('remote patch redraws normalized values and offline keeps drafts', (tester) async {
    size(tester, 390, 1);
    Object data = {'name': 'remote'};
    var online = true;
    late StateSetter hostSetState;
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
      ],
    };
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return PluginView(
                key: const ValueKey('one-panel'),
                view: source,
                data: data,
                onAction: !online
                    ? null
                    : (a) async {
                        setState(() => data = {'name': 'NORMALIZED'});
                        return true;
                      },
              );
            },
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'draft');
    await tester.pump();
    hostSetState(() => online = false);
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'draft');
    hostSetState(() => online = true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('submit:view')));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'NORMALIZED');
  });

  testWidgets('tool-card budget disables inputs even with an invoke callback', (tester) async {
    size(tester, 390, 1);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: PluginView(
            view: {
              'v': 2,
              'type': 'form',
              'submit': 'save',
              'children': [
                {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
              ],
            },
            budget: PluginViewBudget.toolCard,
            onAction: _ok,
          ),
        ),
      ),
    );
    expect(tester.widget<TextField>(find.byType(TextField)).readOnly, isTrue);
    expect(find.byKey(const ValueKey('submit:view')), findsNothing);
  });

  testWidgets('screen reader buttons act; text fields have labels and keyboard focus', (tester) async {
    size(tester, 390, 1);
    final handle = tester.ensureSemantics();
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
        {
          'type': 'segmented',
          'label': 'Mode',
          'bind': 'data.mode',
          'options': ['A', 'B'],
        },
      ],
    };
    await tester.pumpWidget(bed(source));
    await tester.pump();
    expectAllButtonsTappable();
    expect(find.bySemanticsLabel('Name'), findsWidgets);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, isNotNull);
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus, isTrue);
    expect(tester.takeException(), isNull);
    handle.dispose();
  });

  testWidgets('busy submit preserves its actual rectangle', (tester) async {
    size(tester, 390, 1.3);
    final response = Completer<bool>();
    final source = {
      'v': 2,
      'type': 'form',
      'submit': 'save',
      'children': [
        {'type': 'textField', 'label': 'Name', 'bind': 'data.name'},
      ],
    };
    await tester.pumpWidget(bed(source, send: (_) => response.future));
    final submit = find.byKey(const ValueKey('submit:view'));
    final before = tester.getRect(submit);
    await tester.tap(submit);
    await tester.pump();
    expect(tester.getRect(submit), before);
    response.complete(true);
    await tester.pump();
  });
}
