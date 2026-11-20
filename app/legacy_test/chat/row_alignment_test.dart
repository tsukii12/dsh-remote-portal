// Every row keeps its side while it eases in and after: the user bubble's
// right edge sits on the row's content edge (at rest, mid-animation, right
// after send and after the echo), replies and notices start on the left one.

import 'dart:math' as math;

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_list.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_app/ui/theme/shapes.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

final _time = DateTime(2026);

UserChatItem _user(int seq, String text, {String? requestId}) =>
    UserChatItem(seq: seq, time: _time, text: text, images: const [], files: const [], requestId: requestId);

AssistantChatItem _reply(int seq, String text) =>
    AssistantChatItem(id: 'a$seq', seq: seq, time: _time, text: text, reasoning: '');

NoticeChatItem _stopped(int seq) => NoticeChatItem(seq: seq, kind: 'aborted', text: 'aborted');

/// The row's content box: the reading column minus the gutters.
Rect _content(WidgetTester tester, Finder inRow) {
  final row = tester.getRect(
    find
        .ancestor(of: inRow, matching: find.byWidgetPredicate((w) => w is KeyedSubtree && w.key is ValueKey<String>))
        .first,
  );
  final width = math.min(row.width, AppSpace.readingWidth) - 2 * AppSpace.gutter;
  return Rect.fromCenter(center: row.center, width: width, height: row.height);
}

/// The painted bubble (not the full-width column around it).
Finder _bubble() => find.descendant(of: find.byType(UserBubble).last, matching: find.byType(DecoratedBox)).first;

void _expectRight(WidgetTester tester, String when) {
  final bubble = _bubble();
  expect(
    tester.getRect(bubble).right,
    moreOrLessEquals(_content(tester, bubble).right, epsilon: 0.01),
    reason: 'user bubble $when',
  );
}

void _expectLeft(WidgetTester tester, Finder finder, String what) {
  expect(tester.getRect(finder).left, moreOrLessEquals(_content(tester, finder).left, epsilon: 0.01), reason: what);
}

/// The notice's leading icon square.
Finder _noticeIcon() => find.descendant(of: find.byType(NoticeRow).last, matching: find.byType(SizedBox)).first;

/// The reply's first line of text.
Finder _replyText() => find.descendant(of: find.byType(AssistantMessage).last, matching: find.byType(RichText)).first;

/// Opacity of the fade around [finder]; below 1 while the row eases in.
double _fade(WidgetTester tester, Finder finder) =>
    tester.widget<Opacity>(find.ancestor(of: finder, matching: find.byType(Opacity)).first).opacity;

Future<FakeChatController> _open(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 10);
  return harness.controllers['s1']!;
}

void main() {
  testWidgets('at rest: the bubble sits right, reply and notice left', (tester) async {
    await _open(tester, ChatState(loading: false, items: [_user(1, '你好'), _reply(2, '在的'), _stopped(3)]));
    expect(find.byType(ChatList), findsOneWidget);
    _expectRight(tester, 'at rest');
    _expectLeft(tester, _replyText(), 'reply at rest');
    _expectLeft(tester, _noticeIcon(), 'notice at rest');
  });

  testWidgets('a sent bubble stays right while it eases in and after the echo', (tester) async {
    final first = [_user(1, '你好'), _reply(2, '在的')];
    final chat = await _open(tester, ChatState(loading: false, items: first));

    chat.emit(
      ChatState(
        loading: false,
        items: first,
        pending: [PendingPrompt(requestId: 'r2', text: '好', time: _time)],
      ),
    );
    await tester.pump();
    expect(find.text('发送中'), findsOneWidget);
    _expectRight(tester, 'right after send');

    await tester.pump(const Duration(milliseconds: 120));
    expect(_fade(tester, _bubble()), inExclusiveRange(0, 1));
    _expectRight(tester, 'mid-animation');

    await pumpFrames(tester);
    _expectRight(tester, 'pending, settled');

    chat.emit(
      ChatState(
        loading: false,
        running: true,
        items: [
          ...first,
          _user(3, '好', requestId: 'r2'),
        ],
      ),
    );
    await pumpFrames(tester);
    expect(find.text('发送中'), findsNothing);
    _expectRight(tester, 'after the echo');
  });

  testWidgets('fresh rows ease in on their own side', (tester) async {
    final first = [_user(1, '你好'), _reply(2, '在的')];
    final chat = await _open(tester, ChatState(loading: false, items: first));

    // A message sent from another device: no pending bubble, it eases in.
    final withUser = [...first, _user(3, '好')];
    chat.emit(ChatState(loading: false, running: true, items: withUser));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_fade(tester, _bubble()), inExclusiveRange(0, 1));
    _expectRight(tester, 'fresh, mid-animation');
    await pumpFrames(tester);
    _expectRight(tester, 'fresh, settled');

    chat.emit(ChatState(loading: false, items: [...withUser, _reply(4, '收到'), _stopped(5)]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    expect(_fade(tester, _noticeIcon()), inExclusiveRange(0, 1));
    _expectLeft(tester, _replyText(), 'reply, mid-animation');
    _expectLeft(tester, _noticeIcon(), 'notice, mid-animation');
    await pumpFrames(tester);
    _expectLeft(tester, _replyText(), 'reply, settled');
    _expectLeft(tester, _noticeIcon(), 'notice, settled');
    _expectRight(tester, 'after the reply');
  });
}
