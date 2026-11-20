import 'dart:async';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_app/ui/engine_settings/engine_settings_page.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> affinityDescribe(String value, int revision, {bool credential = false}) => {
  'namespaces': [
    {
      'ns': 'affinity',
      'schema': {
        'type': 'object',
        'dict': {
          if (credential)
            'keyRef': {
              'type': 'string',
              'meta': {'role': 'credential-ref', 'default': 'TEST_KEY'},
            },
          'name': {'type': 'string'},
          'password': {
            'type': 'string',
            'meta': {'role': 'secret'},
          },
        },
      },
      'value': {'name': value},
      'base': {'name': value},
      'revision': revision,
    },
  ],
};
final testHostProvider = StateProvider<HostConnection?>((ref) => null);

class DelayedDescribeHost extends FakeSettingsHost {
  DelayedDescribeHost() : super(describe: affinityDescribe('alpha', 1));
  final describeGate = Completer<void>();
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    final response = await super.call(endpoint, args, timeout: timeout);
    if (endpoint == 'settings/describe') await describeGate.future;
    return response;
  }
}

void main() {
  for (final mode in ['text', 'secret', 'credential']) {
    final secret = mode != 'text';
    testWidgets('old $mode sheet cannot write newly selected host', (tester) async {
      final a = FakeSettingsHost(describe: affinityDescribe('alpha', 1, credential: mode == 'credential'));
      final b = FakeSettingsHost(describe: affinityDescribe('beta', 10, credential: mode == 'credential'));
      final aClient = DshClient.withCarrier(a);
      final bClient = DshClient.withCarrier(b);
      await pumpPage(
        tester,
        const EngineSettingsPage(ns: 'affinity'),
        overrides: [
          ...engineOverrides(aClient).skip(1),
          testHostProvider.overrideWith((ref) => fakeConnection(aClient, local: false)),
          activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(testHostProvider))),
        ],
      );
      final container = ProviderScope.containerOf(tester.element(find.byType(EngineSettingsPage)));
      final controller = container.read(engineSettingsProvider.notifier);
      await tester.tap(find.text(secret ? 'Password' : 'Name'));
      await settle(tester);
      await tester.enterText(find.byKey(ValueKey(secret ? 'secret-input' : 'text-input')), 'draft-for-alpha');
      container.read(testHostProvider.notifier).state = fakeConnection(bClient, local: false);
      await flush(tester);
      expect(identical(controller, container.read(engineSettingsProvider.notifier)), isTrue);
      expect(container.read(engineSettingsProvider).value!.valueOf(const FieldRef('affinity', ['name'])), 'beta');
      await tester.tap(find.text(appL10n.commonDone));
      await flush(tester);
      expect(b.mutates(), isEmpty, reason: 'the open editor belongs to alpha, never beta');
      expect(a.mutates(), isEmpty);
      expect(b.credentials, isEmpty, reason: 'credential-reference secrets retain their original host too');
      expect(a.credentials, isEmpty);
    });
  }

  test('late old describe cannot replace current write revision', () async {
    final a = DelayedDescribeHost();
    final b = FakeSettingsHost(describe: affinityDescribe('beta', 10));
    final aClient = DshClient.withCarrier(a);
    final bClient = DshClient.withCarrier(b);
    final container = ProviderContainer(
      overrides: [
        ...engineOverrides(aClient).skip(1),
        testHostProvider.overrideWith((ref) => fakeConnection(aClient, local: false)),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(testHostProvider))),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(subscription.close);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.calls.where((call) => call.$1 == 'settings/describe'), hasLength(1));
    container.read(testHostProvider.notifier).state = fakeConnection(bClient, local: false);
    await container.read(engineSettingsProvider.future);
    a.describeGate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await container.read(engineSettingsProvider.notifier).set(const FieldRef('affinity', ['name']), 'new beta');
    expect(b.mutates().first['expectedRevision'], 10);
  });
  Future<ProviderContainer> startContainer(DshClient client) async {
    final container = ProviderContainer(
      overrides: [
        ...engineOverrides(client).skip(1),
        testHostProvider.overrideWith((ref) => fakeConnection(client, local: false)),
        activeConnectionProvider.overrideWith((ref) => AsyncData(ref.watch(testHostProvider))),
      ],
    );
    addTearDown(container.dispose);
    final subscription = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(subscription.close);
    await container.read(engineSettingsProvider.future);
    return container;
  }

  Future<void> switchTo(ProviderContainer container, DshClient client) async {
    container.read(testHostProvider.notifier).state = fakeConnection(client, local: false);
    await container.read(engineSettingsProvider.future);
  }

  test('old queued writes do not start after host switch and old completion cannot publish', () async {
    final a = FakeSettingsHost(describe: affinityDescribe('alpha', 1))..gate = Completer<void>();
    final b = FakeSettingsHost(describe: affinityDescribe('beta', 10));
    final aClient = DshClient.withCarrier(a);
    final bClient = DshClient.withCarrier(b);
    final container = await startContainer(aClient);
    final controller = container.read(engineSettingsProvider.notifier);
    const field = FieldRef('affinity', ['name']);
    final first = controller.set(field, 'first alpha');
    final second = controller.set(field, 'second alpha');
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(a.mutates(), hasLength(1));
    await switchTo(container, bClient);
    a.gate!.complete();
    expect(await first, isFalse);
    expect(await second, isFalse);
    expect(
      a.mutates(),
      hasLength(1),
      reason: 'already sent first call may complete, queued second call must not start',
    );
    expect(b.mutates(), isEmpty);
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'beta');
  });

  test('A-B-A using the same client still invalidates the old editor generation', () async {
    final a = FakeSettingsHost(describe: affinityDescribe('alpha', 1));
    final b = FakeSettingsHost(describe: affinityDescribe('beta', 10));
    final aClient = DshClient.withCarrier(a);
    final container = await startContainer(aClient);
    final old = container.read(engineSettingsProvider.notifier).edit(container.read(engineSettingsProvider).value!);
    await switchTo(container, DshClient.withCarrier(b));
    await switchTo(container, aClient);
    expect(await old.set(const FieldRef('affinity', ['name']), 'stale alpha'), isFalse);
    expect(a.mutates(), isEmpty);
  });

  test('loading retains old value but cannot acquire the new host writer', () async {
    final a = FakeSettingsHost(describe: affinityDescribe('alpha', 1));
    final b = DelayedDescribeHost();
    final aClient = DshClient.withCarrier(a);
    final container = await startContainer(aClient);
    final old = container.read(engineSettingsProvider).value!;
    container.read(testHostProvider.notifier).state = fakeConnection(DshClient.withCarrier(b), local: false);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final loading = container.read(engineSettingsProvider);
    expect(loading.isLoading, isTrue);
    expect(identical(loading.value, old), isTrue);
    final controller = container.read(engineSettingsProvider.notifier);
    expect(await controller.edit(loading.value!).set(const FieldRef('affinity', ['name']), 'stale'), isFalse);
    expect(await controller.set(const FieldRef('affinity', ['name']), 'stale direct'), isFalse);
    b.describeGate.complete();
    await container.read(engineSettingsProvider.future);
    expect(b.mutates(), isEmpty);
  });
}
