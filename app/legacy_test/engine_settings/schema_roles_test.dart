import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Object roleFixture() => jsonDecode(File('test/engine_settings/fixtures/schemastery-roles.json').readAsStringSync());
FakeSettingsHost roleHost(String key, Object? value) {
  final root = SchemaNode.fromJson(roleFixture());
  // Keep the true serialized refs, changing only the root's field selection
  // so each test can reach a control on a phone without artificial tall views.
  final json = roleFixture() as Map<String, dynamic>;
  final refs = json['refs'] as Map<String, dynamic>;
  final rootJson = refs['${json['uid']}'] as Map<String, dynamic>;
  final dict = rootJson['dict'] as Map<String, dynamic>;
  rootJson['dict'] = {key: dict[key]};
  assert(root.fields!.containsKey(key));
  return FakeSettingsHost(
    describe: {
      'namespaces': [
        {
          'ns': 'roles',
          'schema': json,
          'revision': 0,
          'value': {key: value},
          'base': {key: value},
        },
      ],
    },
  );
}

Future<void> openRole(WidgetTester tester, String key, Object? value) => pumpPage(
  tester,
  const EngineSettingsPage(ns: 'roles'),
  overrides: engineOverrides(DshClient.withCarrier(roleHost(key, value))),
);

void main() {
  test('date and regexp use their serialized string input without running callbacks', () {
    final fields = SchemaNode.fromJson(roleFixture()).fields!;
    expect(kindOf(fields['timestamp']!), FieldKind.text);
    expect(textInputNodeOf(fields['timestamp']!).meta.role, 'datetime');
    expect(kindOf(fields['matcher']!), FieldKind.text);
    expect(textInputNodeOf(fields['matcher']!).meta.role, 'regexp');
    expect(schemaHexColor('#abc'), const Color(0xffaabbcc));
    expect(schemaHexColor('#336699'), const Color(0xff336699));
    expect(schemaHexColor('rebeccapurple'), isNull, reason: 'unknown preview does not reject a schema string');
  });

  for (final key in ['paragraph', 'transformed']) {
    testWidgets('$key textarea has multiline native input', (tester) async {
      await openRole(tester, key, 'line one\nline two');
      await tester.tap(find.text(humanizeKey(key)));
      await settle(tester);
      final input = tester.widget<TextField>(find.byKey(const ValueKey('text-input')));
      expect(input.keyboardType, TextInputType.multiline);
      expect(input.maxLines, greaterThan(1));
    });
  }

  testWidgets('secret role stays write-only', (tester) async {
    await openRole(tester, 'password', null);
    await tester.tap(find.text('Password'));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('secret-input'))).obscureText, isTrue);
  });

  testWidgets('link role requests a URL keyboard', (tester) async {
    await openRole(tester, 'homepage', 'https://example.test');
    await tester.tap(find.text('Homepage'));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).keyboardType, TextInputType.url);
  });

  testWidgets('color role previews and offers native color choices', (tester) async {
    await openRole(tester, 'tint', '#336699');
    await tester.tap(find.text('Tint'));
    await settle(tester);
    expect(
      tester.widget<SchemaColorDot>(find.byKey(const ValueKey('schema-color-preview'))).color,
      const Color(0xff336699),
    );
    await tester.tap(find.byTooltip('#ef4444'));
    await tester.pump();
    expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).controller!.text, '#ef4444');
  });

  testWidgets('percent slider keeps numeric UI', (tester) async {
    await openRole(tester, 'opacity', 0.5);
    await tester.tap(find.text('Opacity'));
    await settle(tester);
    expect(find.byType(Slider), findsOneWidget);
    expect(find.byKey(const ValueKey('number-input')), findsOneWidget);
  });

  testWidgets('radio role remains native choice chips', (tester) async {
    await openRole(tester, 'mode', 'auto');
    expect(find.text('自动'), findsOneWidget);
    expect(find.text('manual'), findsOneWidget);
  });

  testWidgets('table role uses mobile object rows and an item form', (tester) async {
    await openRole(tester, 'rows', [
      {'name': 'first row'},
    ]);
    await tester.tap(find.text('Rows'));
    await settle(tester);
    expect(find.text('first row'), findsWidgets);
    await tester.tap(find.text('first row').first);
    await settle(tester);
    expect(find.byType(TextField), findsWidgets);
  });

  testWidgets('date role opens the native calendar', (tester) async {
    await openRole(tester, 'timestamp', '2026-10-27T12:00:00Z');
    await tester.tap(find.text('Timestamp'));
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('text-input'))).keyboardType, TextInputType.datetime);
    await tester.tap(find.byIcon(AppIcons.calendar));
    await settle(tester);
    expect(find.byType(DatePickerDialog), findsOneWidget);
  });

  testWidgets('regexp role remains editable as text', (tester) async {
    await openRole(tester, 'matcher', r'^test$');
    await tester.tap(find.text('Matcher'));
    await settle(tester);
    expect(find.byKey(const ValueKey('text-input')), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('color role narrow large text ${brightness.name}', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'roles'),
        overrides: engineOverrides(DshClient.withCarrier(roleHost('tint', '#336699'))),
        brightness: brightness,
      );
      tester.view.physicalSize = const Size(640, 1800);
      await tester.pump();
      await tester.tap(find.text('Tint'));
      await settle(tester);
      expect(find.byKey(const ValueKey('schema-color-preview')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('hidden and disabled metadata remain effective', (tester) async {
    await openRole(tester, 'hidden', 'not visible');
    expect(find.text('Hidden'), findsNothing);
    await openRole(tester, 'disabled', false);
    expect(tester.widget<Switch>(find.byType(Switch)).onChanged, isNull);
  });
}
