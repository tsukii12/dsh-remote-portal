// A long tool output is clipped in the chat row and whole on its own page.

import 'package:dsh_app/ui/chat/output_page.dart';
import 'package:dsh_app/ui/chat/render/ansi_text.dart';
import 'package:dsh_app/ui/chat/render/long_text.dart';
import 'package:dsh_app/ui/chat/tool_view.dart';
import 'package:dsh_app/ui/chat/widgets/tool_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/harness.dart';
import 'support/sample_chat.dart';

String _numbered(int lines) => [for (var i = 1; i <= lines; i++) 'line $i'].join('\n');

/// Everything on screen as text: plain and rich text, and selectable text.
String _shown(WidgetTester tester) => [
  ...tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()),
  ...tester.widgetList<SelectableText>(find.byType(SelectableText)).map((w) => w.data ?? w.textSpan!.toPlainText()),
].join('\n');

Widget _detail(String result, {String name = 'bash', Map<String, Object?> args = const {'command': 'make'}}) => testApp(
  Scaffold(
    body: SingleChildScrollView(
      child: ToolDetail(view: ToolView.of(tool('a', name, args, result: result))),
    ),
  ),
);

void main() {
  setUpAll(loadTestFonts);

  group('clipLongText', () {
    test('ordinary output is left whole', () {
      final text = _numbered(kClipHeadLines + kClipTailLines);
      final clip = clipLongText(text);
      expect(clip.clipped, isFalse);
      expect(clip.head, same(text));
      expect(clip.totalLines, kClipHeadLines + kClipTailLines);
    });

    test('many lines keep whole lines of the head and the tail', () {
      final clip = clipLongText(_numbered(5000));
      expect(clip.clipped, isTrue);
      expect(clip.totalLines, 5000);
      expect(clip.head.split('\n'), [for (var i = 1; i <= kClipHeadLines; i++) 'line $i']);
      expect(clip.tail!.split('\n'), [for (var i = 5000 - kClipTailLines + 1; i <= 5000; i++) 'line $i']);
      expect(clip.hiddenLines, 5000 - kClipHeadLines - kClipTailLines);
    });

    test('head, hidden part and tail add up to the text', () {
      for (final text in [_numbered(5000), 'x' * 100000, '${'y' * 9000}\n${_numbered(900)}\n${'z' * 30000}']) {
        final clip = clipLongText(text);
        expect(clip.clipped, isTrue);
        final head = text.startsWith('${clip.head}\n') ? clip.head.length + 1 : clip.head.length;
        expect(head + clip.hiddenChars + clip.tail!.length, text.length);
        expect(text.endsWith(clip.tail!), isTrue);
        expect(clip.head.length + clip.tail!.length, lessThanOrEqualTo(kClipMaxChars));
      }
    });

    test('one enormous line is cut by characters', () {
      final clip = clipLongText('x' * 2000000);
      expect(clip.totalLines, 1);
      expect(clip.hiddenLines, 0);
      expect(clip.hiddenChars, 2000000 - kClipMaxChars);
    });

    test('a cut never lands inside an escape sequence or a surrogate pair', () {
      // Every position in the long line is the start of an escape or an emoji half.
      final coloured = '\x1B[38;2;10;20;30mab' * 20000;
      final clip = clipLongText(coloured);
      expect(stripAnsi(clip.head), matches(RegExp(r'^(ab)*$')));
      expect(stripAnsi(clip.tail!), matches(RegExp(r'^(ab)*$')));

      final emoji = clipLongText('😀' * 60000);
      expect(emoji.head.runes.every((r) => r == 0x1F600), isTrue);
      expect(emoji.tail!.runes.every((r) => r == 0x1F600), isTrue);
    });

    test('a cut never lands inside a hyperlink (OSC) sequence', () {
      // The letters of the address are not the end of the sequence: BEL or ST is.
      for (final end in ['\x07', '\x1B\\']) {
        final link = '\x1B]8;;https://example.com/a/long/path/to/somewhere$end';
        final clip = clipLongText('${link}x' * 6000);
        expect(stripAnsi(clip.head), matches(RegExp(r'^x*$')));
        expect(stripAnsi(clip.tail!), matches(RegExp(r'^x*$')));
      }
    });

    test('the tail carries the colour that was on where it starts', () {
      final middle = _numbered(3000);
      // Set in the head and never reset; set in the hidden middle; reset before the tail.
      expect(clipLongText('\x1B[31m$middle', ansi: true).tailSgr, '\x1B[31m');
      expect(clipLongText('$middle\n\x1B[1;32mgreen\n$middle', ansi: true).tailSgr, '\x1B[1;32m');
      expect(clipLongText('\x1B[31mred\x1B[0m\n$middle', ansi: true).tailSgr, isEmpty);
      // Text that is not parsed as ANSI is left alone.
      expect(clipLongText('\x1B[31m$middle').tailSgr, isEmpty);
    });
  });

  group('SgrCarry', () {
    test('keeps what is still in effect and drops what a reset ended', () {
      const text = 'a\x1B[31mb\x1B[1mc\x1B[0md\x1B[0;34me\x1B[2Kf';
      final carry = SgrCarry(text);
      expect(carry.prefix, isEmpty);
      carry.advanceTo(text.indexOf('c'));
      expect(carry.prefix, '\x1B[1;31m');
      carry.advanceTo(text.indexOf('d'));
      expect(carry.prefix, isEmpty);
      carry.advanceTo(text.length);
      // A reset that also sets a colour leaves the colour; a non-colour sequence is not carried.
      expect(carry.prefix, '\x1B[34m');
      expect(carry.escapeChars, text.length - 'abcdef'.length);
    });

    test('replaying the prefix gives the colours of parsing in one go', () {
      const base = TextStyle(color: Color(0xFF000000));
      final palette = [for (var i = 0; i < 16; i++) Color(0xFF000000 + i * 16)];
      Map<String, Object?> styleOf(TextSpan span) {
        final s = (span.children!.last as TextSpan).style!;
        return {
          'fg': s.color,
          'bg': s.backgroundColor,
          'weight': s.fontWeight,
          'italic': s.fontStyle,
          'line': s.decoration,
        };
      }

      // Each of these leaves some state on; "X" is then rendered both ways.
      for (final before in [
        '\x1B[31m',
        '\x1B[1;3;4m\x1B[22m',
        '\x1B[38;5;208m\x1B[48;2;1;2;3m',
        '\x1B[31m\x1B[39m\x1B[44m',
        '\x1B[38;2;255;255;255;48;2;10;20;30m',
        '\x1B[38;5;999m\x1B[92m\x1B[38;5m',
        '\x1B[0;1;35m\x1B[m\x1B[4m',
      ]) {
        final carry = SgrCarry('${before}X')..advanceTo(before.length);
        expect(
          styleOf(parseAnsi('${carry.prefix}X', base, palette)),
          styleOf(parseAnsi('${before}X', base, palette)),
          reason: before.replaceAll('\x1B', 'ESC'),
        );
      }
    });

    test('a colour set once survives any number of later attribute changes', () {
      final text = '\x1B[31m${'\x1B[1mx\x1B[22my' * 500}';
      final carry = SgrCarry(text)..advanceTo(text.length);
      expect(carry.prefix, '\x1B[31m');
    });
  });

  test('a long colour sequence counts as one escape wherever the cut lands', () {
    const sequence = '\x1B[38;2;255;255;255;48;2;255;255;255m';
    const text = 'ab${sequence}cd';
    expect(sequence.length, greaterThan(24));
    for (var i = 3; i < 2 + sequence.length; i++) {
      expect(ansiEscapeAround(text, i), (2, 2 + sequence.length), reason: 'at $i');
    }
    expect(ansiEscapeAround(text, 2), isNull);
    expect(ansiEscapeAround(text, 2 + sequence.length), isNull);
  });

  testWidgets('ordinary output has no clip marker and no view-all bar', (tester) async {
    await tester.pumpWidget(_detail(_numbered(40)));
    expect(find.text('查看全部'), findsNothing);
    expect(_shown(tester), contains('line 40'));
    expect(_shown(tester), isNot(contains('省略')));
  });

  testWidgets('long output lays out only its head and tail, and opens whole', (tester) async {
    mockClipboard(tester);
    final output = _numbered(5000);
    await tester.pumpWidget(_detail(output));

    final shown = _shown(tester);
    expect(shown, contains('line 1\n'));
    expect(shown, contains('line 5000'));
    expect(shown, isNot(contains('line 2500')));
    expect(find.text('中间省略 4,800 行'), findsOneWidget);
    expect(
      find.text('共 5,000 行 · ${output.length ~/ 1000},${'${output.length % 1000}'.padLeft(3, '0')} 字'),
      findsOneWidget,
    );

    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.byType(OutputPage), findsOneWidget);
    expect(find.text('输出'), findsOneWidget);
    expect(find.text('line 1', findRichText: true), findsOneWidget);
    // Rows are built as they scroll into view, not all 5000 at once.
    expect(find.text('line 2500', findRichText: true), findsNothing);

    await tester.tap(find.byTooltip('跳到末尾'));
    await tester.pumpAndSettle();
    expect(find.text('line 5000', findRichText: true), findsOneWidget);
    expect(find.byTooltip('回到开头'), findsOneWidget);
    await tester.tap(find.byTooltip('回到开头'));
    await tester.pumpAndSettle();
    expect(find.text('line 1', findRichText: true), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();
    expect(copied, output);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the gap marker opens the full page too', (tester) async {
    await tester.pumpWidget(_detail(_numbered(3000)));
    await tester.ensureVisible(find.text('中间省略 2,800 行'));
    await tester.pump();
    await tester.tap(find.text('中间省略 2,800 行'));
    await tester.pumpAndSettle();
    expect(find.byType(OutputPage), findsOneWidget);
  });

  testWidgets('a long command is clipped but keeps its prompt', (tester) async {
    final command = _numbered(2000);
    await tester.pumpWidget(_detail('ok', args: {'command': command}));
    expect(_shown(tester), contains(r'$ line 1'));
    expect(find.text('中间省略 1,800 行'), findsOneWidget);
    await tester.tap(find.text('查看全部'));
    await tester.pumpAndSettle();
    expect(find.text('命令'), findsOneWidget);
    // The prompt is decoration: the full page (and its copy) is the command itself.
    expect(tester.widget<OutputPage>(find.byType(OutputPage)).text, command);
  });

  testWidgets('the full page splits one enormous line into rows', (tester) async {
    final text = 'x' * 50000;
    await tester.pumpWidget(testApp(OutputPage(title: '输出', text: text)));
    await tester.pump();
    expect(find.text('共 1 行 · 50,000 字'), findsOneWidget);
    final longest = tester
        .widgetList<RichText>(find.byType(RichText))
        .map((w) => w.text.toPlainText().length)
        .reduce((a, b) => a > b ? a : b);
    expect(longest, lessThanOrEqualTo(4000));
  });

  testWidgets('the full page keeps ANSI colours and copies plain text', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    await tester.pumpWidget(
      testApp(const OutputPage(title: '输出', text: 'ok\n\x1B[31mfailed\nhere\x1B[0m', ansi: true)),
    );
    await tester.pump();
    expect(find.text('failed', findRichText: true), findsOneWidget);
    expect(find.textContaining('\x1B', findRichText: true), findsNothing);
    // The red set on the second line is still on for the third, which is its own row.
    Color? colourOf(String row) {
      final span = tester.widget<RichText>(find.text(row, findRichText: true)).text;
      Color? colour;
      span.visitChildren((s) {
        if (s is TextSpan && s.text == row) colour = s.style?.color;
        return colour == null;
      });
      return colour;
    }

    expect(colourOf('failed'), isNotNull);
    expect(colourOf('here'), colourOf('failed'));
    expect(colourOf('ok'), isNot(colourOf('failed')));
    // Characters counted without the colour codes.
    expect(find.text('共 3 行 · 14 字'), findsOneWidget);
    await tester.tap(find.byTooltip('复制全文'));
    await tester.pump();
    expect(copied, 'ok\nfailed\nhere');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the full page splits an enormous coloured line too, colour kept', (tester) async {
    final text = '\x1B[31m${'ab\x1B[1mcd' * 20000}';
    await tester.pumpWidget(testApp(OutputPage(title: '输出', text: text, ansi: true)));
    await tester.pump();
    final rows = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText()).toList();
    final body = rows.where((r) => RegExp(r'^(ab|cd)').hasMatch(r)).toList();
    expect(body, isNotEmpty);
    // No row is the whole line, and no escape sequence was cut in half.
    expect(body.every((r) => r.length <= 4000 && RegExp(r'^[abcd]+$').hasMatch(r)), isTrue);
  });

  // Preparing the rows is one pass over the text. Done once per row or per cut
  // (which is what a search to the end of the text, or back to its start, amounts
  // to) these sizes would take minutes rather than a moment.
  testWidgets('opening the full page stays one pass over a huge output', (tester) async {
    final sparse = '\x1B[31monce\n${'plain line\n' * 300000}end';
    await tester.pumpWidget(testApp(OutputPage(title: '输出', text: sparse, ansi: true)));
    await tester.pump();
    expect(find.text('共 300,002 行 · 3,300,008 字'), findsOneWidget);

    final oneLine = '\x1B[32m${'x' * 8000000}';
    await tester.pumpWidget(testApp(OutputPage(key: UniqueKey(), title: '输出', text: oneLine, ansi: true)));
    await tester.pump();
    expect(find.text('共 1 行 · 8,000,000 字'), findsOneWidget);

    // Megabytes of digits after ESC[ are not a colour: plain text, in bounded rows.
    final runaway = '\x1B[${'1;' * 2000000}m tail';
    await tester.pumpWidget(testApp(OutputPage(key: UniqueKey(), title: '输出', text: runaway, ansi: true)));
    await tester.pump();
    final rows = tester.widgetList<RichText>(find.byType(RichText)).map((w) => w.text.toPlainText().length);
    expect(rows.every((length) => length <= 4000), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));
}
