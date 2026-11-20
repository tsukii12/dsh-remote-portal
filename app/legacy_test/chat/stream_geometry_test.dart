// The message stream lines up on two edges: every process row (thinking,
// tool, group, notice, command) puts its 24dp glyph on the answer text's left
// edge and its trailing status on the right edge, while the tap highlight
// bleeds 8dp past both; expanded content starts at the text column (32). The
// cards share one anatomy (16 all round, title icon 20 + 8), the approval
// card's two buttons are equal and mirrored, and the reply actions' first
// icon sits on the text edge with the footnote's chevron on the right one.

import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/ui/chat/turn_summary.dart';
import 'package:dsh_app/ui/chat/widgets/approval_card.dart';
import 'package:dsh_app/ui/chat/widgets/assistant_message.dart';
import 'package:dsh_app/ui/chat/widgets/change_card.dart';
import 'package:dsh_app/ui/chat/widgets/chat_card.dart';
import 'package:dsh_app/ui/chat/widgets/command_row.dart';
import 'package:dsh_app/ui/chat/widgets/notice_row.dart';
import 'package:dsh_app/ui/chat/widgets/question_card.dart';
import 'package:dsh_app/ui/chat/widgets/thinking_pill.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:dsh_app/ui/common/think_glyph.dart';
import 'package:dsh_app/ui/common/tool_glyph.dart';
import 'package:dsh_app/ui/theme/app_icons.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

Future<void> _noRespond(ApprovalRequest r, ApprovalDecision d) async {}
Future<void> _noAllowAll(ApprovalRequest r) async {}
Future<void> _noAnswer(UserQuestionRequest r, List<QuestionAnswer> a) async {}

/// The column every row is laid into (as in the chat list: 16 gutter).
const _column = Key('column');

Future<void> _pump(WidgetTester tester, List<Widget> children) async {
  usePhoneView(tester);
  tester.view.physicalSize = const Size(780, 3000);
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 40, 16, 40),
          child: Column(key: _column, crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
        ),
      ),
    ),
  );
  await pumpFrames(tester, 2);
}

Rect _rect(WidgetTester tester, Finder finder) => tester.getRect(finder);

void _near(double actual, double expected, String what) =>
    expect(actual, moreOrLessEquals(expected, epsilon: 0.01), reason: what);

void main() {
  setUpAll(loadTestFonts);

  testWidgets('process rows: glyphs on the text edge, trail on the right', (tester) async {
    final running = tool('r', 'bash', {'command': 'npm install'}, status: ToolStatus.running);
    final edit = tool('e', 'edit', {'file_path': '/root/workspace/lib/a.dart', 'old_string': 'a', 'new_string': 'b'});
    final group = [
      tool('g1', 'read', {'file_path': '/root/workspace/lib/a.dart'}),
      tool('g2', 'grep', {'pattern': 'submit'}),
      tool('g3', 'bash', {'command': 'ls'}),
    ];
    await _pump(tester, [
      AssistantMessage(item: assistant(1, '正文从这里开始。')),
      const ThinkingPill(key: ValueKey('think'), reasoning: '先看一下\n再说'),
      ToolRow(key: const ValueKey('run'), item: running, onRespond: _noRespond),
      ToolRow(key: const ValueKey('edit'), item: edit, onRespond: _noRespond),
      ToolGroup(key: const ValueKey('group'), tools: group, onRespond: _noRespond),
      const NoticeRow(
        key: ValueKey('notice'),
        item: NoticeChatItem(seq: 2, kind: 'retry', text: 'Retrying (2/5)'),
      ),
      const CommandRow(
        key: ValueKey('command'),
        notice: CommandNotice(id: 'c', name: 'compact'),
      ),
    ]);

    final column = _rect(tester, find.byKey(_column));
    final text = _rect(tester, find.text('正文从这里开始。'));
    _near(text.left, column.left, 'answer text starts at the column');

    Rect glyphIn(String key, Finder glyph) =>
        _rect(tester, find.descendant(of: find.byKey(ValueKey(key)), matching: glyph).first);

    // Every lead glyph is 24 square, on the column's left edge.
    final leads = {
      'think': glyphIn('think', find.ancestor(of: find.byType(ThinkGlyph), matching: find.byType(SizedBox))),
      'run': glyphIn('run', find.byType(ToolGlyph)),
      'edit': glyphIn('edit', find.byType(ToolGlyph)),
      'group': glyphIn('group', find.byType(ToolGlyph)),
      'notice': glyphIn('notice', find.ancestor(of: find.byIcon(AppIcons.retry), matching: find.byType(SizedBox))),
      'command': glyphIn('command', find.ancestor(of: find.byType(Icon), matching: find.byType(SizedBox))),
    };
    for (final MapEntry(:key, :value) in leads.entries) {
      _near(value.left, column.left, '$key glyph on the text edge');
      _near(value.width, 24, '$key glyph is 24 wide');
      _near(value.height, 24, '$key glyph is 24 high');
    }

    // Labels start at the text column (24 + 8).
    final label = _rect(tester, find.text('运行'));
    _near(label.left, column.left + 32, 'verb at the text column');

    // Trailing status: the spinner, the diff count and the chevrons end on
    // the column's right edge.
    final spinner = _rect(
      tester,
      find.descendant(of: find.byKey(const ValueKey('run')), matching: find.byType(CircularProgressIndicator)).first,
    );
    _near(spinner.right, column.right, 'spinner on the right edge');
    final counts = _rect(
      tester,
      find.descendant(of: find.byKey(const ValueKey('edit')), matching: find.byType(DiffCounts)),
    );
    _near(counts.right, column.right, 'diff count on the right edge');
    for (final key in ['think', 'group']) {
      final chevron = glyphIn(key, find.byIcon(AppIcons.expand));
      _near(chevron.right, column.right, '$key chevron on the right edge');
    }

    // The ink bleeds 8 past both edges.
    final ink = _rect(
      tester,
      find.descendant(of: find.byKey(const ValueKey('run')), matching: find.byType(InkWell)).first,
    );
    _near(ink.left, column.left - 8, 'highlight bleeds left');
    _near(ink.right, column.right + 8, 'highlight bleeds right');
  });

  testWidgets('expanded thinking and groups start at the text column', (tester) async {
    final group = [
      tool('g1', 'read', {'file_path': '/root/workspace/lib/a.dart'}),
      tool('g2', 'grep', {'pattern': 'submit'}),
      tool('g3', 'bash', {'command': 'ls'}),
    ];
    await _pump(tester, [const ThinkingPill(reasoning: '展开后的思考全文'), ToolGroup(tools: group, onRespond: _noRespond)]);
    final column = _rect(tester, find.byKey(_column));
    await tester.tap(find.text('思考'));
    await tester.tap(find.text(summarizeTools(group).label));
    await pumpFrames(tester, 4);

    final thought = _rect(tester, find.textContaining('展开后的思考全文'));
    _near(thought.left, column.left + 32, 'thinking text at the text column');
    final inner = _rect(tester, find.byType(ToolGlyph).at(1));
    _near(inner.left, column.left + 32, 'grouped rows at the text column');
  });

  testWidgets('approval card: equal, mirrored buttons; centred allow-all', (tester) async {
    await _pump(tester, [ApprovalCard(request: approval, onRespond: _noRespond, onAllowAll: _noAllowAll)]);
    final card = _rect(tester, find.byType(ApprovalCard));
    final reject = _rect(tester, find.byType(OutlinedButton));
    final allow = _rect(tester, find.byType(FilledButton));
    final allowAll = _rect(tester, find.byType(TextButton));
    final icon = _rect(tester, find.byIcon(AppIcons.approval));

    _near(reject.width, allow.width, 'buttons are the same width');
    _near(reject.height, 44, 'buttons are 44 high');
    _near(allow.height, reject.height, 'buttons are the same height');
    _near(reject.top, allow.top, 'buttons on one line');
    _near(reject.left - card.left, 16, 'left inset 16');
    _near(card.right - allow.right, 16, 'right inset mirrors the left');
    _near(allow.left - reject.right, 12, 'gap between the buttons');
    _near(allowAll.center.dx, card.center.dx, 'allow-all is centred');
    _near(icon.left - card.left, 16, 'title icon at the inset');
    _near(icon.top - card.top, 16, 'title row at the top inset');
  });

  testWidgets('cards share the title anatomy and the side insets', (tester) async {
    const question = UserQuestionRequest(
      eventId: 'q',
      sessionId: 's',
      questions: [
        UserQuestion(
          id: 'db',
          question: '数据库用哪一个?',
          options: [QuestionOption('SQLite', '单文件'), QuestionOption('PostgreSQL', '需要单独的服务')],
        ),
      ],
    );
    final files = [
      for (final name in ['a.dart', 'b.dart'])
        FileChange(path: '/root/workspace/lib/$name', created: false, added: 3, removed: 1, lines: const [], edits: 1),
    ];
    await _pump(tester, [
      const QuestionCard(request: question, onAnswer: _noAnswer),
      const SizedBox(height: 12),
      ChangeCard(files: files),
    ]);

    for (final card in [find.byType(QuestionCard), find.byType(ChangeCard)]) {
      final box = _rect(tester, card);
      final chat = find.descendant(of: card, matching: find.byType(ChatCard));
      final title = _rect(tester, find.descendant(of: chat, matching: find.byType(Icon)).first);
      _near(title.left - box.left, 16, 'title icon 16 from the left');
      _near(title.top - box.top, 16, 'title icon 16 from the top');
      _near(title.width, 20, 'title icon is 20');
    }

    // Question options and the submit button share the card's 16 insets.
    final card = _rect(tester, find.byType(QuestionCard));
    final submit = _rect(tester, find.byType(FilledButton));
    _near(submit.left - card.left, 16, 'submit left inset');
    _near(card.right - submit.right, 16, 'submit right inset');
    _near(submit.height, 44, 'submit is 44 high');
    final options = find.ancestor(of: find.byType(InkWell), matching: find.byType(AnimatedContainer));
    expect(options, findsNWidgets(2));
    for (var i = 0; i < 2; i++) {
      final option = _rect(tester, options.at(i));
      _near(option.left, submit.left, 'option $i left matches submit');
      _near(option.right, submit.right, 'option $i right matches submit');
    }

    // Change card: the title counts and every row's counts end 16 in.
    final change = _rect(tester, find.byType(ChangeCard));
    final counts = find.descendant(of: find.byType(ChangeCard), matching: find.byType(DiffCounts));
    for (var i = 0; i < counts.evaluate().length; i++) {
      _near(change.right - _rect(tester, counts.at(i)).right, 16, 'counts $i end 16 from the right');
    }
  });

  testWidgets('reply actions: first icon on the text edge, footnote opposite', (tester) async {
    await _pump(tester, [
      AssistantMessage(
        item: assistant(1, '回答'),
        showActions: true,
        footnote: const Text('4.3 秒', key: ValueKey('foot')),
      ),
    ]);
    final column = _rect(tester, find.byKey(_column));
    final copy = _rect(tester, find.byIcon(AppIcons.copy));
    _near(copy.left, column.left, 'copy icon on the text edge');
    _near(copy.width, 20, 'action icons are 20');
    final foot = _rect(tester, find.byKey(const ValueKey('foot')));
    _near(foot.right, column.right + 8, 'footnote padding lands on the bleed');
  });
}
