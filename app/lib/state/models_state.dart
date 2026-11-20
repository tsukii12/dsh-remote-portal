import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_state.dart';
import 'hosts_state.dart';
import 'read_list_cache.dart';
import 'read_list_identity.dart';
import 'settings_state.dart';

/// `session/modelCatalog` of the active host (null while disconnected).
///
/// DSH 0.2.1 lists no models until a provider credential exists, so the
/// catalog is re-read when the key saved in the app changes and again when
/// the Host confirms the credential (`credentials/reference-updated`) or its
/// adapters change (`llm/adapters-updated`): the app pushes the key to DSH
/// asynchronously, and the first re-read can beat it. A custom provider's
/// model edits (thinking levels, names) change no route, so the pi-ai
/// section's own update counts too.
final modelCatalogProvider = FutureProvider<ModelCatalog?>((ref) async {
  final conn = ref.watch(readListLiveConnectionProvider);
  if (conn == null) return null;
  final identity = ref.watch(readListIdentityProvider);
  final cache = ref.read(readListCacheProvider);
  ref.watch(settingsProvider.select((s) => s.apiKey));
  final sub = conn.client.hostEvents.listen((event) {
    final refresh = switch (event) {
      CredentialUpdatedEvent() || HostReadyEvent() => true,
      SettingsUpdatedEvent(:final namespace) => namespace == piAiSettingsNs || namespace == defaultModelSettingsNs,
      UnknownHostEvent(:final event) => event == 'llm/adapters-updated',
      _ => false,
    };
    if (refresh && ref.mounted) ref.invalidateSelf();
  });
  ref.onDispose(() => unawaited(sub.cancel()));
  final catalog = await conn.client.listModels();
  if (ref.mounted) {
    cache.stamp(catalog, identity, conn.client);
    cache.put(readListKey(identity, ReadListKind.models), catalog, () => CachedModels(catalog));
  }
  return catalog;
});

/// A stale catalog is for browsing only; model selection still needs the
/// current provider's successful authoritative response.
final modelListViewProvider = Provider.autoDispose<ReadListView<ModelCatalog>>((ref) {
  final source = ref.watch(modelCatalogProvider);
  final identity = ref.watch(readListIdentityProvider);
  final connection = ref.watch(readListLiveConnectionProvider);
  final cache = ref.watch(readListCacheProvider);
  ref.watch(readListCacheChangesProvider);
  final raw = source.value;
  final status = source.hasError
      ? ReadListStatus.failed
      : connection == null
      ? ReadListStatus.offline
      : ReadListStatus.updating;
  if (raw != null && cache.current(raw, identity, connection?.client)) {
    final ready = !source.isLoading && !source.hasError;
    return ReadListView(value: raw, readOnly: !ready, status: ready ? ReadListStatus.current : status);
  }
  return ReadListView(
    value: cache.get<CachedModels>(readListKey(identity, ReadListKind.models))?.value,
    readOnly: true,
    status: status,
  );
});

const defaultModelSettingsNs = 'agent-default-model';

/// A picker belongs to one host/connection lifetime, including same-client
/// reconnects and A -> B -> A. It must not acquire a new destination later.
final modelSelectionScopeProvider = Provider<Object>((ref) {
  ref.watch(activeHostProvider);
  ref.watch(activeConnectionProvider);
  final connection = ref.watch(readListLiveConnectionProvider);
  if (connection != null) {
    final client = connection.client;
    final generation = client.mux.generation;
    final sub = client.mux.states.listen((state) {
      if (ref.mounted &&
          (!identical(generation, client.mux.generation) ||
              state == DshConnectionState.reconnecting ||
              state == DshConnectionState.unauthorized ||
              state == DshConnectionState.closed)) {
        ref.invalidateSelf();
      }
    });
    ref.onDispose(() => unawaited(sub.cancel()));
  }
  return Object();
});

/// Only a current response can supply the new-chat chip's effective default;
/// cached or retained catalogs are for browsing, not a claim about defaults.
final currentModelCatalogProvider = Provider<ModelCatalog?>((ref) {
  final view = ref.watch(modelListViewProvider);
  return view.readOnly ? null : view.value;
});

/// Model picked on the new-chat screen before a session exists. Applied to the
/// session right after it is created, then cleared; never carried to a host
/// selected later or a new connection generation.
class PendingModelController extends Notifier<ModelSelection?> {
  @override
  ModelSelection? build() {
    ref.watch(modelSelectionScopeProvider);
    return null;
  }

  void select(ModelSelection? selection) => state = selection;
}

final pendingModelProvider = NotifierProvider<PendingModelController, ModelSelection?>(PendingModelController.new);

/// Catalog entry for the exact provider/model route in [selection].
/// A same-named model on another provider is not the active selection.
ModelInfo? findModel(ModelCatalog? catalog, ModelSelection? selection) {
  if (catalog == null || selection == null) return null;
  for (final model in catalog.models) {
    if (model.provider == selection.provider && model.id == selection.model) {
      return model;
    }
  }
  return null;
}

/// Selection validation must use the fresh route and effort list together.
/// A retained current selection can outlive an adapter's effort edits.
bool isValidModelSelection(ModelCatalog? catalog, ModelSelection? selection) {
  final model = findModel(catalog, selection);
  if (model == null) return false;
  final effort = selection?.reasoningEffort;
  return effort == null || model.efforts.any((entry) => entry.id == effort);
}

/// The effort [model] starts at when it is picked: the engine's own default
/// when the model names one (DeepSeek: 高), else 中, else its lowest level
/// that thinks, else the first. A custom provider's models name no default
/// (the adapter only knows a route-wide one), and the engine runs a selection
/// without an effort as not thinking: so picking one must say which.
String? startingEffort(ModelInfo model) {
  final ids = [for (final e in model.efforts) e.id];
  if (ids.isEmpty) return null;
  if (model.defaultEffort case final effort? when ids.contains(effort)) return effort;
  if (ids.contains('medium')) return 'medium';
  for (final id in ids) {
    if (id != 'off' && id != 'none') return id;
  }
  return ids.first;
}
