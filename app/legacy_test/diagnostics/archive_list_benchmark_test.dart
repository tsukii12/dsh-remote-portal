import 'dart:convert';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('public bulk archive planning and undo on loaded session inventories', () async {
    SharedPreferences.setMockInitialValues({});
    WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (final n in [100, 1000, 4000]) {
      final host = FakeWorkspaceHost();
      final date = DateTime.utc(2026, 1, 1);
      for (var i = 0; i < n; i++) {
        host.seedSession('s$i', 'Session $i', date);
      }
      final container = ProviderContainer(overrides: workspaceOverrides(host, current: null));
      final sub = container.listen(sessionsProvider, (_, _) {});
      final client = container.read(activeConnectionProvider).value!.client;
      try {
        expect((await container.read(sessionsProvider.future)).length, n);
        final controller = container.read(sessionsProvider.notifier);
        for (final selection in [(1, false), (1, true), (10, false), (100, false), (n ~/ 2, false)]) {
          final count = selection.$1;
          final ids = List.generate(count, (i) => 's${selection.$2 ? n - 1 : i * n ~/ count}');
          final micros = <int>[];
          for (var repeat = 0; repeat < 13; repeat++) {
            final watch = Stopwatch()..start();
            final pending = controller.scheduleArchive(ids);
            watch.stop();
            expect(container.read(sessionsProvider).value!.length, n - ids.length);
            expect(pending.cancel(), isTrue);
            pending.release();
            expect(container.read(sessionsProvider).value!.length, n);
            await pending.windowClosed;
            if (repeat >= 3) micros.add(watch.elapsedMicroseconds);
          }
          expect(host.calls.where((c) => c.$1 == 'workspace/archiveSession'), isEmpty);
          micros.sort();
          // ignore: avoid_print
          print(
            jsonEncode({
              'sessions': n,
              'selected': ids.length,
              'lastSingle': selection.$2,
              'warmup': 3,
              'samples': 10,
              'minMicros': micros.first,
              'medianMicros': (micros[4] + micros[5]) / 2,
              'maxMicros': micros.last,
              'archiveRpcCalls': 0,
            }),
          );
        }
      } finally {
        sub.close();
        container.dispose();
        await client.close();
      }
    }
  });
}
