/// Explicitly enabled against a disposable 0.2.2 Host with default deflate.
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

void main() {
  test('default deflate negotiates and preserves a large control baseline', () async {
    final client = await DshClient.connect(launchUrl: Platform.environment['DSH_LIVE_URL']);
    addTearDown(client.close);
    for (var i = 0; i < 3; i++) {
      await client.createSession(cwd: Platform.environment['DSH_LIVE_CWD']);
    }
    final socket = await client.connection.connectWebSocket('/api/remote.mux');
    addTearDown(socket.close);
    // Dart 3.13 WebSocket.extensions is hardcoded empty; the live runner
    // independently records negotiated headers and RSV1 frames without payloads.
    socket.add(
      jsonEncode({
        'type': 'open',
        'streamId': 'compression-probe',
        'endpoint': 'session/control',
        'payload': {'args': <String, Object?>{}},
      }),
    );
    final raw = await socket.first.timeout(const Duration(seconds: 5));
    expect(raw, isA<String>());
    expect((raw as String).length, greaterThan(1024));
    final frame = jsonDecode(raw) as Map;
    expect(frame['type'], 'item');
    expect((frame['value'] as Map)['type'], 'baseline');
  }, skip: Platform.environment['DSH_DEFLATE_LIVE'] != '1' ? 'requires disposable rc.1 default-deflate Host' : null);
}
