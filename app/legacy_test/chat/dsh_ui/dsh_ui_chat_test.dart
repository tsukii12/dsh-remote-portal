// dsh-ui inside the real chat: a reply's ```dsh-ui block draws as a card, a
// tap sends the visible answer, and once the answer is in the transcript the
// user's side shows a tag and the card turns read-only. Copying a reply never
// copies the JSON.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/chat_screen.dart';
import 'package:dsh_app/ui/chat/dsh_ui/dsh_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';
import '../support/sample_chat.dart';

const _reply = '''两个方案的月供差不多，主要差在总利息。

```dsh-ui
{"type":"stack","title":"选一个方案","children":[
 {"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}]}
```''';

ChatState _state({bool answered = false}) => ChatState(
  loading: false,
  items: [user(1, '帮我比较一下两个贷款方案'), assistant(2, _reply), if (answered) user(3, '[dsh-ui reply] 选一个方案\n选择：方案 B')],
);

Future<ChatHarness> _pump(WidgetTester tester, ChatState state) async {
  usePhoneView(tester);
  mockClipboard(tester);
  final harness = ChatHarness(session: 's1', states: {'s1': state});
  await tester.pumpWidget(testApp(const ChatScreen(), overrides: harness.overrides));
  await pumpFrames(tester, 10);
  return harness;
}

void main() {
  testWidgets('a reply block draws as a card; a tap sends the answer', (tester) async {
    final harness = await _pump(tester, _state());
    expect(find.byType(DshUiBlock), findsOneWidget);
    expect(find.textContaining('"type"'), findsNothing);
    await tester.tap(find.text('方案 B'));
    await pumpFrames(tester);
    final sent = harness.controllers['s1']!.sent.single;
    expect(parseDshUiReply(sent)?.chipLabel, contains('方案 B'));
  });

  testWidgets('answered: the user side is a tag and the card is read-only', (tester) async {
    final harness = await _pump(tester, _state(answered: true));
    expect(find.byType(DshUiReplyChip), findsOneWidget);
    expect(find.textContaining('[dsh-ui reply]'), findsNothing);
    await tester.tap(find.text('方案 A').first);
    await pumpFrames(tester);
    expect(harness.controllers['s1']!.sent, isEmpty);
  });

  testWidgets('copying a reply copies the summary, not the JSON', (tester) async {
    final copied = <String>[];
    await _pump(tester, _state());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    await tester.tap(find.byTooltip('复制'));
    await pumpFrames(tester);
    expect(copied.single, contains('两个方案的月供差不多'));
    expect(copied.single, isNot(contains('"type"')));
    // Let the "已复制" feedback run out.
    await tester.pump(const Duration(seconds: 4));
  });

  // The model sometimes copies the AGENTS.md example's old shape: the JSON
  // without a fence. The reply must still draw as a card, not a wall of JSON.
  testWidgets('a bare view JSON draws as a card', (tester) async {
    const bare = '''两个方案的月供差不多，主要差在总利息。

{"type":"stack","title":"选一个方案","children":[
 {"type":"options","id":"plan","options":[{"label":"方案 A"},{"label":"方案 B"}]}]}''';
    await _pump(
      tester,
      ChatState(loading: false, items: [user(1, '帮我比较一下两个贷款方案'), assistant(2, bare)]),
    );
    expect(find.byType(DshUiBlock), findsOneWidget);
    expect(find.textContaining('"type"'), findsNothing);
    expect(find.text('方案 B'), findsOneWidget);
  });

  // An options card may allow an answer beyond its presets: the input sits
  // under the rows and what the person types comes back on its own line.
  testWidgets('options freetext sends the typed answer with the choice', (tester) async {
    const reply = '''两个方案的月供差不多，主要差在总利息。

```dsh-ui
{"type":"stack","title":"选一个方案","children":[
 {"type":"options","id":"plan","freetext":true,"options":[{"label":"方案 A"},{"label":"方案 B"}]}]}
```''';
    final harness = await _pump(
      tester,
      ChatState(loading: false, items: [user(1, '帮我比较一下两个贷款方案'), assistant(2, reply)]),
    );
    final field = find.descendant(of: find.byType(DshUiCard), matching: find.byType(TextField));
    expect(field, findsOneWidget);
    // 只填字、不选预设也能发。
    await tester.enterText(field, '先算一次总利息');
    await pumpFrames(tester, 2);
    await tester.tap(find.descendant(of: find.byType(DshUiCard), matching: find.text('发送')));
    await pumpFrames(tester, 4);
    final sent = harness.controllers['s1']!.sent.single;
    expect(sent, contains('[dsh-ui reply] 选一个方案'));
    expect(sent, contains('其他：先算一次总利息'));
  });
}
