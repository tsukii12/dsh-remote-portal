// Real drawer bulk pin/unpin UI with one held carrier reply.
// No new product API: these can run unchanged on original f87.
import 'dart:async';

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/drawer_view_state.dart';
import 'package:dsh_app/state/hosts_state.dart';
import 'package:dsh_app/state/workspaces_state.dart';
import 'package:dsh_app/ui/shell/drawer/selection_bars.dart';
import 'package:dsh_app/ui/shell/home_shell.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shell/golden_harness.dart';
import '../workspace/support.dart';
import '../state/read_list_refresh_test.dart' show SwitchConnection, switchConnectionProvider;

class _PinHost extends FakeWorkspaceHost {
  Completer<void>? firstReply;
  bool failPins = false;
  final received = <({String endpoint, String id})>[];

  @override
  Future<RpcResult> call(String endpoint, Map<String, Object?> args, {Duration? timeout}) async {
    if (endpoint == 'workspace/pinSession' || endpoint == 'workspace/unpinSession') {
      final request = args['request']! as Map;
      received.add((endpoint: endpoint, id: request['sessionId']! as String));
      final gate = firstReply;
      if (gate != null && received.length == 1) await gate.future;
      if (failPins) throw const DshClosedException('controlled pin rejection');
    }
    return super.call(endpoint, args, timeout: timeout);
  }
}

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 450));
  await tester.pump(const Duration(milliseconds: 450));
}

void _seed(_PinHost host, String label, bool unpin) {
  final now = DateTime(2026, 10, 28, 10);
  host.seedSession('s1', '$label first', now);
  host.seedSession('s2', '$label second', now.subtract(const Duration(seconds: 1)));
  host.seedWorkspace('/root/$label', sessionIds: ['s1', 's2']);
  host.pinned = unpin ? ['s1', 's2'] : [];
}

Future<(_PinHost, ProviderContainer)> _start(WidgetTester tester, bool unpin, {ValueNotifier<bool>? visible}) async {
  SharedPreferences.setMockInitialValues({});
  final host = _PinHost();
  _seed(host, 'A', unpin);
  final connection = workspaceHost(host);
  addTearDown(connection.client.close);
  usePhoneSurface(tester);
  await tester.pumpWidget(
    goldenApp(
      brightness: Brightness.light,
      home: visible == null
          ? HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true)
          : ValueListenableBuilder<bool>(
              valueListenable: visible,
              builder: (_, show, _) => show
                  ? HomeShell(chatBuilder: (_) => const SizedBox.expand(), initiallyOpen: true)
                  : const SizedBox.shrink(),
            ),
      overrides: [
        ...workspaceOverrides(host, current: null, prefs: const WorkspacePrefs(loaded: true)).skip(1),
        switchConnectionProvider.overrideWith(() => SwitchConnection(connection)),
        activeConnectionProvider.overrideWith((ref) => ref.watch(switchConnectionProvider)),
      ],
    ),
  );
  await _settle(tester);
  final container = ProviderScope.containerOf(tester.element(find.byType(HomeShell)));
  expect(container.read(workspacesProvider).ready, isTrue);
  container.read(drawerSelectionProvider.notifier).start('s1');
  container.read(drawerSelectionProvider.notifier).toggle('s2');
  await _settle(tester);
  return (host, container);
}

Future<void> _tapAction(WidgetTester tester, bool unpin) async {
  await tester.tap(find.descendant(of: find.byType(SelectionActionBar), matching: find.text(unpin ? '取消置顶' : '置顶')));
  await tester.pump();
}

void main() {
  for (final unpin in [false, true]) {
    final action = unpin ? 'unpin' : 'pin';
    for (final focus in ['rpc', 'selection', 'notice', 'pinned state']) {
      testWidgets('bulk $action preserves new Host $focus after held reply', (tester) async {
        final (hostA, container) = await _start(tester, unpin);
        if (focus == 'pinned state') {
          // One item isolates the late A acknowledgement from any later RPC.
          container.read(drawerSelectionProvider.notifier).toggle('s2');
          await _settle(tester);
        }
        final gate = Completer<void>();
        hostA.firstReply = gate;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        await _tapAction(tester, unpin);
        expect(hostA.received, hasLength(1), reason: 'The real first carrier request must already be in flight.');

        final hostB = _PinHost();
        _seed(hostB, 'B', unpin);
        final connectionB = workspaceHost(hostB, local: false);
        addTearDown(connectionB.client.close);
        container.read(switchConnectionProvider.notifier).set(connectionB);
        container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
        await _settle(tester);
        expect(container.read(workspacesProvider).ready, isTrue);
        expect(container.read(activeConnectionProvider).value!.client, same(connectionB.client));
        container.read(drawerSelectionProvider.notifier).start('s1');
        container.read(drawerSelectionProvider.notifier).toggle('s2');
        final newer = container.read(drawerSelectionProvider);
        await _settle(tester);
        gate.complete();
        await _settle(tester);

        // Separate tests put each observation first: a failed RPC assertion
        // must not prevent observing the old completion's UI side effects.
        if (focus == 'selection') expect(container.read(drawerSelectionProvider), same(newer));
        if (focus == 'pinned state') {
          expect(container.read(workspacesProvider).pinnedSessionIds, unpin ? ['s1', 's2'] : <String>[]);
          expect(hostB.received, isEmpty);
          expect(hostA.received, hasLength(1));
          expect(tester.takeException(), isNull);
          return;
        }
        if (focus == 'notice') {
          expect(find.text(unpin ? '已取消置顶 2 个对话' : '已置顶 2 个对话'), findsNothing);
        }
        expect(hostB.received, isEmpty, reason: 'A bulk intent cannot send its remaining request to B.');
        expect(
          hostA.received,
          hasLength(1),
          reason: 'Already sent A work may finish; no new requests after owner retirement.',
        );
        expect(container.read(drawerSelectionProvider), same(newer), reason: 'A completion cannot end B selection.');
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('same-owner bulk pin keeps original bottom-up order and finishes selection', (tester) async {
    final (host, container) = await _start(tester, false);
    await _tapAction(tester, false);
    await _settle(tester);
    expect(host.received.map((item) => item.id), ['s2', 's1']);
    expect(host.pinned, ['s1', 's2']);
    expect(container.read(drawerSelectionProvider), isNull);
    expect(find.text('已置顶 2 个对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  for (final transition in ['ABA', 'reconnect', 'new selection', 'late error']) {
    testWidgets('held pin retires correctly across $transition', (tester) async {
      final (hostA, container) = await _start(tester, false);
      final originalConnection = container.read(activeConnectionProvider).value!;
      final gate = Completer<void>();
      hostA.firstReply = gate;
      hostA.failPins = transition == 'late error';
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      await _tapAction(tester, false);
      expect(hostA.received, hasLength(1));
      if (transition == 'ABA' || transition == 'late error') {
        final hostB = _PinHost();
        _seed(hostB, 'B', false);
        hostB.failPins = transition == 'late error';
        final b = workspaceHost(hostB, local: false);
        addTearDown(b.client.close);
        container.read(switchConnectionProvider.notifier).set(b);
        container.read(activeHostProvider.notifier).select(HostRef.portal('pc'));
        await _settle(tester);
        expect(container.read(workspacesProvider).ready, isTrue);
        if (transition == 'ABA') {
          container.read(switchConnectionProvider.notifier).set(originalConnection);
          container.read(activeHostProvider.notifier).select(HostRef.none);
          await _settle(tester);
          expect(container.read(workspacesProvider).ready, isTrue);
        }
      } else if (transition == 'reconnect') {
        final ready = originalConnection.client.mux.lastReadyGenerationNumber;
        originalConnection.client.mux.reconnect();
        await _settle(tester);
        expect(originalConnection.client.mux.lastReadyGenerationNumber, greaterThan(ready));
        expect(container.read(workspacesProvider).ready, isTrue);
      }
      container.read(drawerSelectionProvider.notifier).start('s1');
      container.read(drawerSelectionProvider.notifier).toggle('s2');
      final newer = container.read(drawerSelectionProvider);
      gate.complete();
      await _settle(tester);
      if (transition == 'late error') expect(find.text('没能置顶，稍后再试'), findsNothing);
      expect(container.read(drawerSelectionProvider), same(newer));
      expect(hostA.received, hasLength(transition == 'new selection' ? 2 : 1));
      expect(find.text('已置顶 2 个对话'), findsNothing);
      expect(find.text('没能置顶，稍后再试'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('same Host batch survives drawer widget disposal', (tester) async {
    final visible = ValueNotifier(true);
    addTearDown(visible.dispose);
    final (host, container) = await _start(tester, false, visible: visible);
    final lifetime = container.listen(activeHostProvider, (_, _) {});
    addTearDown(lifetime.close);
    final gate = Completer<void>();
    host.firstReply = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await _tapAction(tester, false);
    expect(host.received, hasLength(1));
    visible.value = false;
    await tester.pump();
    expect(find.byType(HomeShell), findsNothing);
    expect(lifetime.closed, isFalse);
    gate.complete();
    await _settle(tester);
    expect(host.received.map((item) => item.id), ['s2', 's1']);
    expect(host.pinned, ['s1', 's2']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same Host failures keep the batch and show its failure result', (tester) async {
    final (host, container) = await _start(tester, false);
    host.failPins = true;
    await _tapAction(tester, false);
    await _settle(tester);
    expect(host.received.map((item) => item.id), ['s2', 's1']);
    expect(container.read(drawerSelectionProvider), isNull);
    expect(find.text('没能置顶，稍后再试'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('container disposal retires a held batch without another request', (tester) async {
    final (host, container) = await _start(tester, false);
    final lifetime = container.listen(activeHostProvider, (_, _) {});
    addTearDown(lifetime.close);
    final gate = Completer<void>();
    host.firstReply = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await _tapAction(tester, false);
    expect(host.received, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(lifetime.closed, isTrue);
    gate.complete();
    await _settle(tester);
    expect(host.received, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('selection.end listener creates a new selection without an old result notice', (tester) async {
    final (host, container) = await _start(tester, false);
    final gate = Completer<void>();
    host.firstReply = gate;
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    await _tapAction(tester, false);
    expect(host.received, hasLength(1));
    var fired = false;
    Set<String>? newer;
    final listener = container.listen(drawerSelectionProvider, (before, after) {
      if (fired || before == null || after != null) return;
      fired = true;
      container.read(drawerSelectionProvider.notifier).start('s1');
      container.read(drawerSelectionProvider.notifier).toggle('s2');
      newer = container.read(drawerSelectionProvider);
    });
    addTearDown(listener.close);
    gate.complete();
    await _settle(tester);
    expect(fired, isTrue, reason: 'The listener must run from the real completion end().');
    expect(host.received.map((item) => item.id), ['s2', 's1']);
    expect(newer, isNotNull);
    expect(container.read(drawerSelectionProvider), same(newer));
    expect(find.text('已置顶 2 个对话'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
