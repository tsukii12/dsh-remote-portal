import 'dart:async';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class HeldDescribeHost extends FakeSettingsHost {
  HeldDescribeHost()
    : super(
        describe: {
          'namespaces': [
            {
              'ns': 'refresh-order',
              'schema': {
                'type': 'object',
                'dict': {
                  'name': {'type': 'string'},
                },
              },
              'base': {'name': 'initial'},
              'value': {'name': 'initial'},
              'revision': 1,
            },
          ],
        },
      );
  Completer<void>? holdNext;
  String heldEndpoint = 'settings/describe';
  bool failNext = false;
  final captured = <Completer<void>>[];
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'settings/describe' && failNext) {
      failNext = false;
      return RpcError(DshRemoteException('test/failure', 'description unavailable'));
    }
    final gate = endpoint == heldEndpoint ? holdNext : null;
    if (gate != null) holdNext = null;
    final response = await super.call(endpoint, args, timeout: timeout);
    if (gate != null) {
      captured.add(gate);
      await gate.future;
    }
    return response;
  }
}

void main() {
  const field = FieldRef('refresh-order', ['name']);
  for (final later in ['refresh', 'acknowledged-write']) {
    test('late same-host describe cannot roll back $later', () async {
      final host = HeldDescribeHost();
      final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
      addTearDown(container.dispose);
      final sub = container.listen(engineSettingsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(engineSettingsProvider.future);
      final controller = container.read(engineSettingsProvider.notifier);
      final gate = host.holdNext = Completer<void>();
      final old = controller.refresh();
      while (host.captured.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      if (later == 'refresh') {
        host.externalSet(field.ns, field.path, 'newer', notify: false);
        await controller.refresh();
      } else {
        expect(await controller.set(field, 'newer'), isTrue);
      }
      expect(container.read(engineSettingsProvider).value!.valueOf(field), 'newer');
      expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 2);
      gate.complete();
      await old;
      expect(container.read(engineSettingsProvider).value!.valueOf(field), 'newer');
      expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 2);
    });
  }

  Future<ProviderContainer> start(HeldDescribeHost host) async {
    final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(engineSettingsProvider.future);
    return container;
  }

  Future<void> waitCaptured(HeldDescribeHost host) async {
    for (var attempt = 0; attempt < 1000 && host.captured.isEmpty; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(host.captured, isNotEmpty, reason: 'the test must actually intercept its target RPC');
  }

  test('ack invalidation re-reads other namespaces and profile permissions', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final gate = host.holdNext = Completer<void>();
    final old = controller.refresh();
    await waitCaptured(host);
    expect(await controller.set(field, 'acknowledged'), isTrue);
    host.writable = false;
    host.namespaces['new-plugin'] = FakeNamespace(
      ns: 'new-plugin',
      schemaJson: {
        'type': 'object',
        'dict': {
          'enabled': {'type': 'boolean'},
        },
      },
      base: {'enabled': true},
      revision: 5,
    );
    gate.complete();
    await old;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.valueOf(field), 'acknowledged');
    expect(state[field.ns]!.revision, 2);
    expect(state.writable, isFalse);
    expect(state['new-plugin']!.revision, 5);
    expect(
      host.calls.where((c) => c.$1 == 'settings/describe'),
      hasLength(3),
      reason: 'initial, invalidated read, fresh retry',
    );
  });

  test('failed latest refresh keeps cache and does not block a subsequent refresh', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.externalSet(field.ns, field.path, 'intermediate', notify: false);
    final gate = host.holdNext = Completer<void>();
    final old = controller.refresh();
    await waitCaptured(host);
    host.failNext = true;
    await expectLater(controller.refresh(), throwsA(isA<DshRemoteException>()));
    gate.complete();
    await old;
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'initial');
    host.externalSet(field.ns, field.path, 'latest', notify: false);
    await controller.refresh();
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'latest');
    expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 3);
  });

  test('late old read cannot restore a superseded dynamic schema', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final gate = host.holdNext = Completer<void>();
    final old = controller.refresh();
    await waitCaptured(host);
    host.namespaces[field.ns] = FakeNamespace(
      ns: field.ns,
      schemaJson: {
        'type': 'object',
        'dict': {
          'name': {'type': 'number'},
        },
      },
      base: {'name': 7},
      revision: 2,
    );
    await controller.refresh();
    expect(container.read(engineSettingsProvider).value!.nodeOf(field)!.type, 'number');
    gate.complete();
    await old;
    expect(container.read(engineSettingsProvider).value!.nodeOf(field)!.type, 'number');
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 7);
  });

  test('refresh preserves a pending optimistic write until its acknowledgement', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.gate = Completer<void>();
    final save = controller.set(field, 'pending');
    await controller.refresh();
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'pending');
    expect(container.read(engineSettingsProvider).value!.isSaving(field), isTrue);
    host.gate!.complete();
    expect(await save, isTrue);
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'pending');
    expect(container.read(engineSettingsProvider).value!.isSaving(field), isFalse);
  });

  test('conflict rejection supersedes an older describe without overwriting external value', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final gate = host.holdNext = Completer<void>();
    final old = controller.refresh();
    await waitCaptured(host);
    host.externalSet(field.ns, field.path, 'external', notify: false);
    expect(await controller.set(field, 'my edit'), isFalse);
    expect(host.mutates(), hasLength(1));
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'external');
    gate.complete();
    await old;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.valueOf(field), 'external');
    expect(state[field.ns]!.revision, 2);
    expect(state.errorOf(field), isNotNull);
    expect(state.isSaving(field), isFalse);
  });

  test('failed reread after acknowledgement retains the confirmed save and remains retryable', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final gate = host.holdNext = Completer<void>();
    final old = controller.refresh();
    await waitCaptured(host);
    expect(await controller.set(field, 'acknowledged'), isTrue);
    host.failNext = true;
    final failure = expectLater(old, throwsA(isA<DshRemoteException>()));
    gate.complete();
    await failure;
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'acknowledged');
    expect(container.read(engineSettingsProvider).value!.isSaving(field), isFalse);
    await controller.refresh();
    expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 2);
  });

  test('description waiting for credentials cannot advance an invisible write revision', () async {
    final host = HeldDescribeHost();
    host.namespaces[field.ns] = FakeNamespace(
      ns: field.ns,
      schemaJson: {
        'type': 'object',
        'dict': {
          'name': {'type': 'string'},
          'password': {
            'type': 'string',
            'meta': {'role': 'secret'},
          },
          'keyRef': {
            'type': 'string',
            'meta': {'role': 'credential-ref', 'default': 'REFRESH_TEST_KEY'},
          },
        },
      },
      base: {'name': 'initial'},
      revision: 1,
    );
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.externalSet(field.ns, field.path, 'external', notify: false);
    host.heldEndpoint = 'credentials/describe';
    final gate = host.holdNext = Completer<void>();
    final read = controller.refresh();
    await waitCaptured(host);
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'initial');
    final accepted = await controller.set(field, 'my edit');
    gate.complete();
    await read;
    expect(accepted, isFalse, reason: 'the edit saw initial; it must conflict with the unseen external value');
    expect(host.mutates().first['expectedRevision'], 1);
    expect(host.namespaces[field.ns]!.value['name'], 'external');
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'external');
  });

  test('refresh during initial build finishes after that build and retains newer data', () async {
    final host = HeldDescribeHost();
    final gate = host.holdNext = Completer<void>();
    final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    final initial = container.read(engineSettingsProvider.future);
    await waitCaptured(host);
    host.externalSet(field.ns, field.path, 'new during build', notify: false);
    final refresh = container.read(engineSettingsProvider.notifier).refresh();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    gate.complete();
    await initial;
    await refresh;
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'new during build');
    expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 2);
  });

  test('repeated acknowledgements bound immediate rereads and defer through existing refresh timer', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final first = host.holdNext = Completer<void>();
    final refresh = controller.refresh();
    await waitCaptured(host);
    expect(await controller.set(field, 'ack one'), isTrue);
    final second = host.holdNext = Completer<void>();
    first.complete();
    for (var attempt = 0; attempt < 1000 && host.captured.length < 2; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(host.captured, hasLength(2));
    expect(await controller.set(field, 'ack two'), isTrue);
    second.complete();
    await refresh;
    expect(host.calls.where((c) => c.$1 == 'settings/describe'), hasLength(3));
    expect(container.read(engineSettingsProvider).value!.valueOf(field), 'ack two');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(host.calls.where((c) => c.$1 == 'settings/describe'), hasLength(4));
    expect(container.read(engineSettingsProvider).value![field.ns]!.revision, 3);
  });

  // The engine pages' queue has the shape of CR-e0b8ece B1 (plugin config):
  // an edit made on top of an earlier one still in flight.
  test('an edit queued behind one refused for a same-field conflict is not sent on the new revision', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.externalSet(field.ns, field.path, 'external', notify: false);
    final first = controller.set(field, 'mine');
    final second = controller.set(field, 'mine again');
    expect(await Future.wait([first, second]), [false, false]);
    expect(host.mutates(), hasLength(1), reason: 'the second edit was made on "mine", which never landed');
    expect(host.namespaces[field.ns]!.value['name'], 'external');
    final state = container.read(engineSettingsProvider).value!;
    expect(state.valueOf(field), 'external');
    expect(state.errorOf(field), isNotNull);
    expect(state.isSaving(field), isFalse);
  });

  test('edits queued on top of each other all land when nothing else changed', () async {
    final host = HeldDescribeHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    final writes = [controller.set(field, 'one'), controller.set(field, 'two'), controller.set(field, 'three')];
    expect(await Future.wait(writes), [true, true, true]);
    expect([for (final m in host.mutates()) m['expectedRevision']], [1, 2, 3]);
    expect(host.namespaces[field.ns]!.value['name'], 'three');
  });
}
