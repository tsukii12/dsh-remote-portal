// Live check of the 文件 page's Host calls against a running `dsh web`.
//
// Skipped unless DSH_LIVE_URL (the `dsh web:` launch URL with `?token=`) and
// DSH_LIVE_CWD (a throwaway folder this test may write into) are set:
//
//   DSH_LIVE_URL='http://127.0.0.1:3080/?token=…' DSH_LIVE_CWD=/tmp/ws \
//     flutter test test/files/workspace_live_test.dart
library;

import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/state/workspace_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final url = Platform.environment['DSH_LIVE_URL'];
  final cwd = Platform.environment['DSH_LIVE_CWD'];
  final skip = url == null || cwd == null ? 'set DSH_LIVE_URL and DSH_LIVE_CWD' : null;

  group('live workspace', skip: skip, () {
    late DshClient client;
    late String sessionId;
    late WorkspaceSource source;

    setUpAll(() async {
      client = await DshClient.connect(launchUrl: url);
      final created = asMapOrNull(
        await client.rpc.call('session/create', {
          'request': {'cwd': cwd},
        }),
      );
      sessionId = created!['sessionId']! as String;
      source = ClientWorkspaceSource(client, sessionId);
      Directory('$cwd/live/sub').createSync(recursive: true);
      File('$cwd/live/a.txt').writeAsStringSync([for (var i = 1; i <= 1200; i++) 'line $i'].join('\n'));
      File('$cwd/live/t.csv').writeAsStringSync('k,v\n1,2\n');
    });

    tearDownAll(() async {
      Directory('$cwd/live').deleteSync(recursive: true);
      await client.close();
    });

    test('root and folders list; relative and absolute agree', () async {
      final root = await source.list('');
      expect(root.path, '');
      expect(root.entries.map((e) => e.name), contains('live'));
      final rel = await source.list('live');
      final abs = await source.list('$cwd/live');
      expect(rel.entries.map((e) => e.name).toSet(), {'sub', 'a.txt', 't.csv'});
      expect(abs.entries.map((e) => e.name).toSet(), rel.entries.map((e) => e.name).toSet());
    });

    test('pages, windows, stat time', () async {
      final first = await source.read('live/a.txt', limit: 500);
      expect((first.lines, first.eof), (500, false));
      final next = await source.read('live/a.txt', offset: 501, limit: 500);
      expect(next.text.split('\n').first, 'line 501');
      expect(next.version, first.version);
      final window = await source.readWindow('live/t.csv', length: 2 * 1024 * 1024);
      expect(utf8.decode(window.data), 'k,v\n1,2\n');
      expect(window.eof, isTrue);
      final stat = await source.stat('live/a.txt');
      final at = modifiedFromVersion(stat.version);
      expect(at, isNotNull, reason: stat.version);
      expect(at!.difference(File('$cwd/live/a.txt').lastModifiedSync()).inSeconds.abs(), lessThan(2));
    });

    test('a folder watch says ready, then each change', () async {
      final frames = <DshWorkspaceWatchFrame>[];
      final sub = source.watch('live').listen(frames.add);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (frames.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(frames.first, isA<DshWorkspaceWatchReady>());
      File('$cwd/live/new.md').writeAsStringSync('# new');
      while (frames.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(frames.last, isA<DshWorkspaceWatchChange>());
      await sub.cancel();
      expect((await source.list('live')).entries.map((e) => e.name), contains('new.md'));
    });

    test('a file watch reports new versions', () async {
      final frames = <DshWorkspaceWatchFrame>[];
      final sub = source.watch('live/t.csv').listen(frames.add);
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (frames.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      File('$cwd/live/t.csv').writeAsStringSync('k,v\n3,4\n');
      while (frames.length < 2 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final change = frames.whereType<DshWorkspaceWatchChange>().first;
      expect(change.version, isNotEmpty);
      expect(change.absolutePath, endsWith('/live/t.csv'));
      await sub.cancel();
    });

    test('name search', () async {
      final hits = await source.search('a.txt');
      expect(hits.map((h) => h.path), contains('live/a.txt'));
    });
  });
}

Map<String, Object?>? asMapOrNull(Object? value) => value is Map ? value.cast<String, Object?>() : null;
