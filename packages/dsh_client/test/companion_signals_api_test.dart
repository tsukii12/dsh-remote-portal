import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

import 'support/companion_signal_host.dart';

void main() {
  late CompanionSignalTestHost host;
  late DshClient client;
  setUp(() async {
    host = await CompanionSignalTestHost.start();
    client = await host.connect();
  });
  tearDown(() async {
    await host.close();
  });

  test('capability GET is authenticated and does not subscribe or follow', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    expect(cap.available, isTrue);
    expect(cap.isFor(client), isTrue);
    expect(cap.devicePowerAvailable, isFalse);
    expect(cap.notificationsAvailable, isFalse);
    expect(cap.counts, isFalse);
    expect(cap.replay, isFalse);
    expect(host.streamOpens, 0);
    expect(host.paths.where((p) => p.contains('/session/')), isEmpty);
    expect(host.cookies.every((v) => v == 'dsh-auth-signal=v1.test'), isTrue);
  });
  test('explicit unavailable capability stays unavailable', () async {
    host.capability = {
      ...signalTestCapabilities(),
      'available': false,
      'reason': 'producer-unavailable',
      'kinds': <String>[],
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    expect(cap.available, isFalse);
    expect(() => client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true), throwsArgumentError);
  });
  test('only recognized unclaimed 404 is old-host absence', () async {
    host.capabilityStatus = 404;
    host.capability = {
      'error': {'code': 'companion/not-found'},
    };
    expect(await client.readCompanionSignalCapabilities(), isNull);
    host.capability = {
      'error': {'code': 'companion/signals-not-found'},
    };
    await expectLater(client.readCompanionSignalCapabilities(), throwsA(isA<DshHttpException>()));
  });
  test('capability rejects malformed success rather than downgrade', () async {
    for (final patch in [
      {'counts': true},
      {'replay': true},
      {'maxEventBytes': 2048},
      {'generation': 'ABCDEFAB-1111-4111-8111-111111111111'},
      {
        'kinds': ['run.result', 'task.terminal'],
      },
      {
        'devicePower': {'available': true},
      },
      {'unexpected': 'private'},
    ]) {
      host.capability = {...signalTestCapabilities(), ...patch};
      await expectLater(client.readCompanionSignalCapabilities(), throwsA(isA<DshProtocolException>()));
    }
  });
  test('capability bound applies after decompression', () async {
    host.customCapability = (req) async {
      req.response
        ..headers.contentType = ContentType.json
        ..headers.set('content-encoding', 'gzip')
        ..add(gzip.encode(utf8.encode(jsonEncode({'padding': 'x' * 5000}))));
      await req.response.close();
    };
    await expectLater(client.readCompanionSignalCapabilities(), throwsA(isA<DshProtocolException>()));
  });
  test('capability cannot be transplanted to another actual client', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final other = await host.connect();
    expect(() => other.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true), throwsArgumentError);
  });
  test('subscription requires an already ready mux and never starts it', () async {
    final idle = await host.connect(startMux: false);
    final cap = (await idle.readCompanionSignalCapabilities())!;
    expect(() => idle.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true), throwsArgumentError);
    expect(idle.mux.generation, isNull);
  });
  test('actual ready SSE mints private receipt with local host and original age', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final got = Completer<CompanionRunReceipt>();
    final sub = client.watchCompanionRunSignals(cap, hostKey: 'host-a', isAllowed: () => true).listen(got.complete);
    await host.streamOpened.future;
    host.run(signalTestEnvelope());
    final receipt = await got.future;
    expect(receipt.current, isTrue);
    expect(receipt.locallyCurrent, isTrue);
    expect(identical(receipt.client, client), isTrue);
    expect(identical(receipt.muxGeneration, client.mux.generation), isTrue);
    expect(receipt.signal.source['hostKey'], 'host-a');
    expect(receipt.signal.observedAt.isUtc, isTrue);
    expect(receipt.ageMs, greaterThanOrEqualTo(0));
    await sub.cancel();
    expect(receipt.current, isFalse);
  });
  test('shared18-case fixture has identical Dart and Node acceptance', () {
    final fixture = jsonDecode(File('test/fixtures/companion_signal_results.json').readAsStringSync()) as Map;
    expect((fixture['cases'] as List).length, 18);
    for (final raw in fixture['cases'] as List) {
      final c = raw as Map, source = Map<String, Object?>.from(c['source'] as Map);
      final metadata = Map<String, Object?>.from(c['metadata'] as Map)..remove('v');
      final seq = source['seq'];
      final value = {
        'v': 1,
        'id': seq is int
            ? companionRunEventId(source['sessionId'] as String, source['callId'] as String, seq)
            : 'invalid',
        'generation': fixture['generation'],
        'source': source,
        'payload': metadata,
      };
      if (c['valid'] == true) {
        expect(() => CompanionRunEnvelope.fromJson(value), returnsNormally, reason: c['name'] as String);
      } else {
        expect(() => CompanionRunEnvelope.fromJson(value), throwsFormatException, reason: c['name'] as String);
      }
    }
  });
  test('event ID matches independent SHA256 JSON tuple vectors', () {
    expect(companionRunEventId('s-a', 'call-a', 4), '1Nkrc5fNYeUTTM3EcLZu5UejjHgxV2wvVVa_fuu8u-M');
    expect(companionRunEventId('会话🐱', '调用🐈', 4), 'dZpCecXPIcz0IaFh3B6KpgQdp1UmQcFMR9hN74PSSps');
  });
  test('run before ready is a protocol error', () async {
    host.sendReady = false;
    host.onStream = (res) async {
      final v = signalTestEnvelope();
      host.frame(res, 'companion/run-result', v, id: v['id'] as String);
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('mismatched Host generation retires stream', () async {
    host.sendReady = false;
    host.onStream = (res) async {
      host.frame(res, 'companion/ready', {'v': 1, 'generation': '55555555-5555-4555-8555-555555555555'});
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('second ready is not a replay reset', () async {
    host.onStream = (res) async {
      host.frame(res, 'companion/ready', {'v': 1, 'generation': signalTestGeneration});
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('unbounded unterminated line is rejected before UTF8 accumulation', () async {
    host.onStream = (res) async {
      res.write('data: ${'x' * 2050}');
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('payload over1024 rejects before metadata decode', () async {
    host.onStream = (res) async {
      host.frame(res, 'companion/run-result', {'padding': 'x' * 1100}, id: 'x');
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('unknown extra run body field is rejected', () async {
    host.onStream = (res) async {
      final v = {...signalTestEnvelope(), 'stdout': 'do not retain'};
      host.frame(res, 'companion/run-result', v, id: v['id'] as String);
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('SSE id must match exact envelope and content-derived id', () async {
    host.onStream = (res) async {
      host.frame(res, 'companion/run-result', signalTestEnvelope(), id: 'wrong');
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    await expectLater(
      client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>(),
      throwsA(isA<DshProtocolException>()),
    );
  });
  test('pause retires all existing receipt authority', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final got = Completer<CompanionRunReceipt>();
    final sub = client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).listen(got.complete);
    await host.streamOpened.future;
    host.run(signalTestEnvelope());
    final r = await got.future;
    sub.pause();
    expect(r.locallyCurrent, isFalse);
    expect(r.current, isFalse);
    await sub.cancel();
    expect(host.streamOpens, 1);
  });
  test('mux loss invalidates receipt and does not reconnect signal stream', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final got = Completer<CompanionRunReceipt>();
    final sub = client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).listen(got.complete);
    await host.streamOpened.future;
    host.run(signalTestEnvelope());
    final r = await got.future;
    client.mux.reconnect();
    expect(r.current, isFalse);
    await client.mux.ready();
    expect(host.streamOpens, 1);
    await sub.cancel();
  });
  test('revoked before listening does not open HTTP stream', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final values = await client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => false).toList();
    expect(values, isEmpty);
    expect(host.streamOpens, 0);
  });
  test('consent predicate cancelling its own stream cannot preserve receipt', () async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    final got = Completer<CompanionRunReceipt>();
    var armed = false;
    late StreamSubscription<CompanionRunReceipt> sub;
    sub = client
        .watchCompanionRunSignals(
          cap,
          hostKey: 'h',
          isAllowed: () {
            if (armed) unawaited(sub.cancel());
            return true;
          },
        )
        .listen(got.complete);
    await host.streamOpened.future;
    host.run(signalTestEnvelope());
    final r = await got.future;
    armed = true;
    expect(r.current, isFalse);
    expect(r.locallyCurrent, isFalse);
    await sub.cancel();
  });
  test('Host unavailable closes without fabricating result', () async {
    host.onStream = (res) async {
      host.frame(res, 'companion/unavailable', {
        'v': 1,
        'generation': signalTestGeneration,
        'reason': 'producer-unavailable',
      });
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    expect(await client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).toList(), isEmpty);
  });
  test('malformed UTF8 is rejected without retaining raw diagnostics', () async {
    host.onStream = (res) async {
      res.add([100, 97, 116, 97, 58, 32, 255, 10, 10]);
    };
    final cap = (await client.readCompanionSignalCapabilities())!;
    try {
      await client.watchCompanionRunSignals(cap, hostKey: 'h', isAllowed: () => true).drain<void>();
      fail('expected error');
    } on DshProtocolException catch (error) {
      expect(error.message, 'invalid companion signal stream');
    }
  });
  test('normalization rejects body fields, controls and inconsistent terminal phase', () async {
    final proof = await host.proof(client);
    final good = {
      'v': 1,
      'id': 't',
      'kind': 'task.terminal',
      'source': {'type': 'dsh', 'hostKey': 'h', 'sessionId': 's', 'seq': 2, 'turn': 1},
      'observedAt': proof.observedAt.toIso8601String(),
      'freshness': 'live',
      'payload': {'phase': 'completed', 'endKind': 'completed', 'endSeq': 2, 'turn': 1},
    };
    expect(() => CompanionSignalV1.fromJson(good), returnsNormally);
    for (final patch in [
      {'title': 'private'},
      {'id': 'bad\u0000'},
      {'observedAt': '2026-11-07T00:00:00+00:00'},
      {
        'payload': {'phase': 'completed', 'endKind': 'max-tokens', 'endSeq': 2, 'turn': 1},
      },
    ]) {
      expect(() => CompanionSignalV1.fromJson({...good, ...patch}), throwsFormatException);
    }
  });
  test('queued mux receipt retains old actual generation after reconnect', () async {
    final events = <MuxEventReceipt>[];
    final sub = client.mux.hostEventReceipts.listen(events.add);
    sub.pause();
    host.event({
      'type': 'emit',
      'event': 'api-session/status',
      'args': ['s', false],
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    client.mux.reconnect();
    await client.mux.ready();
    sub.resume();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final old = events.firstWhere((r) => r.event is SessionStatusEvent);
    expect(old.provenance.current, isFalse);
    await sub.cancel();
  });
  test('local request resolution publishes clear with real provenance', () async {
    final next = client.mux.hostEventReceipts.firstWhere((r) => r.event is HostRequestCancelledEvent);
    client.mux.resolvePendingRequest('request-x');
    final receipt = await next;
    expect((receipt.event as HostRequestCancelledEvent).eventId, 'request-x');
    expect(receipt.provenance.current, isTrue);
    expect(identical(client.mux.provenanceFor(receipt.event), receipt.provenance), isTrue);
  });
}
