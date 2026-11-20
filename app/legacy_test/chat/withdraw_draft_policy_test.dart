import 'dart:async';
import 'dart:typed_data';

import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/composer_quote.dart';
import 'package:dsh_app/state/draft_store.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/harness.dart';

class _HeldWithdrawal extends FakeChatController {
  _HeldWithdrawal(super.sessionId, super.initial);
  final result = Completer<bool>();
  @override
  Future<bool> withdrawQueued(PendingPrompt prompt) {
    withdrawn.add(prompt.requestId);
    return result.future;
  }
}

void main() {
  for (final scenario in ['empty target', 'typed target', 'existing origin', 'visible edited origin']) {
    testWidgets('withdrawal draft policy preserves $scenario', (tester) async {
      usePhoneView(tester);
      mockClipboard(tester);
      SharedPreferences.setMockInitialValues({});
      final oldFile = DraftAttachment.sniff('queued-file.txt', Uint8List.fromList([1, 2, 3]));
      final prompt = PendingPrompt(
        requestId: 'queued-local',
        inboxId: 'queue-slot',
        text: withQuote('old quote', 'withdrawn body'),
        time: DateTime(2026, 10, 28),
        mode: SendMode.queue,
        attachments: [oldFile],
      );
      final ui = ChatHarness(session: 'S');
      final controllers = <String, _HeldWithdrawal>{};
      await tester.pumpWidget(
        testApp(
          const ChatScreen(),
          overrides: [
            for (final override in ui.overrides)
              if (override.origin != chatProvider) override,
            chatProvider.overrideWith2(
              (id) => controllers[id] = _HeldWithdrawal(
                id,
                ChatState(loading: false, running: true, pending: id == 'S' ? [prompt] : const []),
              ),
            ),
          ],
        ),
      );
      await pumpFrames(tester);
      final container = ProviderScope.containerOf(tester.element(find.byType(ChatScreen)));
      try {
        await tester.tap(find.text('撤回'));
        await pumpFrames(tester);
        expect(controllers['S']!.withdrawn, ['queued-local']);
        if (scenario == 'existing origin' || scenario == 'visible edited origin') {
          await tester.enterText(find.byType(TextField), 'new origin draft');
          container.read(composerQuoteProvider.notifier).set('S', 'new origin quote');
        }
        if (scenario != 'visible edited origin') {
          container.read(currentSessionProvider.notifier).select('T');
          await pumpFrames(tester);
          if (scenario == 'typed target') {
            await tester.enterText(find.byType(TextField), 'target draft');
          }
        }
        controllers['S']!.result.complete(true);
        await pumpFrames(tester);
        final drafts = container.read(draftStoreProvider).drafts;
        final quotes = container.read(composerQuoteProvider);
        final shown = tester.widget<TextField>(find.byType(TextField)).controller!.text;
        if (scenario == 'visible edited origin') {
          expect(shown, 'new origin draft');
          expect(quotes['S'], 'new origin quote');
          // Existing behavior may return attachments independently of text.
          expect(find.text('queued-file.txt'), findsWidgets);
        } else {
          expect(shown, scenario == 'typed target' ? 'target draft' : isEmpty);
          expect(drafts['T']?.attachments ?? const [], isEmpty);
          expect(quotes['T'], isNull);
          expect(find.text('已撤回，可修改后再发'), findsNothing);
          if (scenario == 'existing origin') {
            expect(drafts['S']!.text, 'new origin draft');
            expect(drafts['S']!.attachments, isEmpty);
            expect(quotes['S'], 'new origin quote');
          } else {
            expect(drafts['S']!.text, 'withdrawn body');
            expect(drafts['S']!.attachments.single, same(oldFile));
            expect(quotes['S'], 'old quote');
          }
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.pump(const Duration(milliseconds: 600));
      }
    });
  }
}
