import 'dart:async';

import 'package:dsh_app/companion/companion_signals.dart';
import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/notify/chat_alerts.dart';
import 'package:dsh_app/pets/pet_signals.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../packages/dsh_client/test/support/companion_signal_host.dart';

class _Source extends DshAlertSource {
  _Source(super.client);
  List<SessionSummary> sessions = [_summary('s'), _summary('sub', parent: 's')];
  TurnOutcome? outcome;
  Future<TurnOutcome?>? pendingOutcome;
  Future<ToolCallPart?>? pendingApproval;
  int turnReads = 0;
  @override
  Future<List<SessionSummary>> listSessions() async => sessions;
  @override
  Future<TurnOutcome?> lastTurn(String sessionId) async {
    turnReads++;
    return pendingOutcome ?? outcome;
  }

  @override
  Future<ToolCallPart?> approvalCall(ApprovalRequest request) async => pendingApproval;
}

SessionSummary _summary(String id, {bool running = false, String? parent}) => SessionSummary.fromJson({
  'sessionId': id,
  'running': running,
  'blank': false,
  'agentAvailable': true,
  'updatedAt': 1794090000000,
  if (parent != null) 'origin': 'subagent',
  'parentSessionId': ?parent,
  'projections': {'title': 'PRIVATE TITLE'},
});
TurnOutcome _outcome(int seq, String reason, {int turn = 2}) => outcomeFromEvents([
  TurnEndedEvent(seq, DateTime.utc(2026, 11, 7), const {}, turn: turn, reason: TurnEndReason(reason)),
], title: 'PRIVATE TITLE')!;
Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

Map<String, Object?> _request(String id, {String session = 's'}) => {
  'type': 'waterfall',
  'event': 'approval/request',
  'eventId': id,
  'agentId': session,
  'request': {'toolName': 'bash', 'callId': 'call-$id', 'reason': 'PRIVATE APPROVAL REASON'},
};

void main() {
  AppLocale.use(AppLocale.zhCN);
  late CompanionSignalTestHost host;
  late DshClient client;
  late _Source source;
  late HostAlertTracker tracker;
  late HostConnection connection;
  late CompanionSignalGate gate;
  late CompanionSignalIngress ingress;
  final deliveries = <CompanionAlertDelivery>[], alerts = <ChatAlert>[], order = <String>[];
  final reannouncements = <ChatAlert>[];
  bool attached = true, armedDispose = false, disposeOnPublish = false;
  setUp(() async {
    host = await CompanionSignalTestHost.start();
    client = await host.connect();
    source = _Source(client);
    connection = HostConnection(hostId: '', client: client, isLocal: true);
    attached = true;
    armedDispose = false;
    disposeOnPublish = false;
    deliveries.clear();
    alerts.clear();
    order.clear();
    reannouncements.clear();
    tracker = HostAlertTracker(
      host: HostRef.none,
      source: source,
      companionConnection: connection,
      isCompanionAttached: () {
        if (armedDispose) unawaited(tracker.dispose());
        return attached;
      },
      onCompanionSignal: (value) {
        deliveries.add(value);
        order.add(value.signal.kind);
        if (disposeOnPublish) unawaited(tracker.dispose());
      },
      onAlert: alerts.add,
      onReannounce: reannouncements.add,
      onWithdraw: (_, _, _) {
        order.add('legacy-withdraw');
      },
      onSessionGone: (_, _) {},
      announceDelay: Duration.zero,
      reconcileDelay: const Duration(seconds: 1),
    )..start();
    gate = CompanionSignalGate(monotonicMs: () => 1000000);
    gate.enter(recipientContext: Object(), ownerEpoch: Object());
    final selected = CompanionSignalSource.dsh(
      hostKey: companionHostKey(HostRef.none),
      client: client,
      connection: connection,
      isAttached: () => attached,
    );
    gate.setConsent(selected, const CompanionSignalConsent(state: true, optionalSpeech: true));
    ingress = gate.openIngress(selected)!;
    await _settle();
  });
  tearDown(() async {
    await tracker.dispose();
    await host.close();
  });
  Future<void> edge(bool running) async {
    await host.proof(client, session: 's', running: running);
    await _settle();
  }

  Future<void> request(String id, {String session = 's'}) async {
    final next = client.mux.hostEventReceipts.firstWhere((r) => r.event is ApprovalRequestedEvent);
    host.event(_request(id, session: session));
    await next;
    await _settle();
  }

  test('C907 disposal during terminal publication prevents the following alert', () async {
    source.outcome = _outcome(23, 'completed');
    await edge(true);
    disposeOnPublish = true;
    await edge(false);
    expect(deliveries, hasLength(1));
    expect(deliveries.single.current, isFalse);
    expect(alerts, isEmpty);
  });
  test('C907 disposal during request publication prevents the following alert', () async {
    disposeOnPublish = true;
    await request('r');
    expect(deliveries, hasLength(1));
    expect(alerts, isEmpty);
  });
  test('C907 disposal during replay publication prevents reannouncement', () async {
    await request('r');
    expect(alerts, hasLength(1));
    client.mux.reconnect();
    await client.mux.ready();
    await _settle();
    disposeOnPublish = true;
    await request('r');
    expect(deliveries, hasLength(2));
    expect(alerts, hasLength(1));
    expect(reannouncements, isEmpty);
  });
  test('C907 tracker disposal revokes a terminal slot with a still-current mux and ingress', () async {
    source.outcome = _outcome(23, 'completed');
    await edge(true);
    await edge(false);
    final delivery = deliveries.single;
    expect(delivery.receive(gate, ingress), CompanionSignalAdmission.accepted);
    final slot = gate.slots.single;
    final speech = gate.speechCandidate(slot)!;
    final preview = gate.previewMetadata(slot)!;
    final epoch = Object(), keeper = Object(), model = Object();
    final target = CompanionLightShareTarget(
      recipientContext: slot.recipientContext,
      targetEpoch: epoch,
      currentTargetEpoch: () => epoch,
      keeper: keeper,
      modelConfiguration: model,
      currentKeeper: () => keeper,
      currentModelConfiguration: () => model,
    );
    final permit = gate.approveShare(preview, target, explicitlyConfirmed: true)!;
    await tracker.dispose();
    expect(delivery.provenance.current, isTrue);
    expect(gate.ingressCurrent(ingress), isTrue);
    expect(gate.speechCurrent(speech), isFalse);
    expect(gate.previewMetadata(slot), isNull);
    expect(gate.approveShare(preview, target, explicitlyConfirmed: true), isNull);
    var sends = 0;
    final result = await permit.dispatch((_, _, _) async => ++sends);
    expect(result.accepted, isFalse);
    expect(sends, 0);
    expect(gate.slots, isEmpty);
  });
  test('C907 display-wrapper refresh retains scope but retires old receipts', () async {
    await request('r');
    final old = deliveries.single;
    final scope = tracker.requestScope('r');
    final token = alerts.single.petToken!;
    expect(old.receive(gate, ingress), CompanionSignalAdmission.accepted);
    final renamed = HostConnection(hostId: '', client: client, isLocal: true, name: 'new display');
    expect(tracker.updateCompanionConnection(previous: Object(), next: renamed), isFalse);
    expect(old.current, isTrue);
    expect(tracker.updateCompanionConnection(previous: connection, next: renamed), isTrue);
    expect(tracker.requestScope('r'), same(scope));
    expect(tracker.petRequestMatches('r', 's', token), isTrue);
    expect(old.current, isFalse);
    expect(gate.slots, isEmpty);
    final selected = CompanionSignalSource.dsh(
      hostKey: companionHostKey(HostRef.none),
      client: client,
      connection: renamed,
      isAttached: () => attached,
    );
    gate.setConsent(selected, const CompanionSignalConsent(state: true));
    final nextIngress = gate.openIngress(selected)!;
    expect(old.receive(gate, nextIngress), CompanionSignalAdmission.stale);
    await request('r');
    expect(alerts, hasLength(1), reason: 'the same request is not reannounced');
    await request('next');
    expect(deliveries.last.connection, same(renamed));
    expect(deliveries.last.receive(gate, ingress), CompanionSignalAdmission.stale);
    expect(deliveries.last.receive(gate, nextIngress), CompanionSignalAdmission.accepted);
    client.mux.reconnect();
    expect(deliveries.last.current, isFalse);
    expect(tracker.requestScope('r'), isNull);
    await client.mux.ready();
  });

  test('real mux live edge carries exact read endSeq turn and no body', () async {
    source.outcome = _outcome(23, 'completed', turn: 4);
    await edge(true);
    await edge(false);
    expect(deliveries, hasLength(1));
    final d = deliveries.single;
    expect(d.signal.source['seq'], 23);
    expect(d.signal.source['turn'], 4);
    expect(d.signal.freshness, 'live');
    expect(d.signal.payload, {'phase': 'completed', 'endKind': 'completed', 'endSeq': 23, 'turn': 4});
    expect(d.signal.toJson().toString(), isNot(contains('PRIVATE')));
    expect(alerts.single.endSeq, 23);
    expect(alerts.single.sourceSessionId, 's');
    expect(d.receive(gate, ingress), CompanionSignalAdmission.accepted);
  });
  test('unknown initial idle is reconciled and cannot create speech', () async {
    source.sessions = [];
    source.outcome = _outcome(4, 'completed');
    // New unseeded session: no running edge in this actual mux generation.
    await host.proof(client, session: 'unknown', running: false);
    await _settle();
    expect(deliveries.single.signal.freshness, 'reconciled');
    expect(deliveries.single.receive(gate, ingress), CompanionSignalAdmission.accepted);
    expect(gate.speechCandidate(gate.slots.single), isNull);
  });
  test('missing exact turn end creates neither sequence nor success', () async {
    source.outcome = null;
    await edge(true);
    await edge(false);
    expect(source.turnReads, 1);
    expect(deliveries, isEmpty);
    expect(alerts, isEmpty);
  });
  test('terminal finite reasons remain distinct metadata facts', () async {
    final phases = {
      'completed': 'completed',
      'max-tokens': 'output_limit',
      'aborted': 'stopped',
      'interrupted': 'interrupted',
      'error': 'failed',
      'blocked': 'failed',
      'forked': 'unknown',
    };
    var seq = 10;
    for (final entry in phases.entries) {
      source.outcome = _outcome(seq++, entry.key);
      await edge(true);
      await edge(false);
      expect(deliveries.last.signal.payload['phase'], entry.value);
      expect(deliveries.last.signal.payload['endKind'], entry.key);
    }
    expect(deliveries, hasLength(phases.length));
  });
  test('old pending history read cannot gain successor mux identity', () async {
    final pending = Completer<TurnOutcome?>();
    source.pendingOutcome = pending.future;
    await edge(true);
    await edge(false);
    expect(source.turnReads, 1);
    source.sessions = [];
    client.mux.reconnect();
    await client.mux.ready();
    await _settle();
    pending.complete(_outcome(25, 'completed'));
    await _settle();
    expect(deliveries, isEmpty);
  });
  test('reconnect idle reconciliation never promotes prior running proof to live', () async {
    source.outcome = _outcome(27, 'completed');
    await edge(true);
    client.mux.reconnect();
    await client.mux.ready();
    await _settle();
    expect(deliveries, hasLength(1));
    expect(deliveries.single.signal.freshness, 'reconciled');
  });
  test('subagent request keeps actual source separate from navigation root', () async {
    await request('r', session: 'sub');
    final d = deliveries.single;
    expect(d.signal.source['sessionId'], 'sub');
    expect(d.signal.payload['openSessionId'], 's');
    expect(d.signal.payload['requestId'], 'r');
    expect(d.signal.toJson().toString(), isNot(contains('PRIVATE')));
    expect(d.receive(gate, ingress), CompanionSignalAdmission.accepted);
    expect(alerts.single.sessionId, 's');
    expect(alerts.single.sourceSessionId, 'sub');
  });
  test('local request answer emits metadata clear before legacy withdrawal', () async {
    await request('r');
    expect(deliveries.single.receive(gate, ingress), CompanionSignalAdmission.accepted);
    final next = client.mux.hostEventReceipts.firstWhere((r) => r.event is HostRequestCancelledEvent);
    client.mux.resolvePendingRequest('r');
    await next;
    await _settle();
    expect(order.sublist(order.length - 2), ['task.approval_cleared', 'legacy-withdraw']);
    expect(deliveries.last.receive(gate, ingress), CompanionSignalAdmission.cleared);
    expect(gate.slots, isEmpty);
  });
  test('unknown raw cancel cannot invent request kind or source metadata', () async {
    final next = client.mux.hostEventReceipts.firstWhere((r) => r.event is HostRequestCancelledEvent);
    client.mux.resolvePendingRequest('unseen');
    await next;
    await _settle();
    expect(deliveries, isEmpty);
  });
  test('same client but different connection object cannot reuse delivery', () async {
    source.outcome = _outcome(20, 'completed');
    await edge(true);
    await edge(false);
    final other = CompanionSignalSource.dsh(
      hostKey: companionHostKey(HostRef.none),
      client: client,
      connection: HostConnection(hostId: '', client: client, isLocal: true),
      isAttached: () => true,
    );
    gate.setConsent(other, const CompanionSignalConsent(state: true));
    final token = gate.openIngress(other)!;
    expect(deliveries.single.receive(gate, token), CompanionSignalAdmission.stale);
  });
  test('independent companion bus never invokes legacy PetEvent text lane', () async {
    source.outcome = _outcome(20, 'completed');
    await edge(true);
    await edge(false);
    final bus = PetEventBus();
    var legacy = 0, metadata = 0;
    final oldSub = bus.events.listen((_) {
      legacy++;
    });
    final newSub = bus.companionSignals.listen((_) {
      metadata++;
    });
    bus.companionSignal(deliveries.single);
    expect(metadata, 1);
    expect(legacy, 0);
    await oldSub.cancel();
    await newSub.cancel();
    bus.dispose();
  });
  test('tracker disposal inside attached predicate cannot publish metadata', () async {
    source.outcome = _outcome(20, 'completed');
    await edge(true);
    armedDispose = true;
    await edge(false);
    expect(deliveries, isEmpty);
  });
  test('request scope retires synchronously when actual mux generation leaves', () async {
    await request('r');
    expect(tracker.requestScope('r'), isNotNull);
    client.mux.reconnect();
    expect(tracker.requestScope('r'), isNull);
    await client.mux.ready();
    await _settle();
  });
}
