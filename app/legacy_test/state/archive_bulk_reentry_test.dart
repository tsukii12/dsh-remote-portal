import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import 'read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _ArchiveHost extends FakeWorkspaceHost {
  bool failUndo = false;
  Completer<void>? archiveGate;
  Completer<void>? undoGate;
  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint != 'workspace/archiveSession' && endpoint != 'workspace/unarchiveSession') {
      return super.call(endpoint, args, timeout: timeout);
    }
    calls.add((endpoint, args));
    if (endpoint == 'workspace/unarchiveSession' && failUndo) {
      return const RpcError(DshRemoteException('foo/bar', 'private failure'));
    }
    final request = args['request']! as Map;
    final id = request['sessionId']! as String;
    if (endpoint == 'workspace/archiveSession') {
      if (archiveGate case final gate?) await gate.future;
      archived = [...archived, id];
      pinned = pinned.where((value) => value != id).toList();
      push({'type': 'pinned', 'pinnedSessionIds': pinned});
    } else {
      if (undoGate case final gate?) await gate.future;
      archived = archived.where((value) => value != id).toList();
    }
    push({'type': 'archived', 'archivedSessionIds': archived});
    return RpcOk({'archivedSessionIds': archived});
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<(_ArchiveHost, ProviderContainer)> start(WidgetTester tester, {bool running = false}) async {
    final host = _ArchiveHost();
    host.seedSession('s1', '归档测试', DateTime.now(), running: running);
    host.seedWorkspace('/root/code', title: '项目', sessionIds: ['s1']);
    host.pinned = ['s1'];
    final initialConnection = workspaceHost(host);
    usePhoneSurface(tester);
    await tester.pumpWidget(
      goldenApp(
        brightness: Brightness.light,
        home: HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true),
        overrides: [
          ...workspaceOverrides(
            host,
            current: 's1',
            prefs: const WorkspacePrefs(loaded: true, selected: 'ws-1'),
          ).skip(1),
          switchConnectionProvider.overrideWith(() => SwitchConnection(initialConnection)),
          activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
        ],
      ),
    );
    await _settle(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
    final client = container.read(activeConnectionProvider).value!.client;
    addTearDown(client.close);
    return (host, container);
  }

  for (final roundTrip in [false, true]) {
    testWidgets('bulk sync reentry preserves the newer owner selection: roundTrip=$roundTrip', (tester) async {
      final (hostA, container) = await start(tester);
      final connectionA = container.read(activeConnectionProvider).value!;
      final hostB = _ArchiveHost();
      hostB.seedSession('s1', 'B same id', DateTime.now());
      hostB.seedWorkspace('/root/b', sessionIds: ['s1']);
      final connectionB = workspaceHost(hostB, local: false);
      addTearDown(connectionB.client.close);
      container.read(drawerSelectionProvider.notifier).start('s1');
      await _settle(tester);
      final originalSelection = container.read(drawerSelectionProvider);
      var changed = false;
      final subscription = container.listen(currentSessionProvider, (previous, next) {
        if (next == null && !changed) {
          changed = true;
          container.read(switchConnectionProvider.notifier).set(connectionB);
          container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
          if (roundTrip) {
            container.read(switchConnectionProvider.notifier).set(connectionA);
            container.read(activeHostProvider.notifier).select(HostRef.none);
          }
          container.read(drawerSelectionProvider.notifier).start('s1');
        }
      });
      addTearDown(subscription.close);
      // Exercise the real bulk button, not the state scheduling API directly.
      await tester.tap(find.text('归档'));
      await _settle(tester);
      expect(changed, isTrue);
      expect(container.read(drawerSelectionProvider), {'s1'});
      expect(identical(container.read(drawerSelectionProvider), originalSelection), isFalse);
      await tester.pump(const Duration(seconds: 5));
      expect(hostA.argsOf('workspace/archiveSession'), isEmpty);
      expect(hostB.argsOf('workspace/archiveSession'), isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
}
