// Messages DSH puts in the agent inbox itself (an approval-policy or plan-mode
// switch, a working-directory change, a subagent's result...) are context for
// the model, never the person's words: they must not show as "my" bubble with
// 撤回, and the next send must not carry or move them (0.9.8 smoke 06g/06h/06r).

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/background_task_notice.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/pending_notice_harness.dart';

/// Every `source.kind` DSH 0.2.1-rc.4 inserts into an inbox on its own, with
/// the kind of text it carries (the English the model reads).
const _engineNotes = {
  'user-approval': 'The approval policy changed from "ask" to "never" (changed by the user).',
  'plan-mode': 'The user switched this session to plan mode.',
  'working-directory': 'The working directory changed from "/root" to "/root/app".',
  'cordis-host-runner': 'The user manually ran Cordis Plugin demo, Package p1, as run-1.',
  'subagent-settled': 'Subagent "child-1" finished.',
  'agent-message': 'Team message from reviewer:',
  'team-message': 'Team message from lead:',
  'goal': 'Goal round 2: continue working toward the objective.',
  'schedule': 'Reminder: check the build.',
  'user-question-reply': '{"kind":"answer_to_pending_question","tool":"ask_user_question"}',
  'tool-goal': 'The goal is complete; wrap up.',
  'ptc-mode': 'Images from the dispatched tool call.',
};

Map<String, Object?> _note(String kind, {String id = 'note-1', Map<String, Object?> extra = const {}}) =>
    pendingMessage(id: id, text: _engineNotes[kind]!, source: {'kind': kind, ...extra});

void main() {
  for (final MapEntry(key: kind, value: text) in _engineNotes.entries) {
    for (final (slot, running) in [('next-step', false), ('next-step', true), ('next-turn', true)]) {
      testWidgets('$kind in $slot (running=$running) is not drawn as the person\'s message', (tester) async {
        final h = PendingNoticeHarness();
        addTearDown(h.dispose);
        await h.mount(tester);
        h.snapshot([_note(kind)], slot: slot);
        h.running(running);
        await h.settle(tester);
        expect(h.state.pending, isEmpty, reason: 'nothing of it waits to be sent');
        expect(find.byType(UserBubble), findsNothing);
        expect(find.byType(BackgroundTaskNotice), findsNothing);
        expect(find.text(text), findsNothing);
        for (final label in ['未发送', '撤回', '立即发送', '发送', '改为插话']) {
          expect(find.text(label), findsNothing);
        }
        expect(h.client.calls, isEmpty);
      });
    }
  }

  testWidgets('a live insertion during an idle chat stays out of it too', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot(const []);
    await h.settle(tester);
    h.splice([
      _note('plan-mode', extra: {'form': 'notice', 'summary': _engineNotes['plan-mode']}),
    ]);
    h.splice([_note('user-approval', id: 'note-2')]);
    await h.settle(tester);
    expect(h.state.pending, isEmpty);
    expect(find.byType(UserBubble), findsNothing);
    expect(find.text('撤回'), findsNothing);
  });

  testWidgets('the next send carries only the person\'s words; the note goes with that turn unseen', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    await h.mount(tester);
    h.snapshot([_note('user-approval'), _note('plan-mode', id: 'note-2')]);
    await h.settle(tester);
    expect(await h.chat.send('帮我看看这个项目'), isTrue);
    await h.settle(tester);
    expect(h.client.calls, ['prompt:queue:帮我看看这个项目']);
    expect(h.state.pending.map((p) => p.text), ['帮我看看这个项目']);
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.text('撤回'), findsNothing, reason: 'still on its way: no inbox entry yet');
    final requestId = h.client.sent.single.requestId;
    // DSH: the turn starts, takes the notes and the prompt out of the inbox and logs them.
    h.splice([
      pendingMessage(id: 'mine', text: '帮我看看这个项目', source: {'kind': 'user', 'rpcId': requestId}),
    ], slot: 'next-turn');
    await h.settle(tester);
    expect(h.state.pending.single.text, '帮我看看这个项目');
    h.running(true);
    h.splice(const [], removed: 2);
    h.splice(const [], slot: 'next-turn', removed: 1);
    h.log('user/message', _note('user-approval'));
    h.log('user/message', _note('plan-mode', id: 'note-2'));
    h.log('user/message', pendingMessage(id: 'mine', text: '帮我看看这个项目', source: {'kind': 'user', 'rpcId': requestId}));
    await h.settle(tester);
    expect(h.state.pending, isEmpty);
    expect(h.state.items.whereType<UserChatItem>().map((u) => u.text), ['帮我看看这个项目']);
    expect(find.text(_engineNotes['user-approval']!), findsNothing);
    expect(h.client.calls, ['prompt:queue:帮我看看这个项目'], reason: 'the notes were never moved, removed or sent');
  });

  testWidgets('stop wakes the person\'s waiting prompt, never a note', (tester) async {
    final h = PendingNoticeHarness();
    // Disposed inside the test: the stop's 10 s fallback timer goes with the controller.
    try {
      h.client.events.add(
        parseFollowFrame('s', {
          'type': 'snapshot',
          'header': {'id': 's', 'createdAt': 1792700000000},
          'cursor': 0,
          'records': const [],
          'hasMore': false,
          'projections': {
            'asOfSeq': 0,
            'values': {
              'inbox': {
                'next-step': [_note('plan-mode')],
                'next-turn': [
                  pendingMessage(id: 'mine', text: '然后跑一下测试', source: {'kind': 'user', 'rpcId': 'r1'}),
                  _note('schedule', id: 'note-2'),
                ],
              },
            },
          },
        }),
      );
      h.running(true);
      await h.settle(tester);
      expect(h.state.pending.map((p) => p.text), ['然后跑一下测试']);
      expect(await h.chat.cancel(), isEmpty);
      expect(h.client.calls, ['cancel:s', 'remove:mine', 'prompt:queue:然后跑一下测试']);
    } finally {
      await h.dispose();
    }
  });

  testWidgets('the controller refuses to move a note even when asked directly', (tester) async {
    final h = PendingNoticeHarness();
    addTearDown(h.dispose);
    // Controls act only on an applied session baseline (G54).
    h.snapshot(const []);
    h.running(true);
    await h.settle(tester);
    for (final kind in _engineNotes.keys) {
      final prompt = PendingPrompt(
        requestId: kind,
        text: _engineNotes[kind]!,
        time: DateTime(2026),
        inboxId: 'item-$kind',
        slot: InboxSlot.nextTurn,
        sourceKind: kind,
      );
      expect(prompt.isEngineNote, isTrue, reason: kind);
      expect(await h.chat.sendNow(prompt), isEmpty, reason: kind);
      expect(await h.chat.steerQueued(prompt), isFalse, reason: kind);
      expect(await h.chat.withdrawQueued(prompt), isFalse, reason: kind);
    }
    expect(h.client.calls, isEmpty);
  });

  test('only the person, a background task, or an unconfirmed producer keep their old rows', () {
    PendingPrompt of(String kind) => PendingPrompt(requestId: kind, text: 'x', time: DateTime(2026), sourceKind: kind);
    expect(of('user').isEngineNote, isFalse);
    expect(of('tool-jobs').isEngineNote, isFalse);
    expect(of('tool-jobs').isBackgroundTask, isTrue);
    expect(of('unknown').isEngineNote, isFalse);
    expect(of('other-producer').isEngineNote, isFalse);
  });

  testWidgets('ChatScreen draws no bubble for a note handed to it in state', (tester) async {
    usePhoneView(tester);
    mockClipboard(tester);
    final initial = ChatState(
      loading: false,
      pending: [
        PendingPrompt(
          requestId: 'note',
          text: _engineNotes['user-approval']!,
          time: DateTime(2026),
          inboxId: 'note-1',
          slot: InboxSlot.nextStep,
          sourceKind: 'user-approval',
          resendable: false,
        ),
      ],
    );
    final h = ChatHarness(session: 's', states: {'s': initial});
    await tester.pumpWidget(testApp(const ChatScreen(), overrides: h.overrides));
    await pumpFrames(tester);
    expect(find.byType(UserBubble), findsNothing);
    expect(find.text(_engineNotes['user-approval']!), findsNothing);
    expect(find.text('撤回'), findsNothing);
    expect(find.text('未发送'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
