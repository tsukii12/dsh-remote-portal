import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_app/ui/engine_settings/numeric_edit_math.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Object numericFixture() =>
    jsonDecode(File('test/engine_settings/fixtures/schemastery-numeric-editor.json').readAsStringSync());
Future<FakeSettingsHost> openNumber(WidgetTester tester, String key) async {
  final schema = numericFixture() as Map<String, dynamic>;
  final node = SchemaNode.fromJson(schema).fields![key]!;
  final root = (schema['refs'] as Map)['${schema['uid']}'] as Map;
  root['dict'] = {key: (root['dict'] as Map)[key]};
  final host = FakeSettingsHost(
    describe: {
      'namespaces': [
        {
          'ns': 'number',
          'schema': schema,
          'base': {key: node.meta.defaultValue},
          'value': {key: node.meta.defaultValue},
          'revision': 0,
        },
      ],
    },
  );
  await pumpPage(
    tester,
    const EngineSettingsPage(ns: 'number'),
    overrides: engineOverrides(DshClient.withCarrier(host)),
  );
  await tester.tap(find.text(labelFor(key, node, const FieldCopy())));
  await settle(tester);
  return host;
}

String numberText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const ValueKey('number-input'))).controller!.text;

void main() {
  test('decimal UI steps avoid rounding tails and reject overflow', () {
    expect(decimalStepValue(0.1, 0.1, 2), 0.3);
    expect(decimalStepValue(0.5, 1, 2), 2.5);
    expect(decimalStepValue(0.2, 0.1, -1), 0.1);
    expect(decimalStepValue(1e-7, 1e-7, 2), 3e-7);
    expect(decimalStepValue(1e308, 1e308, 1), isNull);
    expect(schemaSliderDivisions(0, 1, .3), isNull);
    expect(schemaSliderDivisions(.5, 3.5, -1), 3);
    expect(validateNumber('1e308', const SchemaMeta(), FieldUnit.milliseconds), isNotNull);
  });

  for (final (key, expected) in [('precise', 0.123456789), ('huge', 1e20)]) {
    testWidgets('$key retains full input precision and done does not overwrite', (tester) async {
      final host = await openNumber(tester, key);
      expect(num.parse(numberText(tester)), expected);
      await tester.tap(find.text(appL10n.commonDone));
      await flush(tester);
      expect(host.mutates(), isEmpty);
      expect(find.byType(NumberFieldSheet), findsNothing);
    });
  }

  testWidgets('slider preserves fractional origin with integral step', (tester) async {
    await openNumber(tester, 'offset');
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.divisions, 3);
    slider.onChanged!(1.5);
    await tester.pump();
    expect(numberText(tester), '1.5');
  });

  testWidgets('stepper honors actual stored millisecond and percent increments', (tester) async {
    await openNumber(tester, 'timeoutMs');
    await tester.tap(find.byKey(const ValueKey('step-up')));
    await tester.pump();
    expect(numberText(tester), '0.11');
    await tester.tap(find.text(appL10n.commonDone));
    await flush(tester);
    await openNumber(tester, 'ratio');
    await tester.tap(find.byKey(const ValueKey('step-up')));
    await tester.pump();
    expect(numberText(tester), '30');
  });

  testWidgets('uneven range does not offer a slider with invalid intermediate values', (tester) async {
    await openNumber(tester, 'uneven');
    expect(find.byType(Slider), findsNothing);
    await tester.tap(find.byKey(const ValueKey('step-up')));
    await tester.pump();
    expect(numberText(tester), '0.3');
  });

  testWidgets('overflowing milliseconds produce validation error without crashing or writing', (tester) async {
    final host = await openNumber(tester, 'timeoutMs');
    await tester.enterText(find.byKey(const ValueKey('number-input')), '1e308');
    await tester.tap(find.text(appL10n.commonDone));
    await flush(tester);
    expect(host.mutates(), isEmpty);
    expect(find.text(appL10n.engineFieldEnterNumeric), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
