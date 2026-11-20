import 'package:dsh_app/state/artifacts.dart';
import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/settings_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/chat/widgets/background_task_notice.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/pending_notice_harness.dart';
import 'support/harness.dart';

void main() {
  test('copies preserve producer metadata and replacement sources clear obsolete forms', () {
    final original = PendingPrompt(
      requestId: 'job',
      text: backgroundNoticeBody,
      time: DateTime(2026),
      sourceKind: 'tool-jobs',
      sourceForm: 'notice',
    );
    final copy = original.withMode(SendMode.queue).placed('item', InboxSlot.nextTurn);
    expect(copy.sourceKind, 'tool-jobs');
    expect(copy.sourceForm, 'notice');
    expect(copy.isBackgroundTask, isTrue);
    expect(copy.text, original.text);
    final legacy = copy.placed('item', InboxSlot.nextStep, source: const MessageSource('tool-jobs', {}));
    expect(legacy.sourceKind, 'tool-jobs');
    expect(legacy.sourceForm, isNull);
    final malformed = copy.placed('item', InboxSlot.nextStep, source: const MessageSource('tool-jobs', {'form': 7}));
    expect(malformed.sourceForm, isNull);
    final human = copy.placed('item', InboxSlot.nextTurn, source: const MessageSource('user', {}));
    expect(human.isBackgroundTask, isFalse);
    expect(human.sourceForm, isNull);
  });

  test('old local constructors retain the human default', () {
    final prompt = PendingPrompt(requestId: 'old', text: backgroundNoticeBody, time: DateTime(2026));
    expect(prompt.sourceKind, 'user');
    expect(prompt.isBackgroundTask, isFalse);
    expect(prompt.withMode(SendMode.steer).placed('item', InboxSlot.nextStep).sourceKind, 'user');
    expect(prompt.resendable, isTrue);
  });

  for (final form in [
    null,
    '',
    'summary',
    'Notice',
    7,
    false,
    const {'notice': true},
  ]) {
    testWidgets('tool-jobs unconfirmed form uses neutral read-only copy: $form', (tester) async {
      final h = PendingNoticeHarness();
      addTearDown(h.dispose);
      await h.mount(tester);
      h.snapshot([
        pendingMessage(source: {'kind': 'tool-jobs', 'form': ?form}),
      ]);
      h.running(true);
      await h.settle(tester);
      final prompt = h.state.pending.single;
      expect(prompt.sourceKind, 'tool-jobs');
      expect(prompt.sourceForm, form is String ? form : null);
      expect(find.text('后台任务消息'), findsOneWidget);
      expect(find.text('后台任务通知'), findsNothing);
      expect(find.byType(UserBubble), findsNothing);
      expect(await h.chat.sendNow(prompt), isEmpty);
      expect(await h.chat.steerQueued(prompt), isFalse);
      expect(await h.chat.withdrawQueued(prompt), isFalse);
      expect(h.client.calls, isEmpty);
    });
  }

  testWidgets('human text cannot claim a producer by repeating its JSON', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    const body = '{"source":{"kind":"tool-jobs","form":"notice"}}\n$backgroundNoticeBody';
    h.snapshot([
      pendingMessage(text: body, source: {'kind': 'user', 'form': 'notice', 'rpcId': 'human'}),
    ], slot: 'next-turn');
    h.running(true);
    await h.settle(tester);
    expect(h.state.pending.single.isBackgroundTask, isFalse);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.byType(BackgroundTaskNotice), findsNothing);
    expect(find.text('立即发送'), findsOneWidget);
    expect(await h.chat.withdrawQueued(h.state.pending.single), isTrue);
    expect(h.client.calls, ['remove:notice-1']);
  });

  testWidgets('a local optimistic send keeps its source through the inbox echo', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    // Controls act only on an applied session baseline (G54).
    h.snapshot(const []);
    h.running(true);
    await h.settle(tester);
    expect(await h.chat.send(backgroundNoticeBody, mode: SendMode.queue), isTrue);
    await h.settle(tester);
    final requestId = h.client.sent.single.requestId;
    expect(h.state.pending.single.sourceKind, 'user');
    expect(find.byType(UserBubble), findsOneWidget);
    h.splice([
      pendingMessage(source: {'kind': 'user', 'rpcId': requestId}),
    ], slot: 'next-turn');
    await h.settle(tester);
    expect(h.state.pending, hasLength(1));
    expect(h.state.pending.single.sourceKind, 'user');
    expect(h.state.pending.single.inboxId, 'notice-1');
    expect(find.text('立即发送'), findsOneWidget);
  });

  testWidgets('producer branch takes precedence over a reply-marker body', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    const body = '[dsh-ui reply] 自动内容\n确认：开始部署';
    h.snapshot([pendingMessage(text: body)]);
    await h.settle(tester);
    expect(find.byType(DshUiReplyChip), findsNothing);
    expect(find.byType(BackgroundTaskNotice), findsOneWidget);
    await tester.tap(find.text('后台任务通知'));
    await h.settle(tester);
    expect(tester.widget<SelectableText>(find.byType(SelectableText)).data, body);
    expect(find.byType(DshUiReplyChip), findsNothing);
    expect(h.client.calls, isEmpty);
  });

  for (final feed in ['live', 'resync']) {
    testWidgets('same inbox key replacement collapses before painting new details: $feed', (tester) async {
      final h = PendingNoticeHarness();
      addTearDown(h.dispose);
      await h.mount(tester);
      h.snapshot([pendingMessage(text: 'old technical details')]);
      await h.settle(tester);
      await tester.tap(find.text('后台任务通知'));
      await h.settle(tester);
      expect(find.text('old technical details'), findsOneWidget);
      final replacement = pendingMessage(text: 'new technical details');
      if (feed == 'live') {
        h.splice([replacement], removed: 1);
      } else {
        h.snapshot([replacement], resync: true);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(h.state.pending.single.text, 'new technical details');
      expect(
        find.byType(SelectableText),
        findsNothing,
        reason: 'Check the first replacement frame, not a settled animation.',
      );
      expect(find.text('old technical details'), findsNothing);
      await tester.tap(find.text('后台任务通知'));
      await h.settle(tester);
      expect(find.text('new technical details'), findsOneWidget);
      expect(h.client.calls, isEmpty);
    });
  }

  testWidgets('consumption removes the notice without producing human history', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot([pendingMessage()]);
    await h.settle(tester);
    await tester.tap(find.text('后台任务通知'));
    await h.settle(tester);
    h.splice(const [], removed: 1);
    h.log('user/message', pendingMessage());
    await h.settle(tester);
    expect(h.state.pending, isEmpty);
    expect(h.state.items.whereType<UserChatItem>(), isEmpty);
    expect(find.byType(BackgroundTaskNotice), findsNothing);
    expect(find.byType(UserBubble), findsNothing);
    expect(h.withdrawn, isEmpty);
    expect(h.sentNow, isEmpty);
    h.splice([pendingMessage()]);
    await h.settle(tester);
    expect(find.byType(BackgroundTaskNotice), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing, reason: 'A newly inserted occurrence starts closed.');
  });

  testWidgets('a replacement client snapshot cannot reuse the old expanded details', (tester) async {
    final h = PendingNoticeHarness();
    final next = PendingNoticeClient();
    addTearDown(next.events.close);
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot([pendingMessage(text: 'old host details')]);
    await h.settle(tester);
    await tester.tap(find.text('后台任务通知'));
    await h.settle(tester);
    expect(find.text('old host details'), findsOneWidget);
    h.container.updateOverrides([
      activeConnectionProvider.overrideWithValue(AsyncData(HostConnection(hostId: '', client: next, isLocal: true))),
      settingsProvider.overrideWith(TestSettings.new),
      sessionArtifactsProvider('s').overrideWithValue(const []),
    ]);
    await h.settle(tester);
    next.events.add(
      SessionSnapshotEvent.fromJson('s', {
        'cursor': 0,
        'projections': {
          'asOfSeq': 0,
          'values': {
            'inbox': {
              'next-step': [pendingMessage(text: 'new host details')],
            },
          },
        },
      }),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(h.state.pending.single.text, 'new host details');
    expect(find.byType(SelectableText), findsNothing);
    expect(next.calls, isEmpty);
  });

  testWidgets('stop does not remove or replay a last automatic notice', (tester) async {
    final h = PendingNoticeHarness();
    try {
      h.snapshot([pendingMessage()], slot: 'next-turn');
      h.running(true);
      await h.settle(tester);
      expect(await h.chat.cancel(), isEmpty);
      expect(h.client.calls, ['cancel:s']);
      expect(h.state.pending.single.isBackgroundTask, isTrue);
    } finally {
      await h.dispose();
    }
  });

  testWidgets('source guard also rejects a notice incorrectly marked resendable', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    final prompt = PendingPrompt(
      requestId: 'job',
      text: backgroundNoticeBody,
      time: DateTime(2026),
      inboxId: 'item',
      slot: InboxSlot.nextTurn,
      sourceKind: 'tool-jobs',
      sourceForm: 'notice',
    );
    expect(prompt.resendable, isTrue);
    expect(await h.chat.sendNow(prompt), isEmpty);
    expect(await h.chat.steerQueued(prompt), isFalse);
    expect(await h.chat.withdrawQueued(prompt), isFalse);
    expect(h.client.calls, isEmpty);
  });

  for (final draft in ['', '保留我正在编辑的内容']) {
    testWidgets('ChatScreen consumption leaves the composer unchanged: ${draft.isEmpty ? 'empty' : 'draft'}', (
      tester,
    ) async {
      usePhoneView(tester);
      mockClipboard(tester);
      final initial = ChatState(
        loading: false,
        running: true,
        pending: [
          PendingPrompt(
            requestId: 'notice',
            text: backgroundNoticeBody,
            time: DateTime(2026),
            inboxId: 'notice-1',
            slot: InboxSlot.nextTurn,
            sourceKind: 'tool-jobs',
            sourceForm: 'notice',
            resendable: false,
          ),
        ],
      );
      final h = ChatHarness(session: 's', states: {'s': initial});
      await tester.pumpWidget(testApp(const ChatScreen(), overrides: h.overrides));
      await pumpFrames(tester);
      expect(find.byType(BackgroundTaskNotice), findsOneWidget);
      expect(find.text('撤回'), findsNothing);
      expect(find.text('改为插话'), findsNothing);
      expect(find.text('立即发送'), findsNothing);
      if (draft.isNotEmpty) {
        await tester.enterText(find.byType(TextField), draft);
        await pumpFrames(tester, 2);
      }
      await tester.tap(find.text('后台任务通知'));
      await pumpFrames(tester);
      final controller = h.controllers['s']!;
      controller.emit(initial.copyWith(pending: const []));
      await pumpFrames(tester);
      expect(find.byType(BackgroundTaskNotice), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, draft);
      expect(controller.withdrawn, isEmpty);
      expect(controller.sentNow, isEmpty);
      expect(controller.steered, isEmpty);
      expect(controller.sent, isEmpty);
      expect(find.text('已撤回，可修改后再发'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
