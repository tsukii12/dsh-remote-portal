// Production ChatScreen and its lent composer; only the bridge transport is
// scripted. A plugin answer belongs to the conversation where the tap began.
import 'dart:async';

import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../chat/support/harness.dart';
import 'support.dart';

DshGoInvokeResult _insert() => DshGoInvokeResult.fromJson({
  'v': 1,
  'effects': [
    {'type': 'insert', 'text': 'plugin result'},
  ],
});

String _draft(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).first).controller!.text;

Future<ProviderContainer> _mount(WidgetTester tester, FakeBridge bridge, String? session) async {
  usePhoneView(tester);
  final chat = ChatHarness(session: session);
  await tester.pumpWidget(
    testApp(
      const ChatScreen(),
      overrides: [
        ...chat.overrides,
        ...nativeOverrides(bridge, clock: () => DateTime(2026, 10, 28)),
      ],
    ),
  );
  await pumpFrames(tester);
  return ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
}

void main() {
  setUpAll(loadTestFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final (from, to) in <(String?, String?)>[('s1', 's1'), ('s1', 's2'), ('s1', null), (null, 's2')]) {
    testWidgets('immediate answer $from -> $to only writes its original composer owner', (tester) async {
      final pending = Completer<DshGoInvokeResult>();
      final bridge = FakeBridge(contributions([quickPlugin()]))..answer = (_) => pending.future;
      final container = await _mount(tester, bridge, from);
      await tester.enterText(find.byType(TextField).first, 'source draft');
      await tester.tap(find.text('译成英文'));
      await pumpFrames(tester, 2);
      expect(bridge.invocations, hasLength(1));
      expect(bridge.invocations.single.scope.sessionId, from);
      if (from != to) {
        container.read(currentSessionProvider.notifier).select(to);
        await pumpFrames(tester, 2);
        await tester.enterText(find.byType(TextField).first, 'target draft');
      }
      pending.complete(_insert());
      await pumpFrames(tester, 2);
      if (from == to) {
        expect(_draft(tester), contains('plugin result'));
      } else {
        expect(_draft(tester), 'target draft');
        container.read(currentSessionProvider.notifier).select(from);
        await pumpFrames(tester, 2);
        expect(_draft(tester), 'source draft');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a deferred answer cannot write into a later conversation', (tester) async {
    final bridge = FakeBridge(contributions([quickPlugin()]))
      ..answer = (_) => DshGoInvokeResult.fromJson({
        'v': 1,
        'effects': [],
        'pending': {'id': 'p1', 'label': 'working', 'timeoutMs': 30000},
      });
    final container = await _mount(tester, bridge, 's1');
    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester, 2);
    expect(bridge.invocations, hasLength(1));
    container.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester, 2);
    await tester.enterText(find.byType(TextField).first, 'target draft');
    bridge.socket.push({
      't': 'done',
      'pending': 'p1',
      'effects': [
        {'type': 'insert', 'text': 'plugin result'},
      ],
    });
    await pumpFrames(tester, 2);
    expect(_draft(tester), 'target draft');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a static effect chain retires after its awaited copy crosses a conversation switch', (tester) async {
    final copied = Completer<Object?>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') return copied.future;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final bridge = FakeBridge(
      contributions([
        plugin(
          'static-owner',
          composer: [
            {
              'id': 'copy-insert',
              'label': '复制再插入',
              'effect': [
                {'type': 'copy', 'text': 'copied'},
                {'type': 'insert', 'text': 'plugin result'},
              ],
            },
          ],
        ),
      ]),
    );
    final container = await _mount(tester, bridge, 's1');
    await tester.tap(find.text('复制再插入'));
    await pumpFrames(tester, 2);
    container.read(currentSessionProvider.notifier).select('s2');
    await pumpFrames(tester, 2);
    await tester.enterText(find.byType(TextField).first, 'target draft');
    copied.complete(null);
    await pumpFrames(tester, 2);
    expect(_draft(tester), 'target draft');
    expect(bridge.invocations, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final frameBetween in [false, true]) {
    testWidgets('leaving and returning retires the tap, frameBetween=$frameBetween', (tester) async {
      final pending = Completer<DshGoInvokeResult>();
      final bridge = FakeBridge(contributions([quickPlugin()]))..answer = (_) => pending.future;
      final container = await _mount(tester, bridge, 's1');
      await tester.enterText(find.byType(TextField).first, 'source draft');
      await tester.tap(find.text('译成英文'));
      await pumpFrames(tester, 2);
      expect(bridge.invocations, hasLength(1));
      container.read(currentSessionProvider.notifier).select('s2');
      if (frameBetween) await pumpFrames(tester, 2);
      container.read(currentSessionProvider.notifier).select('s1');
      await pumpFrames(tester, 2);
      expect(_draft(tester), 'source draft');
      pending.complete(_insert());
      await pumpFrames(tester, 2);
      expect(_draft(tester), 'source draft');
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('typing within the same conversation does not retire an insert action', (tester) async {
    final pending = Completer<DshGoInvokeResult>();
    final bridge = FakeBridge(contributions([quickPlugin()]))..answer = (_) => pending.future;
    await _mount(tester, bridge, 's1');
    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester, 2);
    await tester.enterText(find.byType(TextField).first, 'new typing');
    pending.complete(_insert());
    await pumpFrames(tester, 2);
    expect(_draft(tester), 'new typing plugin result ');
    expect(tester.takeException(), isNull);
  });

  testWidgets('a capsule rendered for the previous session cannot dispatch before the next frame', (tester) async {
    final bridge = FakeBridge(contributions([quickPlugin()]))..answer = (_) => _insert();
    final container = await _mount(tester, bridge, 's1');
    container.read(currentSessionProvider.notifier).select('s2');
    // No frame has rebuilt the capsule closure; it still carries scope s1.
    await tester.tap(find.text('译成英文'));
    await pumpFrames(tester, 2);
    expect(bridge.invocations, isEmpty);
    expect(_draft(tester), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
