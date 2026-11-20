import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/read_list_cache.dart';
import 'package:dsh_app/state/read_list_identity.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart' show FakeWorkspaceHost;
import 'read_list_refresh_test.dart'
    show FixedHost, ListHost, SwitchConnection, listOverrides, switchConnectionProvider;

class _PausedWorkspaceHost extends FakeWorkspaceHost {
  final pending = <String, Completer<RpcResult>>{};
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) =>
      pending[endpoint]?.future ?? super.call(endpoint, args, timeout: timeout);
}

Future<void> _flush(ProviderContainer c) async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
    await c.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a retained but closed client revokes live authority without dropping its display snapshot', () async {
    final host = ListHost('live');
    final c = ProviderContainer(overrides: listOverrides(host));
    addTearDown(c.dispose);
    c.listen(modelListViewProvider, (_, _) {});
    await c.read(modelCatalogProvider.future);
    await _flush(c);
    expect(c.read(modelListViewProvider).readOnly, isFalse);
    await host.client.close();
    await _flush(c);
    expect(c.read(activeConnectionProvider).value!.client, same(host.client));
    expect(c.read(readListLiveConnectionProvider), isNull);
    final view = c.read(modelListViewProvider);
    expect(view.value!.models.single.name, 'live Model 0');
    expect(view.status, ReadListStatus.offline);
    expect(view.readOnly, isTrue);
  });

  for (final mutation in ['create', 'rename', 'delete', 'pinSession', 'unpinSession']) {
    test('late workspace/$mutation cannot cross A to B to the same A client', () async {
      final a = _PausedWorkspaceHost();
      final original = a.seedWorkspace('/a', title: 'Current A');
      final id = original['workspaceId'] as String;
      final b = FakeWorkspaceHost()..seedWorkspace('/b', title: 'Current B');
      final ac = DshClient.withCarrier(a);
      final bc = DshClient.withCarrier(b);
      final aConnection = HostConnection(hostId: '', client: ac, isLocal: true);
      final bConnection = HostConnection(hostId: '', client: bc, isLocal: true);
      final identity = ReadListIdentity.of(['workspace-source']);
      final c = ProviderContainer(
        overrides: [
          activeHostProvider.overrideWith(FixedHost.new),
          switchConnectionProvider.overrideWith(() => SwitchConnection(aConnection)),
          activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
          readListIdentityProvider.overrideWithValue(identity),
        ],
      );
      addTearDown(() async {
        c.dispose();
        await ac.close();
        await bc.close();
      });
      c.listen(workspacesProvider, (_, _) {});
      await _flush(c);
      expect(c.read(workspacesProvider).workspaces.single.title, 'Current A');
      final old = Completer<RpcResult>();
      a.pending['workspace/$mutation'] = old;
      final controller = c.read(workspacesProvider.notifier);
      final request = switch (mutation) {
        'create' => controller.add('/late'),
        'rename' => controller.rename(id, 'Late'),
        'delete' => controller.remove(id),
        'pinSession' => controller.pinSession('late-session'),
        _ => controller.unpinSession('old-session'),
      };
      c.read(switchConnectionProvider.notifier).set(bConnection);
      await _flush(c);
      expect(c.read(workspacesProvider).workspaces.single.title, 'Current B');
      c.read(switchConnectionProvider.notifier).set(aConnection);
      await _flush(c);
      final before = c.read(workspacesProvider);
      expect(before.workspaces.single.title, 'Current A');
      old.complete(
        RpcOk(switch (mutation) {
          'create' => {
            'workspace': {...original, 'workspaceId': 'late-new', 'title': 'Late'},
            'created': true,
          },
          'rename' => {
            'workspace': {...original, 'title': 'Late', 'updatedAt': '2099-01-01T00:00:00Z'},
          },
          'delete' => {'deleted': true},
          _ => {
            'pinnedSessionIds': ['late-session'],
          },
        }),
      );
      await request;
      await _flush(c);
      Map<String, Object> visible(WorkspacesState value) => {
        'rows': [for (final w in value.workspaces) '${w.workspaceId}:${w.title}'],
        'pinned': value.pinnedSessionIds,
        'archived': value.archivedSessionIds,
      };
      expect(
        visible(c.read(workspacesProvider)),
        visible(before),
        reason: 'old reply must not change current rows or pins',
      );
      expect(c.read(workspacesProvider), same(before), reason: 'discard stale completion before every state mutation');
      expect(c.read(readListCacheProvider).current(before, identity, ac), isTrue);
    });
  }
}
