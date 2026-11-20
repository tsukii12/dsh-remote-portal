import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../workspace/support.dart';

Future<(FakeWorkspaceHost, ProviderContainer)> fixture({bool invalidRows = false}) async {
  SharedPreferences.setMockInitialValues({});
  final host = FakeWorkspaceHost();
  for (var i = 0; i < 6; i++) {
    host.seedSession('s$i', 'Session $i', DateTime.utc(2026));
  }
  if (invalidRows) {
    host.sessions[1]['blank'] = true;
    host.sessions[2]['origin'] = 'subagent';
    host.archived = ['s3'];
    host.sessions.insert(0, {...host.sessions.last, 'blank': true});
  }
  final c = ProviderContainer(overrides: workspaceOverrides(host, current: null));
  final sub = c.listen(sessionsProvider, (_, _) {});
  final client = c.read(activeConnectionProvider).value!.client;
  addTearDown(() async {
    sub.close();
    c.dispose();
    await client.close();
  });
  await c.read(sessionsProvider.future);
  final ready = Completer<void>();
  final workspaceSub = c.listen(workspacesProvider, (_, next) {
    if (next.ready && !ready.isCompleted) ready.complete();
  }, fireImmediately: true);
  await ready.future;
  workspaceSub.close();
  return (host, c);
}

void track(PendingSessionArchive plan) {
  addTearDown(() {
    plan.cancel();
    plan.release();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
  test('first input order is immutable and reordered same set returns the identical undo plan', () async {
    final (host, c) = await fixture();
    final controller = c.read(sessionsProvider.notifier);
    final input = ['s2', 's0', 's2'];
    final plan = controller.scheduleArchive(input);
    track(plan);
    expect(plan.ids, ['s2', 's0']);
    input.clear();
    expect(plan.ids, ['s2', 's0']);
    expect(() => plan.ids.add('s4'), throwsUnsupportedError);
    expect(identical(controller.scheduleArchive(['s0', 's2', 's0']), plan), isTrue);
    expect(plan.cancel(), isTrue);
    expect(c.read(sessionsProvider).value!.length, 6);
    expect(host.calls.where((row) => row.$1 == 'workspace/archiveSession'), isEmpty);
  });
  test('every selected ID must qualify; invalid replacement keeps the old plan and sends nothing', () async {
    final (host, c) = await fixture(invalidRows: true);
    final controller = c.read(sessionsProvider.notifier);
    expect(controller.beginDeletion('s4'), isNull);
    final plan = controller.scheduleArchive(['s0']);
    track(plan);
    for (final bad in ['unknown', 's1', 's2', 's3', 's4']) {
      expect(() => controller.scheduleArchive(['s5', bad]), throwsA(isA<DshClosedException>()), reason: bad);
      expect(plan.canUndo, isTrue);
      expect(c.read(sessionsProvider).value!.any((row) => row.sessionId == 's0'), isFalse);
    }
    expect(() => controller.scheduleArchive([]), throwsA(isA<DshClosedException>()));
    expect(plan.cancel(), isTrue);
    // A duplicate ineligible row must not hide a later eligible row with the same ID.
    final duplicate = controller.scheduleArchive(['s5']);
    track(duplicate);
    expect(duplicate.ids, ['s5']);
    expect(duplicate.cancel(), isTrue);
    expect(host.calls.where((row) => row.$1 == 'workspace/archiveSession'), isEmpty);
  });
}
