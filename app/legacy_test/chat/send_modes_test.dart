import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/empty_state.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

Future<void> pumpScreen(WidgetTester tester, ChatHarness harness) async {
  usePhoneView(tester);
  mockClipboard(tester);
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester);
}

ChatState runningWith(List<PendingPrompt> pending) => ChatState(loading: false, running: true, pending: pending);

PendingPrompt prompt(
  String id,
  String text, {
  InboxSlot? slot,
  SendMode mode = SendMode.now,
  String? inboxId,
  bool resendable = true,
}) => PendingPrompt(
  requestId: id,
  text: text,
  time: DateTime(2026, 10, 23, 9),
  mode: mode,
  slot: slot,
  inboxId: inboxId,
  resendable: resendable,
);

/// The pending line's text actions, left to right.
List<String> pendingActions(WidgetTester tester) {
  final buttons = find.descendant(of: find.byType(UserBubble), matching: find.byType(TextButton)).evaluate().toList()
    ..sort(
      (a, b) => tester.getTopLeft(find.byWidget(a.widget)).dx.compareTo(tester.getTopLeft(find.byWidget(b.widget)).dx),
    );
  return [for (final b in buttons) ((b.widget as TextButton).child! as Text).data!];
}

void main() {
  setUpAll(() => chatClock = () => DateTime(2026, 10, 23, 9));

  testWidgets('while generating, typing and tapping send goes out right away', (tester) async {
    final harness = ChatHarness(session: 's1', states: {'s1': runningWith(const [])});
    await pumpScreen(tester, harness);
    expect(find.text('生成中 · 可直接插话'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '用 pnpm 别用 npm');
    // Let the stop key finish turning into ↑ before tapping it.
    await pumpFrames(tester, 2);
    await tester.tap(find.byIcon(AppIcons.send));
    await pumpFrames(tester);

    final c = harness.controllers['s1']!;
    expect(c.sent, ['用 pnpm 别用 npm']);
    // The controller turns "now" into steering while a turn runs.
    expect(c.sentModes, [SendMode.now]);
  });

  testWidgets('long-press send offers 插话 / 中断并发送 / 排队', (tester) async {
    final harness = ChatHarness(session: 's1', states: {'s1': runningWith(const [])});
    await pumpScreen(tester, harness);
    await tester.enterText(find.byType(TextField), '先停一下');
    await pumpFrames(tester, 2);

    await tester.longPress(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    expect(find.text('发送方式'), findsOneWidget);
    expect(find.text('插话'), findsOneWidget);
    expect(find.text('排队'), findsOneWidget);

    await tester.tap(find.text('中断并发送'));
    await pumpFrames(tester);
    final c = harness.controllers['s1']!;
    expect(c.sent, ['先停一下']);
    expect(c.sentModes, [SendMode.interrupt]);
  });

  testWidgets('idle: long-press just sends', (tester) async {
    final harness = ChatHarness(session: 's1', states: {'s1': const ChatState(loading: false)});
    await pumpScreen(tester, harness);
    await tester.enterText(find.byType(TextField), '你好');
    await tester.pump();
    await tester.longPress(find.byIcon(AppIcons.send));
    await pumpFrames(tester);
    expect(find.text('发送方式'), findsNothing);
    expect(harness.controllers['s1']!.sent, ['你好']);
  });

  testWidgets('a queued message can be moved into the turn or withdrawn', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': runningWith([
          prompt('r1', '顺便把 README 也改了', slot: InboxSlot.nextTurn, inboxId: 'q1', mode: SendMode.queue),
        ]),
      },
    );
    await pumpScreen(tester, harness);
    expect(find.text('排队中 · 本轮结束后发送'), findsOneWidget);
    expect(pendingActions(tester), ['立即发送', '改为插话', '撤回']);

    await tester.tap(find.text('改为插话'));
    await pumpFrames(tester);
    final c = harness.controllers['s1']!;
    expect(c.steered, ['r1']);

    await tester.tap(find.text('撤回'));
    await pumpFrames(tester);
    expect(c.withdrawn, ['r1']);
    // Back in the composer for editing.
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, '顺便把 README 也改了');
    expect(find.text('已撤回，可修改后再发'), findsOneWidget);
  });

  testWidgets('a steering message says the agent will see it next, no 改为插话', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': runningWith([prompt('r2', '用中文回答', slot: InboxSlot.nextStep, inboxId: 's1', mode: SendMode.steer)]),
      },
    );
    await pumpScreen(tester, harness);
    expect(find.text('插话 · 下一步生效'), findsOneWidget);
    expect(pendingActions(tester), ['立即发送', '撤回']);

    await tester.tap(find.text('立即发送'));
    await pumpFrames(tester);
    expect(harness.controllers['s1']!.sentNow, ['r2']);
  });

  testWidgets('left in the inbox with no turn running: 未发送, 发送 / 撤回', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': ChatState(
          loading: false,
          pending: [prompt('r4', '停下之前发的', slot: InboxSlot.nextStep, inboxId: 'q4', mode: SendMode.steer)],
        ),
      },
    );
    await pumpScreen(tester, harness);
    expect(find.text('未发送'), findsOneWidget);
    expect(find.text('插话 · 下一步生效'), findsNothing);
    expect(pendingActions(tester), ['发送', '撤回']);

    await tester.tap(find.text('发送'));
    await pumpFrames(tester);
    expect(harness.controllers['s1']!.sentNow, ['r4']);
  });

  testWidgets('sent elsewhere with attachments: no 立即发送', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': runningWith([
          prompt('r5', '电脑上发的', slot: InboxSlot.nextTurn, inboxId: 'q5', mode: SendMode.queue, resendable: false),
        ]),
      },
    );
    await pumpScreen(tester, harness);
    expect(pendingActions(tester), ['改为插话', '撤回']);
  });

  testWidgets('before the Host reports it, a bubble has no actions', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {
        's1': runningWith([prompt('r3', '停', mode: SendMode.interrupt)]),
      },
    );
    await pumpScreen(tester, harness);
    expect(find.text('正在停止本轮'), findsOneWidget);
    expect(find.text('撤回'), findsNothing);
  });

  testWidgets('a notice shows in info colours and can be dismissed', (tester) async {
    final harness = ChatHarness(
      session: 's1',
      states: {'s1': const ChatState(loading: false, notice: '当前模型只能读文字,图片已作为文件发给 AI')},
    );
    await pumpScreen(tester, harness);
    expect(find.textContaining('只能读文字'), findsOneWidget);
    expect(find.byIcon(AppIcons.info), findsOneWidget);
    expect(find.byIcon(AppIcons.error), findsNothing);

    await tester.tap(find.byTooltip('关闭'));
    await pumpFrames(tester);
    expect(find.textContaining('只能读文字'), findsNothing);
  });
}
