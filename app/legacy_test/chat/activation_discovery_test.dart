import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/session_sync_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final baselineFirst in [true, false]) {
    test(
      'fresh alpha2 activates with baseline first: $baselineFirst without replacing main follow',
      () => HttpOverrides.runWithHttpOverrides(() async {
        final h = await SyncHarness.start(initialSnapshot: baselineFirst);
        void Function()? leave;
        try {
          h.host.indexHtml =
              '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
                'rev': 'test',
                'entries': [],
                'release': {'version': '0.2.2-alpha.2'},
              })}</script>';
          final requests = <Map>[];
          final original = h.host.onOpen!;
          h.host.onOpen = (socket, id, endpoint, payload) {
            if (endpoint == 'session/follow') requests.add((payload['args'] as Map)['request'] as Map);
            original(socket, id, endpoint, payload);
          };
          await waitSync(() => h.follows.isNotEmpty, 'main follow');
          final main = h.follows.first;
          final entered = Completer<void>();
          final release = Completer<void>();
          h.host.beforeIndex = () {
            if (!entered.isCompleted) entered.complete();
            return release.future;
          };
          leave = h.chat.beginInteraction(() => true);
          if (!baselineFirst) {
            h.followMode = 'snapshot';
            main.socket.item(main.id, syncSnapshot(1));
          }
          await entered.future.timeout(const Duration(seconds: 4));
          expect(h.state.controlReady, isTrue, reason: 'metadata must not hold syncReady');
          final send = h.chat.send('first message');
          await waitSync(() => h.methods.contains('session/prompt'), 'first send before release response');
          release.complete();
          await waitSync(() => requests.any((r) => r['activate'] == true), 'auxiliary activate');
          await send;
          expect(h.follows.length, 2, reason: 'one main and one auxiliary');
          expect(h.state.controlReady, isTrue);
          expect(h.cancelledBackendRuns, isEmpty);
          expect(h.observedTurns, [1], reason: 'auxiliary snapshot must not enter transcript');
          for (var i = 0; i < 3; i++) {
            leave!();
            leave = h.chat.beginInteraction(() => true);
          }
          await Future<void>.delayed(const Duration(milliseconds: 30));
          expect(h.follows.length, 2, reason: 'returning to an already activated epoch never reopens');
        } finally {
          leave?.call();
          await h.close();
        }
      }, RealSyncHttp()),
    );
  }

  test(
    'known alpha2 leases before a replacement baseline activate without another primary resync',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start();
      void Function()? leave;
      try {
        h.host.indexHtml =
            '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
              'rev': 'test',
              'entries': [],
              'release': {'version': '0.2.2-alpha.2'},
            })}</script>';
        final requests = <Map>[];
        final original = h.host.onOpen!;
        h.host.onOpen = (socket, id, endpoint, payload) {
          if (endpoint == 'session/follow') requests.add((payload['args'] as Map)['request'] as Map);
          original(socket, id, endpoint, payload);
        };
        leave = h.chat.beginInteraction(() => true);
        expect(await h.chat.resync(), isTrue);
        await waitSync(() => requests.any((r) => r['activate'] == true), 'first real alpha2 activation');
        final before = h.follows.length;
        leave();
        leave = null;
        final reads = h.host.requests.where((r) => r['path'] == '/').length;
        h.followMode = 'hold';
        final resync = h.chat.resync();
        await waitSync(() => h.follows.length == before + 1, 'replacement passive follow');
        leave = h.chat.beginInteraction(() => true);
        expect(h.follows.length, before + 1);
        h.followMode = 'snapshot';
        final main = h.follows.last;
        main.socket.item(main.id, syncSnapshot(1));
        expect(await resync, isTrue);
        await waitSync(() => h.follows.length == before + 2, 'activation after baseline');
        expect(h.state.controlReady, isTrue);
        expect(h.host.requests.where((r) => r['path'] == '/').length, reads);
        expect(h.cancelledBackendRuns, isEmpty);
      } finally {
        leave?.call();
        await h.close();
      }
    }, RealSyncHttp()),
  );

  test(
    'revoked interaction cannot activate after delayed metadata',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final h = await SyncHarness.start();
      try {
        h.host.indexHtml =
            '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
              'rev': 'test',
              'entries': [],
              'release': {'version': '0.2.2-alpha.2'},
            })}</script>';
        final entered = Completer<void>();
        final release = Completer<void>();
        h.host.beforeIndex = () {
          entered.complete();
          return release.future;
        };
        final leave = h.chat.beginInteraction(() => true);
        await entered.future.timeout(const Duration(seconds: 4));
        leave();
        release.complete();
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.follows.length, 1);
        expect(h.state.controlReady, isTrue);
        final again = h.chat.beginInteraction(() => true);
        await waitSync(() => h.follows.length == 2, 'later valid interaction uses cached release');
        again();
      } finally {
        await h.close();
      }
    }, RealSyncHttp()),
  );
}
