import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/fake_dsh.dart';

void main() {
  Future<(FakeDsh, DshClient, List<Map<Object?, Object?>>)> setup(String? version) async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    host.indexHtml =
        '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
          'rev': 'test',
          'entries': [],
          if (version != null) 'release': {'version': version},
        })}</script>';
    final requests = <Map<Object?, Object?>>[];
    host.onOpen = (socket, id, endpoint, payload) {
      if (endpoint == 'session/follow') {
        requests.add((payload['args'] as Map<Object?, Object?>)['request'] as Map<Object?, Object?>);
        socket.item(id, {
          'type': 'snapshot',
          'header': {'version': 4, 'id': 's', 'createdAt': 0, 'isSeeded': false},
          'cursor': 0,
          'records': [],
          'hasMore': false,
          'projections': {'asOfSeq': 0, 'values': {}},
        });
      }
    };
    final client = await DshClient.connect(baseUri: host.baseUri, token: FakeDsh.token);
    addTearDown(client.close);
    return (host, client, requests);
  }

  Future<void> opened(List<Map<Object?, Object?>> requests, [int count = 1]) async {
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return requests.length < count;
    }).timeout(const Duration(seconds: 5));
  }

  for (final version in ['0.2.1-rc.2', '0.2.1-rc.4', null, 'bogus', '0.2.2-alpha.3']) {
    test('interactive watch omits activation for unconfirmed release $version', () async {
      final (host, client, requests) = await setup(version);
      final checked = Completer<bool>();
      final sub = client
          .watch('s', options: WatchOptions(activate: true, onActivationChecked: checked.complete))
          .listen((_) {});
      addTearDown(sub.cancel);
      expect(await checked.future.timeout(const Duration(seconds: 3)), isFalse);
      expect(requests.single, isNot(contains('activate')));
      final reads = host.requests.where((r) => r['path'] == '/').length;
      final checkedAgain = Completer<bool>();
      final other = client
          .watch('other', options: WatchOptions(activate: true, onActivationChecked: checkedAgain.complete))
          .listen((_) {});
      addTearDown(other.cancel);
      expect(await checkedAgain.future.timeout(const Duration(seconds: 3)), isFalse);
      expect(host.requests.where((r) => r['path'] == '/').length, reads);
      expect(requests.every((r) => !r.containsKey('activate')), isTrue);
    });
  }

  for (final (version, found) in [('0.2.1-rc.4', false), (null, false), ('0.2.2-alpha.2', true)]) {
    test('each release check is reported ($version: $found); a refused check is not made', () async {
      final (host, client, requests) = await setup(version);
      final checks = <bool>[];
      var interactive = true;
      final sub = client
          .watch(
            's',
            options: WatchOptions(
              activate: true,
              activationAllowed: () => interactive,
              onActivationChecked: checks.add,
            ),
          )
          .listen((_) {});
      addTearDown(sub.cancel);
      await Future.doWhile(() async {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        return checks.isEmpty;
      }).timeout(const Duration(seconds: 5));
      await opened(requests, found ? 2 : 1);
      expect(checks, [found]);
      expect(requests.first, isNot(contains('activate')));
      expect(requests.last['activate'], found ? true : isNull);
      // A reconnect without the interaction: no release read, nothing reported.
      interactive = false;
      final reads = host.requests.where((r) => r['path'] == '/').length;
      client.mux.reconnect();
      await opened(requests, found ? 3 : 2);
      expect(checks, [found]);
      expect(host.requests.where((r) => r['path'] == '/').length, reads);
      expect(requests.last, isNot(contains('activate')));
    });
  }

  test('confirmed alpha2 interactive watch activates inside request only', () async {
    final (_, client, requests) = await setup('0.2.2-alpha.2');
    final sub = client.watch('s', options: const WatchOptions(activate: true, includeSyncEvents: true)).listen((_) {});
    addTearDown(sub.cancel);
    await opened(requests, 2);
    expect(requests.first, isNot(contains('activate')));
    expect(requests.last['activate'], true);
    expect(requests.last['address'], {'kind': 'session', 'sessionId': 's'});
  });

  test('preview stays passive and does not fetch release metadata', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final before = host.requests.length;
    final sub = client.watch('s').listen((_) {});
    addTearDown(sub.cancel);
    await opened(requests);
    expect(requests.single, isNot(contains('activate')));
    expect(host.requests.skip(before).where((r) => r['path'] == '/'), isEmpty);
  });

  test('leaving while discovery is pending revokes activation', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final entered = Completer<void>();
    final release = Completer<void>();
    host.beforeIndex = () {
      entered.complete();
      return release.future;
    };
    var interactive = true;
    final sub = client
        .watch('s', options: WatchOptions(activate: true, activationAllowed: () => interactive))
        .listen((_) {});
    addTearDown(sub.cancel);
    await entered.future;
    interactive = false;
    release.complete();
    await opened(requests);
    expect(requests.single, isNot(contains('activate')));
  });

  test('reconnect rediscovers release; downgrade never reuses alpha2 evidence', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final sub = client.watch('s', options: const WatchOptions(activate: true, includeSyncEvents: true)).listen((_) {});
    addTearDown(sub.cancel);
    await opened(requests, 2);
    expect(requests.last['activate'], true);
    host.indexHtml = '';
    client.mux.reconnect();
    await opened(requests, 3);
    expect(requests.last, isNot(contains('activate')));
  });
  test('held discovery never blocks primary baseline; concurrent watches share one read', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final entered = Completer<void>();
    final release = Completer<void>();
    host.beforeIndex = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    final events = <DshEvent>[];
    final baseline = Completer<void>();
    final sub = client.watch('s', options: const WatchOptions(activate: true, includeSyncEvents: true)).listen((e) {
      events.add(e);
      if (e is SessionSnapshotEvent && !baseline.isCompleted) baseline.complete();
    });
    addTearDown(sub.cancel);
    await baseline.future.timeout(const Duration(seconds: 2));
    await entered.future;
    final epochs = events.whereType<SessionSyncEvent>().length;
    expect(requests.single, isNot(contains('activate')));
    final secondChecks = Completer<void>();
    final other = client
        .watch(
          'other',
          options: WatchOptions(
            activate: true,
            onActivationChecked: (_) {
              if (!secondChecks.isCompleted) secondChecks.complete();
            },
          ),
        )
        .listen((_) {});
    addTearDown(other.cancel);
    await opened(requests, 2);
    final before = host.requests.where((r) => r['path'] == '/').length;
    release.complete();
    await secondChecks.future;
    await opened(requests, 4);
    expect(host.requests.where((r) => r['path'] == '/').length, before);
    expect(events.whereType<SessionSyncEvent>().length, epochs);
    expect(events.whereType<SessionSnapshotEvent>().length, 1);
  });

  test('deadline caches unknown and ignores a late positive response', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final release = Completer<void>();
    host.beforeIndex = () => release.future;
    final checked = Completer<bool>();
    final sub = client
        .watch('s', options: WatchOptions(activate: true, onActivationChecked: checked.complete))
        .listen((_) {});
    addTearDown(sub.cancel);
    expect(await checked.future.timeout(const Duration(seconds: 3)), isFalse);
    expect(requests.single, isNot(contains('activate')));
    final reads = host.requests.where((r) => r['path'] == '/').length;
    release.complete();
    final again = Completer<bool>();
    final other = client
        .watch('other', options: WatchOptions(activate: true, onActivationChecked: again.complete))
        .listen((_) {});
    addTearDown(other.cancel);
    expect(await again.future, isFalse);
    expect(host.requests.where((r) => r['path'] == '/').length, reads);
    expect(requests.every((r) => !r.containsKey('activate')), isTrue);
  });

  test('gzip release HTML is decoded before auditing the version', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    host.gzipIndex = true;
    final sub = client.watch('s', options: const WatchOptions(activate: true, includeSyncEvents: true)).listen((_) {});
    addTearDown(sub.cancel);
    await opened(requests, 2);
    expect(requests.first, isNot(contains('activate')));
    expect(requests.last['activate'], isTrue);
  });

  test('late evidence from a retired generation never reports or activates', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final entered = Completer<void>();
    final release = Completer<void>();
    host.beforeIndex = () {
      if (!entered.isCompleted) entered.complete();
      return release.future;
    };
    final checks = <bool>[];
    final sub = client
        .watch('s', options: WatchOptions(activate: true, onActivationChecked: checks.add))
        .listen((_) {});
    addTearDown(sub.cancel);
    await entered.future;
    host.beforeIndex = null;
    host.indexHtml = '';
    client.mux.reconnect();
    await opened(requests, 2);
    await Future.doWhile(() async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      return checks.isEmpty;
    }).timeout(const Duration(seconds: 3));
    release.complete();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(checks, [false]);
    expect(requests.every((r) => !r.containsKey('activate')), isTrue);
  });

  test('same epoch deduplicates interaction and later successful returns', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    final baseline = Completer<void>();
    SessionFollowEpoch? epoch;
    final approvals = <ApprovalRequestedEvent>[];
    final approved = Completer<void>();
    final sub = client.watch('s', options: const WatchOptions(includeSyncEvents: true)).listen((e) {
      if (e is SessionSyncEvent) epoch = e.epoch;
      if (e is ApprovalRequestedEvent) {
        approvals.add(e);
        if (!approved.isCompleted) approved.complete();
      }
      if (e is SessionSnapshotEvent && !baseline.isCompleted) baseline.complete();
    });
    addTearDown(sub.cancel);
    await baseline.future;
    host.sockets.single.event({
      'type': 'waterfall',
      'event': 'approval/request',
      'eventId': 'pending-1',
      'agentId': 's',
      'request': {'toolName': 'bash', 'callId': 'call-1', 'reason': 'fixture'},
    });
    await approved.future.timeout(const Duration(seconds: 3));
    final results = await Future.wait(
      List.generate(5, (_) => client.activateSessionForInteraction('s', epoch: epoch!, allowed: () => true)),
    );
    expect(results, everyElement(isTrue));
    expect(approvals.length, 1, reason: 'auxiliary follow does not replay Host requests');
    expect(client.mux.pendingRequests.length, 1);
    expect(host.rpcCalls, isEmpty, reason: 'no implicit approval or session/cancel');
    expect(requests.length, 2);
    final reads = host.requests.where((r) => r['path'] == '/').length;
    expect(await client.activateSessionForInteraction('s', epoch: epoch!, allowed: () => true), isTrue);
    expect(requests.length, 2);
    expect(host.requests.where((r) => r['path'] == '/').length, reads);
  });

  test('callback revoking intent prevents dispatch after a positive probe', () async {
    final (_, client, requests) = await setup('0.2.2-alpha.2');
    var allowed = true;
    final checked = Completer<void>();
    final sub = client
        .watch(
          's',
          options: WatchOptions(
            activate: true,
            activationAllowed: () => allowed,
            onActivationChecked: (supported) {
              expect(supported, isTrue);
              allowed = false;
              checked.complete();
            },
          ),
        )
        .listen((_) {});
    addTearDown(sub.cancel);
    await checked.future;
    expect(requests.single, isNot(contains('activate')));
  });
  test('failed auxiliary opening retries only on a later explicit interaction', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
    SessionFollowEpoch? epoch;
    final baseline = Completer<void>();
    final sub = client.watch('s', options: const WatchOptions(includeSyncEvents: true)).listen((e) {
      if (e is SessionSyncEvent) epoch = e.epoch;
      if (e is SessionSnapshotEvent && !baseline.isCompleted) baseline.complete();
    });
    addTearDown(sub.cancel);
    await baseline.future;
    final original = host.onOpen!;
    var attempts = 0;
    host.onOpen = (socket, id, endpoint, payload) {
      final request = (payload['args'] as Map)['request'] as Map;
      if (request['activate'] == true && ++attempts == 1) {
        requests.add(request);
        socket.item(id, {'type': 'not-a-snapshot'});
      } else {
        original(socket, id, endpoint, payload);
      }
    };
    expect(await client.activateSessionForInteraction('s', epoch: epoch!, allowed: () => true), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(attempts, 1, reason: 'no automatic retry loop');
    expect(await client.activateSessionForInteraction('s', epoch: epoch!, allowed: () => true), isTrue);
    expect(attempts, 2);
    expect(requests.length, 3);
  });

  test('revoked lease receives neither positive callback nor activation after discovery', () async {
    final (host, client, requests) = await setup('0.2.2-alpha.2');
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
    var allowed = true;
    final checks = <bool>[];
    final pending = client.activateSessionForInteraction(
      's',
      epoch: epoch!,
      allowed: () => allowed,
      onActivationChecked: checks.add,
    );
    await entered.future;
    allowed = false;
    release.complete();
    expect(await pending, isFalse);
    expect(checks, isEmpty);
    expect(requests.single, isNot(contains('activate')));
  });
}
