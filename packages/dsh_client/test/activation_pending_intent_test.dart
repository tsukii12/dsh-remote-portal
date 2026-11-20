import 'dart:async';
import 'dart:convert';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

void main() {
  test('a new independent lease is not lost behind a revoked pending lease', () async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    host.indexHtml =
        '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
          'rev': 'test',
          'entries': [],
          'release': {'version': '0.2.2-alpha.2'},
        })}</script>';
    var openings = 0;
    host.onOpen = (socket, id, endpoint, payload) {
      openings++;
      socket.item(id, {
        'type': 'snapshot',
        'header': {'version': 4, 'id': 's', 'createdAt': 0, 'isSeeded': false},
        'cursor': 0,
        'records': [],
        'hasMore': false,
        'projections': {'asOfSeq': 0, 'values': {}},
      });
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    addTearDown(client.close);
    SessionFollowEpoch? epoch;
    final baseline = Completer<void>();
    final sub = client.watch('s', options: const WatchOptions(includeSyncEvents: true)).listen((e) {
      if (e is SessionSyncEvent) epoch = e.epoch;
      if (e is SessionSnapshotEvent && !baseline.isCompleted) baseline.complete();
    });
    addTearDown(sub.cancel);
    await baseline.future;
    final entered = Completer<void>();
    final release = Completer<void>();
    host.beforeIndex = () {
      entered.complete();
      return release.future;
    };
    var firstAllowed = true;
    final firstChecks = <bool>[];
    final secondChecks = <bool>[];
    final first = client.activateSessionForInteraction(
      's',
      epoch: epoch!,
      allowed: () => firstAllowed,
      onActivationChecked: firstChecks.add,
    );
    await entered.future;
    firstAllowed = false;
    final second = client.activateSessionForInteraction(
      's',
      epoch: epoch!,
      allowed: () => true,
      onActivationChecked: secondChecks.add,
    );
    release.complete();
    expect(await first, isFalse);
    expect(await second, isTrue, reason: 'the second lease owns a separate live intent');
    expect(openings, 2, reason: 'one shared auxiliary at most');
    expect(firstChecks, isEmpty);
    expect(secondChecks, [true]);
  });
}
