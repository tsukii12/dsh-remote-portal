import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class _Preferences extends InMemorySharedPreferencesStore {
  _Preferences(super.data) : super.withData();

  final ready = Completer<void>();
  int reads = 0;

  @override
  Future<Map<String, Object>> getAll() async {
    reads++;
    await ready.future;
    return super.getAll();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final cold in [true, false]) {
    test('a pending workspace selection stays with its host (${cold ? 'cold storage' : 'cached storage'})', () async {
      const remote = HostRef.portal('workspace-preference-owner');
      final localKey = WorkspacePrefsController.keyFor(HostRef.none);
      final remoteKey = WorkspacePrefsController.keyFor(remote);
      final remoteView = jsonEncode({
        'selected': 'remote-workspace',
        'pinned': ['remote-pin'],
        'groups': {'remote-workspace': 'Remote group'},
        'recent': ['/srv/remote'],
      });
      SharedPreferences.setMockInitialValues({});
      final previous = SharedPreferencesStorePlatform.instance;
      final store = _Preferences({'flutter.$remoteKey': remoteView});
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() {
        if (!store.ready.isCompleted) store.ready.complete();
        SharedPreferencesStorePlatform.instance = previous;
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.listen(workspacePrefsProvider, (_, _) {});
      final view = container.read(workspacePrefsProvider.notifier);
      expect(store.reads, 1);
      if (!cold) {
        store.ready.complete();
        await view.selection();
      }

      // Use the real host selector and preference controller. Only the
      // platform storage read is held; no provider lifecycle is mocked.
      final saving = view.select('local-workspace');
      container.read(activeHostProvider.notifier).select(remote);
      expect(container.read(activeHostProvider), remote);
      container.read(workspacePrefsProvider);
      if (cold) store.ready.complete();
      await saving;
      await container.read(activeHostProvider.notifier).ready;
      await container.read(workspacePrefsProvider.notifier).selection();

      final stored = await store.getAll();
      expect(stored['flutter.$remoteKey'], remoteView);
      expect(jsonDecode(stored['flutter.$localKey']! as String), {
        'selected': 'local-workspace',
        'pinned': <String>[],
        'groups': <String, String>{},
        'recent': <String>[],
      });

      // Read from the platform again, then reopen the real controllers:
      // isolation must survive a restart, not merely the current UI state.
      SharedPreferences.resetStatic();
      final restarted = ProviderContainer();
      addTearDown(restarted.dispose);
      await restarted.read(activeHostProvider.notifier).ready;
      expect(restarted.read(activeHostProvider), remote);
      expect(await restarted.read(workspacePrefsProvider.notifier).selection(), 'remote-workspace');
      expect(restarted.read(workspacePrefsProvider).groups, {'remote-workspace': 'Remote group'});
      restarted.read(activeHostProvider.notifier).select(HostRef.none);
      expect(await restarted.read(workspacePrefsProvider.notifier).selection(), 'local-workspace');
    });
  }
}
