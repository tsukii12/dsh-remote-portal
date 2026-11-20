// `WorkspacesApi`: the request shapes the Host expects and the replies as a
// throwaway DSH 0.2.1-rc.2 `dsh web` returned them.

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

const fastMux = MuxOptions(readyTimeout: Duration(seconds: 2), retryCaps: [Duration(milliseconds: 20)]);

Map<String, Object?> ok(Object? value) => {'ok': true, 'value': value};

Map<String, Object?> fail(String code, [Map<String, Object?> details = const {}]) => {
  'ok': false,
  'error': {'code': code, 'message': code, 'details': details},
};

/// `directoryPicker/list {path: /home/u/proj}` (shape copied from a live Host).
const _listing = {
  'path': '/home/u/proj',
  'home': '/home/u',
  'crumbs': [
    {'name': '/', 'path': '/', 'hidden': false},
    {'name': 'home', 'path': '/home', 'hidden': false},
    {'name': 'u', 'path': '/home/u', 'hidden': false},
    {'name': 'proj', 'path': '/home/u/proj', 'hidden': false},
  ],
  'entries': [
    {'name': '.hidden', 'path': '/home/u/proj/.hidden', 'hidden': true},
    {'name': 'a', 'path': '/home/u/proj/a', 'hidden': false},
  ],
  'truncated': false,
};

Map<String, Object?> _workspace(String id, String title, {String updatedAt = '2026-10-24T05:54:09.212Z'}) => {
  'workspaceId': id,
  'path': '/home/u/proj/$title',
  'title': title,
  'sessionIds': ['session-1'],
  'createdAt': '2026-10-24T05:54:09.208Z',
  'updatedAt': updatedAt,
};

void main() {
  late FakeDsh host;

  setUp(() async => host = await FakeDsh.start());
  tearDown(() async => host.close());

  Future<DshClient> connect() async {
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, muxOptions: fastMux);
    addTearDown(client.close);
    return client;
  }

  Map<String, Object?> argsOf(String endpoint) =>
      ((host.rpcCalls.lastWhere((c) => c['method'] == endpoint)['payload'] as Map)['args'] as Map)
          .cast<String, Object?>();

  group('directory picker', () {
    test('browseDirectory parses one level with its crumbs; no path lists home', () async {
      host.handlers['directoryPicker/list'] = (_) => ok(_listing);
      final client = await connect();
      final level = await client.browseDirectory();
      expect(argsOf('directoryPicker/list'), isEmpty);
      expect(level.path, '/home/u/proj');
      expect(level.home, '/home/u');
      expect(level.name, 'proj');
      expect(level.parent?.path, '/home/u');
      expect([for (final c in level.crumbs) c.path], ['/', '/home', '/home/u', '/home/u/proj']);
      expect(level.entries.first.hidden, isTrue);
      expect(level.entries.last.name, 'a');
      expect(level.truncated, isFalse);

      await client.browseDirectory('/home/u/proj');
      expect(argsOf('directoryPicker/list'), {'path': '/home/u/proj'});
    });

    test('the root has no parent; a listing without crumbs gets one for itself', () {
      final root = DirectoryLevel.fromJson({
        'path': '/',
        'home': '/root',
        'crumbs': [
          {'name': '/', 'path': '/', 'hidden': false},
        ],
        'entries': <Object?>[],
        'truncated': true,
      });
      expect(root.parent, isNull);
      expect(root.truncated, isTrue);
      final bare = DirectoryLevel.fromJson({'path': '/srv', 'home': '/root'});
      expect(bare.crumbs.single.path, '/srv');
      expect(bare.entries, isEmpty);
    });

    test('createDirectory sends parent and name; Host refusals keep their codes', () async {
      host.handlers['directoryPicker/createDirectory'] = (args) =>
          args['name'] == 'c' ? ok('/home/u/proj/c') : fail(WorkspaceErrors.exists, {'path': '/home/u/proj/a'});
      final client = await connect();
      expect(await client.createDirectory('/home/u/proj', 'c'), '/home/u/proj/c');
      expect(argsOf('directoryPicker/createDirectory'), {'path': '/home/u/proj', 'name': 'c'});
      await expectLater(
        client.createDirectory('/home/u/proj', 'a'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', WorkspaceErrors.exists)),
      );
    });

    test('the HTTP carrier serves browsing and folder creation', () async {
      final client = await connect();
      expect(client.canBrowseDirectories, isTrue);
      expect(client.canCreateDirectories, isTrue);
    });
  });

  group('workspace', () {
    test('rename, delete and move wrap their arguments in `request`', () async {
      host.handlers['workspace/rename'] = (args) => ok({'workspace': _workspace('w1', 'Project C')});
      host.handlers['workspace/delete'] = (_) => ok({'deleted': true});
      host.handlers['workspace/insertBefore'] = (_) => ok({
        'workspaceIds': ['w1', 'w2'],
      });
      final client = await connect();

      final renamed = await client.renameWorkspace('w1', 'Project C');
      expect(argsOf('workspace/rename'), {
        'request': {'workspaceId': 'w1', 'title': 'Project C'},
      });
      expect(renamed.title, 'Project C');
      expect(renamed.sessionIds, ['session-1']);
      expect(renamed.updatedAt, DateTime.utc(2026, 10, 24, 5, 54, 9, 212));

      await client.deleteWorkspace('w1');
      expect(argsOf('workspace/delete'), {
        'request': {'workspaceId': 'w1'},
      });

      expect(await client.moveWorkspace('w1', beforeId: 'w2'), ['w1', 'w2']);
      expect(argsOf('workspace/insertBefore'), {
        'request': {'workspaceId': 'w1', 'beforeWorkspaceId': 'w2'},
      });
      await client.moveWorkspace('w1');
      expect(argsOf('workspace/insertBefore'), {
        'request': {'workspaceId': 'w1'},
      });
    });

    test('a name clash surfaces as workspace/name-conflict', () async {
      host.handlers['workspace/rename'] = (_) => fail(WorkspaceErrors.nameConflict, {'name': 'a'});
      final client = await connect();
      await expectLater(
        client.renameWorkspace('w1', 'a'),
        throwsA(isA<DshRemoteException>().having((e) => e.code, 'code', WorkspaceErrors.nameConflict)),
      );
    });

    test('pin and unpin return the pin set', () async {
      host.handlers['workspace/pinSession'] = (_) => ok({
        'pinnedSessionIds': ['session-2', 'session-1'],
      });
      host.handlers['workspace/unpinSession'] = (_) => ok({'pinnedSessionIds': <Object?>[]});
      final client = await connect();
      expect(await client.pinSession('session-2'), ['session-2', 'session-1']);
      expect(argsOf('workspace/pinSession'), {
        'request': {'sessionId': 'session-2'},
      });
      expect(await client.unpinSession('session-2'), isEmpty);
      expect(argsOf('workspace/unpinSession'), {
        'request': {'sessionId': 'session-2'},
      });
    });

    test('a `replace` frame reads as a full state; other frames do not', () {
      final replace = WorkspaceUpdate.fromJson({
        'type': 'replace',
        'value': {
          'items': [_workspace('w2', 'b')],
          'archivedSessionIds': ['session-9'],
          'pinnedSessionIds': ['session-1'],
        },
      });
      final full = workspaceReplaceFrame(replace);
      expect(full, isNotNull);
      expect(full!.workspaces.single.workspaceId, 'w2');
      expect(full.archivedSessionIds, ['session-9']);
      expect(full.pinnedSessionIds, ['session-1']);
      expect(workspaceReplaceFrame(WorkspaceUpdate.fromJson({'type': 'order', 'workspaceIds': <Object?>[]})), isNull);
    });
  });
}
