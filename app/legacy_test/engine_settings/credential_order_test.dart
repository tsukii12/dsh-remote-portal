import 'dart:async';

import 'package:dsh_app/state/engine_settings_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

class HeldCredentialHost extends FakeSettingsHost {
  HeldCredentialHost()
    : super(
        describe: {
          'namespaces': [
            {
              'ns': 'credential-order',
              'schema': {
                'type': 'object',
                'dict': {
                  'name': {'type': 'string'},
                  'apiKey': {
                    'type': 'string',
                    'meta': {'role': 'secret'},
                  },
                  'keyRef': {
                    'type': 'string',
                    'meta': {'role': 'credential-ref', 'default': 'ORDER_TEST_KEY'},
                  },
                },
              },
              'value': {'name': 'initial'},
              'base': {'name': 'initial'},
              'revision': 1,
            },
          ],
        },
      );
  Completer<void>? nextCredential;
  bool failNextCredential = false;
  Completer<void>? captured;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'credentials/describe' && failNextCredential) {
      failNextCredential = false;
      return RpcError(DshRemoteException('test/failure', 'credential status unavailable'));
    }
    final gate = endpoint == 'credentials/describe' ? nextCredential : null;
    if (gate != null) nextCredential = null;
    final response = await super.call(endpoint, args, timeout: timeout);
    if (gate != null) {
      captured!.complete();
      await gate.future;
    }
    return response;
  }
}

void main() {
  const key = FieldRef('credential-order', ['apiKey']);
  for (final newer in ['clear', 'full-refresh-environment']) {
    test('old credential status cannot overwrite newer $newer status', () async {
      final host = HeldCredentialHost();
      final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
      addTearDown(container.dispose);
      final sub = container.listen(engineSettingsProvider, (_, _) {});
      addTearDown(sub.close);
      await container.read(engineSettingsProvider.future);
      final controller = container.read(engineSettingsProvider.notifier);
      host.captured = Completer<void>();
      final gate = host.nextCredential = Completer<void>();
      final old = controller.setSecret(key, 'synthetic-test-only');
      await host.captured!.future.timeout(const Duration(seconds: 2));
      if (newer == 'clear') {
        await controller.clearSecret(key);
        expect(host.credentials, isEmpty);
        expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isFalse);
      } else {
        host.envCredentials.add('ORDER_TEST_KEY');
        await controller.refresh();
        expect(container.read(engineSettingsProvider).value!.secretWritable(key), isFalse);
      }
      gate.complete();
      await old;
      if (newer == 'clear') {
        expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isFalse);
      } else {
        expect(container.read(engineSettingsProvider).value!.secretWritable(key), isFalse);
      }
    });
  }

  Future<ProviderContainer> start(HeldCredentialHost host) async {
    final container = ProviderContainer(overrides: engineOverrides(DshClient.withCarrier(host)));
    addTearDown(container.dispose);
    final sub = container.listen(engineSettingsProvider, (_, _) {});
    addTearDown(sub.close);
    await container.read(engineSettingsProvider.future);
    return container;
  }

  test('old full refresh publishes namespace changes but preserves newer cleared credential status', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    await controller.setSecret(key, 'synthetic-test-only');
    host.externalSet(key.ns, ['name'], 'new namespace value', notify: false);
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final old = controller.refresh();
    await host.captured!.future.timeout(const Duration(seconds: 2));
    await controller.clearSecret(key);
    expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isFalse);
    gate.complete();
    await old;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.secretConfigured(key), isFalse);
    expect(state.valueOf(const FieldRef('credential-order', ['name'])), 'new namespace value');
    expect(state[key.ns]!.revision, 2);
  });

  test('latest credential failure retains last known status while namespaces refresh and next read recovers', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    await controller.setSecret(key, 'synthetic-first');
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final oldClear = controller.clearSecret(key);
    await host.captured!.future.timeout(const Duration(seconds: 2));
    await controller.setSecret(key, 'synthetic-later');
    host.externalSet(key.ns, ['name'], 'new value despite status failure', notify: false);
    host.failNextCredential = true;
    await controller.refresh();
    final state = container.read(engineSettingsProvider).value!;
    gate.complete();
    await oldClear;
    expect(state.secretConfigured(key), isTrue);
    expect(state.valueOf(const FieldRef('credential-order', ['name'])), 'new value despite status failure');
    expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isTrue);
    await controller.clearSecret(key);
    expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isFalse);
  });

  test('initial credential failure does not leak another snapshot and is recoverable', () async {
    final host = HeldCredentialHost()..failNextCredential = true;
    final container = await start(host);
    expect(container.read(engineSettingsProvider).value!.credentials, isEmpty);
    await container.read(engineSettingsProvider.notifier).setSecret(key, 'synthetic-test-only');
    expect(container.read(engineSettingsProvider).value!.secretConfigured(key), isTrue);
  });

  test('late credential-only read cannot restore old refs after full refresh changes schema', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final old = controller.setSecret(key, 'synthetic-old-reference');
    await host.captured!.future.timeout(const Duration(seconds: 2));
    host.namespaces[key.ns] = FakeNamespace(
      ns: key.ns,
      schemaJson: {
        'type': 'object',
        'dict': {
          'apiKey': {
            'type': 'string',
            'meta': {'role': 'secret'},
          },
          'keyRef': {
            'type': 'string',
            'meta': {'role': 'credential-ref', 'default': 'NEW_ORDER_KEY'},
          },
        },
      },
      base: {},
      revision: 2,
    );
    host.envCredentials.add('NEW_ORDER_KEY');
    await controller.refresh();
    expect(container.read(engineSettingsProvider).value!.credentialRefOf(key), 'NEW_ORDER_KEY');
    gate.complete();
    await old;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.credentials.keys, ['NEW_ORDER_KEY']);
    expect(state.secretConfigured(key), isTrue);
    expect(state.secretWritable(key), isFalse);
    expect(
      host.calls.where((c) => c.$1 == 'credentials/set').length,
      1,
      reason: 'following a status request never repeats the secret mutation',
    );
  });

  FakeNamespace referenceNamespace(String ns, String ref, int revision) => FakeNamespace(
    ns: ns,
    schemaJson: {
      'type': 'object',
      'dict': {
        'apiKey': {
          'type': 'string',
          'meta': {'role': 'secret'},
        },
        'keyRef': {
          'type': 'string',
          'meta': {'role': 'credential-ref', 'default': ref},
        },
      },
    },
    base: {},
    revision: revision,
  );

  // Regression from the independent R1 review: newer credential-only work
  // still uses the visible old schema while full refresh is awaiting new refs.
  test('full refresh retains new refs when old visible refs start a later credential-only read', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.namespaces[key.ns] = referenceNamespace(key.ns, 'NEW_REVIEW_KEY', 2);
    host.envCredentials.add('NEW_REVIEW_KEY');
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final refresh = controller.refresh();
    await host.captured!.future.timeout(const Duration(seconds: 2));
    expect(container.read(engineSettingsProvider).value!.credentialRefOf(key), 'ORDER_TEST_KEY');
    await controller.setSecret(key, 'synthetic-visible-old-reference');
    gate.complete();
    await refresh;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.credentialRefOf(key), 'NEW_REVIEW_KEY');
    expect(state.credentials.keys, ['NEW_REVIEW_KEY']);
    expect(state.secretConfigured(key), isTrue);
    expect(state.secretWritable(key), isFalse);
  });

  test('two consecutive full schema changes never restore the intermediate refs', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    host.namespaces[key.ns] = referenceNamespace(key.ns, 'INTERMEDIATE_KEY', 2);
    host.envCredentials.add('INTERMEDIATE_KEY');
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final first = controller.refresh();
    await host.captured!.future.timeout(const Duration(seconds: 2));
    host.namespaces[key.ns] = referenceNamespace(key.ns, 'FINAL_KEY', 3);
    host.envCredentials.add('FINAL_KEY');
    await controller.refresh();
    gate.complete();
    await first;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.credentialRefOf(key), 'FINAL_KEY');
    expect(state.credentials.keys, ['FINAL_KEY']);
    expect(state.secretConfigured(key), isTrue);
    expect(state.secretWritable(key), isFalse);
    expect(state[key.ns]!.revision, 3);
  });

  test('partly overlapping refs keep newer shared status and newly discovered status together', () async {
    final host = HeldCredentialHost();
    final container = await start(host);
    final controller = container.read(engineSettingsProvider.notifier);
    await controller.setSecret(key, 'synthetic-old-shared-status');
    host.namespaces['new-credential'] = referenceNamespace('new-credential', 'ADDED_KEY', 2);
    host.envCredentials.add('ADDED_KEY');
    host.captured = Completer<void>();
    final gate = host.nextCredential = Completer<void>();
    final full = controller.refresh();
    await host.captured!.future.timeout(const Duration(seconds: 2));
    await controller.clearSecret(key);
    gate.complete();
    await full;
    final state = container.read(engineSettingsProvider).value!;
    expect(state.secretConfigured(key), isFalse);
    const added = FieldRef('new-credential', ['apiKey']);
    expect(state.secretConfigured(added), isTrue);
    expect(state.secretWritable(added), isFalse);
    expect(state.credentials.keys.toSet(), {'ORDER_TEST_KEY', 'ADDED_KEY'});
  });
}
