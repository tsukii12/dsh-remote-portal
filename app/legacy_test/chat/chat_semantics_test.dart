import 'dart:typed_data';

import 'package:dsh_app/l10n/l10n.dart';
import 'package:dsh_app/state/attachments.dart';
import 'package:dsh_app/ui/chat/chat_rows.dart';
import 'package:dsh_app/ui/chat/diff_page.dart';
import 'package:dsh_app/ui/chat/render/code_block.dart';
import 'package:dsh_app/ui/chat/secret_mask.dart';
import 'package:dsh_app/ui/chat/trajectory_sheet.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/usage_sheet.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/change_card.dart';
import 'package:dsh_app/ui/chat/widgets/chat_card.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/chat/widgets/turn_footnote.dart';
import 'package:dsh_app/ui/chat/widgets/turn_process.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

final _time = DateTime(2026);
final _spans = [
  for (var i = 0; i < 3; i++)
    TraceSpan(
      kind: TraceKind.tool,
      step: 1,
      seq: i + 1,
      start: _time,
      end: _time.add(const Duration(seconds: 1)),
      callId: 'c$i',
      toolName: 'bash',
    ),
];
final _trace = TurnTrace(
  turn: 1,
  startSeq: 1,
  start: _time,
  spans: _spans,
  endSeq: 10,
  end: _time.add(const Duration(seconds: 1)),
  endReason: const TurnEndReason('completed'),
);
const _file = FileChange(path: 'a.dart', created: false, added: 1, removed: 1, lines: [], edits: 1);
const _other = FileChange(path: 'b.dart', created: false, added: 2, removed: 0, lines: [], edits: 1);

void main() {
  setUpAll(loadTestFonts);
  tearDown(() => AppLocale.use(AppLocale.zhCN));

  for (final (locale, text) in [
    (AppLocale.zhCN, '早上好\n请帮我看看'),
    (AppLocale.en, 'Good morning\nPlease help me'),
  ]) {
    testWidgets('$locale: user message semantics have no speaker prefix', (tester) async {
      AppLocale.use(locale);
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(testApp(Scaffold(body: UserBubble(text: text))));

        final message = find.bySemanticsLabel(text);
        expect(message, findsOneWidget);
        final data = tester.getSemantics(message).getSemanticsData();
        expect(data.label, text);
        expect(data.flagsCollection.isHeader, isTrue);
        expect(data.hasAction(SemanticsAction.longPress), isTrue);
      } finally {
        handle.dispose();
      }
    });
  }

  testWidgets('user message text stays separate from its image and file semantics', (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: UserBubble(
              text: '早上好',
              attachments: SentAttachments.pending([
                DraftAttachment.sniff('photo.png', tinyPng),
                DraftAttachment(name: 'notes.txt', bytes: Uint8List.fromList([65])),
              ]),
            ),
          ),
        ),
      );
      await pumpFrames(tester);

      final message = tester.getSemantics(find.bySemanticsLabel('早上好'));
      expect(message.getSemanticsData().label, '早上好');
      expect(message.getSemanticsData().hasAction(SemanticsAction.longPress), isTrue);
      final image = tester.getSemantics(find.bySemanticsLabel('图片'));
      expect(image.id, isNot(message.id));
      expect(image.flagsCollection.isImage, isTrue);
      expect(image.flagsCollection.isButton, isTrue);
      expect(image.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      final file = tester.getSemantics(find.text('notes.txt'));
      expect(file.id, isNot(message.id));
      expect(file.getSemanticsData().label, contains('notes.txt'));
    } finally {
      handle.dispose();
    }
  });

  testWidgets('excluded child semantics retain the matching tap actions', (tester) async {
    final handle = tester.ensureSemantics();
    final tools = [
      for (var i = 0; i < 3; i++) tool('c$i', 'bash', {'command': 'echo $i'}),
    ];
    final widgets = <Widget>[
      TurnProcess(
        row: TurnProcessRow(_trace, const [], toolCalls: 3, messages: 0),
        buildRow: (_) => const SizedBox(),
        gapBefore: (_, _) => 0,
      ),
      ToolGroup(tools: tools, onRespond: (_, _) async {}),
      const ChangeCard(files: [_file]),
      const CodeBlock(code: 'answer', replyActions: true),
      const SecretText('sk-0123456789abcdef0123456789abcdef', style: TextStyle(fontSize: 14), interactive: true),
      ContextRing(fraction: 0.4, onTap: () {}),
      ChatCardFooter(label: '展开卡片', onTap: () {}),
      TurnFootnote(trace: _trace, onTap: () {}),
      SpanTile(span: _spans.first, trace: _trace, total: const Duration(seconds: 1), now: _time, onTap: () {}),
      TrajectoryList(
        trace: _trace,
        total: const Duration(seconds: 1),
        tools: {for (final tool in tools) tool.callId: tool},
        onOpen: (_) {},
      ),
      // The file chips only show with more than one file.
      const ChangeDiffPage(files: [_file, _other]),
    ];
    for (final widget in widgets) {
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: KeyedSubtree(key: const ValueKey('subject'), child: widget),
          ),
        ),
      );
      await tester.pump();
      final buttons = find.descendant(
        of: find.byKey(const ValueKey('subject')),
        matching: find.byWidgetPredicate((w) => w is Semantics && w.excludeSemantics && w.properties.button == true),
      );
      expect(buttons, findsWidgets, reason: '${widget.runtimeType}');
      for (final element in buttons.evaluate()) {
        final semantics = element.widget as Semantics;
        expect(semantics.properties.onTap, isNotNull, reason: '${widget.runtimeType}: ${semantics.properties.label}');
        final node = tester.getSemantics(find.byWidget(semantics));
        expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      }
    }
    handle.dispose();
  });
  testWidgets('user messages and Markdown headings are navigable, reply root is not a heading', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: Column(
            children: [
              const UserBubble(text: '我的问题'),
              AssistantMessage(item: assistant(2, '## 步骤\n\n回答')),
            ],
          ),
        ),
      ),
    );
    final user = tester.getSemantics(find.bySemanticsLabel('我的问题'));
    expect(user.getSemanticsData().label, '我的问题');
    expect(user.flagsCollection.isHeader, isTrue);
    final heading = tester.getSemantics(find.bySemanticsLabel('步骤'));
    expect(heading.flagsCollection.isHeader, isTrue);
    final root = find.descendant(
      of: find.byType(AssistantMessage),
      matching: find.byWidgetPredicate((w) => w is Semantics && w.container && w.explicitChildNodes),
    );
    expect(tester.getSemantics(root).flagsCollection.isHeader, isFalse);
    handle.dispose();
  });
}
