import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/ui/chat/render/markdown_body.dart';
import 'package:dsh_app/ui/chat/render/markdown_image.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart' show fakeConnection, testApp;

List<Artifact> _presented(List<String> paths) {
  final transcript = ChatTranscript();
  var seq = 0;
  void event(String type, Map<String, Object?> data) {
    transcript.apply(
      parseFollowFrame('s1', {
        'type': 'event',
        'event': {'type': type, 'seq': seq++, 'time': 1792900000000, 'data': data},
      }),
    );
  }

  event('turn/start', {'turn': 1});
  event(presentedEventType, {
    'turn': 1,
    'callId': 'present1',
    'files': [
      for (final path in paths) {'path': path},
    ],
  });
  event('turn/end', {
    'turn': 1,
    'reason': {'kind': 'completed'},
  });
  return deriveArtifacts(events: transcript.events, turns: transcript.turns, cwd: '/root/workspace').single.files;
}

class _ImageReader implements WorkspaceImageReader {
  final calls = <(String, String)>[];

  @override
  Future<LoadedImage> read(String sessionId, String path) async {
    calls.add((sessionId, path));
    throw const ArtifactError('missing');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('percent-decoded boundary spaces remain part of the linked path', () {
    const cwd = '/root/workspace';
    expect(resolveWorkspaceLink('%20report.pdf%20', baseDir: cwd), '$cwd/ report.pdf ');
    expect(resolveWorkspaceLink('file:///tmp/report.pdf%20'), '/tmp/report.pdf ');
    expect(resolveWorkspaceLink('report.pdf%C2%A0', baseDir: cwd), '$cwd/report.pdf\u00a0');
    expect(linkedPaths('[spaced](report.pdf%20) [ordinary](report.pdf)', cwd: cwd), [
      '$cwd/report.pdf ',
      '$cwd/report.pdf',
    ]);
  });

  test('two presented paths must not collapse into one artifact', () {
    final files = _presented(['/root/report.pdf ', '/root/report.pdf']);
    expect(files.map((file) => file.path), ['/root/report.pdf ', '/root/report.pdf']);
    expect(files.map((file) => file.origin), [ArtifactOrigin.delivered, ArtifactOrigin.delivered]);
  });

  test('materialization reads the requested file rather than its ordinary sibling', () async {
    final directory = await Directory.systemTemp.createTemp('artifact-whitespace-');
    addTearDown(() => directory.delete(recursive: true));
    final ordinary = File('${directory.path}/report.pdf')..writeAsStringSync('ordinary sibling');
    final spaced = File('${directory.path}/report.pdf ')..writeAsStringSync('requested trailing-space file');
    const channel = MethodChannel('dsh/files');
    final requests = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'resolveGuest');
      final path = (call.arguments as Map)['path']! as String;
      requests.add(path);
      return switch (path) {
        '/root/report.pdf ' => spaced.path,
        '/root/report.pdf' => ordinary.path,
        _ => null,
      };
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final artifact = _presented(['/root/report.pdf ']).single;
    final files = ArtifactFiles(connection: fakeConnection, channel: const FilesChannel());
    final materialized = await files.materialize('s1', artifact);
    expect(await materialized.readAsString(), 'requested trailing-space file');
    expect(requests, ['/root/report.pdf ']);
    expect(await ordinary.readAsString(), 'ordinary sibling');
  });

  testWidgets('the real Markdown image reader receives the decoded trailing space', (tester) async {
    final reader = _ImageReader();
    await tester.pumpWidget(
      testApp(
        const MarkdownImageScope(
          sessionId: 's1',
          baseDir: '/root/workspace',
          child: Material(child: MarkdownBody(text: '![chart](chart.png%20)')),
        ),
        overrides: [
          activeConnectionProvider.overrideWithValue(const AsyncData(null)),
          workspaceImageReaderProvider.overrideWithValue(CachedImageReader(reader)),
        ],
      ),
    );
    await tester.pump();
    expect(reader.calls, [('s1', '/root/workspace/chart.png ')]);
    expect(tester.takeException(), isNull);
  });
}
