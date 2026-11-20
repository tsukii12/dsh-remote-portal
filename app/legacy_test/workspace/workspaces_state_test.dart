// Workspace state: following `workspace/follow`, the registry mutations, the
// phone's per-host view (selection, pins, groups, recent folders), the list
// sections, new conversations landing in the selected workspace, and the
// display text.

import 'dart:convert';

import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/workspace/directory_picker.dart';
import 'package:dsh_app/ui/workspace/workspace_format.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime, FakeSettings;
import 'support.dart';

Workspace _w(String id, String title, {String? path}) =>
    Workspace(workspaceId: id, path: path ?? '/root/$title', title: title, sessionIds: const []);

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  ProviderContainer containerFor(FakeWorkspaceHost host, {bool local = true}) {
    final conn = workspaceHost(host, local: local);
    final container = ProviderContainer(
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData(conn)),
        localRuntimeProvider.overrideWith(() => FakeRuntime(const LocalRuntimeState(loaded: true))),
        settingsProvider.overrideWith(() => FakeSettings(const AppSettings(loaded: true))),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('following the host', () {
    test('baseline, then upsert / order / remove / pinned frames', () async {
      final host = FakeWorkspaceHost(folders: ['/root/a', '/root/b']);
      host.seedWorkspace('/root/a');
      final container = containerFor(host);
      final sub = container.listen(workspacesProvider, (_, _) {});
      addTearDown(sub.close);
      expect(container.read(workspacesProvider).status, WorkspacesStatus.loading);
      await _settle();
      var state = container.read(workspacesProvider);
      expect(state.ready, isTrue);
      expect([for (final w in state.workspaces) w.title], ['a']);

      // A workspace added elsewhere goes to the front.
      final b = host.seedWorkspace('/root/b');
      host.push({'type': 'upsert', 'workspace': b});
      host.push({
        'type': 'order',
        'workspaceIds': [for (final w in host.workspaces) w['workspaceId']],
      });
      await _settle();
      expect([for (final w in container.read(workspacesProvider).workspaces) w.title], ['b', 'a']);

      host.push({
        'type': 'pinned',
        'pinnedSessionIds': ['s1'],
      });
      host.push({'type': 'remove', 'workspaceId': b['workspaceId']});
      await _settle();
      state = container.read(workspacesProvider);
      expect([for (final w in state.workspaces) w.title], ['a']);
      expect(state.pinnedSessionIds, ['s1']);

      // A late upsert never brings a removed workspace back.
      host.push({'type': 'upsert', 'workspace': b});
      await _settle();
      expect(container.read(workspacesProvider).workspaces, hasLength(1));
    });

    test('a replace frame swaps the whole state', () async {
      final host = FakeWorkspaceHost();
      host.seedWorkspace('/root/a');
      final container = containerFor(host);
      container.listen(workspacesProvider, (_, _) {});
      await _settle();
      host.push({
        'type': 'replace',
        'value': {
          'items': [
            {'workspaceId': 'ws-x', 'path': '/srv/x', 'title': 'x', 'sessionIds': <Object?>[]},
          ],
          'archivedSessionIds': <Object?>[],
          'pinnedSessionIds': ['s9'],
        },
      });
      await _settle();
      final state = container.read(workspacesProvider);
      expect([for (final w in state.workspaces) w.workspaceId], ['ws-x']);
      expect(state.pinnedSessionIds, ['s9']);
    });

    test('offline without a connection', () {
      final container = ProviderContainer(
        overrides: [activeConnectionProvider.overrideWithValue(const AsyncData(null))],
      );
      addTearDown(container.dispose);
      expect(container.read(workspacesProvider).status, WorkspacesStatus.offline);
    });
  });

  group('mutations', () {
    test('add, rename (and its conflict), remove; removal forgets the phone-side view', () async {
      final host = FakeWorkspaceHost(folders: ['/root/code/app', '/root/code/site']);
      final container = containerFor(host);
      container.listen(workspacesProvider, (_, _) {});
      container.listen(workspacePrefsProvider, (_, _) {});
      await _settle();
      final notifier = container.read(workspacesProvider.notifier);

      final app = await notifier.add('/root/code/app');
      final site = await notifier.add('/root/code/site');
      expect(host.argsOf('workspace/create').first, {
        'request': {'path': '/root/code/app'},
      });
      await _settle();
      expect([for (final w in container.read(workspacesProvider).workspaces) w.title], ['site', 'app']);

      await notifier.rename(app.workspaceId, '应用');
      await _settle();
      expect(container.read(workspacesProvider).byId(app.workspaceId)!.title, '应用');
      await expectLater(
        notifier.rename(site.workspaceId, '应用'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', WorkspaceErrors.nameConflict)),
      );

      final prefs = container.read(workspacePrefsProvider.notifier);
      await prefs.select(app.workspaceId);
      await prefs.setPinned(app.workspaceId, true);
      await prefs.setGroup(app.workspaceId, '工作');
      expect(container.read(selectedWorkspaceProvider)?.workspaceId, app.workspaceId);

      await notifier.remove(app.workspaceId);
      await _settle();
      expect(container.read(workspacesProvider).byId(app.workspaceId), isNull);
      final view = container.read(workspacePrefsProvider);
      expect(view.selected, isNull);
      expect(view.pinned, isEmpty);
      expect(view.groups, isEmpty);
      expect(container.read(selectedWorkspaceProvider), isNull);
    });

    test('adding a missing folder fails with workspace/invalid-path', () async {
      final host = FakeWorkspaceHost();
      final container = containerFor(host);
      container.listen(workspacesProvider, (_, _) {});
      await _settle();
      await expectLater(
        container.read(workspacesProvider.notifier).add('/root/nope'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', WorkspaceErrors.invalidPath)),
      );
    });

    test('pinning a conversation updates the pin set', () async {
      final host = FakeWorkspaceHost();
      final container = containerFor(host);
      container.listen(workspacesProvider, (_, _) {});
      await _settle();
      await container.read(workspacesProvider.notifier).pinSession('s1');
      expect(container.read(workspacesProvider).pinnedSessionIds, ['s1']);
      await container.read(workspacesProvider.notifier).unpinSession('s1');
      expect(container.read(workspacesProvider).pinnedSessionIds, isEmpty);
    });
  });

  group('new conversations', () {
    test('start in the selected workspace, else in the default folder', () async {
      final host = FakeWorkspaceHost(folders: ['/root/code/app']);
      final ws = host.seedWorkspace('/root/code/app');
      final container = containerFor(host);
      container.listen(workspacesProvider, (_, _) {});
      container.listen(sessionsProvider, (_, _) {});
      await _settle();

      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {
        'request': {'cwd': localWorkspaceDir},
      });

      await container.read(workspacePrefsProvider.notifier).select(ws['workspaceId'] as String);
      await container.read(sessionsProvider.notifier).create();
      expect(host.argsOf('session/create').last, {
        'request': {'workspaceId': ws['workspaceId']},
      });
      await _settle();
      expect(container.read(workspacesProvider).workspaces.single.sessionIds, hasLength(1));
    });

    test('a workspace removed meanwhile falls back to the default folder', () async {
      final host = FakeWorkspaceHost();
      final client = DshClient.withCarrier(host);
      await createSessionInWorkspace(client, 'ws-gone', cwd: '/root/workspace');
      expect(
        [for (final a in host.argsOf('session/create')) a['request']],
        [
          {'workspaceId': 'ws-gone'},
          {'cwd': '/root/workspace'},
        ],
      );
    });
  });

  group('the phone-side view', () {
    test('is stored per host and survives a restart', () async {
      final host = FakeWorkspaceHost();
      var container = containerFor(host);
      final prefs = container.read(workspacePrefsProvider.notifier);
      expect(await prefs.selection(), isNull);
      await prefs.select('ws-1');
      await prefs.setPinned('ws-2', true);
      await prefs.setGroup('ws-1', ' 工作 ');
      for (final f in ['/a', '/b', '/c', '/d', '/a', '/e']) {
        await prefs.remember(f);
      }
      final stored = (await SharedPreferences.getInstance()).getString(WorkspacePrefsController.keyFor(HostRef.none));
      expect(jsonDecode(stored!), {
        'selected': 'ws-1',
        'pinned': ['ws-2'],
        'groups': {'ws-1': '工作'},
        'recent': ['/e', '/a', '/d', '/c'],
      });

      container = containerFor(host);
      expect(await container.read(workspacePrefsProvider.notifier).selection(), 'ws-1');
      expect(container.read(workspacePrefsProvider).groups, {'ws-1': '工作'});
    });

    test('sections: pinned, then groups in list order, then the rest', () {
      final ws = [_w('1', 'a'), _w('2', 'b'), _w('3', 'c'), _w('4', 'd'), _w('5', 'e')];
      const prefs = WorkspacePrefs(loaded: true, pinned: ['4'], groups: {'3': '个人', '1': '工作', '5': '工作', '4': '工作'});
      final sections = workspaceSections(ws, prefs);
      expect([for (final s in sections) s.title], ['置顶', '工作', '个人', '其他']);
      expect([for (final s in sections) s.items.map((w) => w.title).join()], ['d', 'ae', 'c', 'b']);
      // No pins or groups: one untitled block.
      final plain = workspaceSections(ws, const WorkspacePrefs(loaded: true));
      expect(plain.single.title, isNull);
      expect(plain.single.items, hasLength(5));
    });
  });

  group('text', () {
    test('titles: stored, the first-use default, else the folder', () {
      expect(workspaceTitle(_w('1', 'dsh-app')), 'dsh-app');
      expect(workspaceTitle(_w('1', 'default-workspace')), '默认工作区');
      expect(workspaceTitle(_w('1', '', path: '/srv/site')), 'site');
    });

    test('paths: phone storage, home, elsewhere', () {
      expect(displayPath('/sdcard', local: true), '手机存储');
      expect(displayPath('/sdcard/Documents/notes', local: true), '手机存储/Documents/notes');
      expect(displayPath('/root', local: true), '~');
      expect(displayPath('/root/workspace', local: true), '~/workspace');
      expect(displayPath('/rootfs', local: true), '/rootfs');
      expect(displayPath('/home/u/code', local: false, home: '/home/u'), '~/code');
      expect(displayPath('/sdcard/x', local: false), '/sdcard/x');
      expect(parentFolder('/root/code/app'), '/root/code');
      expect(parentFolder('/root'), '/');
      expect(parentFolder('/'), isNull);
      expect(folderNameProblem(''), isNotNull);
      expect(folderNameProblem('a/b'), isNotNull);
      expect(folderNameProblem('..'), isNotNull);
      expect(folderNameProblem('新项目'), isNull);
    });

    test('breadcrumbs start at 手机存储 / 主目录 / 根目录', () {
      DirectoryLevel level(String path, {String home = '/root'}) {
        var at = '';
        return DirectoryLevel(
          path: path,
          home: home,
          crumbs: [
            const DirectoryEntry(name: '/', path: '/'),
            for (final p in path.split('/').where((p) => p.isNotEmpty)) DirectoryEntry(name: p, path: at = '$at/$p'),
          ],
          entries: const [],
        );
      }

      expect([for (final c in displayCrumbs(level('/sdcard/Download'), local: true)) c.label], ['手机存储', 'Download']);
      expect([for (final c in displayCrumbs(level('/root/code'), local: true)) c.label], ['主目录', 'code']);
      expect([for (final c in displayCrumbs(level('/srv/www'), local: true)) c.label], ['根目录', 'srv', 'www']);
      expect([for (final c in displayCrumbs(level('/sdcard/x'), local: false)) c.label], ['根目录', 'sdcard', 'x']);
      expect(levelTitle(level('/root'), local: true), '主目录');
    });

    test('errors are one short line', () {
      expect(workspaceErrorText(const DshRemoteException(WorkspaceErrors.nameConflict, 'x')), '已有同名的工作区');
      expect(workspaceErrorText(const DshRemoteException(WorkspaceErrors.exists, 'x')), '已经有同名的文件夹');
      expect(workspaceErrorText(const DshTransportException('down')), '没能连上引擎');
      expect(workspaceErrorText(StateError('x'), fallback: '没能添加工作区'), '没能添加工作区');
    });
  });

  group('recentWorkspace', () {
    final at = DateTime.utc(2026, 11, 5);
    SessionSummary session(String id, Duration ago) =>
        SessionSummary(sessionId: id, updatedAt: at.subtract(ago), running: false, blank: false, agentAvailable: true);
    Workspace workspace(String id, {List<String> sessions = const [], DateTime? createdAt}) =>
        Workspace(workspaceId: id, path: '/$id', title: id, sessionIds: sessions, createdAt: createdAt);

    test('the one whose conversation moved last', () {
      final recent = recentWorkspace(
        [
          workspace('old', sessions: ['a', 'b']),
          workspace('new', sessions: ['c']),
        ],
        [
          session('a', const Duration(days: 3)),
          session('b', const Duration(days: 2)),
          session('c', const Duration(hours: 1)),
        ],
      );
      expect(recent?.workspaceId, 'new');
    });

    test('a workspace with no known conversation counts from its creation', () {
      final recent = recentWorkspace(
        [
          workspace('used', sessions: ['a']),
          workspace('fresh', sessions: ['gone'], createdAt: at),
        ],
        [session('a', const Duration(days: 1))],
      );
      expect(recent?.workspaceId, 'fresh');
    });

    test('nothing to tell them apart: the first on the list; none: null', () {
      expect(recentWorkspace([workspace('a'), workspace('b')], const [])?.workspaceId, 'a');
      expect(recentWorkspace(const [], const []), isNull);
    });
  });
}
