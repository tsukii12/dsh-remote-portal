import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_app/ui/engine_settings/field_sheets.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

FakeSettingsHost scalarHost() => FakeSettingsHost(
  describe: {
    'namespaces': [
      {
        'ns': 'scalar',
        'schema': jsonDecode(File('test/engine_settings/fixtures/schemastery-scalar-save.json').readAsStringSync()),
        'base': {'name': 'inherited', 'count': 2},
        'value': {'name': 'inherited', 'count': 2},
        'revision': 0,
      },
    ],
  },
);

void main() {
  for (final (title, key, changed, sheet) in [
    ('Name', 'text-input', 'draft value', TextFieldSheet),
    (appL10n.engineFieldQuantity, 'number-input', '7', NumberFieldSheet),
  ]) {
    testWidgets('$title rejected save retains draft and retry closes after acknowledgement', (tester) async {
      final host = scalarHost();
      host.beforeMutate = (_) => throw const DshRemoteException('settings/rejected', 'rejected');
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'scalar'),
        overrides: engineOverrides(DshClient.withCarrier(host)),
      );
      await tester.tap(find.text(title));
      await settle(tester);
      await tester.enterText(find.byKey(ValueKey(key)), changed);
      await tester.tap(find.text(appL10n.commonDone));
      await flush(tester);
      expect(find.byType(sheet), findsOneWidget);
      expect(tester.widget<TextField>(find.byKey(ValueKey(key))).controller!.text, changed);
      expect(find.text(appL10n.commonSaveFailed), findsWidgets);
      final ack = Completer<void>();
      host.beforeMutate = (_) => ack.future;
      await tester.tap(find.text(appL10n.commonDone));
      await tester.pump();
      expect(tester.widget<TextField>(find.byKey(ValueKey(key))).enabled, isFalse);
      expect(find.byType(sheet), findsOneWidget);
      ack.complete();
      await flush(tester);
      expect(find.byType(sheet), findsNothing);
    });

    testWidgets('$title failed reset remains open and retries unset', (tester) async {
      final host = scalarHost();
      host.namespaces['scalar']!.user = {'name': 'custom', 'count': 5};
      host.beforeMutate = (_) => throw const DshRemoteException('settings/rejected', 'rejected');
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'scalar'),
        overrides: engineOverrides(DshClient.withCarrier(host)),
      );
      await tester.tap(find.text(title));
      await settle(tester);
      await tester.tap(find.text(appL10n.engineFieldRestoreDefault));
      await flush(tester);
      expect(find.byType(sheet), findsOneWidget);
      host.beforeMutate = null;
      await tester.tap(find.text(appL10n.engineFieldRestoreDefault));
      await flush(tester);
      expect(find.byType(sheet), findsNothing);
      expect((host.mutates().last['ops'] as List).single['op'], 'unset');
    });
  }

  testWidgets('unchanged inherited number closes without a write or error', (tester) async {
    final host = scalarHost();
    await pumpPage(
      tester,
      const EngineSettingsPage(ns: 'scalar'),
      overrides: engineOverrides(DshClient.withCarrier(host)),
    );
    await tester.tap(find.text(appL10n.engineFieldQuantity));
    await settle(tester);
    await tester.tap(find.text(appL10n.commonDone));
    await flush(tester);
    expect(host.mutates(), isEmpty);
    expect(find.byType(NumberFieldSheet), findsNothing);
  });
}
