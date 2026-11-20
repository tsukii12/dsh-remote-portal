import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_app/ui/engine_settings/sequence_field.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Object sequenceFixture() =>
    jsonDecode(File('test/engine_settings/fixtures/schemastery-sequence.json').readAsStringSync());
FakeSettingsHost sequenceHost() => FakeSettingsHost(
  describe: {
    'namespaces': [
      {
        'ns': 'sequence',
        'schema': sequenceFixture(),
        'revision': 0,
        'value': {
          'tuple': ['start', 1, false, 'fast'],
          'toggles': [true],
          'data': {'key': 'value'},
        },
        'base': {
          'tuple': ['start', 1, false, 'fast'],
          'toggles': [true],
          'data': {'key': 'value'},
        },
      },
    ],
  },
);

Future<void> open(WidgetTester tester, FakeSettingsHost host) =>
    pumpPage(tester, const EngineSettingsPage(ns: 'sequence'), overrides: engineOverrides(DshClient.withCarrier(host)));

void main() {
  test('real tuple, boolean array and any schemas have native controls', () {
    final fields = SchemaNode.fromJson(sequenceFixture()).fields!;
    expect(kindOf(fields['tuple']!), FieldKind.sequence);
    expect(kindOf(fields['toggles']!), FieldKind.sequence);
    expect(kindOf(fields['data']!), FieldKind.jsonValue);
    expect(
      kindOf(
        SchemaNode.fromJson({
          'type': 'tuple',
          'list': [
            {
              'type': 'string',
              'meta': {'role': 'secret'},
            },
          ],
        }),
      ),
      FieldKind.readOnly,
      reason: 'never overwrite redacted secrets through a tuple snapshot',
    );
  });

  testWidgets('tuple validates and saves native fields, preserving extra positions', (tester) async {
    final host = sequenceHost();
    host.namespaces['sequence']!.user = {
      'tuple': ['start', 1, false, 'fast', 'tail'],
    };
    await open(tester, host);
    await tester.tap(find.text('Tuple'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('sequence-0')), '');
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(host.mutates(), isEmpty);
    await tester.enterText(find.byKey(const ValueKey('sequence-0')), 'edited');
    await tester.enterText(find.byKey(const ValueKey('sequence-1')), '2');
    await tester.tap(find.byType(SwitchListTile));
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(host.mutates().single['ops'], [
      {
        'op': 'set',
        'path': ['tuple'],
        'value': ['edited', 2, true, 'fast', 'tail'],
      },
    ]);
  });

  testWidgets('boolean array adds, edits and removes with collection bounds', (tester) async {
    final host = sequenceHost();
    await open(tester, host);
    await tester.tap(find.text('Toggles'));
    await settle(tester);
    await tester.tap(find.text(appL10n.commonAdd));
    await settle(tester);
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect((host.mutates().single['ops'] as List).single['value'], [true, false]);
    await tester.tap(find.text('Toggles'));
    await settle(tester);
    await tester.tap(find.byTooltip(appL10n.commonDelete).last);
    await settle(tester);
    await tester.tap(find.byTooltip(appL10n.commonDelete));
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(find.byType(SequenceFieldSheet), findsOneWidget);
    expect(host.mutates(), hasLength(1), reason: 'min=1 refuses an empty list');
  });

  testWidgets('any JSON checks syntax, writes null, and can restore inheritance', (tester) async {
    final host = sequenceHost();
    await open(tester, host);
    await tester.tap(find.text('Data'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('schema-json-input')), '{');
    await tester.tap(find.text('完成'));
    await settle(tester);
    expect(host.mutates(), isEmpty);
    await tester.enterText(find.byKey(const ValueKey('schema-json-input')), 'null');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(host.mutates().single['ops'], [
      {
        'op': 'set',
        'path': ['data'],
        'value': null,
      },
    ]);
    await tester.tap(find.text('Data'));
    await settle(tester);
    final field = tester.widget<TextFormField>(find.byKey(const ValueKey('schema-json-input')));
    expect(field.controller!.text, 'null', reason: 'explicit null must not display the inherited object');
    await tester.tap(find.text('恢复默认'));
    await flush(tester);
    expect(host.mutates().last['ops'], [
      {
        'op': 'unset',
        'path': ['data'],
      },
    ]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('tuple narrow large text ${brightness.name}', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await pumpPage(tester, const EngineSettingsPage(ns: 'sequence'),
        overrides: engineOverrides(DshClient.withCarrier(sequenceHost())), brightness: brightness);
      tester.view.physicalSize = const Size(640, 1800);
      await tester.pump();
      await tester.tap(find.text('Tuple'));
      await settle(tester);
      expect(find.byType(SequenceFieldSheet), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a rejected JSON save preserves draft and supports retry', (tester) async {
    final host = sequenceHost();
    host.beforeMutate = (_) => throw const DshRemoteException('settings/rejected', 'invalid config');
    await open(tester, host);
    await tester.tap(find.text('Data'));
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('schema-json-input')), '[1, true]');
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(find.byType(SequenceFieldSheet), findsOneWidget);
    expect(find.text(appL10n.commonSaveFailed), findsWidgets);
    host.beforeMutate = null;
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(find.byType(SequenceFieldSheet), findsNothing);
    expect((host.mutates().last['ops'] as List).single['value'], [1, true]);
  });
}
