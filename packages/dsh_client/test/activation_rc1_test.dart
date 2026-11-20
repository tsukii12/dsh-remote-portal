import 'dart:async';
import 'dart:convert';
import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';
import 'support/fake_dsh.dart';

void main() {
  Future<(FakeDsh, DshClient, List<Map<Object?, Object?>>, SessionFollowEpoch)> fixture() async {
    final host = await FakeDsh.start();
    addTearDown(host.close);
    host.indexHtml =
        '<script>globalThis["__DSH_BOOT__"] = ${jsonEncode({
          'rev': 'own-rc1',
          'entries': [],
          'release': {'version': '0.2.2-rc.1'},
        })}</script>';
    final requests = <Map<Object?, Object?>>[];
    host.onOpen = (socket, id, endpoint, payload) {
      if (endpoint != 'session/follow') return;
      requests.add((payload['args'] as Map<Object?, Object?>)['request'] as Map<Object?, Object?>);
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
    final opened = Completer<SessionFollowEpoch>();
    final sub = client.watch('s').listen((event) {
      if (event is SessionSnapshotEvent && !opened.isCompleted) {
        opened.complete(event.followEpoch!);
      }
    }, onError: opened.completeError);
    addTearDown(sub.cancel);
    return (host, client, requests, await opened.future);
  }

  test('audited rc1 explicit interaction opens one auxiliary activation follow', () async {
    final (_, client, requests, epoch) = await fixture();
    final checked = <bool>[];
    expect(
      await client.activateSessionForInteraction(
        's',
        epoch: epoch,
        allowed: () => true,
        onActivationChecked: checked.add,
      ),
      isTrue,
    );
    expect(checked, [true]);
    expect(requests.length, 2);
    expect(requests.first, isNot(contains('activate')));
    expect(requests.last, {
      'address': {'kind': 'session', 'sessionId': 's'},
      'activate': true,
      'maxMessages': 1,
    });
    expect(epoch.isCurrent, isTrue);
    expect(await client.activateSessionForInteraction('s', epoch: epoch, allowed: () => true), isTrue);
    expect(requests.length, 2);
  });

  test('rc1 default preview and refused interaction stay passive', () async {
    final (host, client, requests, epoch) = await fixture();
    final reads = host.requests.where((r) => r['path'] == '/').length;
    expect(await client.activateSessionForInteraction('s', epoch: epoch, allowed: () => false), isFalse);
    expect(requests.length, 1);
    expect(requests.single, isNot(contains('activate')));
    expect(host.requests.where((r) => r['path'] == '/').length, reads);
  });

  test('leaving during rc1 discovery revokes activation', () async {
    final (host, client, requests, epoch) = await fixture();
    final entered = Completer<void>(), release = Completer<void>();
    host.beforeIndex = () {
      entered.complete();
      return release.future;
    };
    var allowed = true;
    final activation = client.activateSessionForInteraction('s', epoch: epoch, allowed: () => allowed);
    await entered.future;
    allowed = false;
    release.complete();
    expect(await activation, isFalse);
    expect(requests.length, 1);
    expect(epoch.isCurrent, isTrue);
  });
}
