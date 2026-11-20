import 'dart:async';

import 'package:dsh_app/state/bots_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/plugins_state.dart';
import 'package:dsh_app/state/providers_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../plugins/support/fake_plugin_host.dart';
import '../providers/support.dart' show FakeProviderBackend;

class SwitchConnection extends Notifier<AsyncValue<HostConnection?>> {
  SwitchConnection(this.initial);
  final HostConnection? initial;
  @override
  AsyncValue<HostConnection?> build() => AsyncData(initial);
  void set(HostConnection? value) => state = AsyncData(value);
}

final switchConnectionProvider = NotifierProvider<SwitchConnection, AsyncValue<HostConnection?>>(
  () => SwitchConnection(null),
);

class SwitchIdentity extends Notifier<ReadListIdentity?> {
  SwitchIdentity(this.initial);
  final ReadListIdentity? initial;
  @override
  ReadListIdentity? build() => initial;
  void set(ReadListIdentity? value) => state = value;
}

final switchIdentityProvider = NotifierProvider<SwitchIdentity, ReadListIdentity?>(() => SwitchIdentity(null));

class FixedHost extends ActiveHostController {
  @override
  HostRef build() => HostRef.none;
}

class SwitchWorkspaces extends WorkspacesController {
  SwitchWorkspaces([this.initial = const WorkspacesState(status: WorkspacesStatus.ready)]);
  final WorkspacesState initial;
  @override
  WorkspacesState build() => initial;
  void set(WorkspacesState value) => state = value;
}

class SwitchWorkspacePrefs extends WorkspacePrefsController {
  SwitchWorkspacePrefs([this.initial = const WorkspacePrefs(loaded: true)]);
  final WorkspacePrefs initial;
  @override
  WorkspacePrefs build() => initial;
  void set(String? id) => state = WorkspacePrefs(loaded: true, selected: id);
}

class ListHost {
  ListHost(this.label) {
    carrier.handlers['pluginManager/listBundles'] = (_) => request('plugins', bundles(label));
    carrier.handlers['session/modelCatalog'] = (_) => request('models', models(label));
    carrier.handlers['session/list'] = (_) => request('sessions', sessions(label));
    client = DshClient.withCarrier(carrier);
  }
  final String label;
  final carrier = FakePluginCarrier();
  late final DshClient client;
  final paused = <String>{};
  final requests = <String, List<Completer<Object?>>>{};
  HostConnection get connection => HostConnection(hostId: '', client: client, isLocal: true);

  Object? request(String kind, Object fallback) {
    if (!paused.contains(kind)) return fallback;
    final pending = Completer<Object?>();
    (requests[kind] ??= []).add(pending);
    return pending.future;
  }

  static List<Object?> bundles(String label) => [bundleJson('plugin-$label', description: 'Description')];
  static Map<String, Object?> models(String label, {int count = 1}) => {
    'groups': [
      {
        'id': 'p',
        'name': 'Provider',
        'models': [
          for (var i = 0; i < count; i++) {'id': '$label-$i', 'name': '$label Model $i', 'description': 'Description'},
        ],
      },
    ],
    'routableProviders': ['p'],
    'failures': <Object?>[],
  };
  static Map<String, Object?> sessions(String label, {int count = 1}) => {
    'items': [
      for (var i = 0; i < count; i++)
        {
          'sessionId': '$label-$i',
          'updatedAt': 1793000000000 - i * 1000,
          'running': false,
          'blank': false,
          'agentAvailable': false,
          'projections': {
            'values': {'title': '$label Session $i'},
          },
        },
    ],
  };
}

List<Override> listOverrides(
  ListHost host, {
  ReadListCache? cache,
  ReadListIdentity? identity,
  SwitchWorkspaces? workspaces,
  SwitchWorkspacePrefs? prefs,
}) => [
  activeHostProvider.overrideWith(FixedHost.new),
  switchConnectionProvider.overrideWith(() => SwitchConnection(host.connection)),
  activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
  switchIdentityProvider.overrideWith(() => SwitchIdentity(identity ?? ReadListIdentity.of(['profile-a']))),
  readListIdentityProvider.overrideWith((ref) => ref.watch(switchIdentityProvider)),
  localSafeModeProvider.overrideWithValue(false),
  workspacesProvider.overrideWith(() => workspaces ?? SwitchWorkspaces()),
  workspacePrefsProvider.overrideWith(() => prefs ?? SwitchWorkspacePrefs()),
  dsBotOwnedSessionsProvider.overrideWithValue(const {}),
  if (cache != null) readListCacheProvider.overrideWithValue(cache),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  late ListHost host;
  late ProviderContainer c;
  setUp(() {
    host = ListHost('A');
    c = ProviderContainer(overrides: listOverrides(host));
  });
  tearDown(() async {
    c.dispose();
    await host.client.close();
  });

  test('plugin overlapping refreshes: second success wins, not last completion', () async {
    await c.read(installedPluginsProvider.future);
    c.listen(pluginListViewProvider, (_, _) {});
    host.paused.add('plugins');
    final notifier = c.read(installedPluginsProvider.notifier);
    final first = notifier.refresh();
    final second = notifier.refresh();
    await c.pump();
    expect(c.read(pluginListViewProvider).readOnly, isTrue);
    expect(host.requests['plugins'], hasLength(2));
    host.requests['plugins']![1].complete(ListHost.bundles('New'));
    await second;
    host.requests['plugins']![0].complete(ListHost.bundles('Old'));
    await first;
    await c.pump();
    expect(c.read(installedPluginsProvider).value!.single.name, 'plugin-New');
    final identity = c.read(readListIdentityProvider);
    expect(
      c
          .read(readListCacheProvider)
          .get<CachedPlugins>(readListKey(identity, ReadListKind.plugins))!
          .rows
          .single
          .bundle
          .name,
      'plugin-New',
    );
    expect(c.read(pluginListViewProvider).readOnly, isFalse);
  });

  test('plugin A to B to same A client: old Ref cannot overwrite new build', () async {
    await c.read(installedPluginsProvider.future);
    host.paused.add('plugins');
    final old = c.read(installedPluginsProvider.notifier).refresh();
    final other = ListHost('B');
    addTearDown(other.client.close);
    c.read(switchConnectionProvider.notifier).set(other.connection);
    await c.read(installedPluginsProvider.future);
    host.paused.remove('plugins');
    c.read(switchConnectionProvider.notifier).set(host.connection);
    await c.read(installedPluginsProvider.future);
    host.requests['plugins']!.single.complete(ListHost.bundles('Late'));
    await old;
    expect(c.read(installedPluginsProvider).value!.single.name, 'plugin-A');
  });

  test('plugin old refresh failure does not mark new client failed', () async {
    await c.read(installedPluginsProvider.future);
    host.paused.add('plugins');
    final old = c.read(installedPluginsProvider.notifier).refresh();
    final observed = expectLater(old, throwsA(isA<DshRemoteException>()));
    final other = ListHost('B');
    addTearDown(other.client.close);
    c.read(switchConnectionProvider.notifier).set(other.connection);
    await c.read(installedPluginsProvider.future);
    host.requests['plugins']!.single.completeError(const DshRemoteException('test/failure', 'late'));
    await observed;
    expect(c.read(installedPluginsProvider).hasError, isFalse);
    expect(c.read(pluginListViewProvider).readOnly, isFalse);
  });

  test('entry refresh coalesces with initial pending plugin build', () async {
    host.paused.add('plugins');
    final initial = c.read(installedPluginsProvider.future);
    final refresh = c.read(installedPluginsProvider.notifier).refresh();
    expect(host.requests['plugins'], hasLength(1));
    host.requests['plugins']!.single.complete(ListHost.bundles('Initial'));
    await Future.wait([initial, refresh]);
    expect(c.read(installedPluginsProvider).value!.single.name, 'plugin-Initial');
  });

  test('models display success across disconnect and a newly constructed client', () async {
    await c.read(modelCatalogProvider.future);
    expect(c.read(modelListViewProvider).readOnly, isFalse);
    c.read(switchConnectionProvider.notifier).set(null);
    await c.read(modelCatalogProvider.future);
    expect(c.read(modelListViewProvider).value!.models.single.name, 'A Model 0');
    expect(c.read(modelListViewProvider).status, ReadListStatus.offline);
    final other = ListHost('New')..paused.add('models');
    addTearDown(other.client.close);
    c.read(switchConnectionProvider.notifier).set(other.connection);
    final load = c.read(modelCatalogProvider.future);
    expect(c.read(modelListViewProvider).value!.models.single.name, 'A Model 0');
    expect(c.read(modelListViewProvider).readOnly, isTrue);
    other.requests['models']!.single.complete(ListHost.models('New'));
    await load;
    expect(c.read(modelListViewProvider).value!.models.single.name, 'New Model 0');
    expect(c.read(modelListViewProvider).readOnly, isFalse);
  });

  test('model late response from previous identity cannot enter current snapshot', () async {
    host.paused.add('models');
    c.listen(modelCatalogProvider, (_, _) {});
    final other = ListHost('B');
    addTearDown(other.client.close);
    c.read(switchIdentityProvider.notifier).set(ReadListIdentity.of(['profile-b']));
    c.read(switchConnectionProvider.notifier).set(other.connection);
    await c.read(modelCatalogProvider.future);
    host.requests['models']!.single.complete(ListHost.models('Late'));
    await c.pump();
    expect(c.read(modelListViewProvider).value!.models.single.name, 'B Model 0');
    expect(
      c
          .read(readListCacheProvider)
          .get<CachedModels>(readListKey(c.read(readListIdentityProvider), ReadListKind.models))!
          .value
          .models
          .single
          .name,
      'B Model 0',
    );
  });

  test('session refresh reverse completion retains newer list', () async {
    await c.read(sessionsProvider.future);
    host.paused.add('sessions');
    final first = c.read(sessionsProvider.notifier).refresh();
    final second = c.read(sessionsProvider.notifier).refresh();
    host.requests['sessions']![1].complete(ListHost.sessions('New'));
    await second;
    host.requests['sessions']![0].complete(ListHost.sessions('Old'));
    await first;
    expect(c.read(sessionsProvider).value!.single.sessionId, 'New-0');
  });

  test('session background refresh coalesced with a failing initial read never leaks an error', () async {
    host.paused.add('sessions');
    final initial = c.read(sessionsProvider.future);
    final initialError = expectLater(initial, throwsStateError);
    final refresh = c.read(sessionsProvider.notifier).refresh();
    final refreshDone = expectLater(refresh, completes);
    expect(host.requests['sessions'], hasLength(1));
    host.requests['sessions']!.single.completeError(StateError('initial list unavailable'));
    await Future.wait([initialError, refreshDone]);
    expect(c.read(sessionsProvider).hasError, isTrue);
  });

  test('selected workspace reconnect uses only its confirmed members, never all sessions', () async {
    c.dispose();
    const workspace = Workspace(workspaceId: 'w', path: '/code', title: 'W', sessionIds: ['A-0']);
    final registry = SwitchWorkspaces(const WorkspacesState(status: WorkspacesStatus.ready, workspaces: [workspace]));
    final prefs = SwitchWorkspacePrefs(const WorkspacePrefs(loaded: true, selected: 'w'));
    c = ProviderContainer(
      overrides: listOverrides(host, workspaces: registry, prefs: prefs),
    );
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions.single.sessionId, 'A-0');
    c.read(switchConnectionProvider.notifier).set(null);
    registry.set(const WorkspacesState());
    await c.read(sessionsProvider.future);
    final cached = c.read(drawerScopeProvider)!;
    expect(cached.readOnly, isTrue);
    expect(cached.scoped, isTrue);
    expect(cached.sessions.single.sessionId, 'A-0');
    prefs.set('unknown-workspace');
    expect(c.read(drawerScopeProvider), isNull);
    prefs.set('w');
    registry.set(
      const WorkspacesState(
        status: WorkspacesStatus.ready,
        workspaces: [
          Workspace(workspaceId: 'w', path: '/another-root', title: 'W', sessionIds: ['A-0']),
        ],
      ),
    );
    expect(c.read(drawerScopeProvider), isNull);
  });

  test('workspace id all cannot collide with the unscoped session cache key', () async {
    c.dispose();
    host.carrier.handlers['session/list'] = (_) => ListHost.sessions('A', count: 2);
    const w = Workspace(workspaceId: 'all', path: '/scoped', title: 'Scoped', sessionIds: ['A-0']);
    final registry = SwitchWorkspaces(const WorkspacesState(status: WorkspacesStatus.ready, workspaces: [w]));
    final prefs = SwitchWorkspacePrefs();
    c = ProviderContainer(
      overrides: listOverrides(host, workspaces: registry, prefs: prefs),
    );
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions, hasLength(2));
    prefs.set('all');
    expect(c.read(drawerScopeProvider)!.sessions.single.sessionId, 'A-0');
    c.read(switchConnectionProvider.notifier).set(null);
    registry.set(const WorkspacesState());
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions.single.sessionId, 'A-0');
    prefs.set(null);
    expect(c.read(drawerScopeProvider)!.sessions, hasLength(2));
  });

  test('a confirmed registry archive update changes the cached projection without a new session reply', () async {
    c.dispose();
    host.carrier.handlers['session/list'] = (_) => ListHost.sessions('A', count: 2);
    final registry = SwitchWorkspaces();
    c = ProviderContainer(overrides: listOverrides(host, workspaces: registry));
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions, hasLength(2));
    // The registry and SessionsController have independent workspace/follow
    // subscriptions. One can deliver this confirmed frame before the other.
    registry.set(const WorkspacesState(status: WorkspacesStatus.ready, archivedSessionIds: ['A-0']));
    expect(c.read(drawerScopeProvider)!.sessions.single.sessionId, 'A-1');
    c.read(switchConnectionProvider.notifier).set(null);
    registry.set(const WorkspacesState());
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions.map((row) => row.sessionId), ['A-1']);
  });

  test('an oversize fresh drawer stays complete and invalidates its older cache', () async {
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider)!.sessions, hasLength(1));
    host.carrier.handlers['session/list'] = (_) => ListHost.sessions('A', count: ReadListData.maxRows + 1);
    await c.read(sessionsProvider.notifier).refresh();
    expect(c.read(drawerScopeProvider)!.sessions, hasLength(ReadListData.maxRows + 1));
    c.read(switchConnectionProvider.notifier).set(null);
    await c.read(sessionsProvider.future);
    expect(c.read(drawerScopeProvider), isNull, reason: 'do not present one older row as the full newer list');
  });

  test('provider failure keeps a successful display snapshot but does not grant edits', () async {
    c.dispose();
    final backend = _SlowProviders();
    c = ProviderContainer(overrides: [...listOverrides(host), providerBackendProvider.overrideWithValue(backend)]);
    c.listen(providerListViewProvider, (_, _) {});
    await c.read(customProvidersProvider.future);
    expect(c.read(providerListViewProvider).readOnly, isFalse);
    backend.fail = true;
    c.invalidate(customProvidersProvider);
    await expectLater(c.read(customProvidersProvider.future), throwsStateError);
    expect(c.read(providerListViewProvider).readOnly, isTrue);
    expect(c.read(providerListViewProvider).status, ReadListStatus.failed);
    final cached = c
        .read(readListCacheProvider)
        .get<CachedProviders>(readListKey(c.read(readListIdentityProvider), ReadListKind.providers));
    expect(cached!.rows.single.name, 'Provider');
  });
}

class _SlowProviders extends FakeProviderBackend {
  _SlowProviders()
    : super(
        profiles: const [ProviderProfile(route: 'custom-p', displayName: 'Provider', api: 'openai-completions')],
      );
  bool fail = false;
  @override
  Future<ProviderSettings?> read() async {
    if (fail) throw StateError('temporary read failed');
    return super.read();
  }
}
