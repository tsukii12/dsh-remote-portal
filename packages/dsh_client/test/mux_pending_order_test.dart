import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  for (final cancelOrder in ['forward', 'reverse', 'middle']) {
    test('pending $cancelOrder cancellation preserves remaining wire order and new tail', () async {
      final host = await FakeDsh.start();
      final entered = Completer<void>();
      final gate = Completer<void>();
      host.beforeEventsReady = () {
        if (!entered.isCompleted) entered.complete();
        return gate.future;
      };
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
      addTearDown(() async {
        if (!gate.isCompleted) gate.complete();
        await client.close();
        await host.close();
      });
      final streams = [
        for (var i = 0; i < 12; i++)
          client.mux.open('session/follow', {
            'request': {'address': client.sessionAddressOf('s-$i')},
          }),
      ];
      final drains = [for (final s in streams) s.items.drain<void>()];
      await entered.future;
      final removed = switch (cancelOrder) {
        'forward' => [0, 1, 2, 3, 4, 5],
        'reverse' => [11, 10, 9, 8, 7, 6],
        _ => [3, 5, 7, 4, 6],
      };
      for (final i in removed) {
        await streams[i].cancel();
        await streams[i].cancel(); // idempotent removal cannot remove a neighbour.
      }
      final tail = client.mux.open('session/follow', {
        'request': {'address': client.sessionAddressOf('tail')},
      });
      drains.add(tail.items.drain<void>());
      final expected = [
        for (var i = 0; i < streams.length; i++)
          if (!removed.contains(i)) streams[i].streamId,
        tail.streamId,
      ];
      final opened = <String>[];
      final finished = Completer<void>();
      host.onOpen = (socket, id, endpoint, payload) {
        opened.add(id);
        socket.send({'type': 'end', 'streamId': id});
        if (opened.length == expected.length) finished.complete();
      };
      gate.complete();
      await client.mux.ready();
      await finished.future;
      await Future.wait(drains);
      expect(opened, expected);
      expect(host.sockets.single.received.where((f) => f['type'] == 'cancel'), isEmpty);
    });
  }

  test('all pending cancellations followed by ready open only the later sentinel', () async {
    final host = await FakeDsh.start();
    final entered = Completer<void>();
    final gate = Completer<void>();
    host.beforeEventsReady = () {
      if (!entered.isCompleted) entered.complete();
      return gate.future;
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
    addTearDown(() async {
      if (!gate.isCompleted) gate.complete();
      await client.close();
      await host.close();
    });
    final streams = [
      for (var i = 0; i < 256; i++)
        client.mux.open('session/follow', {
          'request': {'address': client.sessionAddressOf('s-$i')},
        }),
    ];
    final drains = [for (final s in streams) s.items.drain<void>()];
    await entered.future;
    await Future.wait([for (final s in streams.reversed) s.cancel()]);
    final sentinel = client.mux.open('session/follow', {
      'request': {'address': client.sessionAddressOf('sentinel')},
    });
    drains.add(sentinel.items.drain<void>());
    final opened = <String>[];
    final finished = Completer<void>();
    host.onOpen = (socket, id, endpoint, payload) {
      opened.add(id);
      socket.send({'type': 'end', 'streamId': id});
      if (id == sentinel.streamId) finished.complete();
    };
    gate.complete();
    await finished.future;
    await Future.wait(drains);
    expect(opened, [sentinel.streamId]);
    expect(streams.every((s) => s.isClosed), isTrue);
  });
  for (final action in ['refuse', 'close']) {
    test('pending $action before ready settles remaining streams once', () async {
      final host = await FakeDsh.start();
      final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token, startMux: false);
      addTearDown(() async {
        await client.close();
        await host.close();
      });
      if (action == 'refuse') host.rejectWebSocket = true;
      final streams = [
        for (var i = 0; i < 8; i++)
          client.mux.open('session/follow', {
            'request': {'address': client.sessionAddressOf('s-$i')},
          }),
      ];
      final checks = [
        for (final s in streams.skip(1))
          expectLater(
            s.items.toList(),
            throwsA(action == 'close' ? isA<DshClosedException>() : isA<DshHttpException>()),
          ),
      ];
      final cancelled = streams.first.items.toList();
      await streams.first.cancel();
      if (action == 'close') await client.close();
      await Future.wait(checks);
      expect(await cancelled, isEmpty);
      expect(streams.every((s) => s.isClosed), isTrue);
      expect(client.mux.state, action == 'close' ? DshConnectionState.closed : DshConnectionState.unauthorized);
    });
  }
}
