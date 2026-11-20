import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';

import '../test/support/fake_dsh.dart';

Future<void> main(List<String> args) async {
  final label = args[0], scenario = args[1], phase = args[2];
  final count = switch (scenario) {
    'tiny' => 8,
    'medium' => 256,
    _ => 4096,
  };
  for (var sample = -3; sample < 9; sample++) {
    final host = await FakeDsh.start();
    final entered = Completer<void>(), gate = Completer<void>();
    host.beforeEventsReady = () {
      if (!entered.isCompleted) entered.complete();
      return gate.future;
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    try {
      MuxStream open(String id) => client.mux.open('session/follow', {
        'request': {'address': client.sessionAddressOf(id)},
      });
      final probe = open('probe');
      final probeDone = probe.items.drain<void>();
      await entered.future;
      var streams = <MuxStream>[];
      if (phase == 'cancel') streams = [for (var i = 0; i < count; i++) open('s-$i')];
      final watch = Stopwatch()..start();
      if (phase == 'queue-cancel') streams = [for (var i = 0; i < count; i++) open('s-$i')];
      final ordered = scenario == 'reverse' ? streams.reversed : streams;
      await Future.wait([for (final stream in ordered) stream.cancel()]);
      watch.stop();
      final sentinel = open('sentinel');
      final sentinelDone = sentinel.items.drain<void>();
      final opened = <String>[];
      final finished = Completer<void>();
      host.onOpen = (socket, id, endpoint, payload) {
        opened.add(id);
        socket.send({'type': 'end', 'streamId': id});
        if (id == sentinel.streamId) finished.complete();
      };
      gate.complete();
      await finished.future;
      await Future.wait([probeDone, sentinelDone, for (final s in streams) s.items.drain<void>()]);
      if (opened.length != 2 ||
          opened[0] != probe.streamId ||
          opened[1] != sentinel.streamId ||
          streams.any((s) => !s.isClosed)) {
        throw StateError('pending cancellation/order oracle failed');
      }
      if (host.sockets.single.received.any((f) => f['type'] == 'cancel')) {
        throw StateError('unopened streams sent cancellation');
      }
      if (sample >= 0) {
        print(
          jsonEncode({
            'label': label,
            'scenario': scenario,
            'phase': phase,
            'sample': sample,
            'pending': count,
            'elapsedUs': watch.elapsedMicroseconds,
            'usPerOperation': watch.elapsedMicroseconds / count,
          }),
        );
      }
    } finally {
      if (!gate.isCompleted) gate.complete();
      await client.close();
      await host.close();
    }
  }
}
