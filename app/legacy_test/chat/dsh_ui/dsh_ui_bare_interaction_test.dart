import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui_dialect_card.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/sample_chat.dart';

const _options = '{"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}';
const _confirm = '{"type":"confirm","id":"go","confirmLabel":"开始","cancelLabel":"再想想"}';

String _message(String source, bool fenced) => fenced ? '```dsh-ui\n$source\n```' : source;

Future<ChatHarness> _mount(WidgetTester tester, String message, {bool expired = false}) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(
    session: 's1',
    states: {
      's1': ChatState(loading: false, items: [user(1, '请选择'), assistant(2, message), if (expired) user(3, '不用这个方案了')]),
    },
  );
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 10);
  return harness;
}

void main() {
  for (final fenced in [false, true]) {
    final format = fenced ? 'fenced' : 'bare';
    for (final view in [
      (name: 'options', source: _options, label: '方案 B', reply: '选择：方案 B'),
      (name: 'confirm', source: _confirm, label: '开始', reply: '确认：开始'),
    ]) {
      testWidgets('$format ${view.name}: the visible native answer can be sent', (tester) async {
        try {
          final message = _message(view.source, fenced);
          if (!fenced) expect(message, isNot(contains('dsh-ui')));
          final harness = await _mount(tester, message);
          expect(find.byType(DshUiCard), findsOneWidget);
          expect(find.textContaining('"type"'), findsNothing);
          final answer = find.descendant(of: find.byType(DshUiCard), matching: find.text(view.label));
          expect(answer, findsOneWidget);
          await tester.tap(answer);
          await pumpFrames(tester);
          expect(harness.controllers['s1']!.sent, hasLength(1));
          final sent = harness.controllers['s1']!.sent.single;
          expect(parseDshUiReply(sent), isNotNull);
          expect(sent, contains(view.reply));
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      });

      testWidgets('$format ${view.name}: a later user message keeps the old card expired', (tester) async {
        try {
          final harness = await _mount(tester, _message(view.source, fenced), expired: true);
          expect(find.byType(DshUiCard), findsOneWidget);
          final answer = find.descendant(of: find.byType(DshUiCard), matching: find.text(view.label));
          expect(answer, findsOneWidget);
          await tester.tap(answer);
          await pumpFrames(tester);
          expect(harness.controllers['s1']!.sent, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        }
      });
    }
  }

  testWidgets('genuine genui under a dsh-ui fence remains read-only in ChatScreen', (tester) async {
    const source = '{"title":"构建报告","items":[{"type":"button","label":"重跑","action":"rerun"}]}';
    try {
      final harness = await _mount(tester, _message(source, true));
      expect(find.byType(DshUiDialectCard), findsOneWidget);
      expect(find.byType(DshUiCard), findsNothing);
      final fallback = find.descendant(of: find.byType(DshUiDialectCard), matching: find.textContaining('在网页版查看'));
      expect(fallback, findsOneWidget);
      await tester.tap(fallback);
      await pumpFrames(tester);
      expect(harness.controllers['s1']!.sent, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  });
}
