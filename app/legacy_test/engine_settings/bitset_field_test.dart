import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/engine_settings/bitset_field.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/schema_fields.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Object bitsetFixture() => jsonDecode(File('test/engine_settings/fixtures/schemastery-bitset.json').readAsStringSync());

FakeSettingsHost schemaHost(Object schema, {Map<String, Object?> base = const {}}) => FakeSettingsHost(describe: {
  'namespaces': [
    {'ns': 'structure', 'schema': schema, 'value': base, 'base': base, 'revision': 0},
  ],
});

void main() {
  test('real serialized bit masks survive uid decoding, including signed high bit', () {
    final node = SchemaNode.fromJson(bitsetFixture()).fields!['permissions']!;
    expect(node.bits, {'Read': 1, 'Write': 2, 'Execute': 4, 'High': -2147483648});
    expect(kindOf(node), FieldKind.bitset);
    expect(bitsetSummary(node.bits, 3), 'Read · Write');
    expect(
      SchemaNode.fromJson({
        'type': 'bitset',
        'bits': {'x': 4},
      }).bits,
      {'x': 4},
    );
  });

  testWidgets('bitset saves numeric masks, preserves unknown bits, and restores defaults', (tester) async {
    final host = schemaHost(bitsetFixture(), base: {'permissions': 1});
    host.namespaces['structure']!.user = {'permissions': 9};
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'structure'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    await tester.tap(find.text('Permissions'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bit-Write')));
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(host.mutates().last['ops'], [
      {
        'op': 'set',
        'path': ['permissions'],
        'value': 11,
      },
    ]);
    await tester.tap(find.text('Permissions'));
    await settle(tester);
    await tester.tap(find.text('恢复默认'));
    await flush(tester);
    expect(host.mutates().last['ops'], [
      {
        'op': 'unset',
        'path': ['permissions'],
      },
    ]);
  });

  for (final brightness in Brightness.values) {
    testWidgets('bitset narrow large text ${brightness.name}', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final host = schemaHost(bitsetFixture(), base: {'permissions': 1});
      await pumpPage(tester, const EngineSettingsPage(ns: 'structure'),
        overrides: engineOverrides(DshClient.withCarrier(host)), brightness: brightness);
      tester.view.physicalSize = const Size(640, 1800);
      await tester.pump();
      await tester.tap(find.text('Permissions'));
      await settle(tester);
      expect(find.byType(CheckboxListTile), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a refused bitset save leaves the draft open and reports failure', (tester) async {
    final host = schemaHost(bitsetFixture(), base: {'permissions': 1});
    host.beforeMutate = (_) => throw const DshRemoteException('settings/rejected', 'invalid config');
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'structure'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    await tester.tap(find.text('Permissions'));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bit-Write')));
    await tester.tap(find.text('完成'));
    await flush(tester);
    expect(find.byType(BitsetFieldSheet), findsOneWidget);
    expect(find.text(appL10n.commonSaveFailed), findsWidgets);
    expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('bit-Write'))).value, isTrue);
  });
}
