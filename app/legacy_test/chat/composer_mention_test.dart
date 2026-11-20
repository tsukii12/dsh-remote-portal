// `@` references in the composer: the grammar, chips that edit as one unit,
// and the bubble that shows them after sending.

import 'package:dsh_app/ui/chat/composer.dart';
import 'package:dsh_app/ui/chat/mention/mention_chip.dart';
import 'package:dsh_app/ui/chat/mention/mention_syntax.dart';
import 'package:dsh_app/ui/chat/mention/mention_text_controller.dart';
import 'package:dsh_app/ui/chat/secret_mask.dart';
import 'package:dsh_app/ui/chat/widgets/attachments.dart';
import 'package:dsh_app/ui/chat/widgets/user_bubble.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';

final _login = formatSessionMention('login', '修复 登录] 问题');

void main() {
  setUpAll(loadTestFonts);

  group('grammar', () {
    test('tokens from raw text', () {
      final file = MentionToken.fromRaw('@lib/main.dart', 3)!;
      expect((file.kind, file.label, file.start, file.end), (MentionKind.file, 'main.dart', 3, 17));
      final folder = MentionToken.fromRaw('@lib/ui/', 0)!;
      expect((folder.kind, folder.label), (MentionKind.folder, 'ui/'));
      final quoted = MentionToken.fromRaw('@"lib/ui/login page.dart"', 0)!;
      expect(quoted.label, 'login page.dart');
      final openFolder = MentionToken.fromRaw('@"my dir/', 0)!;
      expect((openFolder.kind, openFolder.label), (MentionKind.folder, 'my dir/'));
      final session = MentionToken.fromRaw(_login, 0)!;
      expect((session.kind, session.label), (MentionKind.session, '修复 登录] 问题'));
      expect(MentionToken.fromRaw('@', 0), isNull);
    });

    test('a sent message: wire, echoed labels, paths, not emails or words', () {
      final text =
          '看 @lib/main.dart, $_login 和 @修复 登录] 问题 还有 @"my dir/ '
          '发给 a@b.com @大家 @README.md。';
      final tokens = parseMessageMentions(text, labels: ['修复 登录] 问题']);
      expect(
        [for (final t in tokens) (t.kind, t.label)],
        [
          (MentionKind.file, 'main.dart'),
          (MentionKind.session, '修复 登录] 问题'),
          (MentionKind.session, '修复 登录] 问题'),
          (MentionKind.folder, 'my dir/'),
          (MentionKind.file, 'README.md'),
        ],
      );
      // Trailing punctuation stays text.
      expect(text.substring(tokens.first.start, tokens.first.end), '@lib/main.dart');
      expect(text.substring(tokens.last.start, tokens.last.end), '@README.md');
    });

    test('the @ word at the caret', () {
      expect(activeMentionQuery('看看 @ma', 6)?.query, 'ma');
      expect(activeMentionQuery('看看 @ma', 6)?.start, 3);
      expect(activeMentionQuery('@', 1)?.query, '');
      expect(activeMentionQuery('@"my fi', 7)?.quoted, isTrue);
      expect(activeMentionQuery('@lib/', 5)?.pathOnly, isTrue);
      expect(activeMentionQuery('a@b', 3), isNull);
      expect(activeMentionQuery('@ma x', 5), isNull);
      expect(activeMentionQuery('第一行 @a\n第二行', 9), isNull);
      // Right after a chip: not a new query.
      const text = '@lib/main.dart';
      expect(activeMentionQuery(text, text.length, tokens: [MentionToken.fromRaw(text, 0)!]), isNull);
    });

    test('fuzzy: prefix, word start, substring, in order', () {
      final prefix = fuzzyScore('main.dart', 'ma')!;
      final word = fuzzyScore('login_main.dart', 'ma')!;
      final inside = fuzzyScore('format.dart', 'ma')!;
      final spread = fuzzyScore('my_app.dart', 'ma')!;
      expect(prefix, greaterThan(word));
      expect(word, greaterThan(inside));
      expect(inside, greaterThan(spread));
      expect(fuzzyScore('readme', 'xyz'), isNull);
      expect(fuzzyScore('修复登录', '登录'), isNotNull);
    });

    test('ages read like the official menu', () {
      final now = DateTime(2026, 10, 24, 12);
      expect(mentionAge(now.subtract(const Duration(seconds: 20)), now), '刚刚');
      expect(mentionAge(now.subtract(const Duration(minutes: 5)), now), '5分钟');
      expect(mentionAge(now.subtract(const Duration(hours: 3)), now), '3小时');
      expect(mentionAge(now.subtract(const Duration(days: 2)), now), '2天');
      expect(mentionAge(now.subtract(const Duration(days: 70)), now), '2个月');
      expect(mentionAge(now.subtract(const Duration(days: 800)), now), '2年');
    });
  });

  group('chips edit as one unit', () {
    late MentionTextController c;

    setUp(() {
      c = MentionTextController();
      c.value = const TextEditingValue(text: '看看 @ma', selection: TextSelection.collapsed(offset: 6));
      c.insertMention('@lib/main.dart', start: 3, end: 6);
    });

    test('picking replaces the @ word with the wire text and a space', () {
      expect(c.text, '看看 @lib/main.dart ');
      expect(c.selection, const TextSelection.collapsed(offset: 18));
      expect(c.tokens.single.label, 'main.dart');
      expect((c.tokens.single.start, c.tokens.single.end), (3, 17));
    });

    test('backspace at the chip deletes all of it', () {
      // The space first, then the chip in one go.
      c.value = const TextEditingValue(text: '看看 @lib/main.dart', selection: TextSelection.collapsed(offset: 17));
      expect(c.tokens, hasLength(1));
      c.value = const TextEditingValue(text: '看看 @lib/main.dar', selection: TextSelection.collapsed(offset: 16));
      expect(c.text, '看看 ');
      expect(c.selection, const TextSelection.collapsed(offset: 3));
      expect(c.tokens, isEmpty);
    });

    test('the caret never rests inside a chip', () {
      c.selection = const TextSelection.collapsed(offset: 9);
      expect(c.selection.baseOffset, 17);
      // One step left from the end jumps to the start.
      c.selection = const TextSelection.collapsed(offset: 16);
      expect(c.selection.baseOffset, 3);
      // A range grows to whole chips.
      c.selection = const TextSelection(baseOffset: 1, extentOffset: 8);
      expect((c.selection.start, c.selection.end), (1, 17));
    });

    test('typing inside a chip lands after it; text around it shifts it', () {
      c.value = const TextEditingValue(text: '看看 @lib/mXain.dart ', selection: TextSelection.collapsed(offset: 10));
      expect(c.text, '看看 @lib/main.dartX ');
      c.value = const TextEditingValue(text: '请看看 @lib/main.dartX ', selection: TextSelection.collapsed(offset: 1));
      expect((c.tokens.single.start, c.tokens.single.end), (4, 18));
    });

    test('a pasted or restored prompt gets its chips', () {
      final restored = MentionTextController();
      restored.text = '对比 $_login 和 @"lib/ui/login page.dart" 吧';
      expect([for (final t in restored.tokens) t.label], ['修复 登录] 问题', 'login page.dart']);
      restored.clear();
      expect(restored.tokens, isEmpty);
    });

    test('typed letters after @ stay text until picked', () {
      final typed = MentionTextController();
      for (final step in ['@', '@l', '@li', '@lib/', '@lib/main.dart']) {
        typed.value = TextEditingValue(
          text: step,
          selection: TextSelection.collapsed(offset: step.length),
        );
      }
      expect(typed.tokens, isEmpty);
    });
  });

  group('in the composer', () {
    Future<MentionTextController> pump(WidgetTester tester) async {
      usePhoneView(tester);
      final controller = MentionTextController();
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Composer(
                    controller: controller,
                    connected: true,
                    running: false,
                    onSend: () {},
                    onStop: () {},
                    leading: AttachButton(onPressed: () {}),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('a chip draws inline and keeps the one-line height', (tester) async {
      final c = await pump(tester);
      final empty = tester.getRect(find.byType(Composer));
      c.value = const TextEditingValue(text: '@', selection: TextSelection.collapsed(offset: 1));
      c.insertMention(_login, start: 0, end: 1);
      await tester.pump();
      expect(find.byType(MentionChip), findsOneWidget);
      expect(find.text('修复 登录] 问题'), findsOneWidget);
      // The hidden wire text takes no room: one line, same capsule.
      expect(tester.getRect(find.byType(Composer)).height, empty.height);
      final chip = tester.getRect(find.byType(MentionChip));
      final field = tester.getRect(find.byType(TextField));
      expect(chip.height, lessThan(field.height));
      expect(chip.center.dy, moreOrLessEquals(field.center.dy, epsilon: 1.5));
    });

    testWidgets('hardware backspace removes the whole chip', (tester) async {
      final c = await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      c.value = const TextEditingValue(text: '看 @', selection: TextSelection.collapsed(offset: 3));
      c.insertMention('@lib/main.dart', start: 2, end: 3);
      await tester.pump();
      // Delete the trailing space, then the chip.
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(c.text, '看 @lib/main.dart');
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(c.text, '看 ');
      expect(find.byType(MentionChip), findsNothing);
    });
  });

  group('sent bubble', () {
    testWidgets('references draw as chips; credentials keep the mask', (tester) async {
      MentionLabels.add('修复 登录] 问题');
      await tester.pumpWidget(
        testApp(
          const Scaffold(
            body: Align(
              alignment: Alignment.topRight,
              child: UserBubble(text: '看看 @lib/main.dart 和 @修复 登录] 问题 有什么关系'),
            ),
          ),
        ),
      );
      expect(find.byType(MentionChip), findsNWidgets(2));
      expect(find.text('main.dart'), findsOneWidget);
      expect(find.byType(SecretText), findsNothing);

      await tester.pumpWidget(
        testApp(const Scaffold(body: UserBubble(text: '@lib/main.dart 用这个 sk-0123456789abcdef0123456789abcdef'))),
      );
      expect(find.byType(SecretText), findsOneWidget);
      expect(find.byType(MentionChip), findsNothing);
    });
  });

  for (final brightness in Brightness.values) {
    testWidgets('golden: sent and sending bubbles (${brightness.name})', (tester) async {
      usePhoneView(tester);
      MentionLabels.add('修复 登录] 问题');
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: Padding(
              padding: const EdgeInsets.fromLTRB(16, 80, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const UserBubble(text: '看看 @lib/main.dart 和 @修复 登录] 问题 有什么关系'),
                  const SizedBox(height: 16),
                  UserBubble(text: '把 @lib/ui/ 下的页面对照 $_login 再改一遍', pendingLabel: '发送中'),
                ],
              ),
            ),
          ),
          brightness: brightness,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await expectLater(
        find.byType(Scaffold),
        matchesGoldenFile('goldens/composer_mention_bubble_${brightness.name}.png'),
      );
    });
  }
}
