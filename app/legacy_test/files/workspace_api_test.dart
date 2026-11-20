// dsh_client's workspace API (workspace_api.dart): wire arguments, parsing,
// and the change feed that opens on each link generation without starting a
// connection itself.

import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'support/memory_workspace.dart';

class _Carrier extends DshCarrier {
  final calls = <(String, Map<String, Object?>)>[];
  final Map<String, Object?> answers = {};
  final links = <_Link>[];

  @override
  String get kind => 'fake';

  @override
  DshTracer? get tracer => null;

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    calls.add((endpoint, args));
    return RpcOk(answers[endpoint]);
  }

  @override
  Future<DshMuxLink> openLink(MuxOptions options) async {
    final link = _Link();
    links.add(link);
    return link;
  }

  @override
  Future<void> close() async {}
}

class _Link implements DshMuxLink {
  DshMuxFrameHandler? _onFrame;
  DshMuxLossHandler? _onLost;
  final opened = <(String id, String endpoint, Map<String, Object?> payload)>[];
  final cancelled = <String>[];

  @override
  void start({required DshMuxFrameHandler onFrame, required DshMuxLossHandler onLost}) {
    _onFrame = onFrame;
    _onLost = onLost;
  }

  @override
  void open(String streamId, String endpoint, Map<String, Object?> payload) {
    opened.add((streamId, endpoint, payload));
    if (endpoint == r'$events') {
      scheduleMicrotask(
        () => _onFrame?.call({
          'type': 'item',
          'streamId': streamId,
          'value': {
            'type': 'ready',
            'clientId': 'c1',
            'host': {'home': '/root'},
          },
        }),
      );
    }
  }

  String idOf(String endpoint) => opened.lastWhere((o) => o.$2 == endpoint).$1;

  void item(String streamId, Object? value) => _onFrame?.call({'type': 'item', 'streamId': streamId, 'value': value});

  void error(String streamId, String code) => _onFrame?.call({
    'type': 'error',
    'streamId': streamId,
    'error': {'code': code, 'message': code, 'details': <String, Object?>{}},
  });

  void lose() => _onLost?.call(const DshCarrierLostException('gone'), null);

  @override
  void sendItem(String streamId, Object? value) {}

  @override
  void endUplink(String streamId) {}

  @override
  void cancel(String streamId) => cancelled.add(streamId);

  @override
  Future<void> close(int code, String reason) async {}
}

// Hold the first real stat snapshot, not the read of the file's current data.
class _HeldStatWorkspace extends MemoryWorkspace {
  _HeldStatWorkspace({required super.files, required super.modified});

  final release = Completer<void>();
  bool captured = false;

  @override
  Future<DshFileStat> stat(String path) async {
    final snapshot = await super.stat(path);
    if (rel(path) == 'a.txt' && !captured) {
      captured = true;
      await release.future;
    }
    return snapshot;
  }
}

ProviderContainer _directoryContainer(_HeldStatWorkspace workspace) {
  final container = ProviderContainer(overrides: [
    workspaceSourceProvider('s1').overrideWithValue(workspace),
    workspaceRootProvider('s1').overrideWithValue(workspace.root),
  ]);
  container.listen(workspaceDirProvider(('s1', '')), (_, _) {});
  addTearDown(() {
    if (!workspace.release.isCompleted) workspace.release.complete();
    container.dispose();
  });
  return container;
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  late _Carrier carrier;
  late DshClient client;

  setUp(() {
    carrier = _Carrier();
    client = DshClient.withCarrier(carrier, muxOptions: const MuxOptions(retryCaps: [Duration(milliseconds: 1)]));
  });

  tearDown(() => client.close());

  test('list: the root goes out as `.`', () async {
    carrier.answers['workspaceFiles/list'] = {
      'path': '',
      'entries': [
        {'name': 'lib', 'type': 'directory'},
        {'name': 'a.txt', 'type': 'file', 'size': 3},
        {'name': 'sock', 'type': 'other'},
        {'type': 'file'},
      ],
      'truncated': true,
    };
    final listing = await client.listWorkspace('s1', '');
    expect(carrier.calls.single.$1, 'workspaceFiles/list');
    expect(carrier.calls.single.$2, {'workspaceFileScopeId': 's1', 'path': '.'});
    expect(listing.entries.map((e) => (e.name, e.type, e.size)), [
      ('lib', DshWorkspaceEntryType.directory, null),
      ('a.txt', DshWorkspaceEntryType.file, 3),
      ('sock', DshWorkspaceEntryType.other, null),
    ]);
    expect(listing.truncated, isTrue);
    await client.listWorkspace('s1', 'lib');
    expect(carrier.calls.last.$2['path'], 'lib');
  });

  test('read: a line window, capped at the Host page limit', () async {
    carrier.answers['workspaceFiles/read'] = {
      'absolutePath': '/w/a.txt',
      'version': 'v1',
      'bytes': 12,
      'offset': 501,
      'text': 'x\ny',
      'lines': 2,
      'eof': true,
    };
    final page = await client.readWorkspaceText('s1', 'a.txt', offset: 501, limit: 9000);
    expect(carrier.calls.single.$2, {
      'workspaceFileScopeId': 's1',
      'path': 'a.txt',
      'range': {'offset': 501, 'limit': workspaceMaxPageLines},
    });
    expect((page.text, page.lines, page.eof, page.offset, page.version, page.bytes), ('x\ny', 2, true, 501, 'v1', 12));
  });

  test('readBytes window: base64 over the tunnel', () async {
    carrier.answers['workspaceFiles/readBytes'] = {
      'data': base64Encode(utf8.encode('a,b')),
      'eof': false,
      'offset': 0,
      'bytes': 9000,
    };
    final window = await client.readWorkspaceWindow('s1', 'x.csv', length: 3);
    expect(carrier.calls.single.$2, {
      'workspaceFileScopeId': 's1',
      'path': 'x.csv',
      'options': {
        'range': {'offset': 0, 'length': 3},
      },
    });
    expect(utf8.decode(window.data), 'a,b');
    expect((window.eof, window.bytes), (false, 9000));
  });

  test('frames', () {
    expect(DshWorkspaceWatchFrame.fromJson({'kind': 'ready'}), isA<DshWorkspaceWatchReady>());
    final change = DshWorkspaceWatchFrame.fromJson({
      'kind': 'change',
      'change': {'absolutePath': '/w/a', 'version': 'v2'},
    });
    expect(change, isA<DshWorkspaceWatchChange>().having((c) => c.version, 'version', 'v2'));
    final gone = DshWorkspaceWatchFrame.fromJson({
      'kind': 'change',
      'change': {'absolutePath': '/w/a', 'absent': true},
    });
    expect(gone, isA<DshWorkspaceWatchChange>().having((c) => c.absent, 'absent', isTrue));
    expect(DshWorkspaceWatchFrame.fromJson({'kind': 'later'}), isNull);
  });

  test('changes: waits for a link, reopens on every generation', () async {
    final frames = <DshWorkspaceWatchFrame>[];
    final sub = client.watchWorkspace('s1', '').listen(frames.add);
    await _settle();
    // Nobody connected: the feed doesn't either.
    expect(carrier.links, isEmpty);

    await client.mux.start();
    await _settle();
    final link = carrier.links.single;
    final id = link.idOf('workspaceFiles/changes');
    expect(link.opened.last.$3, {
      'args': {'workspaceFileScopeId': 's1', 'path': '.'},
    });
    link.item(id, {'kind': 'ready'});
    link.item(id, {
      'kind': 'change',
      'change': {'absolutePath': '/w', 'version': 'v1'},
    });
    await _settle();
    expect(frames, [isA<DshWorkspaceWatchReady>(), isA<DshWorkspaceWatchChange>()]);

    // The link drops and comes back: the watch opens again, ready first.
    link.lose();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(carrier.links.length, 2);
    final again = carrier.links.last;
    final id2 = again.idOf('workspaceFiles/changes');
    again.item(id2, {'kind': 'ready'});
    await _settle();
    expect(frames.length, 3);

    await sub.cancel();
    await _settle();
    expect(again.cancelled, contains(id2));
  });

  test('changes: a Host refusal ends the feed with the error', () async {
    await client.mux.start();
    final errors = <Object>[];
    final done = Completer<void>();
    client.watchWorkspace('s1', 'sub').listen((_) {}, onError: errors.add, onDone: done.complete);
    await _settle();
    final link = carrier.links.single;
    link.error(link.idOf('workspaceFiles/changes'), 'workspace-file/watch-unsupported');
    await done.future.timeout(const Duration(seconds: 2));
    expect(errors.single, isA<DshRemoteException>().having((e) => e.code, 'code', 'workspace-file/watch-unsupported'));
  });

  group('directory timestamp ownership', () {
    final oldTime = DateTime(2026, 10, 24, 9, 30);
    final newTime = DateTime(2026, 10, 24, 10, 30);
    final dir = workspaceDirProvider(('s1', ''));

    for (final content in ['longer', 'b']) {
      testWidgets('refresh ${content.length == 1 ? "same size" : "resized"} keeps the newer stat', (tester) async {
        final ws = _HeldStatWorkspace(files: {'a.txt': 'a'}, modified: oldTime);
        final container = _directoryContainer(ws);
        await tester.pump();
        expect(ws.captured, isTrue);
        expect(container.read(dir).times, isEmpty);

        ws.write('a.txt', content, at: newTime);
        await container.read(dir.notifier).refresh();
        await tester.pump();
        expect(container.read(dir).times['a.txt'], newTime);
        expect(ws.calls.where((c) => c == 'stat a.txt').length, 2);

        ws.release.complete();
        await tester.pump();
        expect(container.read(dir).entries.single.size, content.length);
        expect(container.read(dir).times['a.txt'], newTime);
      });
    }

    testWidgets('a size returning to its old value does not accept the old stat', (tester) async {
      final ws = _HeldStatWorkspace(files: {'a.txt': 'a'}, modified: oldTime);
      final container = _directoryContainer(ws);
      await tester.pump();
      expect(ws.captured, isTrue);
      ws.write('a.txt', 'longer', at: oldTime.add(const Duration(minutes: 10)));
      await container.read(dir.notifier).refresh();
      await tester.pump();
      ws.write('a.txt', 'c', at: newTime);
      await container.read(dir.notifier).refresh();
      await tester.pump();
      expect(container.read(dir).times['a.txt'], newTime);
      ws.release.complete();
      await tester.pump();
      expect(container.read(dir).entries.single.size, 1);
      expect(container.read(dir).times['a.txt'], newTime);
      expect(ws.calls.where((c) => c == 'stat a.txt').length, 3);
    });

    testWidgets('unchanged relist keeps pending timestamps and the following batch', (tester) async {
      final ws = _HeldStatWorkspace(
        files: {for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) '$name.txt': name},
        modified: oldTime,
      );
      final container = _directoryContainer(ws);
      await tester.pump();
      expect(ws.captured, isTrue);
      expect(ws.calls.where((c) => c.startsWith('stat ')).length, 6);
      ws.reconnect();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(ws.calls.where((c) => c == 'list ').length, 2);
      expect(ws.calls.where((c) => c.startsWith('stat ')).length, 6);
      ws.release.complete();
      await tester.pump();
      expect(container.read(dir).times, {for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) '$name.txt': oldTime});
      expect(ws.calls.where((c) => c.startsWith('stat ')).length, 7);
    });
  });

  group('state helpers', () {
    test('natural order, folders first', () {
      final names = ['b10', 'B2', 'a', 'a01', 'a1', '_x', 'Z'];
      expect(names..sort(naturalCompare), ['_x', 'a', 'a01', 'a1', 'B2', 'b10', 'Z']);
      final entries = [
        const DshWorkspaceEntry(name: 'z.txt', type: DshWorkspaceEntryType.file),
        const DshWorkspaceEntry(name: 'src', type: DshWorkspaceEntryType.directory),
        const DshWorkspaceEntry(name: 'A.txt', type: DshWorkspaceEntryType.file),
      ]..sort(compareWorkspaceEntries);
      expect(entries.map((e) => e.name), ['src', 'A.txt', 'z.txt']);
    });

    test('modified time from the version token, when it has one', () {
      final at = DateTime(2026, 10, 24, 9, 30);
      final ns = BigInt.from(at.millisecondsSinceEpoch) * BigInt.from(1000000);
      expect(modifiedFromVersion('36:182198:19:$ns:$ns'), at);
      expect(modifiedFromVersion('opaque'), isNull);
      expect(modifiedFromVersion('1:2:3:4'), isNull);
      expect(modifiedFromVersion('1:2:3:x:5'), isNull);
      // Nonsense times are dropped.
      expect(modifiedFromVersion('1:2:3:5:5'), isNull);
    });

    test('paths', () {
      expect(workspaceHostPath(null, ''), '');
      expect(workspaceHostPath(null, 'a/b'), 'a/b');
      expect(workspaceHostPath('/w', ''), '/w');
      expect(workspaceHostPath('/w', 'a'), '/w/a');
      expect(workspaceHostPath('/', 'a'), '/a');
      expect(workspaceChild('', 'a'), 'a');
      expect(workspaceChild('a', 'b'), 'a/b');
      expect(workspaceParent('a/b/c'), 'a/b');
      expect(workspaceParent('a'), '');
    });
  });
}
