import 'dart:io';

import 'package:dsh_app/state/artifact_files.dart';
import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart' show fakeConnection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('a localhost link survives artifact derivation and resolves the existing local file', () async {
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
    event('tool/call', {
      'turn': 1,
      'step': 1,
      'callId': 'read',
      'name': 'bash',
      'arguments': '{"command":"ls /root/report.docx"}',
    });
    event('tool/result', {
      'turn': 1,
      'step': 1,
      'message': {
        'id': 'result',
        'role': 'tool',
        'toolCallId': 'read',
        'isError': false,
        'content': [
          {'type': 'text', 'text': '/root/report.docx'},
        ],
      },
    });
    event('assistant/message', {
      'turn': 1,
      'step': 2,
      'message': {
        'id': 'answer',
        'role': 'assistant',
        'content': [
          {'type': 'text', 'text': '[document](file://localhost/root/report.docx)'},
        ],
      },
    });
    event('turn/end', {
      'turn': 1,
      'reason': {'kind': 'completed'},
    });
    final artifact = deriveArtifacts(
      events: transcript.events,
      turns: transcript.turns,
      cwd: '/root/workspace',
    ).single.files.single;
    expect(artifact.origin, ArtifactOrigin.linked);

    final directory = Directory.systemTemp.createTempSync('artifact-path-test-');
    final existing = File('${directory.path}/report.docx')..writeAsStringSync('path fixture, no converter involved');
    addTearDown(() => directory.deleteSync(recursive: true));
    const channel = MethodChannel('dsh/files');
    final requests = <String>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'resolveGuest');
      final path = (call.arguments as Map)['path']! as String;
      requests.add(path);
      return path == '/root/report.docx' ? existing.path : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final files = ArtifactFiles(connection: fakeConnection, channel: const FilesChannel());
    File? materialized;
    Object? failure;
    try {
      materialized = await files.materialize('s1', artifact);
    } catch (error) {
      failure = error;
    }
    expect(failure, isNull, reason: 'resolveGuest received $requests for an existing /root/report.docx');
    expect(requests, ['/root/report.docx']);
    expect(materialized!.readAsStringSync(), 'path fixture, no converter involved');
  });
}
