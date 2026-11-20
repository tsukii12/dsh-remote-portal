import 'dart:async';
import 'dart:io';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

void main() {
  test('control preserves baseline, all same-seq keys, null values and legacy frames', () async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    host.onOpen = (socket, id, endpoint, payload) {
      if (endpoint != 'session/control') return;
      socket.item(id, {
        'type': 'baseline',
        'value': {'projections': <String, Object?>{}},
      });
      socket.item(id, {
        'type': 'projection',
        'sessionId': 's',
        'seq': 5,
        'changes': [
          {'key': 'title', 'val': 'Renamed'},
          {'key': 'goal', 'val': null},
        ],
      });
      socket.item(id, {'type': 'projection', 'sessionId': 's', 'seq': 6, 'changes': []});
      socket.item(id, {'type': 'projection', 'sessionId': 's', 'seq': 7, 'key': 'title', 'value': 'Legacy'});
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    addTearDown(client.close);
    final frames = await client.watchSessionControl().take(4).toList().timeout(const Duration(seconds: 5));
    expect(frames.first, isA<SessionControlBaseline>());
    final updates = frames.skip(1).cast<SessionControlProjection>().toList();
    expect(updates.map((u) => u.key), ['title', 'goal', 'title']);
    expect(updates.map((u) => u.seq), [5, 5, 7]);
    expect(updates.map((u) => u.value), ['Renamed', null, 'Legacy']);
    var merged = SessionProjections.empty;
    for (final update in updates.take(2)) {
      merged = merged.withValue(update.key, update.value, update.seq);
    }
    expect(merged.values, {'title': 'Renamed', 'goal': null});
  });

  test('real Host control delivers a title update after baseline', () async {
    final client = await DshClient.connect(launchUrl: Platform.environment['DSH_LIVE_URL']);
    addTearDown(client.close);
    final session = await client.createSession(cwd: Platform.environment['DSH_LIVE_CWD']);
    final baseline = Completer<void>();
    final changed = Completer<SessionControlProjection>();
    final sub = client.watchSessionControl().listen((frame) {
      if (frame is SessionControlBaseline && !baseline.isCompleted) baseline.complete();
      if (frame is SessionControlProjection &&
          frame.sessionId == session.sessionId &&
          frame.key == 'title' &&
          !changed.isCompleted) {
        changed.complete(frame);
      }
    });
    addTearDown(sub.cancel);
    await baseline.future.timeout(const Duration(seconds: 5));
    await client.renameSession(session.sessionId, 'Synthetic control title');
    final update = await changed.future.timeout(const Duration(seconds: 5));
    expect(update.value, 'Synthetic control title');
    expect(update.seq, greaterThanOrEqualTo(0));
  }, skip: Platform.environment['DSH_LIVE_URL'] == null ? 'requires disposable live Host' : null);
}
