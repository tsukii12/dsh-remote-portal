import 'dart:io';

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/features_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';
import 'support/session_sync_host.dart';

// Instruments completion while retaining the complete production operation.
class _ObservedController extends ChatController {
  _ObservedController(super.sessionId);
  bool? returned;
  @override
  Future<bool> withdrawQueued(PendingPrompt prompt) async {
    final ok = await super.withdrawQueued(prompt);
    returned = ok;
    return ok;
  }
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 250; i++) {
    if (ready()) return;
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
    await tester.pump(const Duration(milliseconds: 5));
  }
  fail('UI/IO did not settle');
}

Future<SyncHarness> _start(WidgetTester tester, ReplyHold hold) async {
  usePhoneView(tester);
  mockClipboard(tester);
  SharedPreferences.setMockInitialValues({});
  final ui = ChatHarness(session: 'S');
  late SyncHarness h;
  await tester.runAsync(
    () => HttpOverrides.runWithHttpOverrides(() async {
      h = await SyncHarness.start(
        hold: hold,
        overrides: [
          for (final override in ui.overrides)
            if (override.origin != activeConnectionProvider && override.origin != chatProvider) override,
          chatProvider.overrideWith2(_ObservedController.new),
          skillsProvider.overrideWith((ref, sessionId) async => const []),
          sessionSchedulesProvider.overrideWith((ref, sessionId) async => const []),
        ],
      );
    }, RealSyncHttp()),
  );
  await tester.pumpWidget(UncontrolledProviderScope(container: h.container, child: testApp(const ChatScreen())));
  await pumpFrames(tester);
  return h;
}

Future<void> _close(WidgetTester tester, SyncHarness h, ReplyHold hold) async {
  hold.finish();
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 600));
  await tester.runAsync(h.close);
  await tester.pump();
}

String _input(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField)).controller!.text;

void main() {
  for (final destination in <String?>['T', null]) {
    testWidgets('a successful withdrawal from S cannot restore its text into $destination', (tester) async {
      final hold = ReplyHold()..arm('session/updateQueue');
      final h = await _start(tester, hold);
      try {
        await tester.tap(find.text('撤回'));
        await _pumpUntil(tester, () => hold.received!.isCompleted);
        expect(h.methods.where((method) => method == 'session/updateQueue'), ['session/updateQueue']);
        h.container.read(currentSessionProvider.notifier).select(destination);
        if (destination != null) {
          await _pumpUntil(tester, () => h.container.read(chatProvider(destination)).controlReady);
        }
        await pumpFrames(tester);
        expect(_input(tester), isEmpty);
        await tester.runAsync(() async => hold.finish());
        await _pumpUntil(tester, () => (h.chat as _ObservedController).returned != null);
        expect((h.chat as _ObservedController).returned, isTrue);
        await pumpFrames(tester);
        expect(_input(tester), isEmpty);
        expect(find.text('已撤回，可修改后再发'), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await _close(tester, h, hold);
      }
    });
  }

  testWidgets('a successful withdrawal still restores the original visible composer', (tester) async {
    final hold = ReplyHold()..arm('session/updateQueue');
    final h = await _start(tester, hold);
    try {
      await tester.tap(find.text('撤回'));
      await _pumpUntil(tester, () => hold.received!.isCompleted);
      await tester.runAsync(() async => hold.finish());
      await _pumpUntil(tester, () => (h.chat as _ObservedController).returned != null);
      expect((h.chat as _ObservedController).returned, isTrue);
      await pumpFrames(tester);
      expect(_input(tester), 'queue-run-1');
      expect(find.text('已撤回，可修改后再发'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      await _close(tester, h, hold);
    }
  });
}
