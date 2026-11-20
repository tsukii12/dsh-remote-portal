// Usage statistics against a real HTTP server on loopback (no binding in
// this file: real sockets). What arrives is one JSON POST per past day, with
// no cookie (not even one the server set) and exactly the contract's fields;
// a 2xx is the end of that day, a 500 is tried again later; a server that
// never answers is given up on.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_app/phone/phone_channel.dart';
import 'package:dsh_app/runtime/runtime_bridge.dart';
import 'package:dsh_app/runtime/runtime_state.dart';
import 'package:dsh_app/state/phone_state.dart' show phoneChannelProvider;
import 'package:dsh_app/usage/usage_ledger.dart';
import 'package:dsh_app/usage/usage_net.dart';
import 'package:dsh_app/usage/usage_stats.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart' show FakeRuntime;

class _Received {
  _Received(this.method, this.path, this.headers, this.body);

  final String method;
  final String path;
  final HttpHeaders headers;
  final Map<String, Object?> body;
}

class _NoPhone extends PhoneChannel {
  @override
  Future<PhoneStatus> status() async => const PhoneStatus.notReady();
}

void main() {
  final wasActive = UsageBuild.active;
  late HttpServer server;
  late List<_Received> received;
  late List<int> replies;
  late DateTime now;
  void Function()? resume;

  setUp(() async {
    UsageBuild.active = true;
    received = [];
    replies = [];
    now = DateTime(2026, 10, 28, 9);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final text = await utf8.decodeStream(request);
      received.add(
        _Received(request.method, request.uri.path, request.headers, jsonDecode(text) as Map<String, Object?>),
      );
      request.response
        ..statusCode = replies.isEmpty ? 204 : replies.removeAt(0)
        // A cookie the app must never send back.
        ..headers.add('set-cookie', 'tracker=1; Path=/');
      await request.response.close();
    });
  });

  tearDown(() async {
    UsageBuild.active = wasActive;
    await server.close(force: true);
  });

  Future<void> settle([int ms = 0]) async {
    // Real sockets: wait in real time until the server has answered.
    for (var i = 0; i < 40; i++) {
      await Future<void>.delayed(Duration(milliseconds: ms == 0 ? 5 : ms));
    }
  }

  Future<ProviderContainer> start(Map<String, Object> prefs) async {
    SharedPreferences.setMockInitialValues(prefs);
    final container = ProviderContainer(
      overrides: [
        usageClockProvider.overrideWithValue(() => now),
        usageEndpointProvider.overrideWithValue(Uri.parse('http://127.0.0.1:${server.port}/api/usage/v1')),
        usageDeviceProvider.overrideWithValue(
          () async => const UsageDevice(app: '0.9.9', build: 10301000, sdk: 34, abi: 'arm64-v8a', maker: 'vivo'),
        ),
        usageLanguageProvider.overrideWithValue(() => 'en'),
        usageResumesProvider.overrideWithValue((onResume) {
          resume = onResume;
          return () => resume = null;
        }),
        localRuntimeProvider.overrideWith(
          () => FakeRuntime(
            const LocalRuntimeState(
              loaded: true,
              status: RuntimeStatus(phase: RuntimePhase.running, currentExecutionMode: 'proot'),
            ),
          ),
        ),
        phoneChannelProvider.overrideWithValue(_NoPhone()),
      ],
    );
    addTearDown(container.dispose);
    container.read(usageStatsProvider);
    await settle();
    return container;
  }

  test('one POST per past day, plain JSON, no cookie, nothing extra; a 500 is tried again', () async {
    final c = await start({UsageStatsController.noticedKey: true});
    final usage = c.read(usageStatsProvider.notifier);
    usage
      ..count(UsageCount.turns)
      ..count(UsageCount.turns)
      ..count(UsageCount.phone)
      ..plugins(1);
    now = DateTime(2026, 10, 29, 9);
    usage.count(UsageCount.share);

    // The 28th: the server fails once.
    replies.add(500);
    now = DateTime(2026, 10, 30, 9);
    resume!();
    await settle();
    expect(received, hasLength(1));
    expect(received.single.body['day'], '2026-10-28');

    // Later that day: the 28th again, then the 29th.
    now = now.add(const Duration(hours: 1));
    resume!();
    await settle();
    expect([for (final r in received) r.body['day']], ['2026-10-28', '2026-10-28', '2026-10-29']);
    resume!();
    await settle();
    expect(received, hasLength(3), reason: 'both days are done');

    for (final r in received) {
      expect(r.method, 'POST');
      expect(r.path, '/api/usage/v1');
      expect(r.headers.value(HttpHeaders.contentTypeHeader), 'application/json');
      expect(r.headers.value(HttpHeaders.cookieHeader), isNull);
      expect(r.headers.value(HttpHeaders.authorizationHeader), isNull);
      expect(r.body.keys.toSet(), usagePayloadKeys);
      expect((r.body['counts']! as Map).keys.toSet(), usageCountKeys);
    }
    expect(received[1].body, {
      'v': 1,
      'iid': received[0].body['iid'],
      'day': '2026-10-28',
      'app': '0.9.9',
      'build': 10301000,
      'sdk': 34,
      'abi': 'arm64-v8a',
      'maker': 'vivo',
      'lang': 'en',
      'engine': 'proot',
      'counts': {'turns': 2, 'voice': 0, 'phone': 1, 'share': 0, 'gen': 0, 'plugins': 1},
    });
    expect(received[2].body['counts'], {'turns': 0, 'voice': 0, 'phone': 0, 'share': 1, 'gen': 0, 'plugins': 1});
    // One install id for all of it, 128 bits without padding.
    expect({for (final r in received) r.body['iid']}, hasLength(1));
    expect(received.first.body['iid'], matches(RegExp(r'^[A-Za-z0-9_-]{21}[AQgw]$')));
    for (final r in received) {
      expect(usageProblem(r.body, now), isNull, reason: 'the share host takes it');
    }
  });

  test('a server that never answers is given up on in time, quietly', () async {
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    silent.listen(sockets.add);
    addTearDown(() async {
      for (final s in sockets) {
        s.destroy();
      }
      await silent.close();
    });
    final watch = Stopwatch()..start();
    await expectLater(
      const IoUsageHttp().post(
        Uri.parse('http://127.0.0.1:${silent.port}/api/usage/v1'),
        '{}',
        timeout: const Duration(milliseconds: 300),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
  });

  test('turned off, the server hears nothing', () async {
    final c = await start({UsageStatsController.noticedKey: true});
    final usage = c.read(usageStatsProvider.notifier);
    usage.count(UsageCount.turns);
    await settle();
    await usage.setEnabled(false);
    for (var d = 29; d <= 31; d++) {
      now = DateTime(2026, 10, d, 9);
      usage.count(UsageCount.turns);
      resume!();
      await settle();
    }
    expect(received, isEmpty);
  });
}
