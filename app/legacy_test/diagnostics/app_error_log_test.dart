import 'dart:async';
import 'dart:convert';

import 'package:dsh_app/diagnostics/app_error_log.dart';
import 'package:dsh_app/diagnostics/diagnostics_bundle.dart';
import 'package:dsh_app/diagnostics/diagnostics_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _EvidenceChannel extends DiagnosticsChannel {
  final records = <Map<String, Object?>>[];
  bool fail = false;

  @override
  Future<void> recordAppError({required String source, required String errorType, required String stack}) async {
    if (fail) throw StateError('synthetic evidence failure');
    records.add({'source': source, 'errorType': errorType, 'stack': stack});
  }
}

class _BrokenDescription {
  @override
  String toString() => throw StateError('description itself failed');
}

class _ReentrantDescription {
  _ReentrantDescription(this.log);
  final AppErrorLog log;

  @override
  String toString() {
    log.record(AppErrorSource.flutter, 'nested diagnostic', StackTrace.empty);
    return 'outer diagnostic';
  }
}

void main() {
  test('persistent evidence contains category and source locations, never exception text', () async {
    final channel = _EvidenceChannel();
    final log = AppErrorLog(diagnostics: channel);
    log.record(
      AppErrorSource.platform,
      StateError('PRIVATE_CHAT token=PRIVATE_TOKEN'),
      StackTrace.fromString('#0 synthetic (package:dsh_app/main.dart:12:3)\nPRIVATE_AUDIO\n/home/private.dart:1:2'),
    );
    await Future<void>.value();
    expect(channel.records.single, {
      'source': 'platform',
      'errorType': 'StateError',
      'stack': 'package:dsh_app/main.dart:12:3',
    });
    expect(jsonEncode(channel.records), isNot(contains('PRIVATE_')));
    channel.fail = true;
    expect(() => log.record(AppErrorSource.flutter, StateError('original'), StackTrace.empty), returnsNormally);
    await Future<void>.value();
    expect(log.snapshot(), hasLength(2));
  });

  test('error notifications coalesce and listener errors cannot recursively wake the collector', () async {
    final log = AppErrorLog(diagnostics: _EvidenceChannel());
    var calls = 0;
    log.revision.addListener(() {
      calls++;
      log.record(AppErrorSource.platform, StateError('listener diagnostic'), StackTrace.empty);
    });
    log.record(AppErrorSource.flutter, StateError('one'), StackTrace.empty);
    log.record(AppErrorSource.flutter, StateError('two'), StackTrace.empty);
    expect(calls, 0);
    await Future<void>.value();
    expect(calls, 1);
    expect(log.snapshot(), hasLength(3));
  });

  test('records are redacted on entry, including a truncated private-key block', () {
    final at = DateTime.utc(2026, 10, 28);
    final log = AppErrorLog(clock: () => at);
    log.record(
      AppErrorSource.platform,
      StateError('SYNTHETIC failure password=fixture-password token=fixture-token-123'),
      StackTrace.fromString('Authorization: Bearer fixture-bearer-123\n#0 synthetic.dart:1'),
    );
    final first = log.snapshot().single;
    expect(first.at, at);
    expect(first.source, AppErrorSource.platform);
    final text = jsonEncode(first.toJson());
    for (final secret in ['fixture-password', 'fixture-token-123', 'fixture-bearer-123']) {
      expect(text, isNot(contains(secret)));
    }
    expect(text, contains('synthetic.dart:1'));
    log.record(
      AppErrorSource.flutter,
      '-----BEGIN OPENSSH PRIVATE KEY-----\n${'SYNTHETIC-PRIVATE-MATERIAL' * 1000}',
      StackTrace.empty,
    );
    expect(log.snapshot().last.message, contains('private key redacted'));
    expect(log.snapshot().last.message, isNot(contains('SYNTHETIC-PRIVATE-MATERIAL')));
  });

  test('the tail, messages and stacks are bounded; snapshots stay immutable', () {
    final log = AppErrorLog();
    for (var i = 0; i < 60; i++) {
      log.record(AppErrorSource.flutter, 'error-$i ${'message\n' * 4000}', StackTrace.fromString('frame\n' * 4000));
    }
    final snapshot = log.snapshot();
    expect(snapshot, hasLength(AppErrorLog.maxRecords));
    expect(snapshot.first.message, startsWith('error-20'));
    expect(snapshot.last.message, startsWith('error-59'));
    for (final record in snapshot) {
      expect(record.message.length, lessThanOrEqualTo(AppErrorLog.maxMessageLength));
      expect(record.stack.length, lessThanOrEqualTo(AppErrorLog.maxStackLength));
    }
    expect(() => snapshot.clear(), throwsUnsupportedError);
    log.record(AppErrorSource.platform, 'later', StackTrace.empty);
    expect(snapshot.last.message, startsWith('error-59'));
  });

  test('truncation never keeps a partial named key at either input boundary', () {
    final log = AppErrorLog();
    const secret = 'abcdefghijklmno';
    log.record(AppErrorSource.flutter, '${'x' * 1989} apiKey=$secret', StackTrace.empty);
    expect(log.snapshot().single.message, '<long line omitted>');
    log.record(AppErrorSource.platform, 'first line\n${'x' * 15974} apiKey=$secret', StackTrace.empty);
    expect(log.snapshot().last.message, 'first line\n<text truncated>');
    for (final record in log.snapshot()) {
      expect(record.message, isNot(contains('abcd')));
    }
  });

  test('a broken description or diagnostic clock cannot replace an app error', () {
    final log = AppErrorLog();
    expect(() => log.record(AppErrorSource.flutter, _BrokenDescription(), StackTrace.empty), returnsNormally);
    expect(log.snapshot().single.message, '<description unavailable>');
    final brokenClock = AppErrorLog(clock: () => throw StateError('clock'));
    expect(() => brokenClock.record(AppErrorSource.platform, StateError('app'), StackTrace.empty), returnsNormally);
  });

  test('a description that records another error cannot reenter the collector', () {
    final log = AppErrorLog();
    log.record(AppErrorSource.platform, _ReentrantDescription(log), StackTrace.empty);
    expect(log.snapshot().single.message, 'outer diagnostic');
    log.record(AppErrorSource.flutter, 'next error', StackTrace.empty);
    expect(log.snapshot().map((entry) => entry.message), ['outer diagnostic', 'next error']);
  });

  test('hooks record once and preserve previous callback behavior and return values', () {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    var flutterCalls = 0;
    var platformCalls = 0;
    final log = AppErrorLog();
    final capture = AppErrorCapture(log);
    void previousFlutter(FlutterErrorDetails details) => flutterCalls++;
    bool previousPlatform(Object error, StackTrace stack) {
      platformCalls++;
      return true;
    }

    try {
      FlutterError.onError = previousFlutter;
      PlatformDispatcher.instance.onError = previousPlatform;
      capture.install();
      capture.install();
      FlutterError.reportError(FlutterErrorDetails(exception: StateError('framework'), stack: StackTrace.empty));
      expect(PlatformDispatcher.instance.onError!(StateError('async'), StackTrace.empty), isTrue);
      expect((flutterCalls, platformCalls), (1, 1));
      expect(log.snapshot().map((entry) => entry.source), [AppErrorSource.flutter, AppErrorSource.platform]);
      capture.uninstall();
      expect(FlutterError.onError, same(previousFlutter));
      expect(PlatformDispatcher.instance.onError, same(previousPlatform));
    } finally {
      capture.uninstall();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    }
  });

  for (final absent in [false, true]) {
    test('platform fallback is preserved when previous handler ${absent ? 'is absent' : 'returns false'}', () {
      final original = PlatformDispatcher.instance.onError;
      final log = AppErrorLog();
      final capture = AppErrorCapture(log);
      try {
        PlatformDispatcher.instance.onError = absent ? null : (error, stack) => false;
        capture.install();
        expect(PlatformDispatcher.instance.onError!(StateError('fixture'), StackTrace.empty), isFalse);
        expect(log.snapshot(), hasLength(1));
      } finally {
        capture.uninstall();
        PlatformDispatcher.instance.onError = original;
      }
    });
  }

  test('an existing handler exception still propagates after the error is recorded', () {
    final original = FlutterError.onError;
    final log = AppErrorLog();
    final capture = AppErrorCapture(log);
    try {
      FlutterError.onError = (_) => throw StateError('previous handler');
      capture.install();
      expect(() => FlutterError.onError!(FlutterErrorDetails(exception: StateError('original'))), throwsStateError);
      expect(log.snapshot().single.message, contains('original'));
    } finally {
      capture.uninstall();
      FlutterError.onError = original;
    }
  });

  test('uninstall leaves later integration handlers in place', () {
    final originalFlutter = FlutterError.onError;
    final originalPlatform = PlatformDispatcher.instance.onError;
    final capture = AppErrorCapture(AppErrorLog());
    void laterFlutter(FlutterErrorDetails details) {}
    bool laterPlatform(Object error, StackTrace stack) => true;
    try {
      capture.install();
      FlutterError.onError = laterFlutter;
      PlatformDispatcher.instance.onError = laterPlatform;
      capture.uninstall();
      expect(FlutterError.onError, same(laterFlutter));
      expect(PlatformDispatcher.instance.onError, same(laterPlatform));
    } finally {
      capture.uninstall();
      FlutterError.onError = originalFlutter;
      PlatformDispatcher.instance.onError = originalPlatform;
    }
  });

  test('a root-zone asynchronous error reaches the platform hook and diagnostics', () async {
    final original = PlatformDispatcher.instance.onError;
    final delivered = Completer<void>();
    final log = AppErrorLog();
    final capture = AppErrorCapture(log);
    try {
      // Keep this synthetic probe process alive after the embedding delivers
      // the error. The production wrapper preserves this handler's result.
      PlatformDispatcher.instance.onError = (error, stack) {
        if (!delivered.isCompleted) delivered.complete();
        return true;
      };
      capture.install();
      Zone.root.run(() {
        Future<void>.microtask(() => throw StateError('SYNTHETIC root asynchronous failure'));
      });
      await delivered.future.timeout(const Duration(seconds: 5));
      expect(log.snapshot().single.source, AppErrorSource.platform);
      expect(log.snapshot().single.message, contains('SYNTHETIC root asynchronous failure'));
      expect(log.snapshot().single.stack, contains('app_error_log_test.dart'));
    } finally {
      capture.uninstall();
      PlatformDispatcher.instance.onError = original;
    }
  });

  test('diagnostics bundle includes app records and remains unchanged when none exist', () {
    final log = AppErrorLog();
    log.record(AppErrorSource.platform, StateError('SYNTHETIC error token=synthetic-token-123'), StackTrace.empty);
    DiagnosticsSnapshot snapshot({bool withErrors = true}) => DiagnosticsSnapshot(
      at: DateTime.utc(2026),
      status: const RuntimeStatus.unknown(),
      settings: const AppSettings(),
      appErrors: withErrors ? log.snapshot() : const [],
    );
    final entries = DiagnosticsBundle.entries(snapshot());
    final body = utf8.decode(entries.singleWhere((entry) => entry.name == 'app-errors.json').bytes);
    expect(jsonDecode(body), hasLength(1));
    expect(body, contains('SYNTHETIC error'));
    expect(body, isNot(contains('synthetic-token-123')));
    expect(
      DiagnosticsBundle.entries(snapshot(withErrors: false)).map((entry) => entry.name),
      isNot(contains('app-errors.json')),
    );
  });
}
