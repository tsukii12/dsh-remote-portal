// With a schedule, the clock key sits in the title pill like an end cap: the
// same gap above, below and to its right at every text size, its touch area
// the pill's whole height. The header's mirror is untouched (≡ and + equal,
// 12 from the edges, every piece centred on one line), and the model chip
// gives up the room, so a five-character status still fits where it did.

import 'package:dsh_app/state/connection_state.dart';
import 'package:dsh_app/state/header_schedule_state.dart';
import 'package:dsh_app/state/models_state.dart';
import 'package:dsh_app/state/sessions_state.dart';
import 'package:dsh_app/ui/chat/chat_header.dart';
import 'package:dsh_app/ui/chat/header_schedule.dart';
import 'package:dsh_app/ui/chat/model_sheet.dart';
import 'package:dsh_app/ui/common/status_dot.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

final _now = DateTime(2026, 10, 24, 15, 30);

final _task = ScheduleTask(
  id: 'sch-1',
  sessionId: 's1',
  kind: 'every',
  title: '检查夜间构建',
  prompt: '看一眼构建',
  active: true,
  record: const {'id': 'sch-1', 'kind': 'every'},
  everySeconds: 7200,
  scheduledAt: DateTime(2026, 10, 24, 21, 30),
);

/// Whether the conversation has the task; flip it and invalidate the source.
class _Scheduled {
  _Scheduled(this.on);
  bool on;
}

Future<void> _pump(
  WidgetTester tester, {
  required double width,
  required double scale,
  required _Scheduled scheduled,
  String status = '连接已断开',
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    testApp(
      Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: Align(
              alignment: Alignment.topCenter,
              child: ChatHeader(
                title: '修复登录重复提交',
                status: HeaderStatus(StatusTone.error, status),
                trailing: ModelChip(selection: testCatalog.defaultSelection, onSelected: (_) {}, grouped: true),
                onOpenDrawer: () {},
                onTitleTap: () {},
                onNewChat: () {},
              ),
            ),
          ),
        ),
      ),
      overrides: [
        activeConnectionProvider.overrideWithValue(AsyncData<HostConnection?>(fakeConnection)),
        sessionsProvider.overrideWith(FakeSessions.new),
        currentSessionProvider.overrideWith(() => FixedSession('s1')),
        modelCatalogProvider.overrideWith((ref) async => testCatalog),
        sessionSchedulesProvider.overrideWith((ref, id) async => scheduled.on ? [_task] : const <ScheduleTask>[]),
        scheduleClockProvider.overrideWithValue(() => _now),
      ],
    ),
  );
  await pumpFrames(tester);
}

Rect _rect(WidgetTester tester, String key) => tester.getRect(find.byKey(ValueKey(key)));

/// Where the bar can't keep the title's four characters beside the clock
/// even with the model chip down to ✦ ⌄: the clock gives way.
final _clockGoes = {(360.0, 2.0), (390.0, 2.0)};

/// How many of [text]'s characters are on screen (before the ellipsis).
int _titleChars(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  if (!paragraph.didExceedMaxLines) return text.length;
  final ellipsis = TextPainter(
    text: TextSpan(text: '\u2026', style: paragraph.text.style),
    textScaler: paragraph.textScaler,
    textDirection: TextDirection.ltr,
  )..layout();
  final em = paragraph.textScaler.scale(paragraph.text.style!.fontSize!);
  final chars = ((paragraph.size.width - ellipsis.width) / em + 0.01).floor();
  ellipsis.dispose();
  return chars;
}

void main() {
  for (final width in [360.0, 390.0, 412.0]) {
    for (final scale in [1.0, 1.3, 1.5, 2.0]) {
      testWidgets('clock in the pill at $width and $scale', (tester) async {
        final semantics = tester.ensureSemantics();
        await _pump(tester, width: width, scale: scale, scheduled: _Scheduled(true));
        expect(tester.takeException(), isNull);
        final bar = _rect(tester, 'chat-header-bar');
        final pill = _rect(tester, 'chat-title-pill');
        final menu = _rect(tester, 'chat-menu');
        final fresh = _rect(tester, 'chat-new-chat');
        final title = tester.getRect(find.text('修复登录重复提交'));
        final status = tester.getRect(find.text('连接已断开'));

        // The mirror is untouched.
        expect(pill.top - bar.top, closeTo(bar.bottom - pill.bottom, 0.1));
        expect(menu.size, const Size.square(44));
        expect(fresh.size, menu.size);
        expect(menu.left, 12);
        expect(width - fresh.right, 12);
        expect(pill.left - menu.right, 8);
        for (final piece in [menu, fresh, tester.getRect(find.byType(ModelChip))]) {
          expect(piece.center.dy, closeTo(pill.center.dy, 0.1));
        }

        // The floor: the whole status line and the title's first four
        // characters (360 × 2 can't hold four even without a clock; there
        // the clock still costs the title nothing, below), 16 in from the
        // pill's left.
        expect(
          tester.renderObject<RenderParagraph>(find.text('连接已断开')).didExceedMaxLines,
          isFalse,
          reason: 'five characters of status fit',
        );
        final chars = _titleChars(tester, '修复登录重复提交');
        if (!(width == 360 && scale == 2)) {
          expect(chars, greaterThanOrEqualTo(4), reason: 'title floor');
        }
        expect(title.left - pill.left, moreOrLessEquals(16, epsilon: 0.5));

        final clock = find.byKey(const ValueKey('chat-schedule'));
        final readOut = find.bySemanticsLabel(RegExp('^自动化任务'));
        if (_clockGoes.contains((width, scale))) {
          // Not enough room: the clock gives way, the pill ends in its 16,
          // nothing to tap or read out there.
          expect(clock.hitTestable(), findsNothing);
          expect(readOut, findsNothing);
          expect(
            tester.getRect(find.byType(ModelChip)).width,
            moreOrLessEquals(ModelChip.compactWidth, epsilon: 0.5),
            reason: 'the chip gave all it had first',
          );
          final text = title.right > status.right ? title.right : status.right;
          expect(pill.right - text, moreOrLessEquals(16, epsilon: 0.5));
          // Exactly the bar of a conversation without tasks.
          final scheduledPill = pill;
          final scheduledChip = tester.getRect(find.byType(ModelChip));
          await _pump(tester, width: width, scale: scale, scheduled: _Scheduled(false));
          expect(_rect(tester, 'chat-title-pill'), scheduledPill);
          expect(tester.getRect(find.byType(ModelChip)), scheduledChip);
          expect(_titleChars(tester, '修复登录重复提交'), chars);
          semantics.dispose();
          return;
        }

        expect(clock.hitTestable(), findsOneWidget);
        expect(readOut, findsOneWidget);
        final key = _rect(tester, 'chat-schedule-key');
        final hit = _rect(tester, 'chat-schedule');
        // An end cap: equal gaps above, below and to the right.
        expect(key.size, const Size.square(HeaderScheduleCap.size));
        final inset = pill.right - key.right;
        expect(key.top - pill.top, moreOrLessEquals(inset, epsilon: 0.5));
        expect(pill.bottom - key.bottom, moreOrLessEquals(inset, epsilon: 0.5));
        expect(inset, moreOrLessEquals(HeaderScheduleCap.insetFor(pill.height), epsilon: 0.5));
        // Touch area: from the gap to the pill's end, its whole height.
        expect(hit.top, moreOrLessEquals(pill.top, epsilon: 0.5));
        expect(hit.bottom, moreOrLessEquals(pill.bottom, epsilon: 0.5));
        expect(hit.right, moreOrLessEquals(pill.right, epsilon: 0.5));
        expect(key.left - hit.left, moreOrLessEquals(HeaderScheduleCap.gap, epsilon: 0.5));
        // The text stops at the gap.
        expect(title.right, lessThanOrEqualTo(hit.left + 0.5));
        expect(status.right, lessThanOrEqualTo(hit.left + 0.5));
        semantics.dispose();
      });
    }
  }

  testWidgets('the model chip makes the room for the clock', (tester) async {
    final scheduled = _Scheduled(false);
    // The narrowest phone: with real glyphs a 390 bar has room to spare.
    await _pump(tester, width: 320, scale: 1, scheduled: scheduled);
    final plainChip = tester.getRect(find.byType(ModelChip));
    final plainPill = _rect(tester, 'chat-title-pill');
    final menu = _rect(tester, 'chat-menu');
    final fresh = _rect(tester, 'chat-new-chat');
    expect(find.byKey(const ValueKey('chat-schedule')), findsNothing);

    scheduled.on = true;
    ProviderScope.containerOf(tester.element(find.byType(ChatHeader))).invalidate(sessionSchedulesProvider('s1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-schedule')), findsOneWidget);
    expect(tester.getRect(find.byType(ModelChip)).width, lessThan(plainChip.width));
    final pill = _rect(tester, 'chat-title-pill');
    expect(pill.width, greaterThan(plainPill.width));
    // The clock comes without moving the mirror or the pill's line.
    expect(_rect(tester, 'chat-menu'), menu);
    expect(_rect(tester, 'chat-new-chat'), fresh);
    expect(pill.left, plainPill.left);
    expect(pill.top, plainPill.top);
    expect(pill.height, plainPill.height);

    // And goes back to the plain pill.
    scheduled.on = false;
    ProviderScope.containerOf(tester.element(find.byType(ChatHeader))).invalidate(sessionSchedulesProvider('s1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('chat-schedule')), findsNothing);
    expect(_rect(tester, 'chat-title-pill'), plainPill);
    expect(tester.getRect(find.byType(ModelChip)), plainChip);
  });
}
