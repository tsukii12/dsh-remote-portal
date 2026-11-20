import 'dart:async';
import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/session_sync_host.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('prepared source revoked during beforeDeliver never reaches actual prompt RPC', () => HttpOverrides.runWithHttpOverrides(() async {
    final h = await SyncHarness.start();
    final entered = Completer<void>();
    final release = Completer<void>();
    var allowed = true;
    var checks = 0;
    try {
      final sending = h.chat.send('controlled route', mode: SendMode.queue,
        beforeDeliver: (_) async { entered.complete(); await release.future; return true; },
        deliveryAllowed: () { checks++; return allowed; });
      await entered.future.timeout(const Duration(seconds: 5));
      allowed = false;
      release.complete();
      expect(await sending, isFalse);
      expect(h.boundary, isEmpty);
      expect(h.cancelledBackendRuns, isEmpty);
      expect(checks, 1);
    } finally {
      if (!release.isCompleted) release.complete();
      await h.close();
    }
  }, RealSyncHttp()));

  test('prepared valid source reaches actual queue RPC once without stopping', () => HttpOverrides.runWithHttpOverrides(() async {
    final h = await SyncHarness.start();
    var checks = 0;
    try {
      expect(await h.chat.send('controlled route', mode: SendMode.queue,
        deliveryAllowed: () { checks++; return true; }), isTrue);
      expect(h.boundary.length, 1);
      expect(h.boundary.single['endpoint'], 'session/prompt');
      expect((h.boundary.single['request'] as Map)['mode'], 'queue');
      expect(h.cancelledBackendRuns, isEmpty);
      expect(checks, 1);
    } finally { await h.close(); }
  }, RealSyncHttp()));

  test('ordinary send keeps existing now to steer behavior without source callback', () => HttpOverrides.runWithHttpOverrides(() async {
    final h = await SyncHarness.start();
    try {
      expect(await h.chat.send('ordinary message'), isTrue);
      expect(h.boundary.length, 1);
      expect((h.boundary.single['request'] as Map)['mode'], 'steer');
      expect(h.cancelledBackendRuns, isEmpty);
    } finally { await h.close(); }
  }, RealSyncHttp()));
}
