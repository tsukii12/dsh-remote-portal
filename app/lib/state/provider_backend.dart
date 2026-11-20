import 'dart:async';

import 'package:dsh_client/dsh_client.dart';

/// What the custom-provider screens need from one engine, as a seam the tests
/// can fake. [ClientProviderBackend] is the real one, over a [DshClient].
abstract class ProviderBackend {
  /// The on-device engine (keys typed here are also kept on the phone).
  bool get isLocal;

  /// "本机", "电脑 · SSH" …
  String get hostLabel;

  /// Fires when the pi-ai section, a credential or the route set changes.
  Stream<void> get changes;

  /// The pi-ai section; null when the engine does not mount the adapter.
  Future<ProviderSettings?> read();

  Future<Map<String, CredentialStatus>> credentials(List<String> refs);

  /// Routes currently registered with the LLM service (`llm/listProviders`).
  Future<Set<String>> registeredRoutes();

  /// Configuration diagnostics by route (`llm/listConfigurableProviders`).
  Future<Map<String, String>> diagnostics();

  Future<ProviderSettings> create(ProviderProfile profile);

  Future<ProviderSettings> update(
    String id, {
    String? displayName,
    ProviderApi? api,
    String? baseUrl,
    String? apiKeyEnv,
    List<ProviderModelSpec>? models,
    Map<String, String>? headers,
    int? expectedRevision,
  });

  Future<ProviderSettings> remove(String id, {int? expectedRevision});

  /// Writes one `modelOverrides.<modelId>` entry of a catalog route — how a
  /// model the installed catalog ships (a subscription's, say) gets a
  /// corrected context length without restating the route's model list.
  Future<ProviderSettings> setModelOverride(
    String route,
    String modelId,
    ModelOverride override, {
    int? expectedRevision,
  });

  /// Drops one model override, back to the catalog's figure. [last] also
  /// removes the then-empty `modelOverrides` dict.
  Future<ProviderSettings> clearModelOverride(
    String route,
    String modelId, {
    bool last = false,
    int? expectedRevision,
  });

  Future<void> storeKey(String ref, String key);

  Future<void> clearKey(String ref);

  Future<List<DiscoveredModel>> discover({
    String? provider,
    String? baseUrl,
    ProviderApi? api,
    String? apiKey,
    Map<String, String>? headers,
  });
}

class ClientProviderBackend implements ProviderBackend {
  ClientProviderBackend(this.client, {required this.isLocal, required this.hostLabel});

  final DshClient client;

  @override
  final bool isLocal;

  @override
  final String hostLabel;

  @override
  Stream<void> get changes => client.hostEvents
      .where(
        (event) => switch (event) {
          SettingsUpdatedEvent(:final namespace) => namespace == piAiSettingsNs,
          CredentialUpdatedEvent() || HostReadyEvent() => true,
          UnknownHostEvent(:final event) => event == 'llm/adapters-updated' || event == 'credentials/record-updated',
          _ => false,
        },
      )
      .map((_) {});

  @override
  Future<ProviderSettings?> read() => client.providerSettings();

  @override
  Future<Map<String, CredentialStatus>> credentials(List<String> refs) => client.describeCredentials(refs);

  @override
  Future<Set<String>> registeredRoutes() async => {for (final p in await client.listProviders()) p.id};

  @override
  Future<Map<String, String>> diagnostics() async => {
    for (final p in await client.listConfigurableProviders())
      if (p.settingsNs == piAiSettingsNs && p.error != null) p.provider: p.error!,
  };

  @override
  Future<ProviderSettings> create(ProviderProfile profile) => client.saveProvider(profile);

  @override
  Future<ProviderSettings> update(
    String id, {
    String? displayName,
    ProviderApi? api,
    String? baseUrl,
    String? apiKeyEnv,
    List<ProviderModelSpec>? models,
    Map<String, String>? headers,
    int? expectedRevision,
  }) => client.updateProvider(
    id,
    displayName: displayName,
    api: api,
    baseUrl: baseUrl,
    apiKeyEnv: apiKeyEnv,
    models: models,
    headers: headers,
    expectedRevision: expectedRevision,
  );

  @override
  Future<ProviderSettings> remove(String id, {int? expectedRevision}) =>
      client.removeProvider(id, expectedRevision: expectedRevision);

  @override
  Future<ProviderSettings> setModelOverride(
    String route,
    String modelId,
    ModelOverride override, {
    int? expectedRevision,
  }) => client.setModelOverride(route, modelId, override, expectedRevision: expectedRevision);

  @override
  Future<ProviderSettings> clearModelOverride(
    String route,
    String modelId, {
    bool last = false,
    int? expectedRevision,
  }) => client.clearModelOverride(route, modelId, last: last, expectedRevision: expectedRevision);

  @override
  Future<void> storeKey(String ref, String key) => client.setProviderKey(key, ref: ref);

  @override
  Future<void> clearKey(String ref) => client.clearProviderKey(ref: ref);

  @override
  Future<List<DiscoveredModel>> discover({
    String? provider,
    String? baseUrl,
    ProviderApi? api,
    String? apiKey,
    Map<String, String>? headers,
  }) => client.discoverModels(provider: provider, baseUrl: baseUrl, api: api, apiKey: apiKey, headers: headers);
}
