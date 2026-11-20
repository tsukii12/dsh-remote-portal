import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../engine_settings/support.dart' show FakeSettingsHost;

class _HeadersHost extends FakeSettingsHost {
  _HeadersHost() : super(describe: {'namespaces': <Object?>[]});

  bool supportsDraftHeaders = true;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    if (endpoint == 'settings/mutate') return RpcOk({'value': <String, Object?>{}, 'revision': 1});
    if (endpoint == 'llm/discoverModelsWithHeaders' && !supportsDraftHeaders) {
      return const RpcError(DshRemoteException('METHOD_NOT_FOUND', 'Unknown endpoint'));
    }
    if (endpoint == 'llm/discoverModels' || endpoint == 'llm/discoverModelsWithHeaders') return const RpcOk([]);
    throw StateError('Unexpected endpoint: $endpoint');
  }
}

void main() {
  test('App backend preserves omit, clear and replace through the real client', () async {
    final host = _HeadersHost();
    final client = DshClient.withCarrier(host);
    addTearDown(client.close);
    final backend = ClientProviderBackend(client, isLocal: false, hostLabel: 'test host');
    for (final headers in <Map<String, String>?>[
      null,
      {},
      {'x-opencode-session': 'session-1'},
    ]) {
      await backend.update('custom-header-gateway', displayName: 'Gateway', headers: headers, expectedRevision: 3);
      expect(host.calls.last.$2['ops'], [
        {
          'op': 'set',
          'path': ['providers', 'custom-header-gateway', 'displayName'],
          'value': 'Gateway',
        },
        if (headers != null)
          {
            'op': 'set',
            'path': ['providers', 'custom-header-gateway', 'headers'],
            'value': headers,
          },
      ]);
      expect(host.calls.last.$2['expectedRevision'], 3);
      await backend.discover(provider: 'custom-header-gateway', headers: headers);
      expect(host.calls.last.$1, headers == null ? 'llm/discoverModels' : 'llm/discoverModelsWithHeaders');
      expect(host.calls.last.$2['request'], {
        'provider': 'custom-header-gateway',
        if (headers != null)
          'headers': [
            for (final entry in headers.entries) {'name': entry.key, 'value': entry.value},
          ],
      });
    }
  });

  test('App discovery reports an old Host refusal without dropping headers and retrying', () async {
    final host = _HeadersHost()..supportsDraftHeaders = false;
    final client = DshClient.withCarrier(host);
    addTearDown(client.close);
    final container = ProviderContainer(
      overrides: [
        providerBackendProvider.overrideWithValue(ClientProviderBackend(client, isLocal: false, hostLabel: 'old host')),
      ],
    );
    addTearDown(container.dispose);
    await expectLater(
      container
          .read(providerActionsProvider)
          .discover(
            api: ProviderApi.openaiCompletions,
            baseUrl: 'https://gw.example.com',
            headers: const {'x-opencode-session': 'session-1'},
          ),
      throwsA(isA<DshRemoteException>().having((error) => error.code, 'code', 'METHOD_NOT_FOUND')),
    );
    expect(host.calls.map((call) => call.$1), ['llm/discoverModelsWithHeaders']);
  });
}
