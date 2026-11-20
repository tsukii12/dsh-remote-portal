import 'dart:async';

import 'package:dsh_client/dsh_client.dart';
import 'package:test/test.dart';

// The App gate has no Flutter dependency; this SDK harness exercises it with
// package:test and real transport receipts without adding an App dependency.
// ignore: avoid_relative_lib_imports
import '../../../app/lib/companion/companion_signals.dart';
import 'support/companion_signal_host.dart';

void main() {
  late CompanionSignalTestHost host;
  late DshClient client;
  late CompanionSignalGate gate;
  late CompanionSignalSource source;
  late CompanionSignalIngress ingress;
  late MuxEventProvenance proof;
  late Object room, owner, connection;
  var now = 1000000;
  var attached = true;
  var wall = DateTime.utc(2026, 11, 7, 23, 30);
  setUp(() async {
    host = await CompanionSignalTestHost.start();
    client = await host.connect();
    proof = await host.proof(client);
    now = 1000000;
    attached = true;
    wall = DateTime.utc(2026, 11, 7, 23, 30);
    room = Object();
    owner = Object();
    connection = Object();
    gate = CompanionSignalGate(monotonicMs: () => now, utcNow: () => wall);
    gate.enter(recipientContext: room, ownerEpoch: owner);
    source = CompanionSignalSource.dsh(
      hostKey: 'host-a',
      client: client,
      connection: connection,
      isAttached: () => attached,
    );
    gate.setConsent(source, const CompanionSignalConsent(state: true, optionalSpeech: true));
    ingress = gate.openIngress(source)!;
  });
  tearDown(() async {
    await host.close();
  });
  CompanionSignalV1 terminal(
    String session,
    int seq, {
    int turn = 1,
    String reason = 'completed',
    String freshness = 'live',
  }) => CompanionSignalV1.fromJson({
    'v': 1,
    'id': '$session:$seq',
    'kind': 'task.terminal',
    'source': {'type': 'dsh', 'hostKey': 'host-a', 'sessionId': session, 'seq': seq, 'turn': turn},
    'observedAt': proof.observedAt.toIso8601String(),
    'freshness': freshness,
    'payload': {'phase': terminalPhase(reason), 'endKind': reason, 'endSeq': seq, 'turn': turn},
  });
  CompanionSignalV1 approval(String id, {bool clear = false}) => CompanionSignalV1.fromJson({
    'v': 1,
    'id': '${clear ? 'clear' : 'wait'}:$id',
    'kind': clear ? 'task.approval_cleared' : 'task.approval_waiting',
    'source': {'type': 'dsh', 'hostKey': 'host-a', 'sessionId': clear ? null : 'task', 'requestId': id},
    'observedAt': proof.observedAt.toIso8601String(),
    'freshness': 'live',
    'payload': {'requestId': id, 'openSessionId': clear ? null : 'root', 'requestKind': 'approval'},
  });
  CompanionSignalAdmission receive(CompanionSignalV1 signal, {int age = 0, bool Function()? current}) => gate.receive(
    ingress,
    signal,
    provenance: proof,
    ageMs: age,
    receiptCurrent: current,
    stillPending: signal.kind == 'task.approval_waiting' ? () => true : null,
  );
  CompanionLightShareTarget target({
    Object? context,
    Object? epoch,
    Object? Function()? epochGetter,
    Object? keeper,
    Object? config,
    Object? Function()? keeperGetter,
    Object? Function()? configGetter,
  }) {
    final k = keeper ?? Object(), c = config ?? Object(), e = epoch ?? Object();
    return CompanionLightShareTarget(
      recipientContext: context ?? room,
      targetEpoch: e,
      currentTargetEpoch: epochGetter ?? () => e,
      keeper: k,
      currentKeeper: keeperGetter ?? () => k,
      modelConfiguration: c,
      currentModelConfiguration: configGetter ?? () => c,
    );
  }

  Future<(CompanionRunReceipt, StreamSubscription<CompanionRunReceipt>)> runReceipt() async {
    final cap = (await client.readCompanionSignalCapabilities())!;
    gate.detach(source);
    source = CompanionSignalSource.dsh(
      hostKey: 'host-a',
      client: client,
      connection: connection,
      isAttached: () => attached,
      runCapability: cap,
    );
    gate.setConsent(source, const CompanionSignalConsent(state: true, optionalSpeech: true));
    ingress = gate.openIngress(source)!;
    final got = Completer<CompanionRunReceipt>();
    final sub = client.watchCompanionRunSignals(cap, hostKey: 'host-a', isAllowed: () => attached).listen(got.complete);
    await host.streamOpened.future;
    host.run(signalTestEnvelope());
    return (await got.future, sub);
  }

  test('all new consent levels default false; raw task DTO is not provenance', () {
    expect(const CompanionSignalConsent().state, isFalse);
    expect(const CompanionSignalConsent().optionalSpeech, isFalse);
    expect(const CompanionSignalConsent().voice, isFalse);
    expect(const CompanionSignalConsent().nightCare, isFalse);
    expect(gate.receive(ingress, terminal('a', 1)), CompanionSignalAdmission.stale);
    gate.setConsent(source, const CompanionSignalConsent());
    expect(gate.openIngress(source), isNull);
  });
  test('actual source proof admits metadata only and cannot bind another client', () async {
    expect(receive(terminal('a', 1)), CompanionSignalAdmission.accepted);
    expect(gate.slots.single.signal.toJson().toString(), isNot(contains('title')));
    final other = await host.connect();
    final otherProof = await host.proof(other);
    expect(gate.receive(ingress, terminal('b', 2), provenance: otherProof), CompanionSignalAdmission.stale);
  });
  test('observed time cannot restamp a captured transport receipt', () {
    final value = {...terminal('a', 1).toJson(), 'observedAt': '2026-11-08T12:00:00.000Z'};
    expect(receive(CompanionSignalV1.fromJson(value)), CompanionSignalAdmission.stale);
  });
  test('same endSeq dedups across state eviction and source generation replacement', () async {
    for (var i = 0; i < 9; i++) {
      expect(receive(terminal('s$i', 1)), CompanionSignalAdmission.accepted);
    }
    expect(gate.slots, hasLength(8));
    expect(receive(terminal('s0', 1)), CompanionSignalAdmission.duplicate);
    client.mux.reconnect();
    await client.mux.ready();
    proof = await host.proof(client);
    gate.detach(source);
    source = CompanionSignalSource.dsh(
      hostKey: 'host-a',
      client: client,
      connection: connection,
      isAttached: () => true,
    );
    gate.setConsent(source, const CompanionSignalConsent(state: true));
    ingress = gate.openIngress(source)!;
    expect(receive(terminal('s0', 1)), CompanionSignalAdmission.duplicate);
  });
  test('newer throttled sequence invalidates old success and speech', () {
    receive(terminal('a', 1));
    final old = gate.slots.single;
    final speech = gate.speechCandidate(old)!;
    for (var i = 2; i <= 10; i++) {
      receive(terminal('b', i));
    }
    expect(receive(terminal('a', 11, reason: 'error')), CompanionSignalAdmission.throttled);
    expect(gate.overflowCount('host-a'), 1);
    expect(gate.slotCurrent(old), isFalse);
    expect(gate.speechCurrent(speech), isFalse);
  });
  test('clear before rate and ordinary dedup blocks delayed waiting', () {
    for (var i = 0; i < 10; i++) {
      receive(terminal('busy', i));
    }
    expect(receive(approval('a', clear: true)), CompanionSignalAdmission.cleared);
    expect(receive(approval('a')), CompanionSignalAdmission.stale);
    expect(gate.slots.any((s) => s.signal.requestId == 'a'), isFalse);
  });
  test('approval has real scope and clear removes it immediately', () {
    var pending = true;
    expect(gate.receive(ingress, approval('a'), provenance: proof), CompanionSignalAdmission.rejected);
    expect(
      gate.receive(ingress, approval('a'), provenance: proof, stillPending: () => pending),
      CompanionSignalAdmission.accepted,
    );
    final old = gate.slots.single;
    pending = false;
    expect(gate.slotCurrent(old), isFalse);
    expect(receive(approval('a', clear: true)), CompanionSignalAdmission.cleared);
    expect(gate.slots, isEmpty);
  });
  test('512 seen keys saturate without eviction replay authorization', () {
    for (var i = 0; i < 512; i++) {
      if (i % 10 == 0) now += 60000;
      expect(receive(terminal('s$i', 1)), CompanionSignalAdmission.accepted);
    }
    expect(receive(terminal('overflow', 1)), CompanionSignalAdmission.capacity);
    expect(gate.slots, isEmpty);
    expect(receive(terminal('s0', 1)), CompanionSignalAdmission.duplicate);
  });
  test('clear tombstone saturation still clears and blocks new waiting', () {
    for (var i = 0; i < 513; i++) {
      expect(receive(approval('r$i', clear: true)), CompanionSignalAdmission.cleared);
    }
    expect(receive(approval('new')), CompanionSignalAdmission.stale);
  });
  test('original receipt age prevents delayed speech; reconciled never speaks', () {
    expect(receive(terminal('old', 1), age: 120001), CompanionSignalAdmission.accepted);
    expect(gate.speechCandidate(gate.slots.single), isNull);
    expect(receive(terminal('snap', 1, freshness: 'reconciled')), CompanionSignalAdmission.accepted);
    expect(gate.speechCandidate(gate.slots.last), isNull);
    expect(receive(terminal('expired', 1), age: 600000), CompanionSignalAdmission.stale);
  });
  test('speech TTL expires independently of ten-minute status', () {
    receive(terminal('a', 1));
    final slot = gate.slots.single;
    final speech = gate.speechCandidate(slot)!;
    now = slot.speechExpiresAtMonoMs;
    expect(gate.speechCurrent(speech), isFalse);
    expect(gate.slotCurrent(slot), isTrue);
    now = slot.expiresAtMonoMs;
    expect(gate.slotCurrent(slot), isFalse);
  });
  test('clock rollback fails closed and never resets permission', () {
    receive(terminal('a', 1));
    now--;
    expect(gate.slots, isEmpty);
    expect(gate.faulted, isTrue);
    now += 2000;
    expect(receive(terminal('b', 2)), CompanionSignalAdmission.stale);
  });
  test('same host/session strings cannot migrate recipient owner or connection', () {
    gate.enter(recipientContext: Object(), ownerEpoch: owner);
    expect(receive(terminal('a', 1)), CompanionSignalAdmission.stale);
    gate.enter(recipientContext: room, ownerEpoch: owner);
    expect(receive(terminal('a', 1)), CompanionSignalAdmission.stale);
  });
  test('attached predicate reentering consent cannot admit or keep slot', () {
    gate.detach(source);
    var armed = false;
    source = CompanionSignalSource.dsh(
      hostKey: 'host-a',
      client: client,
      connection: connection,
      isAttached: () {
        if (armed) gate.detach(source);
        return true;
      },
    );
    gate.setConsent(source, const CompanionSignalConsent(state: true));
    ingress = gate.openIngress(source)!;
    armed = true;
    expect(receive(terminal('a', 1)), CompanionSignalAdmission.stale);
    expect(gate.slots, isEmpty);
  });
  test('receipt callback can clear map during prune without stale publish or iterator error', () {
    var armed = false;
    receive(
      terminal('a', 1),
      current: () {
        if (armed) gate.setConsent(source, const CompanionSignalConsent());
        return true;
      },
    );
    final slot = gate.slots.single;
    armed = true;
    expect(gate.slotCurrent(slot), isFalse);
    expect(gate.slots, isEmpty);
    expect(receive(terminal('b', 2)), CompanionSignalAdmission.stale);
  });
  test('raw run DTO lacks authority but actual SSE receipt admits', () async {
    final (receipt, sub) = await runReceipt();
    expect(gate.receive(ingress, receipt.signal, provenance: proof), CompanionSignalAdmission.unavailable);
    expect(gate.receiveRun(ingress, receipt), CompanionSignalAdmission.accepted);
    final slot = gate.slots.single;
    expect(gate.speechCandidate(slot)!.text, '测试命令执行成功，测试数量未知。');
    await sub.cancel();
    expect(gate.slotCurrent(slot), isFalse);
  });
  test('run success and terminal failure in same turn remain separate facts', () async {
    final (receipt, sub) = await runReceipt();
    expect(gate.receiveRun(ingress, receipt), CompanionSignalAdmission.accepted);
    expect(receive(terminal('task', 7, reason: 'error')), CompanionSignalAdmission.accepted);
    expect(gate.slots, hasLength(2));
    expect(gate.slots.map((s) => s.signal.kind).toSet(), {'run.result', 'task.terminal'});
    receive(terminal('task', 9, turn: 2));
    expect(gate.slots, hasLength(1));
    await sub.cancel();
  });
  test('phone power and notifications remain unavailable despite consent', () {
    final power = CompanionSignalV1.fromJson({
      'v': 1,
      'id': 'p',
      'kind': 'device.power',
      'source': {'type': 'device'},
      'observedAt': proof.observedAt.toIso8601String(),
      'freshness': 'live',
      'payload': {'charging': false, 'band': 'low'},
    });
    expect(gate.receive(ingress, power), CompanionSignalAdmission.unavailable);
    expect(
      companionNotificationAllowed(
        'bank',
        phoneDenied: {'bank'},
        safetyDenied: {},
        privatePackages: {},
        allowlist: {'bank'},
        selfPackageId: 'self',
      ),
      isFalse,
    );
    expect(
      companionNotificationAllowed(
        'finance',
        phoneDenied: {},
        safetyDenied: {'finance'},
        privatePackages: {},
        allowlist: {'finance'},
        selfPackageId: 'self',
      ),
      isFalse,
    );
    expect(
      companionNotificationAllowed(
        'private',
        phoneDenied: {},
        safetyDenied: {},
        privatePackages: {'private'},
        allowlist: {'private'},
        selfPackageId: 'self',
      ),
      isFalse,
    );
    expect(
      companionNotificationAllowed(
        'self',
        phoneDenied: {},
        safetyDenied: {},
        privatePackages: {},
        allowlist: {'self'},
        selfPackageId: 'self',
      ),
      isFalse,
    );
    expect(
      companionNotificationAllowed(
        'com.android.permissioncontroller',
        phoneDenied: {},
        safetyDenied: {},
        privatePackages: {},
        allowlist: {'com.android.permissioncontroller'},
        selfPackageId: 'self',
      ),
      isFalse,
    );
  });
  test('local late-use needs actual owner and expires at daytime', () {
    final local = CompanionSignalSource.local(owner: Object(), isAttached: () => attached);
    gate.setConsent(local, const CompanionSignalConsent(state: true, optionalSpeech: true, nightCare: true));
    final token = gate.openIngress(local)!;
    final late = CompanionSignalV1.fromJson({
      'v': 1,
      'id': 'night1',
      'kind': 'app.late_use',
      'source': {'type': 'device'},
      'observedAt': wall.toIso8601String(),
      'freshness': 'live',
      'payload': {
        'nightKey': '2026-11-07',
        'utcOffsetMinutes': 0,
        'recentInteraction': true,
        'activeMinutesBucket': '15plus',
      },
    });
    expect(gate.receive(token, late), CompanionSignalAdmission.accepted);
    final slot = gate.slots.single;
    expect(gate.speechCandidate(slot)!.nightKey, '2026-11-07');
    wall = DateTime.utc(2026, 11, 8, 7);
    expect(gate.slotCurrent(slot), isFalse);
  });
  test('light sharing requires explicit preview confirmation and exact recipient', () async {
    receive(terminal('a', 1));
    final preview = gate.previewMetadata(gate.slots.single)!;
    expect(gate.approveShare(preview, target(), explicitlyConfirmed: false), isNull);
    expect(gate.approveShare(preview, target(context: Object()), explicitlyConfirmed: true), isNull);
    final destination = target();
    final permit = gate.approveShare(preview, destination, explicitlyConfirmed: true)!;
    final result = await permit.dispatch<String>((text, to, stillCurrent) async {
      expect(text, preview.text);
      expect(identical(to, destination), isTrue);
      expect(stillCurrent(), isTrue);
      return 'reply';
    });
    expect(result.accepted, isTrue);
    expect(result.value, 'reply');
  });
  test('one-use permit rechecks revocation across refresh await', () async {
    receive(terminal('a', 1));
    final permit = gate.approveShare(gate.previewMetadata(gate.slots.single)!, target(), explicitlyConfirmed: true)!;
    var sends = 0;
    final result = permit.dispatch<String>((_, _, _) async {
      sends++;
      return 'reply';
    });
    gate.setConsent(source, const CompanionSignalConsent());
    expect((await result).accepted, isFalse);
    expect(sends, 0);
    expect(
      (await permit.dispatch<String>((_, _, _) async {
        sends++;
        return 'again';
      })).accepted,
      isFalse,
    );
    expect(sends, 0);
  });
  test('target epoch A B A never revives once retired', () {
    final first = Object();
    Object selected = first;
    final destination = target(epoch: first, epochGetter: () => selected);
    expect(destination.isCurrent, isTrue);
    selected = Object();
    expect(destination.isCurrent, isFalse);
    selected = first;
    expect(destination.isCurrent, isFalse);
  });
  test('late model response is rejected and cannot reuse consumed permit', () async {
    receive(terminal('a', 1));
    final destination = target();
    final permit = gate.approveShare(gate.previewMetadata(gate.slots.single)!, destination, explicitlyConfirmed: true)!;
    final started = Completer<void>(), reply = Completer<String>();
    var sends = 0;
    final result = permit.dispatch<String>((_, _, _) {
      sends++;
      started.complete();
      return reply.future;
    });
    await started.future;
    destination.retire();
    reply.complete('late');
    expect((await result).accepted, isFalse);
    expect(
      (await permit.dispatch<String>((_, _, _) async {
        sends++;
        return 'again';
      })).value,
      isNull,
    );
    expect(sends, 1);
  });
  test('last network-boundary callback observes revoke during additional await', () async {
    receive(terminal('a', 1));
    final permit = gate.approveShare(gate.previewMetadata(gate.slots.single)!, target(), explicitlyConfirmed: true)!;
    final reached = Completer<void>(), go = Completer<void>();
    var networkWrites = 0;
    final result = permit.dispatch<String>((_, _, stillCurrent) async {
      reached.complete();
      await go.future;
      if (stillCurrent()) networkWrites++;
      return 'value';
    });
    await reached.future;
    gate.leave();
    go.complete();
    expect((await result).accepted, isFalse);
    expect(networkWrites, 0);
  });
  test('target getters cannot revoke source and still obtain permit', () {
    receive(terminal('a', 1));
    final preview = gate.previewMetadata(gate.slots.single)!;
    final config = Object();
    final destination = target(
      config: config,
      configGetter: () {
        gate.setConsent(source, const CompanionSignalConsent());
        return config;
      },
    );
    expect(gate.approveShare(preview, destination, explicitlyConfirmed: true), isNull);
  });
  test('fresh monotonic clock is read after final target getter', () {
    receive(terminal('a', 1));
    final slot = gate.slots.single;
    final e = Object();
    final destination = target(
      epoch: e,
      epochGetter: () {
        now = slot.expiresAtMonoMs;
        return e;
      },
    );
    expect(gate.approveShare(gate.previewMetadata(slot)!, destination, explicitlyConfirmed: true), isNull);
  });
  test('details are exact selected result and rechecked after await', () async {
    receive(terminal('a', 7));
    final slot = gate.slots.single;
    final response = Completer<String>();
    final loaded = gate.loadLocalDetail(slot, (actual, session, seq) {
      expect(identical(actual, client), isTrue);
      expect(session, 'a');
      expect(seq, 7);
      return response.future;
    });
    gate.leave();
    response.complete('selected local detail');
    expect(await loaded, isNull);
  });
  test('detail remains local and rejects oversized or control text', () async {
    receive(terminal('a', 1));
    final slot = gate.slots.single;
    expect(await gate.loadLocalDetail(slot, (_, _, _) async => 'x' * 4097), isNull);
    expect(await gate.loadLocalDetail(slot, (_, _, _) async => 'private\u0000'), isNull);
    final detail = await gate.loadLocalDetail(slot, (_, _, _) async => 'selected\nlocal detail');
    expect(detail!.localDetail, isTrue);
    expect(host.paths.any((p) => p.contains('prompt')), isFalse);
  });
  test('full share refreshes actual C549 identity and refuses changed revision', () async {
    receive(terminal('a', 1));
    final cap = (await client.readCompanionRecallCapabilities())!;
    final binding = await client.readCompanionRecallBinding(cap, signalTestBinding);
    final epoch = Object();
    final destination = CompanionFullShareTarget(
      recipientContext: room,
      targetEpoch: epoch,
      currentTargetEpoch: () => epoch,
      client: client,
      connection: connection,
      capabilities: cap,
      binding: binding,
      currentClient: () => client,
      currentConnection: () => connection,
      currentBinding: () => binding,
    );
    final permit = gate.approveShare(gate.previewMetadata(gate.slots.single)!, destination, explicitlyConfirmed: true)!;
    host.binding = signalTestRecallBinding(memoryRevision: 8);
    var sends = 0;
    expect(
      (await permit.dispatch<String>((_, _, _) async {
        sends++;
        return 'value';
      })).accepted,
      isFalse,
    );
    expect(sends, 0);
    expect(destination.isCurrent, isFalse);
  });
  test('full share refresh rechecks source and same exact destination', () async {
    receive(terminal('a', 1));
    final cap = (await client.readCompanionRecallCapabilities())!;
    final binding = await client.readCompanionRecallBinding(cap, signalTestBinding);
    final epoch = Object();
    final destination = CompanionFullShareTarget(
      recipientContext: room,
      targetEpoch: epoch,
      currentTargetEpoch: () => epoch,
      client: client,
      connection: connection,
      capabilities: cap,
      binding: binding,
      currentClient: () => client,
      currentConnection: () => connection,
      currentBinding: () => binding,
    );
    final permit = gate.approveShare(gate.previewMetadata(gate.slots.single)!, destination, explicitlyConfirmed: true)!;
    host.beforeBinding = () async {
      gate.leave();
    };
    var sends = 0;
    expect(
      (await permit.dispatch<String>((_, _, _) async {
        sends++;
        return 'value';
      })).accepted,
      isFalse,
    );
    expect(sends, 0);
  });
}
