import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _ns = 'secret-target';
const _field = FieldRef(_ns, ['apiKey']);
const _changed = '此项已变化，请重新打开后编辑。';

FakeNamespace targetNamespace({String? ref = 'TARGET_A', bool field = true, bool secret = true, int revision = 1}) =>
    FakeNamespace(
      ns: _ns,
      schemaJson: {
        'type': 'object',
        'dict': {
          'name': {'type': 'string'},
          if (field)
            'apiKey': {
              'type': 'string',
              if (secret) 'meta': {'role': 'secret'},
            },
          if (ref != null)
            'keyRef': {
              'type': 'string',
              'meta': {'role': 'credential-ref', 'default': ref},
            },
        },
      },
      base: {'name': 'initial'},
      revision: revision,
    );

FakeSettingsHost targetHost({String? ref = 'TARGET_A'}) {
  final host = FakeSettingsHost(
    describe: {
      'namespaces': [targetNamespace(ref: ref).view()],
    },
  );
  host.credentials.addAll({'TARGET_A': 'synthetic-A-existing', 'TARGET_B': 'synthetic-B-existing'});
  host.namespaces[_ns]!.secrets['apiKey'] = 'synthetic-document-existing';
  return host;
}

List<String> mutations(FakeSettingsHost host) => [
  for (final call in host.calls)
    if (const {'credentials/set', 'credentials/unset', 'settings/mutate'}.contains(call.$1)) call.$1,
];

void main() {
  Future<ProviderContainer> start(FakeSettingsHost host) async {
    final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(engineSettingsProvider.future);
    return container;
  }

  for (final change in [
    'A-to-B',
    'ref-to-document',
    'document-to-ref',
    'field-removed',
    'namespace-removed',
    'not-secret',
  ]) {
    for (final action in ['set', 'clear']) {
      test('stale secret $action rejects $change before any mutation', () async {
        final host = targetHost(ref: change == 'document-to-ref' ? null : 'TARGET_A');
        final container = await start(host);
        final controller = container.read(engineSettingsProvider.notifier);
        final old = controller.edit(container.read(engineSettingsProvider).value!);
        if (change == 'namespace-removed') {
          host.namespaces.remove(_ns);
        } else {
          host.namespaces[_ns] = targetNamespace(
            ref: change == 'ref-to-document'
                ? null
                : (change == 'A-to-B' || change == 'document-to-ref' ? 'TARGET_B' : 'TARGET_A'),
            field: change != 'field-removed',
            secret: change != 'not-secret',
            revision: 2,
          );
        }
        await controller.refresh();
        final operation = action == 'set' ? old.setSecret(_field, 'synthetic-old-draft') : old.clearSecret(_field);
        await expectLater(
          operation,
          throwsA(isA<EngineSettingsFailure>().having((e) => e.message, 'message', _changed)),
        );
        expect(mutations(host), isEmpty);
        expect(host.credentials['TARGET_A'], 'synthetic-A-existing');
        expect(host.credentials['TARGET_B'], 'synthetic-B-existing');
      });
    }
  }

  for (final ref in ['TARGET_A', null]) {
    for (final refreshed in [false, true]) {
      test('unchanged ${ref ?? 'document'} target remains writable after unrelated refresh=$refreshed', () async {
        final host = targetHost(ref: ref);
        final container = await start(host);
        final controller = container.read(engineSettingsProvider.notifier);
        final old = controller.edit(container.read(engineSettingsProvider).value!);
        if (refreshed) {
          host.externalSet(_ns, ['name'], 'unrelated update', notify: false);
          await controller.refresh();
        }
        await old.setSecret(_field, 'synthetic-valid-new-value');
        if (ref == null) {
          expect(host.namespaces[_ns]!.secrets['apiKey'], 'synthetic-valid-new-value');
        } else {
          expect(host.credentials[ref], 'synthetic-valid-new-value');
        }
        await old.clearSecret(_field);
        expect(
          ref == null ? host.namespaces[_ns]!.secrets.containsKey('apiKey') : host.credentials.containsKey(ref),
          isFalse,
        );
        expect(mutations(host), hasLength(2));
      });
    }
  }

  test('reopening after a target change explicitly permits the new target', () async {
    final host = targetHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.namespaces[_ns] = targetNamespace(ref: 'TARGET_B', revision: 2);
    await controller.refresh();
    final reopened = controller.edit(container.read(engineSettingsProvider).value!);
    await reopened.setSecret(_field, 'synthetic-intended-for-B');
    expect(host.credentials['TARGET_A'], 'synthetic-A-existing');
    expect(host.credentials['TARGET_B'], 'synthetic-intended-for-B');
  });

  for (final action in ['set', 'clear']) {
    testWidgets('real old secret sheet $action rejects new target and preserves the editor', (tester) async {
      final host = targetHost();
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: _ns),
        overrides: engineOverrides(DshClient.withCarrier(host)),
      );
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 900);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await settle(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(EngineSettingsPage)));
      final controller = container.read(engineSettingsProvider.notifier);
      await tester.tap(find.byKey(const ValueKey('secret-target\u0000apiKey')));
      await settle(tester);
      if (action == 'set') await tester.enterText(find.byKey(const ValueKey('secret-input')), 'synthetic-old-draft');
      host.namespaces[_ns] = targetNamespace(ref: 'TARGET_B', revision: 2);
      await tester.runAsync(controller.refresh);
      await settle(tester);
      await tester.tap(find.text(action == 'set' ? appL10n.commonDone : appL10n.engineFieldRemove));
      await flush(tester);
      expect(mutations(host), isEmpty);
      expect(find.text(_changed), findsOneWidget);
      final input = tester.widget<TextField>(find.byKey(const ValueKey('secret-input')));
      expect(input.enabled, isTrue);
      if (action == 'set') expect(input.controller!.text, 'synthetic-old-draft');
      expect(tester.takeException(), isNull);
    });
  }

  test('stale-target explanation follows English app locale', () async {
    AppLocale.use(AppLocale.en);
    addTearDown(() => AppLocale.use(AppLocale.zhCN));
    final host = targetHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final old = controller.edit(container.read(engineSettingsProvider).value!);
    host.namespaces[_ns] = targetNamespace(ref: 'TARGET_B', revision: 2);
    await controller.refresh();
    await expectLater(
      old.clearSecret(_field),
      throwsA(
        isA<EngineSettingsFailure>().having(
          (e) => e.message,
          'message',
          'This field changed. Reopen it to edit.',
        ),
      ),
    );
    expect(mutations(host), isEmpty);
  });

  test('real schemastery transform wrapper with secret role keeps its unchanged target writable', () async {
    final schema = jsonDecode(File('test/engine_settings/fixtures/schemastery-secret-wrapper.json').readAsStringSync());
    final host = FakeSettingsHost(
      describe: {
        'namespaces': [
          {
            'ns': _ns,
            'schema': schema,
            'base': {'name': 'initial'},
            'value': {'name': 'initial'},
            'revision': 1,
          },
        ],
      },
    );
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final snapshot = container.read(engineSettingsProvider).value!;
    expect(snapshot.nodeOf(_field)!.isSecret, isTrue);
    expect(snapshot.nodeOf(_field)!.effective.isSecret, isFalse);
    await controller.edit(snapshot).setSecret(_field, 'synthetic-wrapper-secret');
    expect(host.credentials['TARGET_A'], 'synthetic-wrapper-secret');
  });
}
