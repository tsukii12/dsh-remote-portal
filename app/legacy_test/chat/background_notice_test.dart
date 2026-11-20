import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pending_notice_harness.dart';

void main() {
  for (final feed in ['snapshot', 'live']) {
    for (final slot in ['next-step', 'next-turn']) {
      for (final running in [true, false]) {
        testWidgets('tool-jobs is an independent notice: $feed $slot running=$running', (tester) async {
          final h = PendingNoticeHarness();
          addTearDown(h.dispose);
          final semantics = tester.ensureSemantics();
          try {
            await h.mount(tester);
            if (feed == 'snapshot') {
              h.snapshot([pendingMessage()], slot: slot);
            } else {
              h.splice([pendingMessage()], slot: slot);
            }
            h.running(running);
            await h.settle(tester);
            expect(
              h.state.pending.single.resendable,
              isFalse,
              reason: 'P12 already hides send-now for nonhuman inbox messages.',
            );
            expect(find.byType(UserBubble), findsNothing);
            expect(find.text('后台任务通知'), findsOneWidget);
            expect(find.text(backgroundNoticeBody), findsNothing);
            for (final action in ['立即发送', '发送', '改为插话', '撤回']) {
              expect(find.text(action), findsNothing);
            }
            expect(find.bySemanticsLabel(RegExp(r'^我(?:\n|$)')), findsNothing);
            expect(h.client.calls, isEmpty);
          } finally {
            semantics.dispose();
          }
        });
      }
    }
  }

  for (final action in ['sendNow', 'steer', 'withdraw']) {
    testWidgets('direct $action does not mutate an automatic notice', (tester) async {
      final h = PendingNoticeHarness();
      addTearDown(h.dispose);
      h.snapshot([pendingMessage()], slot: 'next-turn');
      h.running(true);
      await h.settle(tester);
      final prompt = h.state.pending.single;
      switch (action) {
        case 'sendNow':
          expect(await h.chat.sendNow(prompt), isEmpty);
        case 'steer':
          expect(await h.chat.steerQueued(prompt), isFalse);
        case 'withdraw':
          expect(await h.chat.withdrawQueued(prompt), isFalse);
      }
      expect(h.client.calls, isEmpty);
      expect(h.state.pending.single.text, backgroundNoticeBody);
    });
  }

  testWidgets('same body from a human retains every queued action', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot([
      pendingMessage(source: {'kind': 'user', 'rpcId': 'human-1'}),
    ], slot: 'next-turn');
    h.running(true);
    await h.settle(tester);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.text('后台任务通知'), findsNothing);
    expect(h.state.pending.single.resendable, isTrue);
    for (final action in ['立即发送', '改为插话', '撤回']) {
      expect(find.text(action), findsOneWidget);
    }
    await tester.tap(find.text('立即发送'));
    await tester.tap(find.text('改为插话'));
    await tester.tap(find.text('撤回'));
    await h.settle(tester);
    expect(h.sentNow.single.text, backgroundNoticeBody);
    expect(h.withdrawn.single.text, backgroundNoticeBody);
    expect(h.client.calls, ['steer:notice-1']);
  });

  for (final source in [
    null,
    const {'kind': 'unknown'},
    const {'kind': 'other-producer'},
  ]) {
    testWidgets('unconfirmed source retains the existing pending behavior: $source', (tester) async {
      final h = PendingNoticeHarness();
      addTearDown(h.dispose);
      await h.mount(tester);
      h.snapshot([pendingMessage(source: source)], slot: 'next-turn');
      h.running(true);
      await h.settle(tester);
      expect(find.byType(UserBubble), findsOneWidget);
      expect(find.text('后台任务通知'), findsNothing);
      expect(find.text('后台任务消息'), findsNothing);
      expect(find.text('立即发送'), findsNothing);
      expect(find.text('改为插话'), findsOneWidget);
      expect(find.text('撤回'), findsOneWidget);
      expect(await h.chat.steerQueued(h.state.pending.single), isTrue);
      expect(await h.chat.withdrawQueued(h.state.pending.single), isTrue);
      expect(h.client.calls, ['steer:notice-1', 'remove:notice-1']);
    });
  }
}
