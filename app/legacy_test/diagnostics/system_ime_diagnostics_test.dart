import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/diagnostics/diagnostics_markdown.dart';
import 'package:dsh_app/diagnostics/system_ime_diagnostics.dart';
import 'package:dsh_app/diagnostics/system_ime_evidence.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/system_ime_fixture.dart';
import 'support/zip_reader.dart';

class _Channel extends DiagnosticsChannel {
  final requests = <Completer<SystemImeEvidence>>[];
  int cancellations = 0;

  @override
  Future<SystemImeEvidence> collectSystemIme() {
    final reply = Completer<SystemImeEvidence>();
    requests.add(reply);
    return reply.future;
  }

  @override
  Future<void> cancelSystemIme() async { cancellations++; }
}

DiagnosticsSnapshot _snapshot({SystemImeEvidence? evidence}) => DiagnosticsSnapshot(
  at: systemImeAt,
  status: const RuntimeStatus(phase: RuntimePhase.running),
  settings: const AppSettings(),
  systemIme: evidence,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rebuilds only fixed fields, preserves null/false/true, and detaches native maps', () {
    final raw = systemImeReply(count: 3)..['rawLog'] = 'private draft';
    final rows = raw['events'] as List;
    rows[0]['fromUser'] = null;
    rows[1]['fromUser'] = false;
    rows[2]['fromUser'] = true;
    rows[0]['view'] = 'private view';
    final evidence = SystemImeEvidence.fromNative(raw, now: systemImeAt);
    expect(evidence.code, 'ok');
    expect(evidence.events.map((e) => e.fromUser), [null, false, true]);
    expect(evidence.toJson().keys, ['ok', 'code', 'capturedAt', 'source', 'events']);
    expect(evidence.events.first.toJson().keys, ['timestamp', 'event', 'fromUser', 'reason', 'origin']);
    rows[0]['reason'] = 'private mutation';
    expect(jsonEncode(evidence.toJson()), isNot(contains('private')));
    expect(() => evidence.events.clear(), throwsUnsupportedError);
  });

  test('legacy events accept unknown attribution only, not fabricated false', () {
    for (final origin in ['inputMethodManager', 'inputConnection']) {
      final raw = systemImeReply();
      final row = (raw['events'] as List).single as Map;
      row['origin'] = origin;
      row['reason'] = 'unknown';
      row['event'] = origin == 'inputConnection' ? 'connectionClosed' : 'requestShow';
      expect(SystemImeEvidence.fromNative(raw, now: systemImeAt).code, 'ok');
      row['fromUser'] = false;
      expect(SystemImeEvidence.fromNative(raw, now: systemImeAt).code, 'failed');
    }
  });

  test('all native codes have consistent success and no partial failure events', () {
    for (final code in SystemImeEvidence.codes) {
      final evidence = systemImeEvidence(code: code, count: code == 'ok' ? 1 : 0);
      expect(evidence.code, code);
      expect(evidence.ok, code == 'ok' || code == 'noEvents');
    }
    expect(SystemImeEvidence.fromNative(systemImeReply(count: 0), now: systemImeAt).code, 'failed');
    expect(SystemImeEvidence.fromNative(systemImeReply(code: 'noEvents'), now: systemImeAt).code, 'failed');
    expect(SystemImeEvidence.fromNative(systemImeReply(code: 'timeout'), now: systemImeAt).events, isEmpty);
  });

  test('rejects malformed envelope fields and unknown response strings', () {
    final invalid = <Map<String, Object?>>[
      {'code': 'private exception'}, {'source': 'rawLogcat'}, {'ok': 'true'}, {'ok': false},
      {'capturedAt': 0}, {'capturedAt': systemImeAt.millisecondsSinceEpoch.toDouble()},
      {'capturedAt': systemImeAt.millisecondsSinceEpoch + 1},
      {'capturedAt': systemImeAt.millisecondsSinceEpoch - SystemImeEvidence.windowMs - 1},
      {'events': 'raw logs'},
    ];
    for (final fields in invalid) {
      final evidence = SystemImeEvidence.fromNative({...systemImeReply(), ...fields}, now: systemImeAt);
      expect(evidence.code, 'failed', reason: fields.keys.join());
      expect(evidence.events, isEmpty);
      expect(jsonEncode(evidence.toJson()), isNot(contains('private')));
    }
    expect(SystemImeEvidence.fromNative(null, now: systemImeAt).code, 'failed');
  });

  test('rejects malformed event types, combinations, and timestamps without retaining strings', () {
    final invalid = <Map<String, Object?>>[
      {'event': 'private input'}, {'reason': 'private reason'}, {'origin': 'private origin'},
      {'fromUser': 'false'}, {'fromUser': 0}, {'timestamp': '123'},
      {'timestamp': systemImeAt.millisecondsSinceEpoch + 1},
      {'timestamp': systemImeAt.millisecondsSinceEpoch - SystemImeEvidence.windowMs - 1},
      {'event': 'connectionClosed'}, {'reason': 'unknown'},
    ];
    for (final fields in invalid) {
      final raw = systemImeReply();
      (raw['events'] as List)[0].addAll(fields);
      final evidence = SystemImeEvidence.fromNative(raw, now: systemImeAt);
      expect(evidence.code, 'failed', reason: fields.keys.join());
      expect(evidence.events, isEmpty);
      expect(jsonEncode(evidence.toJson()), isNot(contains('private')));
    }
    final missing = systemImeReply();
    (missing['events'] as List)[0].remove('fromUser');
    expect(SystemImeEvidence.fromNative(missing, now: systemImeAt).code, 'failed');
  });

  test('enforces 64 events and inclusive 120-second event window', () {
    expect(systemImeEvidence(count: 64).events, hasLength(64));
    final overflow = systemImeEvidence(count: 65);
    expect(overflow.code, 'limitExceeded');
    expect(overflow.events, isEmpty);
    for (final age in [0, SystemImeEvidence.windowMs]) {
      final raw = systemImeReply();
      (raw['events'] as List)[0]['timestamp'] = systemImeAt.millisecondsSinceEpoch - age;
      expect(SystemImeEvidence.fromNative(raw, now: systemImeAt).code, 'ok');
    }
  });

  test('clear cancels native and rejects late results even after another capture starts', () async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    expect(diagnostics.evidence, isNull);
    expect(channel.requests, isEmpty);
    final first = diagnostics.collect(isCurrent: () => true);
    diagnostics.clear();
    expect(channel.cancellations, 1);
    final second = diagnostics.collect(isCurrent: () => true);
    channel.requests[0].complete(systemImeEvidence());
    await first;
    expect(diagnostics.collecting, isTrue);
    expect(diagnostics.evidence, isNull);
    channel.requests[1].complete(systemImeEvidence(count: 2));
    await second;
    expect(diagnostics.evidence?.events, hasLength(2));
  });

  test('leaving cancels pending; successful evidence survives until clear or dispose', () async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    final first = diagnostics.collect(isCurrent: () => true);
    channel.requests[0].complete(systemImeEvidence());
    await first;
    diagnostics.cancelPending();
    expect(diagnostics.evidence?.code, 'ok');
    final second = diagnostics.collect(isCurrent: () => true);
    expect(diagnostics.evidence, isNull, reason: 'new capture clears previous evidence immediately');
    diagnostics.cancelPending();
    channel.requests[1].complete(systemImeEvidence());
    await second;
    expect(diagnostics.evidence, isNull);
    final third = diagnostics.collect(isCurrent: () => true);
    diagnostics.dispose();
    channel.requests[2].complete(systemImeEvidence());
    await third;
    expect(diagnostics.evidence, isNull);
    expect(diagnostics.collecting, isFalse);
  });

  test('late result from an invalid owner is discarded and double taps do not capture twice', () async {
    final channel = _Channel();
    final diagnostics = SystemImeDiagnostics(channel);
    addTearDown(diagnostics.dispose);
    var current = true;
    final pending = diagnostics.collect(isCurrent: () => current);
    await diagnostics.collect(isCurrent: () => current);
    expect(channel.requests, hasLength(1));
    current = false;
    channel.requests.single.complete(systemImeEvidence());
    await pending;
    expect(diagnostics.evidence, isNull);
  });

  test('Markdown shows only recent fixed events; ZIP retains the full bounded capture', () {
    final snapshot = _snapshot(evidence: systemImeEvidence(count: 64));
    final markdown = diagnosticsMarkdown(snapshot);
    expect('fromUser=null reason='.allMatches(markdown), hasLength(diagnosticsSystemImeEvents));
    expect(markdown, contains('not false'));
    expect(markdown, contains('not live monitoring'));
    expect(markdown, contains('  - ${systemImeAt.millisecondsSinceEpoch - 1} requestHide'));
    expect(markdown, isNot(contains('  - ${systemImeAt.millisecondsSinceEpoch - 64} requestHide')));
    final files = readZip(DiagnosticsBundle.build(snapshot));
    final json = jsonDecode(utf8.decode(files.singleWhere((f) => f.name == 'system-ime.json').data)) as Map;
    expect(json['events'], hasLength(64));
    expect((json['events'] as List).first['fromUser'], isNull);
    final absent = _snapshot();
    expect(diagnosticsMarkdown(absent), isNot(contains('System IME evidence')));
    expect(DiagnosticsBundle.entries(absent).map((e) => e.name), isNot(contains('system-ime.json')));
  });

  test('empty and failed captures explicitly do not prove normal system behavior', () {
    for (final code in ['noEvents', 'unavailable', 'denied', 'failed']) {
      final snapshot = _snapshot(evidence: systemImeEvidence(code: code, count: 0));
      final markdown = diagnosticsMarkdown(snapshot);
      expect(markdown, contains('code: $code'));
      expect(markdown, contains('NOT evidence that the system behaved normally'));
      expect(markdown, isNot(contains('fromUser=false reason=')));
    }
  });

  testWidgets('channel sends no arguments, validates replies, and cancels without permission requests', (tester) async {
    const channel = DiagnosticsChannel();
    final calls = <MethodCall>[];
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel.channel, (call) async {
      calls.add(call);
      return call.method == 'collectSystemIme' ? systemImeReply(at: DateTime.now()) : null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel.channel, null));
    expect((await channel.collectSystemIme()).code, 'ok');
    await channel.cancelSystemIme();
    expect(calls.map((call) => call.method), ['collectSystemIme', 'cancelSystemIme']);
    expect(calls.every((call) => call.arguments == null), isTrue);
    messenger.setMockMethodCallHandler(channel.channel, (call) async => throw MissingPluginException());
    expect((await channel.collectSystemIme()).code, 'unsupported');
    await channel.cancelSystemIme();
    messenger.setMockMethodCallHandler(channel.channel, (call) async => throw PlatformException(code: 'private error'));
    expect((await channel.collectSystemIme()).code, 'failed');
    await channel.cancelSystemIme();
  });
}
